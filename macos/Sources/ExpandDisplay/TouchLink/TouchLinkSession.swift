import CoreGraphics
import Foundation

/// One TouchLink client (over its own TCP socket, or tunnelled inside the ExpandDisplay USB link).
final class TouchLinkSession {
    let peer: String
    /// Physically attached (USB) links skip pairing.
    let trusted: Bool
    let queue = DispatchQueue(label: "expanddisplay.touchlink", qos: .userInteractive)
    let engine: GestureEngine
    let sessionID = UInt32.random(in: 1...UInt32.max)

    private(set) var authenticated = false
    private(set) var deviceName = ""
    private var parser = TLParser()
    private var encoder = TLEncoder()
    private let sendRaw: (Data) -> Void
    private let closeTransport: () -> Void
    private var closed = false

    init(peer: String, trusted: Bool, send: @escaping (Data) -> Void, close: @escaping () -> Void) {
        self.peer = peer
        self.trusted = trusted
        self.sendRaw = send
        self.closeTransport = close
        self.engine = GestureEngine(queue: queue)
    }

    func receive(_ data: Data) {
        queue.async { [self] in
            guard !closed else { return }
            do {
                for (h, payload) in try parser.feed(data) { handle(h, payload) }
            } catch {
                close(reason: 1)
            }
        }
    }

    /// Transport went away.
    func transportClosed() {
        queue.async { [self] in
            guard !closed else { return }
            closed = true
            engine.cancelAll()
            TouchLinkHub.shared.unregister(self)
        }
    }

    func close(reason: UInt8 = 0) {
        queue.async { [self] in
            guard !closed else { return }
            send(.bye, Data([reason]))
            closed = true
            engine.cancelAll()
            TouchLinkHub.shared.unregister(self)
            closeTransport()
        }
    }

    func sendDisplayList() {
        queue.async { [self] in
            guard authenticated, !closed else { return }
            send(.displayList, Self.displayListPayload())
        }
    }

    // MARK: - Private (on queue)

    private func send(_ type: TL.MsgType, _ payload: Data = Data()) {
        sendRaw(encoder.message(type, payload))
    }

    private func handle(_ h: TLHeader, _ p: [UInt8]) {
        var r = LEReader(p)
        if h.type == TL.MsgType.hello.rawValue {
            handleHello(h, &r)
            return
        }
        if h.version != TL.version { close(reason: 2); return }

        switch TL.MsgType(rawValue: h.type) {
        case .ping:
            var echo = Data()
            echo.appendLE(h.timestampUs)
            send(.pong, echo)
        case .pong:
            break
        case .bye:
            closed = true
            engine.cancelAll()
            TouchLinkHub.shared.unregister(self)
            closeTransport()
        case .selectDisplay:
            guard authenticated, let id = r.u32(), let x0 = r.u16(), let y0 = r.u16(),
                  let x1 = r.u16(), let y1 = r.u16() else { return }
            engine.select(display: id, x0: x0, y0: y0, x1: x1, y1: y1)
        case .config:
            guard authenticated, let mode = r.u8(), let lp = r.u16(), let inv = r.u8() else { return }
            engine.config = .init(mode: mode, longPressMs: Int(max(lp, 100)), invertScroll: inv != 0)
        case .touchFrame:
            guard authenticated, let count = r.u8(), r.u8() != nil else { return }
            var contacts: [TLContact] = []
            contacts.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let id = r.u8(), let phase = r.u8(), let x = r.u16(), let y = r.u16(),
                      let pr = r.u8(), let rad = r.u8() else { break }
                contacts.append(TLContact(id: id, phase: phase, x: x, y: y, pressure: pr, radius: rad))
            }
            engine.handle(frame: contacts)
        default:
            break // unknown / not valid in this direction
        }
    }

    private func handleHello(_ h: TLHeader, _ r: inout LEReader) {
        guard h.version == TL.version else {
            sendAck(.versionMismatch)
            close(reason: 2)
            return
        }
        guard let code = r.u32(), r.u16() != nil, r.u16() != nil, r.u8() != nil, r.u16() != nil,
              let nameLen = r.u8() else { close(reason: 1); return }
        let name = String(decoding: r.bytes(Int(nameLen)) ?? [], as: UTF8.self)

        let ok = trusted || TouchLinkPairing.shared.verify(code: code, peer: peer)
        sendAck(ok ? .ok : .pairingFailed)
        guard ok else { return } // the client may retry HELLO with another code
        authenticated = true
        deviceName = name.isEmpty ? peer : name
        TouchLinkHub.shared.register(self)
        send(.displayList, Self.displayListPayload())
    }

    private func sendAck(_ result: TL.HelloResult) {
        var d = Data()
        d.append(result.rawValue)
        d.appendLE(sessionID)
        d.appendLE(TL.maxRateHz)
        send(.helloAck, d)
    }

    static func displayListPayload() -> Data {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let list = ids.prefix(Int(count)).prefix(255)
        var d = Data()
        d.append(UInt8(list.count))
        for id in list {
            let b = CGDisplayBounds(id)
            var scale: UInt8 = 1
            if let m = CGDisplayCopyDisplayMode(id), m.width > 0 {
                scale = UInt8(clamping: Int((Double(m.pixelWidth) / Double(m.width)).rounded()))
            }
            d.appendLE(UInt32(id))
            d.appendLE(UInt16(clamping: Int(b.width)))
            d.appendLE(UInt16(clamping: Int(b.height)))
            d.append(max(scale, 1))
            d.append(id == CGMainDisplayID() ? 1 : 0)
        }
        return d
    }
}

/// §7 pairing: a 6-digit code shown in the menu bar; 3 failures → reject that peer for 1 minute.
final class TouchLinkPairing {
    static let shared = TouchLinkPairing()
    private let lock = NSLock()
    private var failures: [String: (count: Int, until: Date)] = [:]

    private(set) var code: String {
        get { UserDefaults.standard.string(forKey: "touchlinkCode") ?? regenerate() }
        set { UserDefaults.standard.set(newValue, forKey: "touchlinkCode") }
    }

    @discardableResult
    func regenerate() -> String {
        let c = String(format: "%06d", Int.random(in: 0...999_999))
        UserDefaults.standard.set(c, forKey: "touchlinkCode")
        return c
    }

    func verify(code given: UInt32, peer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let f = failures[peer], f.until > Date() { return false }
        if given == UInt32(code) ?? UInt32.max {
            failures[peer] = nil
            return true
        }
        var f = failures[peer] ?? (0, .distantPast)
        f.count += 1
        if f.count >= 3 {
            f = (0, Date().addingTimeInterval(60))
        }
        failures[peer] = f
        return false
    }
}

/// Tracks authenticated sessions for the menu bar and display-change broadcasts.
final class TouchLinkHub {
    static let shared = TouchLinkHub()
    private let lock = NSLock()
    private var sessions: [ObjectIdentifier: (session: TouchLinkSession, name: String)] = [:]
    /// Main thread.
    var onChange: (([String]) -> Void)?

    func register(_ s: TouchLinkSession) {
        lock.lock()
        sessions[ObjectIdentifier(s)] = (s, "\(s.deviceName)\(s.trusted ? " · USB" : "")")
        lock.unlock()
        notify()
    }

    func unregister(_ s: TouchLinkSession) {
        lock.lock()
        sessions[ObjectIdentifier(s)] = nil
        lock.unlock()
        notify()
    }

    func displaysChanged() {
        lock.lock(); let all = sessions.values.map(\.session); lock.unlock()
        all.forEach { $0.sendDisplayList() }
    }

    func disconnectAll() {
        lock.lock(); let all = sessions.values.map(\.session); lock.unlock()
        all.forEach { $0.close(reason: 0) }
    }

    private func notify() {
        lock.lock(); let names = sessions.values.map(\.name).sorted(); lock.unlock()
        DispatchQueue.main.async { self.onChange?(names) }
    }
}
