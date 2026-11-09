import AppKit
import Observation

/// Step-3 experiment: shows how steady and how reliable hand tracking is in
/// real conditions, to decide between Vision and a MediaPipe Core ML model.
/// Can record frames to JSON for the gesture state machine's tests.
@MainActor
@Observable
final class HandLab {
    /// Thumb tip–index tip distance (normalized frame units) to enter / leave a pinch.
    static let pinchOn = 0.055
    static let pinchOff = 0.085
    /// Fingertips below this confidence count as "no hand".
    static let minimumConfidence = 0.3

    private static let trailLength = 30
    private static let pinchHistoryLength = 150

    private(set) var landmarks: HandLandmarks?
    /// Mirrored, normalized (0...1) positions for drawing, newest last.
    private(set) var rawTrail: [CGPoint] = []
    private(set) var filteredTrail: [CGPoint] = []
    /// Pinch distance per frame, nil when no hand. Newest last.
    private(set) var pinchHistory: [Double?] = []
    private(set) var pinchRatio: Double?
    private(set) var isPinching = false
    private(set) var pinchCount = 0

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

    func ingest(_ frame: HandFrame) {
        if isRecording { recording.append(frame) }
        updateRates(with: frame)

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
            pinchRatio = nil
            append(nil, to: &pinchHistory, limit: Self.pinchHistoryLength)
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

        let distance = hand.pinchDistance
        pinchRatio = hand.pinchRatio
        append(distance, to: &pinchHistory, limit: Self.pinchHistoryLength)
        if !isPinching && distance < Self.pinchOn {
            isPinching = true
            pinchCount += 1
        } else if isPinching && distance > Self.pinchOff {
            isPinching = false
        }
    }

    func resetCounters() {
        pinchCount = 0
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

extension HandLandmarks {
    /// Thumb tip to index tip in normalized frame units (as MediaPipe-based
    /// projects measure it). Shrinks as the hand moves away from the camera.
    var pinchDistance: Double {
        let d = self[.thumbTip] - self[.indexTip]
        return (d.x * d.x + d.y * d.y).squareRoot()
    }

    /// Pinch distance divided by palm length (wrist → middle MCP), both
    /// aspect-corrected. Roughly independent of distance to the camera.
    var pinchRatio: Double? {
        let palm = Self.aspectCorrectedLength(self[.middleMCP] - self[.wrist])
        guard palm > 0 else { return nil }
        return Self.aspectCorrectedLength(self[.thumbTip] - self[.indexTip]) / palm
    }

    private static func aspectCorrectedLength(_ v: SIMD2<Double>) -> Double {
        let x = v.x * frameAspect
        return (x * x + v.y * v.y).squareRoot()
    }
}
