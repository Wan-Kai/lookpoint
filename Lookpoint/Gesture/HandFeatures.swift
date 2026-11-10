import Foundation

enum HandShape: Sendable, Equatable {
    /// All four fingers straight.
    case open
    /// Only the index finger straight.
    case point
    /// Index and middle straight, ring and little curled (V).
    case two
    case other
}

/// What the gesture state machine needs from one frame of landmarks.
///
/// Thresholds come from a 7.9-minute recording with Vision at desk distance:
/// a straight finger's ratio sits around 1.4, a curled one around 0.6–0.8.
struct HandFeatures: Sendable, Equatable {
    /// Palm center (wrist, index MCP, middle MCP), mirrored so x grows to the
    /// user's right, y down. Units: frame heights, so x and y are comparable.
    var anchor: SIMD2<Double>
    /// Thumb tip to index tip divided by palm length (wrist → middle MCP).
    /// Pinched ≈ 0.1, open hand ≈ 0.9.
    var indexPinch: Double
    /// Fingertip-to-wrist over PIP-to-wrist for index, middle, ring, little.
    var fingerRatios: [Double]

    static let extendedRatio = 1.2
    static let curledRatio = 1.0
    static let minimumConfidence = 0.3

    var shape: HandShape {
        let extended = fingerRatios.map { $0 > Self.extendedRatio }
        let curled = fingerRatios.map { $0 < Self.curledRatio }
        if extended.allSatisfy({ $0 }) { return .open }
        if extended[0] && curled[1] && curled[2] && curled[3] { return .point }
        if extended[0] && extended[1] && curled[2] && curled[3] { return .two }
        return .other
    }

    /// Mean ratio of ring and little. A fist also brings the thumb to the
    /// index finger, but curls these (≈ 0.75); a pinch leaves them ≈ 1.05.
    var ringLittleRatio: Double { (fingerRatios[2] + fingerRatios[3]) / 2 }

    init(anchor: SIMD2<Double>, indexPinch: Double, fingerRatios: [Double]) {
        self.anchor = anchor
        self.indexPinch = indexPinch
        self.fingerRatios = fingerRatios
    }

    /// Nil when the joints the gestures rely on were not found confidently.
    init?(_ hand: HandLandmarks) {
        typealias J = HandLandmarks.Joint
        let required: [J] = [.wrist, .thumbTip, .indexMCP, .middleMCP,
                             .indexPIP, .indexTip, .middlePIP, .middleTip,
                             .ringPIP, .ringTip, .littlePIP, .littleTip]
        guard required.allSatisfy({ hand.confidence($0) >= Self.minimumConfidence }) else { return nil }

        // Frame-height units with x mirrored.
        func p(_ joint: J) -> SIMD2<Double> {
            let raw = hand[joint]
            return SIMD2((1 - raw.x) * HandLandmarks.frameAspect, raw.y)
        }
        func distance(_ a: J, _ b: J) -> Double {
            let d = p(a) - p(b)
            return (d.x * d.x + d.y * d.y).squareRoot()
        }

        let palm = distance(.wrist, .middleMCP)
        guard palm > 0 else { return nil }

        anchor = (p(.wrist) + p(.indexMCP) + p(.middleMCP)) / 3
        indexPinch = distance(.thumbTip, .indexTip) / palm
        let fingers: [(tip: J, pip: J)] = [(.indexTip, .indexPIP), (.middleTip, .middlePIP),
                                           (.ringTip, .ringPIP), (.littleTip, .littlePIP)]
        fingerRatios = fingers.map { distance($0.tip, .wrist) / max(distance($0.pip, .wrist), 1e-6) }
    }
}
