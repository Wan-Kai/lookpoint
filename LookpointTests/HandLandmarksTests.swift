import Foundation
import Testing
@testable import Lookpoint

private func hand(_ overrides: [HandLandmarks.Joint: SIMD2<Double>]) -> HandLandmarks {
    var points = Array(repeating: SIMD2<Double>(0.5, 0.5), count: HandLandmarks.Joint.allCases.count)
    for (joint, point) in overrides { points[joint.rawValue] = point }
    return HandLandmarks(points: points, confidences: Array(repeating: 1, count: points.count))
}

struct HandLandmarksTests {
    @Test func pinchDistanceIsInNormalizedFrameUnits() {
        let h = hand([.thumbTip: SIMD2(0.50, 0.50), .indexTip: SIMD2(0.53, 0.54)])
        #expect(abs(h.pinchDistance - 0.05) < 1e-9)
    }

    @Test func pinchRatioDoesNotDependOnDistanceToCamera() {
        // The same hand, the second one half as large in the frame (twice as far away).
        let near = hand([
            .wrist: SIMD2(0.5, 0.8), .middleMCP: SIMD2(0.5, 0.6),
            .thumbTip: SIMD2(0.45, 0.5), .indexTip: SIMD2(0.50, 0.45),
        ])
        let far = hand([
            .wrist: SIMD2(0.5, 0.65), .middleMCP: SIMD2(0.5, 0.55),
            .thumbTip: SIMD2(0.475, 0.5), .indexTip: SIMD2(0.50, 0.475),
        ])
        #expect(abs(far.pinchDistance - near.pinchDistance / 2) < 1e-9)
        #expect(abs((near.pinchRatio ?? 0) - (far.pinchRatio ?? 1)) < 1e-9)
    }

    @Test func pinchRatioNeedsAPalm() {
        #expect(hand([:]).pinchRatio == nil)
    }

    @Test func recordedFramesRoundTrip() throws {
        let frames = [
            HandFrame(time: 1.0, latency: 0.008, landmarks: hand([.indexTip: SIMD2(0.1, 0.2)])),
            HandFrame(time: 1.033, latency: 0.007, landmarks: nil),
        ]
        let decoded = try JSONDecoder().decode([HandFrame].self, from: JSONEncoder().encode(frames))
        #expect(decoded.count == 2)
        #expect(decoded[0].landmarks == frames[0].landmarks)
        #expect(decoded[1].landmarks == nil)
    }
}
