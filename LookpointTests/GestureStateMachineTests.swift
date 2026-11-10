import Foundation
import Testing
@testable import Lookpoint

private typealias Event = GestureStateMachine.Event

private let frame = 1.0 / 30

private func open(_ x: Double = 1, _ y: Double = 0.6) -> HandFeatures {
    HandFeatures(anchor: SIMD2(x, y), indexPinch: 0.9, fingerRatios: [1.4, 1.4, 1.4, 1.4])
}

private func pinch(_ x: Double = 1, _ y: Double = 0.6, ratio: Double = 0.1) -> HandFeatures {
    HandFeatures(anchor: SIMD2(x, y), indexPinch: ratio, fingerRatios: [1.1, 1.0, 1.05, 1.05])
}

private func fist(_ x: Double = 1, _ y: Double = 0.6) -> HandFeatures {
    HandFeatures(anchor: SIMD2(x, y), indexPinch: 0.1, fingerRatios: [0.8, 0.75, 0.7, 0.7])
}

private func point(_ x: Double = 1, _ y: Double = 0.6) -> HandFeatures {
    HandFeatures(anchor: SIMD2(x, y), indexPinch: 1.1, fingerRatios: [1.4, 0.7, 0.65, 0.65])
}

private func two(_ x: Double = 1, _ y: Double = 0.6) -> HandFeatures {
    HandFeatures(anchor: SIMD2(x, y), indexPinch: 1.3, fingerRatios: [1.4, 1.45, 0.6, 0.6])
}

private func repeated(_ count: Int, _ make: (Int) -> HandFeatures?) -> [HandFeatures?] {
    (0..<count).map(make)
}

/// Feeds frames at 30 fps, continuing the clock across calls.
private struct Replay {
    var machine = GestureStateMachine()
    var time = 0.0
    var events: [(time: Double, event: Event)] = []

    mutating func feed(_ frames: [HandFeatures?], typing: Bool = false) -> [Event] {
        var produced: [Event] = []
        for features in frames {
            let out = machine.update(features, at: time, typing: typing)
            produced += out
            events += out.map { (time, $0) }
            time += frame
        }
        return produced
    }

    /// Activates with an open palm and returns the replay ready for gestures.
    static func active() -> Replay {
        var replay = Replay()
        _ = replay.feed(repeated(15) { _ in open() })
        return replay
    }
}

private func buttons(_ events: [Event]) -> [Event] {
    events.filter {
        switch $0 {
        case .leftDown, .leftUp: true
        default: false
        }
    }
}

private func moves(_ events: [Event]) -> (dx: Double, dy: Double, count: Int) {
    events.reduce((0.0, 0.0, 0)) { sum, event in
        guard case .move(let dx, let dy) = event else { return sum }
        return (sum.0 + dx, sum.1 + dy, sum.2 + 1)
    }
}

private func scrolled(_ events: [Event]) -> Double {
    events.reduce(0) { sum, event in
        guard case .scroll(let dy) = event else { return sum }
        return sum + dy
    }
}

struct GestureStateMachineTests {
    // MARK: Activation

    @Test func openPalmActivatesAfterDwell() {
        var replay = Replay()
        #expect(replay.feed(repeated(11) { _ in open() }).isEmpty)
        #expect(replay.feed(repeated(2) { _ in open() }) == [.activated])
        #expect(replay.machine.isActive)
    }

    @Test func handLowInTheFrameNeverActivates() {
        var replay = Replay()
        #expect(replay.feed(repeated(60) { _ in open(1, 0.8) }).isEmpty)
    }

    @Test func handPassingThroughDoesNotActivate() {
        var replay = Replay()
        let passing = repeated(9) { open(0.5 + Double($0) * 0.1) } + repeated(10) { _ in nil }
        #expect(replay.feed(passing + passing).isEmpty)
    }

    @Test func otherShapesDoNotActivate() {
        var replay = Replay()
        #expect(replay.feed(repeated(30) { _ in fist() } + repeated(30) { _ in point() }).isEmpty)
    }

    @Test func typingBlocksActivation() {
        var replay = Replay()
        #expect(replay.feed(repeated(30) { _ in open() }, typing: true).isEmpty)
    }

    @Test func typingDeactivatesAndReleasesTheButton() {
        var replay = Replay.active()
        _ = replay.feed(repeated(3) { _ in open() } + repeated(3) { _ in pinch() })
        #expect(replay.feed([open()], typing: true) == [.leftUp(clickCount: 1), .deactivated])
    }

    @Test func losingTheHandReleasesThenDeactivates() {
        var replay = Replay.active()
        _ = replay.feed(repeated(3) { _ in open() } + repeated(3) { _ in pinch() })
        // A few missing frames (motion blur) keep the button down...
        #expect(replay.feed(repeated(7) { _ in nil }).isEmpty)
        // ...longer than 0.25 s releases it...
        #expect(replay.feed(repeated(2) { _ in nil }) == [.leftUp(clickCount: 1)])
        // ...and gone longer than 0.5 s deactivates.
        #expect(replay.feed(repeated(9) { _ in nil }) == [.deactivated])
        #expect(!replay.machine.isActive)
    }

    @Test func briefDropoutKeepsTheSession() {
        var replay = Replay.active()
        #expect(replay.feed(repeated(5) { _ in nil } + repeated(5) { _ in open() }).isEmpty)
        #expect(replay.machine.isActive)
    }

    // MARK: Pointer

    @Test func openPalmMovesThePointer() {
        var replay = Replay.active()
        let events = replay.feed(repeated(15) { open(1 + Double($0) * 0.01) })
        let total = moves(events)
        #expect(total.dx > 0.03)
        #expect(abs(total.dy) < 1e-9)
    }

    @Test func stillHandDoesNotMove() {
        var replay = Replay.active()
        #expect(moves(replay.feed(repeated(30) { _ in open() })).count == 0)
    }

    @Test func fasterHandMovesFurtherForTheSameDistance() {
        var slow = Replay.active()
        let slowTotal = moves(slow.feed(repeated(60) { open(1 + Double($0) * 0.1 / 60) }))
        var fast = Replay.active()
        let fastTotal = moves(fast.feed(repeated(6) { open(1 + Double($0) * 0.1 / 6) } + repeated(30) { _ in open(1.1) }))
        #expect(fastTotal.dx > slowTotal.dx * 1.5)
    }

    @Test func quickFlickCrossesTheScreen() {
        var replay = Replay.active()
        // 0.25 frame heights in about 0.3 s, then rest: a fast hand reaches the far edge.
        let flick = repeated(9) { open(1 + 0.25 * (1 - cos(Double($0 + 1) / 9 * .pi)) / 2) }
        let total = moves(replay.feed(flick + repeated(10) { _ in open(1.25) }))
        #expect(total.dx >= 1)
    }

    @Test func slowHandStaysPrecise() {
        var replay = Replay.active()
        // 0.05 frame heights over 1.5 s (a few centimetres, slowly).
        let total = moves(replay.feed(repeated(45) { open(1 + Double($0 + 1) * 0.05 / 45) }))
        #expect(total.dx > 0.01)
        #expect(total.dx < 0.05)
    }

    @Test func otherShapeFreezesThePointer() {
        var replay = Replay.active()
        // The shape takes over after 3 frames; from then on the fist moves nothing.
        _ = replay.feed(repeated(3) { _ in fist() })
        let events = replay.feed(repeated(30) { fist(1 + Double($0) * 0.01) })
        #expect(moves(events).count == 0)
        #expect(buttons(events).isEmpty)
    }

    @Test func returningToOpenDoesNotJump() {
        var replay = Replay.active()
        // Clutch: move with a fist, then open far away.
        _ = replay.feed(repeated(20) { fist(1 + Double($0) * 0.02) })
        let events = replay.feed(repeated(10) { _ in open(1.4) })
        #expect(abs(moves(events).dx) < 0.02)
    }

    // MARK: Click and drag

    @Test func quickPinchClicksWithoutMoving() {
        var replay = Replay.active()
        let events = replay.feed(repeated(3) { _ in open() } + repeated(6) { _ in pinch() } + repeated(6) { _ in open() })
        #expect(buttons(events) == [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
        #expect(moves(events).count == 0)
    }

    @Test func twoQuickPinchesDoubleClick() {
        var replay = Replay.active()
        let once = repeated(5) { _ in pinch() } + repeated(4) { _ in open() }
        let events = replay.feed(repeated(3) { _ in open() } + once + once)
        #expect(buttons(events) == [
            .leftDown(clickCount: 1), .leftUp(clickCount: 1),
            .leftDown(clickCount: 2), .leftUp(clickCount: 2),
        ])
    }

    @Test func slowSecondPinchIsANewClick() {
        var replay = Replay.active()
        let once = repeated(5) { _ in pinch() } + repeated(20) { _ in open() }
        let events = replay.feed(repeated(3) { _ in open() } + once + once)
        #expect(buttons(events) == [
            .leftDown(clickCount: 1), .leftUp(clickCount: 1),
            .leftDown(clickCount: 1), .leftUp(clickCount: 1),
        ])
    }

    @Test func pinchAndMoveDrags() {
        var replay = Replay.active()
        _ = replay.feed(repeated(3) { _ in open() })
        let events = replay.feed(repeated(30) { pinch(1 + Double($0) * 0.005) } + repeated(4) { _ in open(1.15) })
        #expect(buttons(events) == [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
        let downIndex = events.firstIndex(of: .leftDown(clickCount: 1))!
        let upIndex = events.firstIndex(of: .leftUp(clickCount: 1))!
        #expect(moves(Array(events[downIndex..<upIndex])).dx > 0.03)
    }

    @Test func pinchJitterInsideHysteresisIsOneClick() {
        var replay = Replay.active()
        // After pressing, the ratio wobbles between on (0.25) and off (0.40).
        let wobble = repeated(20) { pinch(ratio: $0.isMultiple(of: 2) ? 0.28 : 0.37) }
        let events = replay.feed(repeated(3) { _ in open() } + repeated(3) { _ in pinch() } + wobble + repeated(4) { _ in open() })
        #expect(buttons(events) == [.leftDown(clickCount: 1), .leftUp(clickCount: 1)])
    }

    @Test func singleFramePinchIsIgnored() {
        var replay = Replay.active()
        let blips = (0..<5).flatMap { _ in [pinch()] + repeated(4) { _ in open() } }
        #expect(buttons(replay.feed(blips)).isEmpty)
    }

    @Test func fistNeverClicks() {
        var replay = Replay.active()
        let events = replay.feed(repeated(3) { _ in open() } + repeated(30) { _ in fist() } + repeated(10) { _ in open() })
        #expect(buttons(events).isEmpty)
    }

    @Test func pinchLongAfterOpenPalmIsIgnored() {
        var replay = Replay.active()
        // Hand sits in some other shape for a second, then the thumb touches the index.
        let events = replay.feed(repeated(30) { _ in point() } + repeated(6) { _ in pinch() })
        #expect(buttons(events).isEmpty)
    }

    // MARK: Scroll

    @Test func twoFingersScrollWithTheHand() {
        var replay = Replay.active()
        let events = replay.feed(repeated(4) { _ in two() } + repeated(20) { two(1, 0.6 + Double($0) * 0.005) })
        #expect(scrolled(events) > 150)
        #expect(moves(events).count == 0)
        #expect(buttons(events).isEmpty)

        var up = Replay.active()
        #expect(scrolled(up.feed(repeated(4) { _ in two() } + repeated(20) { two(1, 0.6 - Double($0) * 0.005) })) < -150)
    }

    @Test func stillTwoFingersDoNotScroll() {
        var replay = Replay.active()
        #expect(scrolled(replay.feed(repeated(30) { _ in two() })) == 0)
    }

    // MARK: Horizontal swipes

    /// A V that settles, then a quick horizontal swipe of 0.12 frame heights over 6 frames.
    private static func swipe(from x: Double, forward: Bool) -> [HandFeatures?] {
        repeated(6) { two(x + (forward ? 1 : -1) * Double($0 + 1) * 0.02) }
    }

    private static func switches(_ events: [Event]) -> [Event] {
        events.filter {
            switch $0 {
            case .swipe: true
            default: false
            }
        }
    }

    @Test func swipeRightSwitchesToTheNextApp() {
        var replay = Replay.active()
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: true)
            + repeated(10) { _ in two(1.12) } + repeated(5) { _ in open(1.12) })
        #expect(Self.switches(events) == [.swipe(rightward: true)])
        #expect(scrolled(events) == 0)
        #expect(moves(events).count == 0)
    }

    @Test func swipeLeftSwitchesToThePreviousApp() {
        var replay = Replay.active()
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: false)
            + repeated(10) { _ in two(0.88) } + repeated(5) { _ in open(0.88) })
        #expect(Self.switches(events) == [.swipe(rightward: false)])
    }

    @Test func returnStrokeDoesNotSwitchBack() {
        var replay = Replay.active()
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: true)
            + Self.swipe(from: 1.12, forward: false) + repeated(10) { _ in two() } + repeated(5) { _ in open() })
        #expect(Self.switches(events) == [.swipe(rightward: true)])
    }

    @Test func repeatedSwipesEachSwitch() {
        var replay = Replay.active()
        let pause = repeated(10) { _ in two(1.12) }
        // Bring the hand back slowly, then swipe again.
        let back = repeated(30) { two(1.12 - Double($0 + 1) * 0.004) }
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: true) + pause + back
            + repeated(5) { _ in two() } + Self.swipe(from: 1, forward: true) + pause + repeated(5) { _ in open(1.12) })
        #expect(Self.switches(events) == [.swipe(rightward: true), .swipe(rightward: true)])
    }

    @Test func slowHorizontalMovementDoesNotSwitch() {
        var replay = Replay.active()
        let events = replay.feed(repeated(4) { _ in two() } + repeated(60) { two(1 + Double($0) * 0.003) })
        #expect(Self.switches(events).isEmpty)
        #expect(scrolled(events) == 0)
    }

    @Test func scrollingWithSidewaysWobbleDoesNotSwitch() {
        var replay = Replay.active()
        let events = replay.feed(repeated(4) { _ in two() }
            + repeated(40) { two(1 + ($0.isMultiple(of: 2) ? 0.015 : -0.015), 0.6 + Double($0) * 0.005) })
        #expect(Self.switches(events).isEmpty)
        #expect(scrolled(events) > 300)
    }

    @Test func blurredFramesMidSwipeKeepTheSwipe() {
        var replay = Replay.active()
        let blurred: [HandFeatures?] = [two(1.02), two(1.04), nil, nil, nil, two(1.12), two(1.14)]
        let events = replay.feed(repeated(4) { _ in two() } + blurred + repeated(5) { _ in two(1.14) })
        #expect(Self.switches(events) == [.swipe(rightward: true)])
    }

    @Test func returnAfterAPauseIsStillAReturn() {
        var replay = Replay.active()
        // Swipe right, rest 0.8 s out there, then bring the hand back.
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: true)
            + repeated(24) { _ in two(1.12) } + Self.swipe(from: 1.12, forward: false) + repeated(5) { _ in two() })
        #expect(Self.switches(events) == [.swipe(rightward: true)])
    }

    @Test func deliberateReverseAfterTheReturnWindowSwitches() {
        var replay = Replay.active()
        // Swipe right, stay out there 2 s, then swipe left on purpose.
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: true)
            + repeated(60) { _ in two(1.12) } + Self.swipe(from: 1.12, forward: false) + repeated(5) { _ in two(1) })
        #expect(Self.switches(events) == [.swipe(rightward: true), .swipe(rightward: false)])
    }

    @Test func swipeLeftAfterReturningFromARightSwipe() {
        var replay = Replay.active()
        // Right, back home, then a real left swipe from home.
        let events = replay.feed(repeated(4) { _ in two() } + Self.swipe(from: 1, forward: true)
            + Self.swipe(from: 1.12, forward: false) + repeated(8) { _ in two(1) } + Self.swipe(from: 1, forward: false)
            + repeated(5) { _ in two(0.88) })
        #expect(Self.switches(events) == [.swipe(rightward: true), .swipe(rightward: false)])
    }


    // MARK: Right Option

    @Test func pointHeldStillTogglesOnce() {
        var replay = Replay.active()
        let events = replay.feed(repeated(60) { _ in point() })
        #expect(events.filter { $0 == .toggleRightOption }.count == 1)
        #expect(moves(events).count == 0)
    }

    @Test func pointHoldNeedsTheFullDuration() {
        var replay = Replay.active()
        // Shape settles after 3 frames, then 0.5 s of hold: not enough.
        let events = replay.feed(repeated(3 + 15) { _ in point() } + repeated(10) { _ in open() })
        #expect(!events.contains(.toggleRightOption))
    }

    @Test func movingPointDoesNotToggle() {
        var replay = Replay.active()
        let events = replay.feed(repeated(90) { point(1 + Double($0) * 0.004) })
        #expect(!events.contains(.toggleRightOption))
    }

    @Test func secondToggleNeedsAFreshPoint() {
        var replay = Replay.active()
        let hold = repeated(40) { _ in point() } + repeated(10) { _ in open() }
        let events = replay.feed(hold + hold)
        #expect(events.filter { $0 == .toggleRightOption }.count == 2)
    }

    // MARK: Return after voice input

    /// Starts voice input with one point-hold, then opens the hand.
    private static func speaking() -> Replay {
        var replay = Replay.active()
        _ = replay.feed(repeated(25) { _ in point() } + repeated(10) { _ in open() })
        return replay
    }

    @Test func holdingAfterStartingDoesNotPressReturn() {
        var replay = Replay.active()
        let events = replay.feed(repeated(120) { _ in point() })
        #expect(events.filter { $0 == .toggleRightOption }.count == 1)
        #expect(!events.contains(.pressReturn))
    }

    @Test func holdingAfterStoppingPressesReturn() {
        var replay = Self.speaking()
        _ = replay.feed(repeated(30) { _ in point() })
        let toggle = replay.events.last { $0.event == .toggleRightOption }!
        _ = replay.feed(repeated(60) { _ in point() })
        let returns = replay.events.filter { $0.event == .pressReturn }
        #expect(returns.count == 1)
        #expect(abs(returns[0].time - toggle.time - 0.8) < 0.05)
    }

    @Test func changingShapeAfterStoppingSkipsReturn() {
        var replay = Self.speaking()
        // Stop fires around frame 21; open the hand 0.5 s later.
        let events = replay.feed(repeated(36) { _ in point() } + repeated(30) { _ in open() })
        #expect(events.contains(.toggleRightOption))
        #expect(!events.contains(.pressReturn))
    }

    @Test func movingAfterStoppingSkipsReturn() {
        var replay = Self.speaking()
        let events = replay.feed(repeated(25) { _ in point() } + repeated(40) { point(1 + Double($0) * 0.003) })
        #expect(events.contains(.toggleRightOption))
        #expect(!events.contains(.pressReturn))
    }

    @Test func speakingSurvivesPuttingTheHandDown() {
        var replay = Self.speaking()
        _ = replay.feed(repeated(40) { _ in nil })
        #expect(!replay.machine.isActive)
        _ = replay.feed(repeated(15) { _ in open() })
        let events = replay.feed(repeated(60) { _ in point() })
        #expect(events.filter { $0 == .pressReturn }.count == 1)
    }

    // MARK: Features

    @Test func shapesFromFingerRatios() {
        #expect(open().shape == .open)
        #expect(point().shape == .point)
        #expect(two().shape == .two)
        #expect(fist().shape == .other)
        #expect(pinch().shape == .other)
    }

    @Test func recordedFramesRoundTrip() throws {
        let landmarks = HandLandmarks(
            points: Array(repeating: SIMD2(0.1, 0.2), count: 21),
            confidences: Array(repeating: 0.9, count: 21)
        )
        let frames = [
            HandFrame(time: 1.0, latency: 0.008, landmarks: landmarks),
            HandFrame(time: 1.033, latency: 0.007, landmarks: nil),
        ]
        let decoded = try JSONDecoder().decode([HandFrame].self, from: JSONEncoder().encode(frames))
        #expect(decoded.map(\.landmarks) == frames.map(\.landmarks))
    }
}
