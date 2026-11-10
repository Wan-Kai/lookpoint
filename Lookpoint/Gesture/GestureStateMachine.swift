import Foundation

/// Turns per-frame hand features into mouse and keyboard intents.
///
/// - Activate: open palm, above the bottom quarter of the frame, held `activationDwell`.
/// - Open palm moves the pointer (relative, with acceleration); any other
///   shape freezes it, which doubles as the clutch.
/// - Thumb–index pinch: left button down; release: up. Movement is held back
///   until the hand clearly moves, so a quick pinch is a clean click.
///   Two pinches within `doubleClickInterval` make a double click.
///   A pinch only starts shortly after an open palm, so a fist (whose thumb
///   also touches the index finger) never clicks.
/// - Two fingers (V): vertical hand movement scrolls, like a trackpad.
/// - Point held still for `holdDuration`: toggle right Option (voice input on/off).
///   When that toggle ends voice input, keeping the point still another
///   `enterDelay` presses Return, which also gives the text time to land.
/// - Deactivate: hand gone for `lostTimeout`, or the user types.
///
/// Every exit path releases a held button first.
struct GestureStateMachine {
    struct Config: Equatable {
        var activationDwell: TimeInterval = 0.4
        /// Hands lower than this (frame heights from the top) never activate;
        /// the recording put a raised hand around 0.6 and keyboard hands out of view.
        var activationMaxY = 0.75
        /// While active, a hand lower than this counts as gone.
        var activeMaxY = 0.85
        var lostTimeout: TimeInterval = 0.5

        /// Frames a new shape must persist before it takes over.
        var shapeFrames = 3

        var pinchOn = 0.25
        var pinchOff = 0.40
        var pinchFrames = 2
        var minimumRingLittleRatio = 0.88
        /// A pinch must start within this long after the last open-palm frame.
        var pinchArmWindow: TimeInterval = 0.6
        /// Hand movement (frame heights) or time before a held pinch starts dragging.
        var dragDistance = 0.015
        var dragDelay: TimeInterval = 0.3
        var doubleClickInterval: TimeInterval = 0.4
        var doubleClickDistance = 0.03

        /// Screen points per frame height: slow hand → `slowGain`, fast → `fastGain`.
        var slowGain = 900.0
        var fastGain = 3200.0
        /// Hand speeds (frame heights per second) between which the gain ramps.
        var slowSpeed = 0.05
        var fastSpeed = 0.6
        /// Pointer moves smaller than this (frame heights) accumulate instead of moving.
        var deadZone = 0.001

        /// Scroll points per frame height of vertical hand movement.
        var scrollGain = 2500.0

        var holdDuration: TimeInterval = 0.6
        var holdTolerance = 0.02
        var holdCooldown: TimeInterval = 1.0
        var enterDelay: TimeInterval = 0.8

        /// One-Euro on the palm anchor in frame heights.
        var filterMinCutoff = 1.5
        var filterBeta = 10.0
    }

    enum Event: Equatable, Sendable {
        case activated
        case deactivated
        /// Screen points, y down.
        case move(dx: Double, dy: Double)
        case leftDown(clickCount: Int)
        case leftUp(clickCount: Int)
        /// Screen points; positive when the hand moves down.
        case scroll(dy: Double)
        case toggleRightOption
        case pressReturn
    }

    enum Mode: Equatable, Sendable {
        case idle
        case activating
        case moving
        case frozen
        case pressed
        case dragging
        case scrolling
        case holding
    }

    var config: Config
    private(set) var mode: Mode = .idle
    var isActive: Bool { mode != .idle && mode != .activating }

    private var activationStart: TimeInterval?
    private var lastSeen = -TimeInterval.infinity

    private var stableShape: HandShape = .other
    private var candidateShape: HandShape = .other
    private var candidateFrames = 0
    private var lastOpen = -TimeInterval.infinity

    private var xFilter: OneEuroFilter
    private var yFilter: OneEuroFilter
    private var previous: (anchor: SIMD2<Double>, time: TimeInterval)?
    /// Where the pointer was last moved from; nil re-anchors on the next frame.
    private var pointerReference: SIMD2<Double>?
    private var scrollReference: Double?

    private var pinchFrames = 0
    private var releaseFrames = 0
    private var isPressed = false
    private var isDragging = false
    private var pressAnchor = SIMD2<Double>.zero
    private var pressTime = 0.0
    private var clickCount = 1
    private var lastRelease: (time: TimeInterval, anchor: SIMD2<Double>, clicks: Int)?

    private var holdStart: (time: TimeInterval, anchor: SIMD2<Double>)?
    private var holdFired = false
    private var lastToggle = -TimeInterval.infinity
    /// Whether our toggles have turned voice input on. Kept across sessions:
    /// people put the hand down while speaking. Pressing right Alt on the
    /// keyboard puts it out of step; the worst case is a Return right after
    /// starting, into an empty field.
    private(set) var isSpeaking = false
    /// Set when a toggle ended voice input and the same hold may still send Return.
    private var pendingReturn: TimeInterval?

    private static let epsilon = 1e-9

    init(config: Config = Config()) {
        self.config = config
        xFilter = OneEuroFilter(minCutoff: config.filterMinCutoff, beta: config.filterBeta)
        yFilter = OneEuroFilter(minCutoff: config.filterMinCutoff, beta: config.filterBeta)
    }

    /// Feeds one camera frame. `typing` is true while the user is using the keyboard.
    mutating func update(_ features: HandFeatures?, at time: TimeInterval, typing: Bool = false) -> [Event] {
        if typing {
            activationStart = nil
            if mode == .activating { mode = .idle }
            return isActive ? deactivate() : []
        }
        return isActive ? updateActive(features, at: time) : updateIdle(features, at: time)
    }

    /// Ends any gesture now, releasing a held button.
    mutating func reset() -> [Event] {
        let events = isActive ? deactivate() : []
        mode = .idle
        activationStart = nil
        return events
    }

    // MARK: Idle

    private mutating func updateIdle(_ features: HandFeatures?, at time: TimeInterval) -> [Event] {
        guard let features, features.shape == .open, features.anchor.y < config.activationMaxY else {
            activationStart = nil
            mode = .idle
            return []
        }
        let start = activationStart ?? time
        activationStart = start
        mode = .activating
        guard time - start + Self.epsilon >= config.activationDwell else { return [] }

        activationStart = nil
        stableShape = .open
        candidateShape = .open
        candidateFrames = config.shapeFrames
        lastOpen = time
        lastSeen = time
        _ = smooth(features.anchor, at: time)
        pointerReference = nil
        mode = .moving
        return [.activated]
    }

    // MARK: Active

    private mutating func updateActive(_ features: HandFeatures?, at time: TimeInterval) -> [Event] {
        guard let features, features.anchor.y < config.activeMaxY else {
            var events: [Event] = []
            if isPressed { events += release() }
            pointerReference = nil
            scrollReference = nil
            holdStart = nil
            previous = nil
            xFilter.reset()
            yFilter.reset()
            mode = .frozen
            if time - lastSeen > config.lostTimeout { events += deactivate() }
            return events
        }
        lastSeen = time
        let anchor = smooth(features.anchor, at: time)
        let speed = handSpeed(anchor, at: time)
        updateShape(features.shape)
        if stableShape == .open { lastOpen = time }

        if isPressed { return updatePressed(features, anchor: anchor, speed: speed, at: time) }

        // Armed right after an open palm, or right after a click (for double clicks).
        let armed = time - lastOpen <= config.pinchArmWindow + Self.epsilon
            || lastRelease.map { time - $0.time <= config.doubleClickInterval } == true
        let canPinch = armed
            && features.indexPinch < config.pinchOn
            && features.ringLittleRatio > config.minimumRingLittleRatio
        pinchFrames = canPinch ? pinchFrames + 1 : 0
        if pinchFrames >= config.pinchFrames {
            return press(at: anchor, time: time)
        }

        switch stableShape {
        case .open:
            mode = .moving
            return moveEvents(to: anchor, speed: speed)
        case .two:
            mode = .scrolling
            defer { scrollReference = anchor.y }
            guard let reference = scrollReference else { return [] }
            let dy = (anchor.y - reference) * config.scrollGain
            return dy == 0 ? [] : [.scroll(dy: dy)]
        case .point:
            mode = .holding
            return holdEvents(anchor: anchor, at: time)
        case .other:
            mode = .frozen
            pointerReference = nil
            return []
        }
    }

    private mutating func updatePressed(
        _ features: HandFeatures, anchor: SIMD2<Double>, speed: Double, at time: TimeInterval
    ) -> [Event] {
        releaseFrames = features.indexPinch > config.pinchOff ? releaseFrames + 1 : 0
        if releaseFrames >= config.pinchFrames {
            pointerReference = nil
            mode = stableShape == .open ? .moving : .frozen
            return release()
        }
        if !isDragging {
            let moved = Self.length(anchor - pressAnchor) > config.dragDistance
            guard moved || time - pressTime >= config.dragDelay else { return [] }
            isDragging = true
            mode = .dragging
            pointerReference = anchor
            return []
        }
        return moveEvents(to: anchor, speed: speed)
    }

    private mutating func press(at anchor: SIMD2<Double>, time: TimeInterval) -> [Event] {
        pinchFrames = 0
        releaseFrames = 0
        isPressed = true
        isDragging = false
        pressAnchor = anchor
        pressTime = time
        if let last = lastRelease,
           time - last.time <= config.doubleClickInterval,
           Self.length(anchor - last.anchor) <= config.doubleClickDistance {
            clickCount = min(last.clicks + 1, 3)
        } else {
            clickCount = 1
        }
        mode = .pressed
        return [.leftDown(clickCount: clickCount)]
    }

    private mutating func release() -> [Event] {
        isPressed = false
        isDragging = false
        releaseFrames = 0
        lastRelease = (lastSeen, pressAnchor, clickCount)
        return [.leftUp(clickCount: clickCount)]
    }

    private mutating func deactivate() -> [Event] {
        var events: [Event] = []
        if isPressed { events += release() }
        events.append(.deactivated)
        mode = .idle
        pointerReference = nil
        scrollReference = nil
        holdStart = nil
        holdFired = false
        pendingReturn = nil
        previous = nil
        pinchFrames = 0
        lastRelease = nil
        xFilter.reset()
        yFilter.reset()
        return events
    }

    // MARK: Helpers

    private mutating func updateShape(_ shape: HandShape) {
        if shape == candidateShape {
            candidateFrames += 1
        } else {
            candidateShape = shape
            candidateFrames = 1
        }
        guard candidateFrames >= config.shapeFrames, candidateShape != stableShape else { return }
        stableShape = candidateShape
        // Each shape starts from where the hand is now, so switching never jumps.
        pointerReference = nil
        scrollReference = nil
        holdStart = nil
        holdFired = false
        pendingReturn = nil
    }

    private mutating func moveEvents(to anchor: SIMD2<Double>, speed: Double) -> [Event] {
        guard let reference = pointerReference else {
            pointerReference = anchor
            return []
        }
        let delta = anchor - reference
        guard Self.length(delta) >= config.deadZone else { return [] }
        pointerReference = anchor
        let t = min(max((speed - config.slowSpeed) / (config.fastSpeed - config.slowSpeed), 0), 1)
        let gain = config.slowGain + (config.fastGain - config.slowGain) * t * t * (3 - 2 * t)
        return [.move(dx: delta.x * gain, dy: delta.y * gain)]
    }

    private mutating func holdEvents(anchor: SIMD2<Double>, at time: TimeInterval) -> [Event] {
        if let start = holdStart, Self.length(anchor - start.anchor) <= config.holdTolerance {
            if let stoppedAt = pendingReturn, time - stoppedAt + Self.epsilon >= config.enterDelay {
                pendingReturn = nil
                return [.pressReturn]
            }
            guard !holdFired,
                  time - start.time + Self.epsilon >= config.holdDuration,
                  time - lastToggle + Self.epsilon >= config.holdCooldown
            else { return [] }
            holdFired = true
            lastToggle = time
            isSpeaking.toggle()
            if !isSpeaking { pendingReturn = time }
            return [.toggleRightOption]
        }
        // Started pointing, or moved too much: the hold restarts here.
        holdStart = (time, anchor)
        pendingReturn = nil
        return []
    }

    private mutating func smooth(_ anchor: SIMD2<Double>, at time: TimeInterval) -> SIMD2<Double> {
        SIMD2(xFilter.filter(anchor.x, at: time), yFilter.filter(anchor.y, at: time))
    }

    private mutating func handSpeed(_ anchor: SIMD2<Double>, at time: TimeInterval) -> Double {
        defer { previous = (anchor, time) }
        guard let previous, time > previous.time else { return 0 }
        return Self.length(anchor - previous.anchor) / (time - previous.time)
    }

    private static func length(_ v: SIMD2<Double>) -> Double {
        (v.x * v.x + v.y * v.y).squareRoot()
    }
}
