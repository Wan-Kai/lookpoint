import AVFoundation
import Vision

/// Owns the camera and runs Vision on its frames.
///
/// One session, one serial queue: every frame is handled on `queue`, and all
/// Vision requests for a frame go through a single `VNImageRequestHandler`.
/// Head pose runs on every `headPoseFrameInterval`-th frame (~10 fps at 30 fps).
final class CameraPipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum StartError: Error {
        case noCamera
        case cannotAddInput
        case cannotAddOutput
    }

    private static let headPoseFrameInterval = 3

    // Only touched on `queue`.
    private let queue = DispatchQueue(label: "lookpoint.camera")
    private let session = AVCaptureSession()
    private let faceRequest: VNDetectFaceRectanglesRequest
    private var frameIndex = 0
    private var isConfigured = false

    /// Called on the camera queue with the largest face's pose, or nil when no face is found.
    private let onHeadPose: @Sendable (HeadPose?) -> Void

    init(onHeadPose: @escaping @Sendable (HeadPose?) -> Void) {
        self.onHeadPose = onHeadPose
        faceRequest = VNDetectFaceRectanglesRequest()
        // Revision 3 is the first to report yaw and pitch.
        faceRequest.revision = VNDetectFaceRectanglesRequestRevision3
        super.init()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.configureIfNeeded()
                    if !self.session.isRunning { self.session.startRunning() }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configureIfNeeded() throws {
        guard !isConfigured else { return }

        // Prefer the built-in camera: "facing the camera" is what defines the primary screen.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = discovery.devices.first ?? AVCaptureDevice.default(for: .video) else {
            throw StartError.noCamera
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw StartError.cannotAddInput }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw StartError.cannotAddOutput }
        session.addOutput(output)

        isConfigured = true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameIndex += 1
        guard frameIndex % Self.headPoseFrameInterval == 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([faceRequest])
        } catch {
            onHeadPose(nil)
            return
        }

        let face = faceRequest.results?.max {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }
        guard let face, let yaw = face.yaw?.doubleValue, let pitch = face.pitch?.doubleValue else {
            onHeadPose(nil)
            return
        }
        onHeadPose(HeadPose(yaw: yaw * 180 / .pi, pitch: pitch * 180 / .pi))
    }
}
