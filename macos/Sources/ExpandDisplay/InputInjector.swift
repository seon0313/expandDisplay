import AppKit
import CoreGraphics

/// Turns normalized touch coordinates from the phone into left-mouse events on the virtual display.
final class InputInjector {
    private var clickCount: Int64 = 1
    private var lastUpTime: TimeInterval = 0
    private var lastDownPoint = CGPoint.zero
    private var isDown = false
    private let source = CGEventSource(stateID: .hidSystemState)

    func handle(action: UInt8, x: Float, y: Float, displayID: CGDirectDisplayID) {
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.height > 0 else { return }
        let nx = CGFloat(min(max(x, 0), 1))
        let ny = CGFloat(min(max(y, 0), 1))
        let p = CGPoint(x: b.minX + nx * (b.width - 1), y: b.minY + ny * (b.height - 1))
        let now = ProcessInfo.processInfo.systemUptime

        switch action {
        case 0: // down
            let dist = hypot(p.x - lastDownPoint.x, p.y - lastDownPoint.y)
            if now - lastUpTime < NSEvent.doubleClickInterval, dist < 16 {
                clickCount += 1
            } else {
                clickCount = 1
            }
            lastDownPoint = p
            isDown = true
            post(.mouseMoved, at: p)
            post(.leftMouseDown, at: p)
        case 1: // move
            post(isDown ? .leftMouseDragged : .mouseMoved, at: p)
        case 2: // up / cancel
            if isDown {
                post(.leftMouseUp, at: p)
            }
            isDown = false
            lastUpTime = now
        default:
            break
        }
    }

    private func post(_ type: CGEventType, at p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        e.post(tap: .cghidEventTap)
    }
}
