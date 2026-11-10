import AppKit
import ApplicationServices

/// Cycles through the windows on the display under the cursor, like ⌘Tab
/// but per screen (⌘Tab is global and would pick apps on the other display).
///
/// The first step of a session snapshots the windows front to back; later
/// steps walk that list, so repeated swipes reach further back instead of
/// bouncing between the top two. Needs Accessibility to raise windows.
@MainActor
final class WindowSwitcher {
    private struct Window {
        let pid: pid_t
        let bounds: CGRect
    }

    private var snapshot: [Window] = []
    private var index = 0

    func step(forward: Bool) {
        if snapshot.isEmpty {
            snapshot = windowsOnCursorDisplay()
            index = 0
        }
        guard snapshot.count > 1 else { return }
        index = (index + (forward ? 1 : -1) + snapshot.count) % snapshot.count
        raise(snapshot[index])
    }

    func end() {
        snapshot = []
    }

    /// Normal app windows on the cursor's display, frontmost first.
    private func windowsOnCursorDisplay() -> [Window] {
        guard let cursor = CGEvent(source: nil)?.location else { return [] }
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(cursor, 1, &id, &count) == .success, count > 0 else { return [] }
        let display = CGDisplayBounds(id)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info -> Window? in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dictionary),
                  bounds.width >= 100, bounds.height >= 100
            else { return nil }
            // The display holding most of the window owns it.
            let overlap = bounds.intersection(display)
            guard !overlap.isNull, overlap.width * overlap.height >= bounds.width * bounds.height / 2 else { return nil }
            return Window(pid: pid, bounds: bounds)
        }
    }

    /// Raises the matching window and makes its app frontmost, both through
    /// Accessibility: `NSRunningApplication.activate` is refused for
    /// background apps since macOS 14.
    private func raise(_ window: Window) {
        let app = AXUIElementCreateApplication(window.pid)
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement],
           let match = windows.first(where: { Self.frame(of: $0).map { Self.close($0, window.bounds) } ?? false }) {
            AXUIElementPerformAction(match, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(match, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 4 && abs(a.minY - b.minY) < 4 && abs(a.width - b.width) < 4 && abs(a.height - b.height) < 4
    }
}
