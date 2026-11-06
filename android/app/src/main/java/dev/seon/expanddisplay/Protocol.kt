package dev.seon.expanddisplay

/** Wire protocol shared with the Mac app: [type: u8][length: u32 BE][payload]. */
object Proto {
    const val SERVICE_TYPE = "_expanddisplay._tcp"
    const val DEFAULT_PORT = 47800

    // Phone -> Mac
    const val CONFIG = 0x01           // i32 w, i32 h, i32 dpi, utf8 name
    const val TOUCH = 0x02            // u8 action, f32 x, f32 y (0..1)
    const val KEYFRAME_REQUEST = 0x03

    // Mac -> Phone
    const val VIDEO_CONFIG = 0x81     // i32 w, i32 h
    const val FRAME = 0x82            // u8 flags, i64 ptsUs, Annex-B H.264
    const val STATUS = 0x83           // utf8

    const val TOUCH_DOWN = 0
    const val TOUCH_MOVE = 1
    const val TOUCH_UP = 2
}

data class HostInfo(val name: String, val address: String, val port: Int)
