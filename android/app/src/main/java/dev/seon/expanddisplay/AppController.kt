package dev.seon.expanddisplay

import android.content.Context
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
        discovery.start()
        autoJob = scope.launch {
            combine(discovery.hosts, _state, _autoConnect) { hosts, st, auto -> Triple(hosts, st, auto) }
                .collect { (hosts, st, auto) ->
                    if (auto && st is ConnState.Disconnected && hosts.isNotEmpty()) {
                        // Small back-off after a failure so we don't spin.
                        if (st.error != null) delay(1500)
                        if (_state.value is ConnState.Disconnected && _autoConnect.value) {
                            discovery.hosts.value.firstOrNull()?.let { connect(it) }
                        }
                    }
                }
        }
    }

    fun stop() {
        disconnect(userInitiated = false)
        discovery.stop()
        scope.cancel()
    }

    fun setAutoConnect(enabled: Boolean) {
        _autoConnect.value = enabled
    }

    fun rescan() = discovery.restart()

    fun connect(host: HostInfo) {
        client?.close()
        _hasVideo.value = false
        _status.value = null
        _state.value = ConnState.Connecting(host)
        val density = context.resources.displayMetrics.densityDpi
        lateinit var c: StreamClient
        c = StreamClient(host, deviceName, density, object : StreamClient.Callbacks {
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
}
