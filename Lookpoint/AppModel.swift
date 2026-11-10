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
        /// Off while the screen is locked or asleep; comes back by itself.
        case paused
    }

    /// Why the camera is off although the user left it on.
    private enum Suspension: Hashable {
        case screenLocked
        case screensAsleep
        case systemAsleep
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
    /// Gesture state machine mode, for the UI.
    private(set) var gestureMode: GestureStateMachine.Mode = .idle
    /// Whether gestures have turned voice input on (counted from our own right Alt toggles).
    private(set) var isSpeaking = false

    let handLab = HandLab()

    /// Hand gestures drive the real mouse and keyboard. Off: the hand lab still
    /// runs the state machine and shows what it would do (dry run).
    var gesturesEnabled: Bool {
        didSet {
            UserDefaults.standard.set(gesturesEnabled, forKey: Keys.gestures)
            if gesturesEnabled { requestAccessibility() } else { stopGestures() }
            pipeline?.detectsHands = detectsHands
        }
    }

    /// Events are only posted with Accessibility; without it the gestures dry-run.
    var gesturesLive: Bool { gesturesEnabled && hasAccessibility }

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
    @ObservationIgnored private var gestures = GestureStateMachine()
    @ObservationIgnored private let gestureOutput = GestureOutput()
    @ObservationIgnored private var accessibilityPoll: Task<Void, Never>?
    @ObservationIgnored private var suspensions: Set<Suspension> = []
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    private var detectsHands: Bool { isHandLabOpen || gesturesEnabled }

    private enum Keys {
        static let enabled = "enabled"
        static let calibration = "secondaryCalibration"
        static let gestures = "gesturesEnabled"
    }

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        gesturesEnabled = defaults.bool(forKey: Keys.gestures)
        calibration = defaults.data(forKey: Keys.calibration)
            .flatMap { try? JSONDecoder().decode(HeadPose?.self, from: $0) }
        router.calibration = calibration

        // Hosted unit tests launch the app; keep the camera off there.
        if isEnabled && !isTesting { start() }
        observeLockAndSleep()
    }

    /// Saves power: no camera or hand tracking while nobody can use the screen.
    private func observeLockAndSleep() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        let rules: [(NotificationCenter, Notification.Name, Suspension, Bool)] = [
            (distributed, .init("com.apple.screenIsLocked"), .screenLocked, true),
            (distributed, .init("com.apple.screenIsUnlocked"), .screenLocked, false),
            (workspace, NSWorkspace.screensDidSleepNotification, .screensAsleep, true),
            (workspace, NSWorkspace.screensDidWakeNotification, .screensAsleep, false),
            (workspace, NSWorkspace.willSleepNotification, .systemAsleep, true),
            (workspace, NSWorkspace.didWakeNotification, .systemAsleep, false),
        ]
        for (center, name, suspension, active) in rules {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSuspended(suspension, active) }
            }
            observers.append((center, token))
        }
    }

    private func setSuspended(_ suspension: Suspension, _ active: Bool) {
        let wasSuspended = !suspensions.isEmpty
        if active { suspensions.insert(suspension) } else { suspensions.remove(suspension) }
        guard wasSuspended != !suspensions.isEmpty, isEnabled, !isTesting else { return }
        if suspensions.isEmpty {
            start()
        } else {
            stop()
            cameraState = .paused
        }
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        guard !hasAccessibility, accessibilityPoll == nil else { return }
        // There is no notification for the grant; check until it arrives.
        accessibilityPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if AXIsProcessTrusted() {
                    self.hasAccessibility = true
                    self.accessibilityPoll = nil
                    return
                }
            }
        }
    }

    /// Sends one right Alt tap now, to check what the voice-input app does with it.
    func testRightAlt() {
        gestureOutput.perform(.toggleRightOption)
    }

    #if DEBUG
    func testGesture(_ event: GestureStateMachine.Event) {
        gestureOutput.perform(event)
    }
    #endif

    /// Releases anything gestures hold. Call before quitting.
    func stopGestures() {
        for event in gestures.reset() where gesturesLive { gestureOutput.perform(event) }
        gestureOutput.releaseAll()
        gestureMode = gestures.mode
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
        pipeline?.detectsHands = detectsHands
    }

    private func start() {
        guard pipeline == nil else { return }
        guard suspensions.isEmpty else {
            cameraState = .paused
            return
        }
        cameraState = .starting
        activity.start()

        let pipeline = CameraPipeline(
            onHeadPose: { [weak self] pose in
                let time = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in self?.handle(pose, at: time) }
            },
            onHand: { [weak self] frame in
                Task { @MainActor in self?.handle(frame) }
            }
        )
        pipeline.detectsHands = detectsHands
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
        stopGestures()
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

        // While a gesture is active the screen stays put, or it would chase the cursor.
        let suppressed = isCalibrating || isHandLabOpen || gestures.isActive || activity.isActive(at: time)
        if let role = router.update(pose: smoothed, at: time, suppressed: suppressed) {
            activeScreen = role
            switcher.move(to: role)
        }
    }

    private func handle(_ frame: HandFrame) {
        guard pipeline != nil else { return }
        let features = frame.landmarks.flatMap(HandFeatures.init)
        let events = detectsHands
            ? gestures.update(features, at: frame.time, typing: activity.isTyping(at: frame.time))
            : []
        if gesturesLive {
            for event in events { gestureOutput.perform(event) }
        }
        gestureMode = gestures.mode
        isSpeaking = gestures.isSpeaking
        handLab.ingest(frame, features: features, events: events, mode: gestures.mode)
    }
}
