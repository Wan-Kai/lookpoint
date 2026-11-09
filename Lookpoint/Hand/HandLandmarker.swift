import Vision

/// The only replaceable seam in the project: a frame in, 21 landmarks out.
///
/// This implementation uses `VNDetectHumanHandPoseRequest`. If it turns out
/// not to be accurate enough, replace the body with a MediaPipe
/// hand_landmarker converted to Core ML (e.g. run through `VNCoreMLRequest`
/// on the same handler) and keep the signature.
///
/// Not thread-safe: call from the camera queue only.
final class HandLandmarker {
    private let request: VNDetectHumanHandPoseRequest

    private static let joints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    init() {
        request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
    }

    /// `handler` wraps the current frame and is shared with the other Vision requests.
    func detect(using handler: VNImageRequestHandler) throws -> HandLandmarks? {
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let recognized = try observation.recognizedPoints(.all)

        var points: [SIMD2<Double>] = []
        var confidences: [Double] = []
        for joint in Self.joints {
            if let point = recognized[joint] {
                // Vision's origin is bottom-left; flip to top-left.
                points.append(SIMD2(Double(point.location.x), 1 - Double(point.location.y)))
                confidences.append(Double(point.confidence))
            } else {
                points.append(.zero)
                confidences.append(0)
            }
        }
        return HandLandmarks(points: points, confidences: confidences)
    }
}
