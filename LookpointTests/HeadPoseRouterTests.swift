import Testing
@testable import Lookpoint

/// Feeds a recorded pose sequence at 10 fps and collects every switch.
private func replay(
    _ router: inout HeadPoseRouter,
    _ poses: [HeadPose?],
    start: Double = 0,
    suppressed: (Int) -> Bool = { _ in false }
) -> [(time: Double, role: ScreenRole)] {
    var switches: [(Double, ScreenRole)] = []
    for (index, pose) in poses.enumerated() {
        let time = start + Double(index) * 0.1
        if let role = router.update(pose: pose, at: time, suppressed: suppressed(index)) {
            switches.append((time, role))
        }
    }
    return switches
}

private func yaw(_ values: [Double]) -> [HeadPose?] {
    values.map { HeadPose(yaw: $0, pitch: 0) }
}

private func hold(_ yaw: Double, _ frames: Int) -> [HeadPose?] {
    Array(repeating: HeadPose(yaw: yaw, pitch: 0), count: frames)
}

struct HeadPoseRouterTests {
    @Test func startsOnPrimary() {
        #expect(HeadPoseRouter().current == .primary)
    }

    @Test func switchesToSecondaryAfterDwell() {
        var router = HeadPoseRouter()
        let switches = replay(&router, hold(0, 5) + hold(30, 10))
        #expect(switches.count == 1)
        #expect(switches.first?.role == .secondary)
        // Entered the zone at t=0.5, dwell 0.3 → switch at t=0.8.
        #expect(abs((switches.first?.time ?? 0) - 0.8) < 1e-9)
        #expect(router.current == .secondary)
    }

    @Test func switchesBackToPrimaryWhenFacingCamera() {
        var router = HeadPoseRouter()
        let switches = replay(&router, hold(30, 10) + hold(2, 10))
        #expect(switches.map(\.role) == [.secondary, .primary])
    }

    @Test func briefGlanceDoesNotSwitch() {
        var router = HeadPoseRouter()
        // 200 ms on the secondary side is shorter than the 300 ms dwell.
        let switches = replay(&router, hold(0, 5) + hold(30, 2) + hold(0, 10))
        #expect(switches.isEmpty)
    }

    @Test func jitterInsideHysteresisBandDoesNotSwitch() {
        var router = HeadPoseRouter()
        // Uncalibrated: primary < 8°, secondary ≥ 15°. 8–15° holds the current screen.
        let noisy = yaw([7, 9, 12, 8.5, 14, 10, 7.5, 13, 9, 14.9, 11, 8])
        #expect(replay(&router, noisy + noisy + noisy).isEmpty)

        var onSecondary = HeadPoseRouter()
        _ = replay(&onSecondary, hold(30, 10))
        #expect(replay(&onSecondary, noisy + noisy, start: 10).isEmpty)
        #expect(onSecondary.current == .secondary)
    }

    @Test func noisyEntryRestartsDwell() {
        var router = HeadPoseRouter()
        // Never three consecutive secondary frames after the first: dwell keeps restarting.
        let flicker = yaw([20, 20, 10, 20, 20, 10, 20, 20, 10, 20, 20, 10])
        #expect(replay(&router, flicker).isEmpty)
    }

    @Test func losingTheFaceDoesNotSwitch() {
        var router = HeadPoseRouter()
        let sequence: [HeadPose?] = hold(30, 2) + [nil, nil] + hold(30, 2) + Array(repeating: nil, count: 10)
        #expect(replay(&router, sequence).isEmpty)
        #expect(router.current == .primary)
    }

    @Test func suppressionBlocksAndRestartsDwell() {
        var router = HeadPoseRouter()
        // Looking at the secondary while typing (frames 0–9) never switches.
        let switches = replay(&router, hold(30, 14)) { $0 < 10 }
        // Suppression ends at frame 10 (t=1.0); dwell restarts there → switch at t=1.3.
        #expect(switches.count == 1)
        #expect(abs((switches.first?.time ?? 0) - 1.3) < 1e-9)
    }

    @Test func cooldownSpacesOutSwitches() {
        var router = HeadPoseRouter()
        // Switch to secondary at t=0.3, then immediately face the camera again.
        let switches = replay(&router, hold(30, 4) + hold(0, 10))
        #expect(switches.map(\.role) == [.secondary, .primary])
        // Primary zone from t=0.4, dwell would allow t=0.7, cooldown holds until t=0.9.
        #expect(abs(switches[1].time - 0.9) < 1e-9)
    }

    @Test func uncalibratedAcceptsEitherSide() {
        var router = HeadPoseRouter()
        #expect(replay(&router, hold(-30, 5)).map(\.role) == [.secondary])
    }

    @Test func calibratedIgnoresTheOppositeSide() {
        var router = HeadPoseRouter(calibration: HeadPose(yaw: 30, pitch: 0))
        #expect(router.zone(for: HeadPose(yaw: -30, pitch: 0)) == nil)
        #expect(replay(&router, hold(-30, 20)).isEmpty)
        #expect(replay(&router, hold(30, 5), start: 5).map(\.role) == [.secondary])
    }

    @Test func calibratedSecondaryAbove() {
        // Secondary screen above the laptop: mostly pitch, almost no yaw.
        var router = HeadPoseRouter(calibration: HeadPose(yaw: 2, pitch: 25))
        #expect(router.zone(for: HeadPose(yaw: 0, pitch: 0)) == .primary)
        #expect(router.zone(for: HeadPose(yaw: 1, pitch: 22)) == .secondary)
        // Looking down at the keyboard is not the secondary screen.
        #expect(router.zone(for: HeadPose(yaw: 0, pitch: -20)) == nil)

        let up = Array(repeating: HeadPose?.some(HeadPose(yaw: 1, pitch: 22)), count: 5)
        #expect(replay(&router, up).map(\.role) == [.secondary])
    }

    @Test func enterThresholdNeverCollapsesIntoPrimary() {
        let router = HeadPoseRouter(calibration: HeadPose(yaw: 10, pitch: 0))
        #expect(router.secondaryEnter == 12)
        #expect(router.zone(for: HeadPose(yaw: 10, pitch: 0)) == nil)
    }
}
