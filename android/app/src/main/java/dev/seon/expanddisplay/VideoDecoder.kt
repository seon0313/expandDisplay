package dev.seon.expanddisplay

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.util.Log
import android.view.Surface
import kotlin.concurrent.thread

/** Hardware H.264 decoder rendering straight to a Surface with minimal buffering. */
class VideoDecoder(surface: Surface, width: Int, height: Int) {
    private val codec: MediaCodec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_VIDEO_AVC)
    @Volatile private var running = true
    @Volatile var broken = false
        private set
    private val outThread: Thread

    init {
        val fmt = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            setInteger(MediaFormat.KEY_PRIORITY, 0) // realtime
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, 2 * 1024 * 1024))
            // Vendor low-latency switches (ignored where unsupported).
            setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
            setInteger("vendor.low-latency.enable", 1)
        }
        try {
            codec.configure(fmt, surface, null, 0)
        } catch (e: Exception) {
            // Some decoders reject unknown vendor keys — retry with the plain format.
            Log.w(TAG, "configure with vendor keys failed, retrying", e)
            codec.reset()
            val plain = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
                if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(width * height, 2 * 1024 * 1024))
            }
            codec.configure(plain, surface, null, 0)
        }
        codec.start()
        outThread = thread(name = "decoder-out", priority = Thread.MAX_PRIORITY) { drainLoop() }
    }

    /** Returns false if the frame could not be queued (caller should request a keyframe). */
    fun feed(data: ByteArray, offset: Int, length: Int, ptsUs: Long, keyframe: Boolean): Boolean {
        if (!running || broken) return false
        return try {
            val idx = codec.dequeueInputBuffer(30_000)
            if (idx < 0) return false
            val buf = codec.getInputBuffer(idx) ?: return false
            buf.clear()
            if (buf.capacity() < length) {
                codec.queueInputBuffer(idx, 0, 0, ptsUs, 0)
                return false
            }
            buf.put(data, offset, length)
            codec.queueInputBuffer(idx, 0, length, ptsUs, if (keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
            true
        } catch (e: Exception) {
            Log.w(TAG, "feed failed", e)
            broken = true
            false
        }
    }

    private fun drainLoop() {
        val info = MediaCodec.BufferInfo()
        while (running) {
            try {
                var idx = codec.dequeueOutputBuffer(info, 10_000)
                if (idx >= 0) {
                    // If several decoded frames piled up (e.g. a Wi-Fi burst), show only the newest:
                    // skipping stale frames keeps latency from accumulating.
                    while (true) {
                        val next = codec.dequeueOutputBuffer(info, 0)
                        if (next < 0) break
                        codec.releaseOutputBuffer(idx, false)
                        idx = next
                    }
                    // Render immediately; never wait for presentation time.
                    codec.releaseOutputBuffer(idx, true)
                }
            } catch (e: Exception) {
                if (running) {
                    Log.w(TAG, "drain failed", e)
                    broken = true
                }
                break
            }
        }
    }

    fun release() {
        running = false
        runCatching { outThread.join(300) }
        runCatching { codec.stop() }
        runCatching { codec.release() }
    }

    companion object {
        private const val TAG = "VideoDecoder"
    }
}
