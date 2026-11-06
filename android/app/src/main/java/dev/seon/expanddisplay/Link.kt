package dev.seon.expanddisplay

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import java.io.BufferedInputStream
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket

/** A byte pipe to the Mac: TCP over Wi-Fi, or a USB accessory (AOA) over the cable. */
interface Link {
    val input: InputStream
    val output: OutputStream
    fun close()
}

class TcpLink(address: String, port: Int) : Link {
    private val socket = Socket().apply {
        tcpNoDelay = true
        receiveBufferSize = 1 shl 20
        trafficClass = 0xB8 // DSCP EF: hint low-latency on Wi-Fi (WMM voice/video)
        connect(InetSocketAddress(address, port), 4000)
        keepAlive = true
    }
    override val input: InputStream = BufferedInputStream(socket.getInputStream(), 256 * 1024)
    override val output: OutputStream = socket.getOutputStream()
    override fun close() {
        runCatching { socket.close() }
    }
}

class UsbLink(usbManager: UsbManager, accessory: UsbAccessory) : Link {
    private val pfd = usbManager.openAccessory(accessory)
        ?: throw IOException("USB 액세서리를 열 수 없습니다 (권한 또는 다른 앱이 사용 중)")
    override val input: InputStream = AccessoryInputStream(FileInputStream(pfd.fileDescriptor))
    override val output: OutputStream = FileOutputStream(pfd.fileDescriptor)
    override fun close() {
        runCatching { pfd.close() }
    }
}

/**
 * The accessory driver requires every read() to ask for at least one full USB bulk buffer
 * (16 KB); smaller reads can drop data. Always read whole chunks and serve bytes from them.
 */
private class AccessoryInputStream(private val src: InputStream) : InputStream() {
    private val buf = ByteArray(16 * 1024 * 4)
    private var pos = 0
    private var lim = 0

    private fun fill(): Boolean {
        while (true) {
            val n = src.read(buf, 0, buf.size)
            if (n < 0) return false
            if (n > 0) {
                pos = 0
                lim = n
                return true
            }
        }
    }

    override fun read(): Int {
        if (pos >= lim && !fill()) return -1
        return buf[pos++].toInt() and 0xFF
    }

    override fun read(b: ByteArray, off: Int, len: Int): Int {
        if (len == 0) return 0
        if (pos >= lim && !fill()) return -1
        val n = minOf(len, lim - pos)
        System.arraycopy(buf, pos, b, off, n)
        pos += n
        return n
    }

    override fun available(): Int = lim - pos
}
