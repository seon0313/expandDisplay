import Foundation

/// Wire protocol (both directions): [type: u8][length: u32 BE][payload]
enum Proto {
    static let serviceType = "_expanddisplay._tcp"
    static let defaultPort: UInt16 = 47800

    // Client (Android) -> Server (Mac)
    static let config: UInt8 = 0x01        // i32 width, i32 height, i32 dpi, utf8 deviceName
    static let touch: UInt8 = 0x02         // u8 action(0 down,1 move,2 up), f32 x, f32 y (normalized 0..1)
    static let keyframeRequest: UInt8 = 0x03

    // Server -> Client
    static let videoConfig: UInt8 = 0x81   // i32 width, i32 height
    static let frame: UInt8 = 0x82         // u8 flags(bit0 = keyframe), i64 ptsUs, Annex-B H.264
    static let status: UInt8 = 0x83        // utf8 message
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - offset }

    mutating func u8() -> UInt8? {
        guard remaining >= 1 else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(bytes[offset + i]) }
        offset += 4
        return v
    }
    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    mutating func rest() -> [UInt8] {
        defer { offset = bytes.count }
        return Array(bytes[offset...])
    }
}
