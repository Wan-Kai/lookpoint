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
    private static let returnKeyCode: CGKeyCode = 36
    private static let controlKeyCode: CGKeyCode = 59
    private static let leftArrowKeyCode: CGKeyCode = 123
    private static let rightArrowKeyCode: CGKeyCode = 124
    // ⌃ (with NX_DEVICELCTLKEYMASK), and ⌃ plus the fn / keypad flags real arrow keys carry:
    // the "Move left/right a space" shortcut is registered as ⌃ + fn + arrow.
    private static let controlDown = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x01 | 0x100)
    private static let controlArrow = CGEventFlags(rawValue: controlDown.rawValue
        | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskNumericPad.rawValue)
    // NX_DEVICERALTKEYMASK and NX_NONCOALSESCEDMASK: apps that tell left from right Option read these.
    private static let rightOptionDown = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40 | 0x100)
    private static let noModifiers = CGEventFlags(rawValue: 0x100)

    func perform(_ event: GestureStateMachine.Event) {
        switch event {
        case .activated:
            scrollRemainder = 0
        case .deactivated:
            releaseAll()
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
        case .swipe(let rightward):
            // Like the trackpad's three-finger swipe: content follows the hand,
            // so swiping left reveals the Space on the right (⌃→).
            tapControlArrow(rightward ? Self.leftArrowKeyCode : Self.rightArrowKeyCode)
        case .pressReturn:
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: Self.returnKeyCode, keyDown: down)
                event?.flags = Self.noModifiers
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Never leave the button held, e.g. when gestures are turned off mid-drag.
    func releaseAll() {
        guard isButtonDown else { return }
        postMouse(.leftMouseUp, at: cursor, clicks: 1)
        isButtonDown = false
    }

    private var cursor: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Moves within the display under the cursor: the head picks the screen, the hand stays on it.
    /// `dx`/`dy` are in widths of that display.
    private func move(dx: Double, dy: Double) {
        let from = cursor
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        let bounds = CGGetDisplaysWithPoint(from, 1, &id, &count) == .success && count > 0
            ? CGDisplayBounds(id) : CGDisplayBounds(CGMainDisplayID())
        let to = CGPoint(
            x: min(max(from.x + dx * bounds.width, bounds.minX), bounds.maxX - 1),
            y: min(max(from.y + dy * bounds.width, bounds.minY), bounds.maxY - 1)
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

    /// The "Move left/right a space" shortcut only fires for events posted to
    /// the session tap with a short gap between them (tested on macOS 26:
    /// the HID tap, or no gap, is ignored). The gaps run off the main thread.
    private func tapControlArrow(_ arrow: CGKeyCode) {
        let presses: [(key: CGKeyCode, down: Bool, flags: CGEventFlags, isModifier: Bool)] = [
            (Self.controlKeyCode, true, Self.controlDown, true),
            (arrow, true, Self.controlArrow, false),
            (arrow, false, Self.controlArrow, false),
            (Self.controlKeyCode, false, Self.noModifiers, true),
        ]
        Self.keySequenceQueue.async {
            let source = CGEventSource(stateID: .hidSystemState)
            for press in presses {
                let event = CGEvent(keyboardEventSource: source, virtualKey: press.key, keyDown: press.down)
                if press.isModifier { event?.type = .flagsChanged }
                event?.flags = press.flags
                event?.post(tap: .cgSessionEventTap)
                usleep(20_000)
            }
        }
    }

    private static let keySequenceQueue = DispatchQueue(label: "lookpoint.keys")

    private func tapRightOption() {
        for (down, flags) in [(true, Self.rightOptionDown), (false, Self.noModifiers)] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: Self.rightOptionKeyCode, keyDown: down)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}
