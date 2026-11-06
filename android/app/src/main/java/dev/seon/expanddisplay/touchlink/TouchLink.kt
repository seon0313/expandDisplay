package dev.seon.expanddisplay.touchlink

import android.os.SystemClock
import android.util.Log
import java.io.BufferedInputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/** TouchLink v1 constants (all integers little-endian). */
object TL {
    const val MAGIC = 0x4C54
    const val VERSION = 1
    const val HEADER = 20
    const val PORT = 47100
    const val SERVICE = "_touchlink._tcp"

    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val DISPLAY_LIST = 0x03
    const val SELECT_DISPLAY = 0x04
    const val CONFIG = 0x05
    const val TOUCH_FRAME = 0x10
    const val PING = 0x20
    const val PONG = 0x21
    const val BYE = 0x7F

    const val BEGAN = 0
    const val MOVED = 1
    const val STATIONARY = 2
    const val ENDED = 3
    const val CANCELLED = 4

    const val RESULT_OK = 0
    const val RESULT_PAIRING_FAILED = 1
    const val RESULT_VERSION_MISMATCH = 2

    fun nowMicros(): Long = SystemClock.elapsedRealtimeNanos() / 1000
}

data class TLDisplay(val id: Long, val widthPt: Int, val heightPt: Int, val scale: Int, val isMain: Boolean)

private fun le(size: Int): ByteBuffer = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN)

/** Incremental stream parser. */
private class TLParser {
    private var buf = ByteArray(4096)
    private var len = 0

    fun feed(data: ByteArray, off: Int, n: Int, onMessage: (type: Int, version: Int, ts: Long, payload: ByteBuffer) -> Unit) {
        if (len + n > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, len + n))
        System.arraycopy(data, off, buf, len, n)
        len += n
        var start = 0
        while (len - start >= TL.HEADER) {
            val h = ByteBuffer.wrap(buf, start, TL.HEADER).order(ByteOrder.LITTLE_ENDIAN)
            val magic = h.short.toInt() and 0xFFFF
            if (magic != TL.MAGIC) throw IllegalStateException("bad TouchLink magic")
            val version = h.get().toInt() and 0xFF
            val type = h.get().toInt() and 0xFF
            val plen = h.short.toInt() and 0xFFFF
            h.short // flags
            h.int // seq
            val ts = h.long
            if (len - start < TL.HEADER + plen) break
            val payload = ByteBuffer.wrap(buf.copyOfRange(start + TL.HEADER, start + TL.HEADER + plen))
                .order(ByteOrder.LITTLE_ENDIAN)
            start += TL.HEADER + plen
            onMessage(type, version, ts, payload)
        }
        if (start > 0) {
            System.arraycopy(buf, start, buf, 0, len - start)
            len -= start
        }
    }
}

/**
 * TouchLink client state: HELLO/pairing, display selection, config, frames, ping/pong.
 * Transport-agnostic: give it a sender and feed it received bytes.
 */
class TouchLinkClient(
    private val sendBytes: (ByteArray) -> Unit,
    private val listener: Listener,
) {
    interface Listener {
        fun onHelloAck(result: Int, codeUsed: Int)
        fun onDisplays(displays: List<TLDisplay>)
        fun onBye()
    }

    private val parser = TLParser()
    private var seq = 0
    private var lastCode = 0

    @Volatile var authenticated = false
        private set
    @Volatile var maxRateHz = 120
        private set
    @Volatile var displays: List<TLDisplay> = emptyList()
        private set
    private var targetId: Long? = null
    private var mode = 0
    private var longPressMs = 500
    private var invertScroll = false

    @Synchronized
    private fun send(type: Int, payload: ByteArray = ByteArray(0)) {
        val b = le(TL.HEADER + payload.size)
            .putShort(TL.MAGIC.toShort())
            .put(TL.VERSION.toByte())
            .put(type.toByte())
            .putShort(payload.size.toShort())
            .putShort(0)
            .putInt(seq++)
            .putLong(TL.nowMicros())
            .put(payload)
        sendBytes(b.array())
    }

    fun hello(pairCode: Int, screenW: Int, screenH: Int, name: String) {
        lastCode = pairCode
        val n = name.toByteArray(Charsets.UTF_8).let { if (it.size > 255) it.copyOf(255) else it }
        val p = le(4 + 2 + 2 + 1 + 2 + 1 + n.size)
            .putInt(pairCode)
            .putShort(screenW.coerceIn(0, 65535).toShort())
            .putShort(screenH.coerceIn(0, 65535).toShort())
            .put(10.toByte())
            .putShort(120.toShort())
            .put(n.size.toByte())
            .put(n)
        send(TL.HELLO, p.array())
    }

    @Synchronized
    fun feed(data: ByteArray, off: Int = 0, n: Int = data.size) {
        parser.feed(data, off, n) { type, version, ts, p -> handle(type, version, ts, p) }
    }

    private fun handle(type: Int, version: Int, ts: Long, p: ByteBuffer) {
        when (type) {
            TL.HELLO_ACK -> {
                val result = p.get().toInt() and 0xFF
                p.int // session id
                maxRateHz = (p.short.toInt() and 0xFFFF).coerceIn(1, 1000)
                authenticated = result == TL.RESULT_OK && version == TL.VERSION
                if (authenticated) {
                    sendConfig()
                    sendSelect()
                }
                listener.onHelloAck(result, lastCode)
            }
            TL.DISPLAY_LIST -> {
                val count = p.get().toInt() and 0xFF
                val list = ArrayList<TLDisplay>(count)
                repeat(count) {
                    if (p.remaining() < 10) return@repeat
                    list += TLDisplay(
                        id = p.int.toLong() and 0xFFFFFFFFL,
                        widthPt = p.short.toInt() and 0xFFFF,
                        heightPt = p.short.toInt() and 0xFFFF,
                        scale = p.get().toInt() and 0xFF,
                        isMain = p.get().toInt() != 0,
                    )
                }
                displays = list
                sendSelect()
                listener.onDisplays(list)
            }
            TL.PING -> send(TL.PONG, le(8).putLong(ts).array())
            TL.BYE -> {
                authenticated = false
                listener.onBye()
            }
        }
    }

    fun setTarget(displayId: Long) {
        targetId = displayId
        sendSelect()
    }

    fun setConfig(mode: Int, longPressMs: Int = 500, invertScroll: Boolean = false) {
        this.mode = mode
        this.longPressMs = longPressMs
        this.invertScroll = invertScroll
        sendConfig()
    }

    private fun sendConfig() {
        if (!authenticated) return
        send(TL.CONFIG, le(4).put(mode.toByte()).putShort(longPressMs.toShort()).put(if (invertScroll) 1 else 0).array())
    }

    private fun sendSelect() {
        val id = targetId ?: return
        if (!authenticated) return
        send(TL.SELECT_DISPLAY, le(12).putInt(id.toInt()).putShort(0).putShort(0)
            .putShort(0xFFFF.toShort()).putShort(0xFFFF.toShort()).array())
    }

    fun sendFrame(payload: ByteArray) {
        if (authenticated) send(TL.TOUCH_FRAME, payload)
    }

    fun bye(reason: Int = 0) {
        if (authenticated) send(TL.BYE, byteArrayOf(reason.toByte()))
        authenticated = false
    }

    fun displaySize(): Pair<Int, Int>? {
        val id = targetId
        val d = displays.firstOrNull { it.id == id } ?: displays.firstOrNull { it.isMain } ?: return null
        return d.widthPt to d.heightPt
    }
}

/** Plain TCP transport to the Mac's TouchLink port (TCP_NODELAY). Callbacks on background threads. */
class TouchLinkTcp(
    private val host: String,
    private val port: Int,
    private val onConnected: () -> Unit,
    private val onBytes: (ByteArray, Int) -> Unit,
    private val onClosed: () -> Unit,
) {
    private var socket: Socket? = null
    @Volatile private var out: OutputStream? = null
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "touchlink-writer").apply { priority = Thread.MAX_PRIORITY } }
    private val closed = AtomicBoolean(false)

    fun start() {
        thread(name = "touchlink-reader", priority = Thread.MAX_PRIORITY) {
            try {
                val s = Socket()
                s.tcpNoDelay = true
                s.trafficClass = 0xB8
                s.connect(InetSocketAddress(host, port), 3000)
                socket = s
                out = s.getOutputStream()
                if (closed.get()) return@thread
                onConnected()
                val input = BufferedInputStream(s.getInputStream(), 16 * 1024)
                val buf = ByteArray(16 * 1024)
                while (!closed.get()) {
                    val n = input.read(buf)
                    if (n < 0) break
                    if (n > 0) onBytes(buf, n)
                }
            } catch (e: Exception) {
                if (!closed.get()) Log.w("TouchLinkTcp", "ended", e)
            } finally {
                close()
                onClosed()
            }
        }
    }

    fun send(bytes: ByteArray) {
        if (closed.get()) return
        try {
            writer.execute {
                try {
                    out?.write(bytes)
                } catch (e: Exception) {
                    close()
                }
            }
        } catch (_: RejectedExecutionException) {
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        writer.shutdown()
    }
}
