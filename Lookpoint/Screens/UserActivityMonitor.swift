import AppKit

/// Tracks the last time the user typed or used the mouse, so head-pose
/// switching can hold off while they are clearly working on the current screen.
///
/// Key events from other apps are only delivered once Accessibility is granted;
/// mouse events arrive without it.
@MainActor
final class UserActivityMonitor {
    /// Seconds of no input before head pose may switch screens again.
    var grace: TimeInterval = 1.5

    private var lastInput = -TimeInterval.infinity
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .mouseMoved, .scrollWheel,
            .leftMouseDown, .leftMouseDragged, .rightMouseDown, .rightMouseDragged,
        ]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            let timestamp = event.timestamp
            MainActor.assumeIsolated { self?.lastInput = timestamp }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// `time` uses the same clock as `NSEvent.timestamp` (`ProcessInfo.systemUptime`).
    func isActive(at time: TimeInterval) -> Bool {
        time - lastInput < grace
    }
}
