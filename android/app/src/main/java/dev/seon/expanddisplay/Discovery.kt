package dev.seon.expanddisplay

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.net.Inet4Address
import java.util.ArrayDeque

/** Finds Macs running ExpandDisplay on the local network via mDNS / DNS-SD (Bonjour). */
class Discovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val multicastLock = context.applicationContext.getSystemService(WifiManager::class.java)
        .createMulticastLock("expanddisplay-mdns").apply { setReferenceCounted(false) }

    private val _hosts = MutableStateFlow<List<HostInfo>>(emptyList())
    val hosts: StateFlow<List<HostInfo>> = _hosts

    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var listener: NsdManager.DiscoveryListener? = null
    private val lock = Any()

    fun start() {
        if (listener != null) return
        multicastLock.acquire()
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                Log.w(TAG, "discovery start failed $errorCode")
                synchronized(lock) { listener = null }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                synchronized(lock) {
                    resolveQueue.add(info)
                    if (!resolving) resolveNext()
                }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                _hosts.value = _hosts.value.filterNot { it.name == info.serviceName }
            }
        }
        listener = l
        try {
            nsd.discoverServices(Proto.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (e: Exception) {
            Log.w(TAG, "discoverServices", e)
            listener = null
        }
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        runCatching { multicastLock.release() }
    }

    /** Restart discovery, e.g. after the network changed. */
    fun restart() {
        stop()
        _hosts.value = emptyList()
        start()
    }

    // Must hold lock.
    private fun resolveNext() {
        val info = resolveQueue.poll()
        if (info == null) {
            resolving = false
            return
        }
        resolving = true
        @Suppress("DEPRECATION")
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                Log.w(TAG, "resolve failed ${serviceInfo.serviceName} $errorCode")
                synchronized(lock) { resolveNext() }
            }

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                val addr = addressOf(serviceInfo)
                if (addr != null) {
                    val host = HostInfo(serviceInfo.serviceName, addr, serviceInfo.port)
                    _hosts.value = _hosts.value.filterNot { it.name == host.name } + host
                }
                synchronized(lock) { resolveNext() }
            }
        })
    }

    private fun addressOf(info: NsdServiceInfo): String? {
        val addrs = if (Build.VERSION.SDK_INT >= 34) {
            info.hostAddresses
        } else {
            @Suppress("DEPRECATION")
            listOfNotNull(info.host)
        }
        val best = addrs.firstOrNull { it is Inet4Address } ?: addrs.firstOrNull()
        return best?.hostAddress?.substringBefore('%')
    }

    companion object {
        private const val TAG = "Discovery"
    }
}
