package dev.seon.expanddisplay

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import androidx.core.content.ContextCompat
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.MotionEvent
import android.view.Surface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.launch

sealed interface ConnState {
    data class Disconnected(val error: String? = null) : ConnState
    data class Connecting(val host: HostInfo) : ConnState
    data class Connected(val host: HostInfo) : ConnState
}

/** App-wide state holder: discovery, the active connection and auto-(re)connect. Main thread. */
class AppController(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val discovery = Discovery(context)

    private val _state = MutableStateFlow<ConnState>(ConnState.Disconnected())
    val state: StateFlow<ConnState> = _state
    private val _hasVideo = MutableStateFlow(false)
    val hasVideo: StateFlow<Boolean> = _hasVideo
    private val _status = MutableStateFlow<String?>(null)
    val status: StateFlow<String?> = _status
    private val _autoConnect = MutableStateFlow(true)
    val autoConnect: StateFlow<Boolean> = _autoConnect

    private var client: StreamClient? = null
    private val usbManager = context.getSystemService(UsbManager::class.java)
    /** The Mac's USB accessory while the cable is plugged in (USB takes priority over Wi-Fi). */
    private var usbAccessory: UsbAccessory? = null
    private val _usbAttached = MutableStateFlow(false)
    val usbAttached: StateFlow<Boolean> = _usbAttached

    private val usbReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            when (intent.action) {
                ACTION_USB_PERMISSION -> {
                    val acc = intent.accessoryExtra() ?: return
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        connectUsb(acc)
                    } else {
                        _status.value = "USB 권한이 거부되었습니다"
                    }
                }
                UsbManager.ACTION_USB_ACCESSORY_DETACHED -> {
                    val acc = intent.accessoryExtra()
                    if (acc == null || isOurAccessory(acc)) onUsbDetached()
                }
            }
        }
    }
    private var surface: Surface? = null
    private var surfaceW = 0
    private var surfaceH = 0
    private var autoJob: Job? = null

    // Wi-Fi power saving adds 50-200 ms latency spikes; the low-latency lock disables it while streaming.
    private val wifiLock: WifiManager.WifiLock =
        context.getSystemService(WifiManager::class.java).createWifiLock(
            WifiManager.WIFI_MODE_FULL_LOW_LATENCY, "expanddisplay-stream",
        ).apply { setReferenceCounted(false) }

    private val deviceName: String by lazy {
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"
    }

    fun start() {
        val filter = IntentFilter().apply {
            addAction(ACTION_USB_PERMISSION)
            addAction(UsbManager.ACTION_USB_ACCESSORY_DETACHED)
        }
        ContextCompat.registerReceiver(context, usbReceiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
        discovery.start()
        autoJob = scope.launch {
            combine(discovery.hosts, _state, _autoConnect) { hosts, st, auto -> Triple(hosts, st, auto) }
                .collect { (hosts, st, auto) ->
                    if (auto && usbAccessory == null && st is ConnState.Disconnected && hosts.isNotEmpty()) {
                        // Small back-off after a failure so we don't spin.
                        if (st.error != null) delay(1500)
                        if (_state.value is ConnState.Disconnected && _autoConnect.value && usbAccessory == null) {
                            discovery.hosts.value.firstOrNull()?.let { connect(it) }
                        }
                    }
                }
        }
    }

    fun stop() {
        runCatching { context.unregisterReceiver(usbReceiver) }
        disconnect(userInitiated = false)
        discovery.stop()
        scope.cancel()
    }

    fun setAutoConnect(enabled: Boolean) {
        _autoConnect.value = enabled
    }

    fun rescan() = discovery.restart()

    fun connect(host: HostInfo) {
        connect(host) { TcpLink(host.address, host.port) }
    }

    // ---- USB (Android Open Accessory) ----

    /** From the USB_ACCESSORY_ATTACHED launch intent (permission is implied). */
    fun handleIntent(intent: Intent?) {
        if (intent?.action == UsbManager.ACTION_USB_ACCESSORY_ATTACHED) {
            intent.accessoryExtra()?.takeIf { isOurAccessory(it) }?.let { connectUsb(it) }
        }
    }

    /** Pick up an already-attached accessory (e.g. app opened manually with the cable in). */
    fun checkUsb() {
        if (usbAccessory != null) return
        val acc = usbManager.accessoryList?.firstOrNull { isOurAccessory(it) } ?: return
        if (usbManager.hasPermission(acc)) {
            connectUsb(acc)
        } else {
            val intent = Intent(ACTION_USB_PERMISSION).setPackage(context.packageName)
            val flags = if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
            usbManager.requestPermission(acc, PendingIntent.getBroadcast(context, 0, intent, flags))
        }
    }

    /** Manual "connect over USB" from the UI. */
    fun reconnectUsb() {
        usbAccessory = null
        checkUsb()
    }

    private fun connectUsb(acc: UsbAccessory) {
        val current = _state.value
        if (usbAccessory == acc && (current is ConnState.Connected || current is ConnState.Connecting) &&
            client?.host?.address == USB_ADDRESS) return
        usbAccessory = acc
        _usbAttached.value = true
        connect(HostInfo("USB 케이블", USB_ADDRESS, 0)) { UsbLink(usbManager, acc) }
    }

    private fun onUsbDetached() {
        usbAccessory = null
        _usbAttached.value = false
        if (client?.host?.address == USB_ADDRESS) {
            val c = client
            client = null
            c?.close()
            runCatching { wifiLock.release() }
            _hasVideo.value = false
            // Falls back to Wi-Fi auto-connect.
            _state.value = ConnState.Disconnected("USB 케이블이 분리되었습니다")
        }
    }

    private fun isOurAccessory(acc: UsbAccessory) =
        acc.manufacturer == "seon0313" && acc.model == "ExpandDisplay"

    private fun connect(host: HostInfo, openLink: () -> Link) {
        client?.close()
        _hasVideo.value = false
        _status.value = null
        _state.value = ConnState.Connecting(host)
        val density = context.resources.displayMetrics.densityDpi
        lateinit var c: StreamClient
        c = StreamClient(host, openLink, deviceName, density, object : StreamClient.Callbacks {
            override fun onConnected() {
                main.post {
                    if (client === c) {
                        runCatching { wifiLock.acquire() }
                        _state.value = ConnState.Connected(host)
                        surface?.let { c.attachSurface(it, surfaceW, surfaceH) }
                    }
                }
            }

            override fun onDisconnected(error: String?) {
                main.post {
                    if (client === c) {
                        client = null
                        if (host.address == USB_ADDRESS) {
                            // e.g. the Mac app restarted: the cable is still in, so reopen the accessory.
                            usbAccessory = null
                            main.postDelayed({ if (client == null) checkUsb() }, 2000)
                        }
                        runCatching { wifiLock.release() }
                        _hasVideo.value = false
                        _state.value = ConnState.Disconnected(error ?: "연결이 종료되었습니다")
                    }
                }
            }

            override fun onStatus(message: String) {
                main.post { if (client === c) _status.value = message }
            }

            override fun onFirstFrame() {
                main.post { if (client === c) _hasVideo.value = true }
            }
        })
        client = c
        c.connect()
    }

    fun disconnect(userInitiated: Boolean) {
        if (userInitiated) _autoConnect.value = false
        val c = client
        client = null
        c?.close()
        runCatching { wifiLock.release() }
        _hasVideo.value = false
        _state.value = ConnState.Disconnected()
    }

    // ---- Called from the SurfaceView ----

    fun onSurface(s: Surface, width: Int, height: Int) {
        if (s !== surface && Build.VERSION.SDK_INT >= 30) {
            // Ask the display to run at a high refresh rate (Fold: 120 Hz) so frames are shown sooner.
            runCatching { s.setFrameRate(120f, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT) }
        }
        surface = s
        surfaceW = width
        surfaceH = height
        if (_state.value is ConnState.Connected) client?.attachSurface(s, width, height)
    }

    fun onSurfaceDestroyed() {
        surface = null
        client?.detachSurface()
    }

    fun onTouch(e: MotionEvent, viewW: Int, viewH: Int) {
        val c = client ?: return
        if (viewW <= 0 || viewH <= 0) return
        val action = when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> Proto.TOUCH_DOWN
            MotionEvent.ACTION_MOVE -> Proto.TOUCH_MOVE
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> Proto.TOUCH_UP
            else -> return // ignore extra fingers
        }
        val x = (e.getX(0) / viewW).coerceIn(0f, 1f)
        val y = (e.getY(0) / viewH).coerceIn(0f, 1f)
        c.sendTouch(action, x, y)
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "dev.seon.expanddisplay.USB_PERMISSION"
        const val USB_ADDRESS = "usb"
    }
}

@Suppress("DEPRECATION")
private fun Intent.accessoryExtra(): UsbAccessory? =
    if (Build.VERSION.SDK_INT >= 33) getParcelableExtra(UsbManager.EXTRA_ACCESSORY, UsbAccessory::class.java)
    else getParcelableExtra(UsbManager.EXTRA_ACCESSORY)
