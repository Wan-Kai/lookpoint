import CoreGraphics

/// Moves the cursor between the primary (built-in) and secondary display.
///
/// Remembers where the cursor was on each display and returns it there.
/// All coordinates are global Quartz coordinates (origin top-left of the main display).
@MainActor
final class DisplaySwitcher {
    private var lastLocation: [CGDirectDisplayID: CGPoint] = [:]

    /// The primary is the built-in display (it has the camera), otherwise the main display.
    /// The secondary is the first other active, non-mirrored display.
    func displays() -> (primary: CGDirectDisplayID, secondary: CGDirectDisplayID)? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 1 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        ids = ids.filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        let primary = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
        guard let secondary = ids.first(where: { $0 != primary }) else { return nil }
        return (primary, secondary)
    }

    /// Warps the cursor to `role`'s display. Returns false if it was already there.
    ///
    /// `CGWarpMouseCursorPosition` posts no events: anything that should react
    /// to the move (e.g. a click to focus) has to post its own `CGEvent`.
    @discardableResult
    func move(to role: ScreenRole) -> Bool {
        guard let displays = displays(), let cursor = CGEvent(source: nil)?.location else { return false }
        let target = role == .primary ? displays.primary : displays.secondary

        let currentDisplay = display(containing: cursor)
        guard currentDisplay != target else { return false }
        if let currentDisplay { lastLocation[currentDisplay] = cursor }

        let bounds = CGDisplayBounds(target)
        let destination = lastLocation[target].flatMap { bounds.contains($0) ? $0 : nil }
            ?? CGPoint(x: bounds.midX, y: bounds.midY)
        CGWarpMouseCursorPosition(destination)
        return true
    }

    private func display(containing point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }
}
