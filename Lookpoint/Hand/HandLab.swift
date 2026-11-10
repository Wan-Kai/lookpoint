import AppKit
import Observation

/// Hand tracking lab: shows tracking quality, the hand shape and what the
/// gesture state machine does with it. Can record frames to JSON for tests.
@MainActor
@Observable
final class HandLab {
    /// Fingertips below this confidence count as "no hand".
    static let minimumConfidence = 0.3

    private static let trailLength = 30
    private static let pinchHistoryLength = 150

    private(set) var landmarks: HandLandmarks?
    /// Mirrored, normalized (0...1) positions for drawing, newest last.
    private(set) var rawTrail: [CGPoint] = []
    private(set) var filteredTrail: [CGPoint] = []
    /// Thumb–index distance over palm length per frame, nil when no hand. Newest last.
    private(set) var pinchHistory: [Double?] = []
    private(set) var features: HandFeatures?
    private(set) var mode: GestureStateMachine.Mode = .idle
    /// Newest first.
    private(set) var eventLog: [String] = []
    private(set) var clickCount = 0
    private(set) var scrollDistance = 0.0
    private(set) var toggleCount = 0

    private(set) var framesPerSecond = 0
    private(set) var handRate = 0.0
    private(set) var latencyMilliseconds = 0.0
    /// Fingertip spread over the last 0.5 s in screen points, if the full frame mapped to the main display.
    private(set) var rawJitter: Double?
    private(set) var filteredJitter: Double?

    private(set) var isRecording = false
    private(set) var lastRecordingURL: URL?

    @ObservationIgnored private var recentFrames: [HandFrame] = []
    @ObservationIgnored private var recentTips: [(time: TimeInterval, raw: CGPoint, filtered: CGPoint)] = []
    // Standard cursor settings for One-Euro on screen points.
    @ObservationIgnored private var xFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
    @ObservationIgnored private var yFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
    @ObservationIgnored private var recording: [HandFrame] = []

    func ingest(_ frame: HandFrame, features: HandFeatures?, events: [GestureStateMachine.Event], mode: GestureStateMachine.Mode) {
        if isRecording { recording.append(frame) }
        updateRates(with: frame)
        self.features = features
        self.mode = mode
        log(events)
        append(features?.indexPinch, to: &pinchHistory, limit: Self.pinchHistoryLength)

        landmarks = frame.landmarks
        guard let hand = frame.landmarks,
              hand.confidence(.indexTip) >= Self.minimumConfidence,
              hand.confidence(.thumbTip) >= Self.minimumConfidence
        else {
            xFilter.reset()
            yFilter.reset()
            recentTips.removeAll()
            rawJitter = nil
            filteredJitter = nil
            return
        }

        let screen = CGDisplayBounds(CGMainDisplayID()).size
        let tip = hand[.indexTip]
        let raw = CGPoint(x: (1 - tip.x) * screen.width, y: tip.y * screen.height)
        let filtered = CGPoint(
            x: xFilter.filter(raw.x, at: frame.time),
            y: yFilter.filter(raw.y, at: frame.time)
        )
        append(CGPoint(x: raw.x / screen.width, y: raw.y / screen.height), to: &rawTrail, limit: Self.trailLength)
        append(CGPoint(x: filtered.x / screen.width, y: filtered.y / screen.height), to: &filteredTrail, limit: Self.trailLength)

        recentTips.append((frame.time, raw, filtered))
        recentTips.removeAll { frame.time - $0.time > 0.5 }
        if recentTips.count >= 5 {
            rawJitter = Self.spread(recentTips.map(\.raw))
            filteredJitter = Self.spread(recentTips.map(\.filtered))
        }
    }

    func resetCounters() {
        clickCount = 0
        scrollDistance = 0
        toggleCount = 0
        eventLog.removeAll()
        rawTrail.removeAll()
        filteredTrail.removeAll()
        pinchHistory.removeAll()
    }

    func toggleRecording() {
        if isRecording {
            isRecording = false
            lastRecordingURL = save(recording)
            recording.removeAll()
        } else {
            recording.removeAll()
            isRecording = true
        }
    }

    func revealLastRecording() {
        if let lastRecordingURL { NSWorkspace.shared.activateFileViewerSelecting([lastRecordingURL]) }
    }

    private func log(_ events: [GestureStateMachine.Event]) {
        for event in events {
            let text: String
            switch event {
            case .activated: text = "激活"
            case .deactivated: text = "退出"
            case .move: continue
            case .leftDown(let n):
                clickCount += 1
                text = n > 1 ? "左键按下 ×\(n)" : "左键按下"
            case .leftUp: text = "左键抬起"
            case .scroll(let dy):
                scrollDistance += abs(dy)
                continue
            case .toggleRightOption:
                toggleCount += 1
                text = "右 Alt 切换"
            case .pressReturn:
                text = "回车"
            case .appSwitch(let forward):
                text = forward ? "切换 App →" : "切换 App ←"
            case .appSwitchCommit:
                text = "确认切换"
            }
            let stamp = Date.now.formatted(.dateTime.hour().minute().second())
            eventLog.insert("\(stamp)  \(text)", at: 0)
            if eventLog.count > 12 { eventLog.removeLast() }
        }
    }

    private func updateRates(with frame: HandFrame) {
        recentFrames.append(frame)
        recentFrames.removeAll { frame.time - $0.time > 1 }
        framesPerSecond = recentFrames.count
        let found = recentFrames.filter {
            guard let hand = $0.landmarks else { return false }
            return hand.confidence(.indexTip) >= Self.minimumConfidence
                && hand.confidence(.thumbTip) >= Self.minimumConfidence
        }
        handRate = Double(found.count) / Double(recentFrames.count)
        latencyMilliseconds = recentFrames.map(\.latency).reduce(0, +) / Double(recentFrames.count) * 1000
    }

    /// Writes `frames` to ~/Documents/lookpoint-recordings/hand-<timestamp>.json.
    private func save(_ frames: [HandFrame]) -> URL? {
        guard !frames.isEmpty else { return nil }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Documents/lookpoint-recordings", directoryHint: .isDirectory)
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        let url = directory.appending(path: "hand-\(stamp).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(frames).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private func append<T>(_ value: T, to array: inout [T], limit: Int) {
        array.append(value)
        if array.count > limit { array.removeFirst(array.count - limit) }
    }

    /// Root-mean-square distance from the centroid.
    private static func spread(_ points: [CGPoint]) -> Double {
        let n = Double(points.count)
        let cx = points.map(\.x).reduce(0, +) / n
        let cy = points.map(\.y).reduce(0, +) / n
        let variance = points.map { ($0.x - cx) * ($0.x - cx) + ($0.y - cy) * ($0.y - cy) }.reduce(0, +) / n
        return variance.squareRoot()
    }
}
