import Foundation

/// 21 hand keypoints in MediaPipe's order, so a MediaPipe-derived model can
/// produce the same struct.
///
/// Points are normalized to the camera frame (1280×720): origin top-left,
/// x to the right, y down, as the camera sees it (not mirrored).
struct HandLandmarks: Sendable, Equatable, Codable {
    enum Joint: Int, CaseIterable, Sendable {
        case wrist
        case thumbCMC, thumbMCP, thumbIP, thumbTip
        case indexMCP, indexPIP, indexDIP, indexTip
        case middleMCP, middlePIP, middleDIP, middleTip
        case ringMCP, ringPIP, ringDIP, ringTip
        case littleMCP, littlePIP, littleDIP, littleTip
    }

    /// Width / height of the frame the points are normalized to.
    static let frameAspect = 16.0 / 9.0

    /// Indexed by `Joint.rawValue`.
    var points: [SIMD2<Double>]
    /// 0...1 per point; 0 when the detector did not find the joint.
    var confidences: [Double]

    subscript(joint: Joint) -> SIMD2<Double> { points[joint.rawValue] }

    func confidence(_ joint: Joint) -> Double { confidences[joint.rawValue] }
}

/// One processed camera frame: the landmarks if a hand was found, plus timing.
struct HandFrame: Sendable, Codable {
    /// `ProcessInfo.systemUptime` when the frame reached the pipeline.
    var time: TimeInterval
    /// Time spent detecting the hand, in seconds.
    var latency: TimeInterval
    var landmarks: HandLandmarks?
}
