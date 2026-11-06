import Foundation

/// TouchLink v1 — little-endian, 20-byte header.
enum TL {
    static let magic: UInt16 = 0x4C54          // bytes 'T','L'
    static let version: UInt8 = 1
    static let headerSize = 20
    static let port: UInt16 = 47100
    static let serviceType = "_touchlink._tcp"
    static let maxRateHz: UInt16 = 120

    enum MsgType: UInt8 {
        case hello = 0x01
        case helloAck = 0x02
        case displayList = 0x03
        case selectDisplay = 0x04
        case config = 0x05
        case touchFrame = 0x10
        case ping = 0x20
        case pong = 0x21
        case bye = 0x7F
    }

    enum Phase: UInt8 {
        case began = 0, moved = 1, stationary = 2, ended = 3, cancelled = 4
    }

    enum HelloResult: UInt8 {
        case ok = 0, pairingFailed = 1, versionMismatch = 2
    }

    static func monotonicMicros() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1000
    }
}

struct TLHeader {
    let version: UInt8
    let type: UInt8
    let payloadLength: Int
    let flags: UInt16
    let seq: UInt32
    let timestampUs: UInt64
}

struct TLContact {
    let id: UInt8
    let phase: UInt8
    let x: UInt16
    let y: UInt16
    let pressure: UInt8
    let radius: UInt8
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var le = v.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}

struct LEReader {
    private let b: [UInt8]
    private(set) var offset = 0
    init(_ bytes: [UInt8]) { b = bytes }
    var remaining: Int { b.count - offset }

    private mutating func read<T: FixedWidthInteger>(_: T.Type) -> T? {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { return nil }
        var v: T = 0
        for i in 0..<n { v |= T(b[offset + i]) << (8 * i) }
        offset += n
        return v
    }
    mutating func u8() -> UInt8? { read(UInt8.self) }
    mutating func u16() -> UInt16? { read(UInt16.self) }
    mutating func u32() -> UInt32? { read(UInt32.self) }
    mutating func u64() -> UInt64? { read(UInt64.self) }
    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard n >= 0, remaining >= n else { return nil }
        defer { offset += n }
        return Array(b[offset..<(offset + n)])
    }
}

enum TLError: Error { case badMagic, tooLarge }

/// Incremental parser for a byte stream of TouchLink messages.
struct TLParser {
    private var buffer: [UInt8] = []

    mutating func feed(_ data: Data) throws -> [(TLHeader, [UInt8])] {
        buffer.append(contentsOf: data)
        var out: [(TLHeader, [UInt8])] = []
        var start = 0
        while buffer.count - start >= TL.headerSize {
            var r = LEReader(Array(buffer[start..<(start + TL.headerSize)]))
            guard let magic = r.u16(), magic == TL.magic else { throw TLError.badMagic }
            let version = r.u8()!, type = r.u8()!
            let len = Int(r.u16()!)
            let flags = r.u16()!, seq = r.u32()!, ts = r.u64()!
            guard buffer.count - start >= TL.headerSize + len else { break }
            let payload = Array(buffer[(start + TL.headerSize)..<(start + TL.headerSize + len)])
            out.append((TLHeader(version: version, type: type, payloadLength: len, flags: flags, seq: seq, timestampUs: ts), payload))
            start += TL.headerSize + len
        }
        if start > 0 { buffer.removeFirst(start) }
        if buffer.count > 1 << 20 { throw TLError.tooLarge }
        return out
    }
}

struct TLEncoder {
    private var seq: UInt32 = 0

    mutating func message(_ type: TL.MsgType, _ payload: Data = Data()) -> Data {
        seq &+= 1
        var d = Data(capacity: TL.headerSize + payload.count)
        d.appendLE(TL.magic)
        d.append(TL.version)
        d.append(type.rawValue)
        d.appendLE(UInt16(payload.count))
        d.appendLE(UInt16(0))
        d.appendLE(seq)
        d.appendLE(TL.monotonicMicros())
        d.append(payload)
        return d
    }
}
