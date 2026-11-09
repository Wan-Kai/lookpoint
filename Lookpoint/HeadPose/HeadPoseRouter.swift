import Foundation

/// Decides which screen the user is looking at from a stream of head poses.
///
/// The pose is reduced to one angle along the "secondary screen axis":
/// - calibrated: the projection of (yaw, pitch) onto the direction recorded
///   while looking at the secondary screen, so a screen above or beside works;
/// - uncalibrated: `|yaw|`, so a secondary screen on either side works.
///
/// Zones along that angle:
/// - `|angle| < primaryLimit` → primary (no calibration needed);
/// - `angle >= secondaryEnter` → secondary;
/// - anything else is the hysteresis band and keeps the current screen.
///
/// A zone must hold for `dwell` before switching, and switches are at least
/// `cooldown` apart. Losing the face or being suppressed (user typing, gesture
/// active, calibrating) never switches and restarts the dwell.
struct HeadPoseRouter {
    struct Config: Equatable {
        var primaryLimit: Double = 8
        /// Assumed secondary angle when there is no calibration.
        var uncalibratedSecondaryAngle: Double = 25
        /// Secondary starts at this fraction of the secondary angle...
        var secondaryEnterFraction: Double = 0.6
        /// ...but never closer than this to `primaryLimit`.
        var minimumBand: Double = 4
        var dwell: TimeInterval = 0.3
        var cooldown: TimeInterval = 0.6
    }

    var config = Config()
    /// Head pose recorded while looking at the secondary screen.
    var calibration: HeadPose? {
        didSet { pending = nil }
    }

    private(set) var current: ScreenRole = .primary
    private var pending: (role: ScreenRole, since: TimeInterval)?
    private var lastSwitch = -TimeInterval.infinity

    init(config: Config = Config(), calibration: HeadPose? = nil) {
        self.config = config
        self.calibration = calibration
    }

    /// Angle along the secondary axis, in degrees.
    func axisAngle(_ pose: HeadPose) -> Double {
        guard let calibration, let length = Self.length(calibration), length > 0 else {
            return abs(pose.yaw)
        }
        return (pose.yaw * calibration.yaw + pose.pitch * calibration.pitch) / length
    }

    var secondaryEnter: Double {
        let angle = calibration.flatMap(Self.length) ?? config.uncalibratedSecondaryAngle
        return max(config.primaryLimit + config.minimumBand, config.secondaryEnterFraction * angle)
    }

    /// The screen this pose points at, or nil inside the hysteresis band.
    func zone(for pose: HeadPose) -> ScreenRole? {
        let angle = axisAngle(pose)
        if abs(angle) < config.primaryLimit { return .primary }
        if angle >= secondaryEnter { return .secondary }
        return nil
    }

    /// Feeds one sample. Returns the new screen when a switch happens.
    mutating func update(pose: HeadPose?, at time: TimeInterval, suppressed: Bool = false) -> ScreenRole? {
        guard let pose, !suppressed, let zone = zone(for: pose), zone != current else {
            pending = nil
            return nil
        }
        if pending?.role != zone {
            pending = (zone, time)
        }
        // Tolerate float rounding in frame timestamps (0.7 - 0.4 < 0.3).
        let epsilon = 1e-9
        guard let pending,
              time - pending.since + epsilon >= config.dwell,
              time - lastSwitch + epsilon >= config.cooldown
        else { return nil }

        current = zone
        lastSwitch = time
        self.pending = nil
        return zone
    }

    private static func length(_ pose: HeadPose) -> Double? {
        (pose.yaw * pose.yaw + pose.pitch * pose.pitch).squareRoot()
    }
}
