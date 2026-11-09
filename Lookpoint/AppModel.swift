import AppKit
import AVFoundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum CameraState: Equatable {
        case off
        case starting
        case running
        case denied
        case failed(String)
    }

    enum CalibrationOutcome: Equatable {
        case saved(HeadPose)
        case tooCloseToPrimary
        case noFace
    }

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    private(set) var cameraState: CameraState = .off
    /// Smoothed pose, nil while no face is detected.
    private(set) var pose: HeadPose?
    private(set) var activeScreen: ScreenRole = .primary
    private(set) var hasAccessibility = AXIsProcessTrusted()
    private(set) var isCalibrating = false
    private(set) var isHandLabOpen = false

    let handLab = HandLab()

    var calibration: HeadPose? {
        didSet {
            router.calibration = calibration
            if let data = try? JSONEncoder().encode(calibration) {
                UserDefaults.standard.set(data, forKey: Keys.calibration)
            }
        }
    }

    var hasSecondaryDisplay: Bool { switcher.displays() != nil }

    @ObservationIgnored private var router = HeadPoseRouter()
    // Tuned for degrees at ~10 fps: steady when still, little lag when turning.
    @ObservationIgnored private var yawFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.02)
    @ObservationIgnored private var pitchFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.02)
    @ObservationIgnored private let switcher = DisplaySwitcher()
    @ObservationIgnored private let activity = UserActivityMonitor()
    @ObservationIgnored private var pipeline: CameraPipeline?
    @ObservationIgnored private var calibrationSamples: [HeadPose]?

    private enum Keys {
        static let enabled = "enabled"
        static let calibration = "secondaryCalibration"
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        calibration = defaults.data(forKey: Keys.calibration)
            .flatMap { try? JSONDecoder().decode(HeadPose?.self, from: $0) }
        router.calibration = calibration

        // Hosted unit tests launch the app; keep the camera off there.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if isEnabled && !isTesting { start() }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
    }

    func refreshPermissions() {
        hasAccessibility = AXIsProcessTrusted()
    }

    /// Averages the pose over `duration` while the user looks at the secondary screen.
    func calibrateSecondary(duration: TimeInterval = 1.5) async -> CalibrationOutcome {
        calibrationSamples = []
        try? await Task.sleep(for: .seconds(duration))
        let samples = calibrationSamples ?? []
        calibrationSamples = nil

        guard samples.count >= 3 else { return .noFace }
        let mean = HeadPose(
            yaw: samples.map(\.yaw).reduce(0, +) / Double(samples.count),
            pitch: samples.map(\.pitch).reduce(0, +) / Double(samples.count)
        )
        // The calibrated pose itself must land in the secondary zone.
        guard HeadPoseRouter(calibration: mean).zone(for: mean) == .secondary else {
            return .tooCloseToPrimary
        }

        calibration = mean
        return .saved(mean)
    }

    /// While true, head pose never switches screens (the calibration window is up).
    func setCalibrating(_ value: Bool) {
        isCalibrating = value
    }

    /// Runs hand detection for the hand lab; head pose does not switch screens meanwhile.
    func setHandLabOpen(_ value: Bool) {
        isHandLabOpen = value
        pipeline?.detectsHands = value
    }

    private func start() {
        guard pipeline == nil else { return }
        cameraState = .starting
        activity.start()

        let pipeline = CameraPipeline(
            onHeadPose: { [weak self] pose in
                let time = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.handle(pose, at: time) }
            },
            onHand: { [weak self] frame in
                Task { @MainActor in self?.handLab.ingest(frame) }
            }
        )
        pipeline.detectsHands = isHandLabOpen
        self.pipeline = pipeline

        Task {
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                cameraState = .denied
                self.pipeline = nil
                return
            }
            do {
                try await pipeline.start()
                // The user may have disabled us while we were waiting for permission.
                if self.pipeline === pipeline { cameraState = .running } else { pipeline.stop() }
            } catch {
                cameraState = .failed(String(describing: error))
                self.pipeline = nil
            }
        }
    }

    private func stop() {
        pipeline?.stop()
        pipeline = nil
        activity.stop()
        cameraState = .off
        pose = nil
        yawFilter.reset()
        pitchFilter.reset()
        _ = router.update(pose: nil, at: ProcessInfo.processInfo.systemUptime)
    }

    private func handle(_ raw: HeadPose?, at time: TimeInterval) {
        guard pipeline != nil else { return }

        guard let raw else {
            pose = nil
            yawFilter.reset()
            pitchFilter.reset()
            _ = router.update(pose: nil, at: time)
            return
        }

        let smoothed = HeadPose(
            yaw: yawFilter.filter(raw.yaw, at: time),
            pitch: pitchFilter.filter(raw.pitch, at: time)
        )
        pose = smoothed
        calibrationSamples?.append(smoothed)

        let suppressed = isCalibrating || isHandLabOpen || activity.isActive(at: time)
        if let role = router.update(pose: smoothed, at: time, suppressed: suppressed) {
            activeScreen = role
            switcher.move(to: role)
        }
    }
}
