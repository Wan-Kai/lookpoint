import Foundation
import Testing
@testable import Lookpoint

private final class BundleToken {}

private typealias Event = GestureStateMachine.Event
private typealias Timeline = [(time: Double, event: Event)]

/// Real Vision output from a 2026-11-10 session at the desk (segments
/// 0–80 s, 159–205 s, 274–317 s, 399–474 s), stored as raw-deflate JSON.
private func recordedTimeline(_ name: String = "hand-recording-2026-11-10.json") throws -> Timeline {
    let url = try #require(Bundle(for: BundleToken.self).url(forResource: name, withExtension: "deflate"))
    let data = try (Data(contentsOf: url) as NSData).decompressed(using: .zlib) as Data
    let frames = try JSONDecoder().decode([HandFrame].self, from: data)

    var machine = GestureStateMachine()
    var timeline: Timeline = []
    for frame in frames {
        let features = frame.landmarks.flatMap(HandFeatures.init)
        timeline += machine.update(features, at: frame.time).map { (frame.time, $0) }
    }
    return timeline
}

private func events(in timeline: Timeline, from start: Double, to end: Double) -> [Event] {
    timeline.filter { $0.time >= start && $0.time < end }.map(\.event)
}

private func isDown(_ event: Event) -> Bool {
    if case .leftDown = event { return true }
    return false
}

private func isUp(_ event: Event) -> Bool {
    if case .leftUp = event { return true }
    return false
}

struct RecordedGestureTests {
    @Test func buttonIsAlwaysReleased() throws {
        var pressed = false
        for (_, event) in try recordedTimeline() {
            if isDown(event) { #expect(!pressed); pressed = true }
            if isUp(event) { #expect(pressed); pressed = false }
            if event == .deactivated { #expect(!pressed) }
        }
        #expect(!pressed)
    }

    @Test func pinchesClick() throws {
        let timeline = try recordedTimeline()
        // Thumb and index together at 5.0–5.9 s.
        #expect(events(in: timeline, from: 5.0, to: 6.0).contains(where: isDown))
        // Held for about 5 s at 414–419 s, with a one-frame dropout: one long press, i.e. a drag.
        let down = try #require(timeline.first { $0.time >= 413.9 && isDown($0.event) })
        let up = try #require(timeline.first { $0.time > down.time && isUp($0.event) })
        #expect(up.time - down.time > 5)
    }

    @Test func fistsDoNotClick() throws {
        let timeline = try recordedTimeline()
        for start in [10.4, 163.5, 276.8] {
            #expect(!events(in: timeline, from: start, to: start + 1).contains(where: isDown))
        }
    }

    @Test func pointingWhileMovingDoesNotToggle() throws {
        let timeline = try recordedTimeline()
        // 24–31.5 s: pointing while the hand travels across the frame.
        #expect(!events(in: timeline, from: 24.0, to: 31.5).contains(.toggleRightOption))
    }

    @Test func pointingStillToggles() throws {
        let timeline = try recordedTimeline()
        let toggles = events(in: timeline, from: 436, to: 452).filter { $0 == .toggleRightOption }
        #expect((2...4).contains(toggles.count))
    }

    @Test func stillTwoFingersBarelyScroll() throws {
        // 436–445 s: a V held fairly still. Jitter must not turn into scrolling.
        let timeline = try recordedTimeline()
        let total = events(in: timeline, from: 436, to: 445).reduce(0.0) { sum, event in
            if case .scroll(let dy) = event { return sum + abs(dy) }
            return sum
        }
        #expect(total < 50)
    }

    @Test func noAppSwitchingInEverydayMovement() throws {
        // The recording has no horizontal V swipes.
        let timeline = try recordedTimeline()
        #expect(!timeline.contains {
            if case .switchWindow = $0.event { return true }
            return false
        })
    }

    @Test func handLowInTheFrameStaysIdle() throws {
        // 452–472 s: the hand flickers in and out near the bottom of the frame.
        let timeline = try recordedTimeline()
        #expect(!events(in: timeline, from: 454, to: 475).contains(.activated))
    }

    /// 2026-11-10: a V swiped left 8 times, then right 7 times, the hand
    /// coming back after each swipe at nearly the same speed.
    @Test func swipesIgnoreTheReturnStroke() throws {
        let switches = try recordedTimeline("swipe-recording-2026-11-10.json").compactMap { _, event -> Bool? in
            if case .switchWindow(let forward) = event { return forward }
            return nil
        }
        #expect(switches == Array(repeating: false, count: 8) + Array(repeating: true, count: 7))
    }
}
