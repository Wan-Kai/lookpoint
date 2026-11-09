import Foundation

/// Head orientation in degrees, as seen by the built-in camera.
/// Looking straight at the camera is roughly (0, 0).
struct HeadPose: Sendable, Equatable, Codable {
    var yaw: Double
    var pitch: Double
}

enum ScreenRole: Sendable, Equatable {
    /// The built-in display, the one with the camera.
    case primary
    case secondary
}
