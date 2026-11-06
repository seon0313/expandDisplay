package dev.seon.expanddisplay

import android.util.Log
import android.view.Surface
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.concurrent.thread

/**
 * One TCP connection to the Mac. Receives H.264 frames and feeds them to a [VideoDecoder];
 * sends the window size and touch events back. Callbacks fire on background threads.
 */
class StreamClient(
    val host: HostInfo,
    private val deviceName: String,
    private val densityDpi: Int,
    private val callbacks: Callbacks,
) {
    interface Callbacks {
        fun onConnected()
        fun onDisconnected(error: String?)
        fun onStatus(message: String)
        fun onFirstFrame()
    }

    private var socket: Socket? = null
    @Volatile private var output: DataOutputStream? = null
    private val writer = Executors.newSingleThreadExecutor { r -> Thread(r, "stream-writer").apply { priority = Thread.MAX_PRIORITY } }
    private val closed = AtomicBoolean(false)
    private val notifiedDisconnect = AtomicBoolean(false)

    // Guarded by lock
    private val lock = Any()
    private var surface: Surface? = null
    private var viewW = 0
    private var viewH = 0
    private var videoW = 0
    private var videoH = 0
    private var decoder: VideoDecoder? = null
    private var waitingForKeyframe = true
    private var gotFirstFrame = false

    fun connect() {
        thread(name = "stream-reader", priority = Thread.MAX_PRIORITY) {
            var error: String? = null
            try {
                val s = Socket()
                s.tcpNoDelay = true
                s.receiveBufferSize = 1 shl 20
                s.trafficClass = 0xB8 // DSCP EF: hint low-latency on Wi-Fi (WMM voice/video)
                s.connect(InetSocketAddress(host.address, host.port), 4000)
                s.keepAlive = true
                socket = s
                output = DataOutputStream(BufferedOutputStream(s.getOutputStream(), 16 * 1024))
                if (closed.get()) return@thread
                callbacks.onConnected()
                synchronized(lock) { if (viewW > 0) sendConfigLocked() }
                readLoop(DataInputStream(BufferedInputStream(s.getInputStream(), 256 * 1024)))
            } catch (e: Exception) {
                if (!closed.get()) {
                    error = e.message ?: e.javaClass.simpleName
                    Log.w(TAG, "connection ended", e)
                }
            } finally {
                shutdown()
                if (notifiedDisconnect.compareAndSet(false, true)) callbacks.onDisconnected(error)
            }
        }
    }

    fun close() {
        shutdown()
    }

    private fun shutdown() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close() }
        writer.shutdownNow()
        synchronized(lock) {
            decoder?.release()
            decoder = null
        }
    }

    // ---- Surface / window size (main thread) ----

    fun attachSurface(s: Surface, width: Int, height: Int) {
        synchronized(lock) {
            if (s !== surface) {
                surface = s
                recreateDecoderLocked(askForKeyframe = true)
            }
            if (width != viewW || height != viewH) {
                viewW = width
                viewH = height
                sendConfigLocked()
            }
        }
    }

    fun detachSurface() {
        synchronized(lock) {
            surface = null
            decoder?.release()
            decoder = null
        }
    }

    // ---- Input ----

    fun sendTouch(action: Int, x: Float, y: Float) {
        val p = ByteBuffer.allocate(9).put(action.toByte()).putFloat(x).putFloat(y).array()
        send(Proto.TOUCH, p)
    }

    // ---- Internals ----

    private fun sendConfigLocked() {
        val name = deviceName.toByteArray(Charsets.UTF_8)
        val p = ByteBuffer.allocate(12 + name.size).putInt(viewW).putInt(viewH).putInt(densityDpi).put(name).array()
        send(Proto.CONFIG, p)
    }

    private fun requestKeyframe() = send(Proto.KEYFRAME_REQUEST, ByteArray(0))

    private fun send(type: Int, payload: ByteArray) {
        if (closed.get()) return
        try {
            writer.execute {
                val out = output ?: return@execute
                try {
                    out.writeByte(type)
                    out.writeInt(payload.size)
                    out.write(payload)
                    out.flush()
                } catch (e: Exception) {
                    shutdown()
                }
            }
        } catch (_: RejectedExecutionException) {
        }
    }

    private fun recreateDecoderLocked(askForKeyframe: Boolean) {
        decoder?.release()
        decoder = null
        val s = surface ?: return
        if (videoW <= 0 || videoH <= 0) return
        decoder = try {
            VideoDecoder(s, videoW, videoH)
        } catch (e: Exception) {
            Log.e(TAG, "decoder create failed", e)
            callbacks.onStatus("디코더 생성 실패: ${e.message}")
            null
        }
        waitingForKeyframe = true
        if (askForKeyframe) requestKeyframe()
    }

    private fun readLoop(input: DataInputStream) {
        var buf = ByteArray(512 * 1024)
        while (!closed.get()) {
            val type = input.readUnsignedByte()
            val len = input.readInt()
            if (len < 0 || len > 64 * 1024 * 1024) throw IllegalStateException("bad packet length $len")
            if (len > buf.size) buf = ByteArray(len + len / 2)
            input.readFully(buf, 0, len)
            when (type) {
                Proto.VIDEO_CONFIG -> {
                    val bb = ByteBuffer.wrap(buf, 0, len)
                    val w = bb.int
                    val h = bb.int
                    synchronized(lock) {
                        if (w == videoW && h == videoH && decoder?.broken == false) {
                            // Same size (e.g. bitrate/fps change on the Mac): keep the decoder and
                            // just resync on the next keyframe — no black flash.
                            waitingForKeyframe = true
                        } else {
                            videoW = w
                            videoH = h
                            recreateDecoderLocked(askForKeyframe = false)
                        }
                    }
                }
                Proto.FRAME -> handleFrame(buf, len)
                Proto.STATUS -> callbacks.onStatus(String(buf, 0, len, Charsets.UTF_8))
            }
        }
    }

    private fun handleFrame(buf: ByteArray, len: Int) {
        if (len < 9) return
        val key = (buf[0].toInt() and 1) != 0
        val pts = ByteBuffer.wrap(buf, 1, 8).long
        var first = false
        synchronized(lock) {
            var d = decoder ?: return
            if (d.broken) {
                recreateDecoderLocked(askForKeyframe = true)
                d = decoder ?: return
            }
            if (waitingForKeyframe && !key) return
            if (d.feed(buf, 9, len - 9, pts, key)) {
                waitingForKeyframe = false
                if (!gotFirstFrame) {
                    gotFirstFrame = true
                    first = true
                }
            } else {
                waitingForKeyframe = true
                requestKeyframe()
            }
        }
        if (first) callbacks.onFirstFrame()
    }

    companion object {
        private const val TAG = "StreamClient"
    }
}
