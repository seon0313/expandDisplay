import AppKit
import CoreGraphics

/// TouchLink §6: turns contact frames into CGEvents (taps, drags, long-press right click, scrolling).
/// Runs entirely on `queue`.
final class GestureEngine {
    struct Config {
        var mode: UInt8 = 0            // 0 pointer, 1 system-compatible (one-finger drag scrolls)
        var longPressMs: Int = 500
        var invertScroll = false
    }

    private enum State {
        case idle
        case pending(id: UInt8, start: CGPoint, t0: TimeInterval)
        case leftDrag(id: UInt8)
        case rightDrag(id: UInt8)
        case oneScroll(id: UInt8, last: CGPoint)
        case twoScroll(last: CGPoint)
        case waitAllUp
    }

    static let slop: CGFloat = 10
    static let secondFingerWait: TimeInterval = 0.050
    static let frameTimeout: TimeInterval = 0.500
    static let doubleTapDistance: CGFloat = 10

    let queue: DispatchQueue
    var config = Config()

    private var displayID: CGDirectDisplayID = CGMainDisplayID()
    private var region = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var contacts: [UInt8: CGPoint] = [:]
    private var order: [UInt8] = []
    private var state: State = .idle
    private var lastFrame: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint = CGPoint(x: -1e6, y: -1e6)
    private var clickState: Int64 = 0
    private var scrollRemainder = CGPoint.zero
    private var lastPoint = CGPoint.zero
    private let source = CGEventSource(stateID: .hidSystemState)

    init(queue: DispatchQueue) { self.queue = queue }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Configuration

    func select(display: CGDirectDisplayID, x0: UInt16, y0: UInt16, x1: UInt16, y1: UInt16) {
        displayID = display
        let fx0 = CGFloat(x0) / 65535, fy0 = CGFloat(y0) / 65535
        let fx1 = CGFloat(x1) / 65535, fy1 = CGFloat(y1) / 65535
        if fx1 > fx0, fy1 > fy0 {
            region = CGRect(x: fx0, y: fy0, width: fx1 - fx0, height: fy1 - fy0)
        } else {
            region = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    // §5: phone-normalized → global CG points (top-left origin, y down, points).
    private func point(_ x: UInt16, _ y: UInt16) -> CGPoint {
        var b = CGDisplayBounds(displayID)
        if b.isEmpty { b = CGDisplayBounds(CGMainDisplayID()) }
        let nx = CGFloat(x) / 65535, ny = CGFloat(y) / 65535
        let px = b.minX + (region.minX + nx * region.width) * b.width
        let py = b.minY + (region.minY + ny * region.height) * b.height
        return CGPoint(x: min(max(px, b.minX), b.maxX - 1), y: min(max(py, b.minY), b.maxY - 1))
    }

    // MARK: Frames

    func handle(frame: [TLContact]) {
        lastFrame = now
        for c in frame {
            let p = point(c.x, c.y)
            switch TL.Phase(rawValue: c.phase) {
            case .began:
                if contacts[c.id] != nil {
                    contacts[c.id] = p
                    moved(c.id, p)
                } else {
                    add(c.id, p)
                    began(c.id, p)
                }
            case .moved, .stationary:
                if contacts[c.id] == nil {
                    // Lost BEGAN (shouldn't happen) — treat as a new touch.
                    add(c.id, p)
                    began(c.id, p)
                } else if c.phase == TL.Phase.moved.rawValue {
                    contacts[c.id] = p
                    moved(c.id, p)
                }
            case .ended:
                guard contacts[c.id] != nil else { continue }
                contacts[c.id] = p
                moved(c.id, p)
                remove(c.id)
                ended(c.id, p)
            case .cancelled:
                guard contacts[c.id] != nil else { continue }
                remove(c.id)
                endGesture()
                state = contacts.isEmpty ? .idle : .waitAllUp
            case .none:
                break
            }
        }
        updateTimer()
    }

    /// Connection lost / timeout: release everything.
    func cancelAll() {
        endGesture()
        contacts.removeAll()
        order.removeAll()
        state = .idle
        updateTimer()
    }

    private func add(_ id: UInt8, _ p: CGPoint) {
        contacts[id] = p
        order.append(id)
    }

    private func remove(_ id: UInt8) {
        contacts[id] = nil
        order.removeAll { $0 == id }
    }

    private func centroid() -> CGPoint {
        let pts = order.prefix(2).compactMap { contacts[$0] }
        guard !pts.isEmpty else { return lastPoint }
        return CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                       y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
    }

    // MARK: Gesture state machine (§6 판정 순서)

    private func began(_ id: UInt8, _ p: CGPoint) {
        switch state {
        case .idle:
            state = .pending(id: id, start: p, t0: now)            // 1. store only
        case let .pending(_, _, t0):
            if now - t0 <= Self.secondFingerWait, contacts.count >= 2 { // 2. second finger → scroll
                let c = centroid()
                post(.mouseMoved, c)
                scrollRemainder = .zero
                scroll(phase: 1, delta: .zero)
                state = .twoScroll(last: c)
            }
        default:
            break
        }
    }

    private func moved(_ id: UInt8, _ p: CGPoint) {
        switch state {
        case let .pending(pid, start, _) where pid == id:
            guard hypot(p.x - start.x, p.y - start.y) > Self.slop else { return } // 3. slop
            if config.mode == 0 {
                post(.mouseMoved, start)
                post(.leftMouseDown, start, click: 1)
                post(.leftMouseDragged, p, click: 1)
                state = .leftDrag(id: id)
            } else {
                post(.mouseMoved, start)
                scrollRemainder = .zero
                scroll(phase: 1, delta: .zero)
                scroll(phase: 2, delta: CGPoint(x: p.x - start.x, y: p.y - start.y))
                state = .oneScroll(id: id, last: p)
            }
        case let .leftDrag(did) where did == id:
            post(.leftMouseDragged, p, click: 1)
        case let .rightDrag(did) where did == id:
            post(.rightMouseDragged, p, button: .right)
        case let .oneScroll(sid, last) where sid == id:
            scroll(phase: 2, delta: CGPoint(x: p.x - last.x, y: p.y - last.y))
            state = .oneScroll(id: id, last: p)
        case let .twoScroll(last):
            guard contacts.count >= 2 else { return }
            let c = centroid()
            scroll(phase: 2, delta: CGPoint(x: c.x - last.x, y: c.y - last.y))
            state = .twoScroll(last: c)
        default:
            break
        }
    }

    /// Called after the contact has been removed.
    private func ended(_ id: UInt8, _ p: CGPoint) {
        let rest: State = contacts.isEmpty ? .idle : .waitAllUp
        switch state {
        case let .pending(pid, start, _) where pid == id:
            tap(at: start)                                          // 5. tap
            state = rest
        case let .leftDrag(did) where did == id:
            post(.leftMouseUp, p, click: 1)
            state = rest
        case let .rightDrag(did) where did == id:
            post(.rightMouseUp, p, button: .right)
            state = rest
        case let .oneScroll(sid, _) where sid == id:
            scroll(phase: 4, delta: .zero)
            state = rest
        case .twoScroll:
            scroll(phase: 4, delta: .zero)                          // 6. one finger lifted
            state = rest
        default:
            if contacts.isEmpty { state = .idle }
        }
    }

    private func endGesture() {
        switch state {
        case .leftDrag: post(.leftMouseUp, lastPoint, click: 1)
        case .rightDrag: post(.rightMouseUp, lastPoint, button: .right)
        case .oneScroll, .twoScroll: scroll(phase: 4, delta: .zero)
        default: break
        }
    }

    private func tap(at p: CGPoint) {
        let t = now
        if t - lastTapTime <= NSEvent.doubleClickInterval,
           hypot(p.x - lastTapPoint.x, p.y - lastTapPoint.y) <= Self.doubleTapDistance {
            clickState += 1
        } else {
            clickState = 1
        }
        post(.mouseMoved, p)
        post(.leftMouseDown, p, click: clickState)
        post(.leftMouseUp, p, click: clickState)
        lastTapTime = t
        lastTapPoint = p
    }

    // MARK: Timer (long press + frame timeout)

    private func updateTimer() {
        if contacts.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        if !contacts.isEmpty, now - lastFrame > Self.frameTimeout {
            cancelAll()                                             // §4 rule 6
            return
        }
        if case let .pending(id, start, t0) = state, now - t0 >= Double(config.longPressMs) / 1000 {
            post(.mouseMoved, start)                                // 4. long press → right down
            post(.rightMouseDown, start, button: .right)
            state = .rightDrag(id: id)
        }
    }

    // MARK: Event posting

    private func post(_ type: CGEventType, _ p: CGPoint, button: CGMouseButton = .left, click: Int64 = 1) {
        lastPoint = p
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: click)
        }
        e.post(tap: .cghidEventTap)
    }

    /// Continuous (trackpad-style) pixel scroll. phase: 1 began, 2 changed, 4 ended.
    /// Default direction: content follows the finger, like a touchscreen.
    private func scroll(phase: Int64, delta: CGPoint) {
        var d = delta
        if config.invertScroll { d = CGPoint(x: -d.x, y: -d.y) }
        let tx = d.x + scrollRemainder.x, ty = d.y + scrollRemainder.y
        let ix = tx.rounded(.towardZero), iy = ty.rounded(.towardZero)
        scrollRemainder = CGPoint(x: tx - ix, y: ty - iy)
        if phase == 2, ix == 0, iy == 0 { return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: Int32(iy), wheel2: Int32(ix), wheel3: 0) else { return }
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        e.post(tap: .cghidEventTap)
    }
}
