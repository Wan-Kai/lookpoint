import Testing
@testable import Lookpoint

struct OneEuroFilterTests {
    @Test func firstSamplePassesThrough() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 0.02)
        #expect(filter.filter(12.5, at: 0) == 12.5)
    }

    @Test func constantSignalStaysConstant() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 0.02)
        for index in 0..<50 {
            #expect(filter.filter(5, at: Double(index) * 0.1) == 5)
        }
    }

    @Test func reducesJitter() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 0.02)
        let raw = (0..<100).map { $0.isMultiple(of: 2) ? 1.0 : -1.0 }
        let smoothed = raw.enumerated().map { filter.filter($1, at: Double($0) * 0.1) }
        let spread = smoothed.dropFirst(20).map(abs).max() ?? .infinity
        #expect(spread < 0.6)
    }

    @Test func followsAStep() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 0.02)
        _ = filter.filter(0, at: 0)
        var value = 0.0
        for index in 1...10 {
            value = filter.filter(30, at: Double(index) * 0.1)
        }
        // Within a second the output is close to the new value.
        #expect(value > 28)
    }

    @Test func ignoresNonIncreasingTime() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 0.02)
        _ = filter.filter(1, at: 1)
        #expect(filter.filter(100, at: 1) == 1)
    }

    @Test func resetStartsOver() {
        var filter = OneEuroFilter(minCutoff: 1, beta: 0.02)
        _ = filter.filter(1, at: 0)
        filter.reset()
        #expect(filter.filter(40, at: 0.1) == 40)
    }
}
