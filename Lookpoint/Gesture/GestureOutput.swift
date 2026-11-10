import AppKit
import CoreGraphics

/// Posts the state machine's intents as real mouse and keyboard events.
/// The only gesture code that touches the system; needs Accessibility.
@MainActor
final class GestureOutput {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var isButtonDown = false
    private var scrollRemainder = 0.0

    private static let rightOptionKeyCode: CGKeyCode = 61
    // NX_DEVICERALTKEYMASK and NX_NONCOALSESCEDMASK: apps that tell left from right Option read these.
    private static let rightOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40 | 0x100)
    private static let noModifiers = CGEventFlags(rawValue: 0x100)

    func perform(_ event: GestureStateMachine.Event) {
        switch event {
        case .activated:
            scrollRemainder = 0
        case .deactivated:
            releaseButton()
        case .move(let dx, let dy):
            move(dx: dx, dy: dy)
        case .leftDown(let clicks):
            postMouse(.leftMouseDown, at: cursor, clicks: clicks)
            isButtonDown = true
        case .leftUp(let clicks):
            postMouse(.leftMouseUp, at: cursor, clicks: clicks)
            isButtonDown = false
        case .scroll(let dy):
            scroll(dy: dy)
        case .toggleRightOption:
            tapRightOption()
        }
    }

    /// Never leave the button held, e.g. when gestures are turned off mid-drag.
    func releaseButton() {
        guard isButtonDown else { return }
        postMouse(.leftMouseUp, at: cursor, clicks: 1)
        isButtonDown = false
    }

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Moves within the display under the cursor: the head picks the screen, the hand stays on it.
    private func move(dx: Double, dy: Double) {
        let from = cursor
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let bounds = CGGetDisplaysWithPoint(from, 1, &id, &count) == .success && count > 0
            ? CGDisplayBounds(id) : CGDisplayBounds(CGMainDisplayID())
        let to = CGPoint(
            x: min(max(from.x + dx, bounds.minX), bounds.maxX - 1),
            y: min(max(from.y + dy, bounds.minY), bounds.maxY - 1)
        )
        let event = CGEvent(mouseEventSource: source, mouseType: isButtonDown ? .leftMouseDragged : .mouseMoved,
                            mouseCursorPosition: to, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventDeltaX, value: Int64((to.x - from.x).rounded()))
        event?.setIntegerValueField(.mouseEventDeltaY, value: Int64((to.y - from.y).rounded()))
        event?.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, clicks: Int) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        event?.post(tap: .cghidEventTap)
    }

    /// Trackpad-like: content follows the hand. Synthetic wheel events skip the
    /// system's "natural scrolling" inversion, so it is applied here.
    private func scroll(dy: Double) {
        let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
        // Hand up (dy < 0) with natural scrolling moves content up, i.e. a negative wheel delta.
        scrollRemainder += natural ? dy : -dy
        let pixels = scrollRemainder.rounded(.towardZero)
        guard pixels != 0 else { return }
        scrollRemainder -= pixels
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                wheel1: Int32(pixels), wheel2: 0, wheel3: 0)?
            .post(tap: .cghidEventTap)
    }

    private func tapRightOption() {
        for (down, flags) in [(true, Self.rightOptionDown), (false, Self.noModifiers)] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: Self.rightOptionKeyCode, keyDown: down)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
