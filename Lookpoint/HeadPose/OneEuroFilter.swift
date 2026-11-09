import Foundation

/// One-Euro filter (Casiez et al., CHI 2012): smooths hard when the signal is
/// still, follows quickly when it moves fast.
struct OneEuroFilter {
    /// Cutoff in Hz when the signal is still. Lower = smoother, more lag.
    var minCutoff: Double
    /// How much the cutoff rises with speed. Higher = less lag on fast moves.
    var beta: Double
    /// Cutoff in Hz for the derivative estimate.
    var derivativeCutoff: Double = 1.0

    private var lastValue: Double?
    private var lastDerivative = 0.0
    private var lastTime: TimeInterval?

    init(minCutoff: Double, beta: Double, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: Double, at time: TimeInterval) -> Double {
        guard let previous = lastValue, let previousTime = lastTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - previousTime
        guard dt > 0 else { return previous }

        let derivative = (value - previous) / dt
        lastDerivative += Self.alpha(cutoff: derivativeCutoff, dt: dt) * (derivative - lastDerivative)

        let cutoff = minCutoff + beta * abs(lastDerivative)
        let filtered = previous + Self.alpha(cutoff: cutoff, dt: dt) * (value - previous)

        lastValue = filtered
        lastTime = time
        return filtered
    }

    mutating func reset() {
        lastValue = nil
        lastDerivative = 0
        lastTime = nil
    }

    private static func alpha(cutoff: Double, dt: TimeInterval) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
