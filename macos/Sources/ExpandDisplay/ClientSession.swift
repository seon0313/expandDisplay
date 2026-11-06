import Foundation
import Network

/// One connected Android device (Wi-Fi or USB). I/O runs on `queue`; callbacks are delivered on main.
final class ClientSession {
    let transport: Transport
    let queue = DispatchQueue(label: "expanddisplay.session", qos: .userInteractive)

    var onConfig: ((_ width: Int, _ height: Int, _ dpi: Int, _ name: String) -> Void)?
    var onTouch: ((_ action: UInt8, _ x: Float, _ y: Float) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    /// Tunnelled TouchLink bytes. Called on `queue` (not main) for latency.
    var onTouchLink: ((Data) -> Void)?
    var onClose: (() -> Void)?

    private var buffer: [UInt8] = []
    private var closed = false

    var peerDescription: String { "\(transport.displayName) · \(transport.kind)" }
    var isUSB: Bool { transport is USBTransport }

    init(transport: Transport) {
        self.transport = transport
    }

    func start() {
        transport.start(queue: queue, onReceive: { [weak self] data in
            guard let self else { return }
            self.buffer.append(contentsOf: data)
            self.parse()
        }, onClose: { [weak self] in
            self?.handleClose()
        })
    }

    func close() {
        queue.async { self.handleClose() }
    }

    // MARK: Sending (any thread)

    func send(type: UInt8, payload: Data, completion: (() -> Void)? = nil) {
        var packet = Data(capacity: payload.count + 5)
        packet.append(type)
        packet.appendBE(UInt32(payload.count))
        packet.append(payload)
        transport.send(packet) { completion?() }
    }

    func sendVideoConfig(width: Int, height: Int, displayID: UInt32) {
        var p = Data()
        p.appendBE(Int32(width))
        p.appendBE(Int32(height))
        p.appendBE(displayID)
        send(type: Proto.videoConfig, payload: p)
    }

    func sendStatus(_ message: String) {
        send(type: Proto.status, payload: Data(message.utf8))
    }

    // MARK: Receiving

    private func parse() {
        var start = 0
        while buffer.count - start >= 5 {
            let type = buffer[start]
            let len = Int(buffer[start + 1]) << 24 | Int(buffer[start + 2]) << 16
                | Int(buffer[start + 3]) << 8 | Int(buffer[start + 4])
            if len > 1 << 20 { handleClose(); return } // garbage
            guard buffer.count - start >= 5 + len else { break }
            let payload = Array(buffer[(start + 5)..<(start + 5 + len)])
            start += 5 + len
            handle(type: type, payload: payload)
        }
        if start > 0 { buffer.removeFirst(start) }
    }

    private func handle(type: UInt8, payload: [UInt8]) {
        var r = ByteReader(payload)
        switch type {
        case Proto.config:
            guard let w = r.i32(), let h = r.i32(), let dpi = r.i32() else { return }
            let name = String(decoding: r.rest(), as: UTF8.self)
            DispatchQueue.main.async { self.onConfig?(Int(w), Int(h), Int(dpi), name.isEmpty ? "Android" : name) }
        case Proto.touch:
            guard let action = r.u8(), let x = r.f32(), let y = r.f32() else { return }
            DispatchQueue.main.async { self.onTouch?(action, x, y) }
        case Proto.touchLinkTunnel:
            onTouchLink?(Data(payload))
        case Proto.keyframeRequest:
            DispatchQueue.main.async { self.onKeyframeRequest?() }
        default:
            break
        }
    }

    private func handleClose() {
        if !closed {
            closed = true
            transport.cancel()
        }
        notifyClosedOnce()
    }

    private var notifiedClose = false
    private func notifyClosedOnce() {
        guard !notifiedClose else { return }
        notifiedClose = true
        DispatchQueue.main.async { self.onClose?() }
    }
}
