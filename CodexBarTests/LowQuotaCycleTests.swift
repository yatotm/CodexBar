import Foundation
import Testing

@MainActor
struct LowQuotaCycleTests {
    @Test func aNewCycleCanWarnEvenIfPreviousCycleWasAlreadyLow() {
        var observation = CodexNotificationService.LowQuotaObservation()
        let reset = TestFixtures.now
        let result0 = observation.observe(remainingPercent: 5, resetsAt: reset, thresholdPercent: 10)
        #expect(result0)
        let result1 = observation.observe(remainingPercent: 4, resetsAt: reset, thresholdPercent: 10)
        #expect(!result1)
        let result2 = observation.observe(remainingPercent: 3, resetsAt: reset.addingTimeInterval(86400), thresholdPercent: 10)
        #expect(result2)
    }

    @Test func repeatedSmallDriftDoesNotMoveTheCycleAnchor() {
        var observation = CodexNotificationService.LowQuotaObservation()
        let reset = TestFixtures.now
        let result3 = observation.observe(remainingPercent: 5, resetsAt: reset, thresholdPercent: 10)
        #expect(result3)
        let result4 = observation.observe(remainingPercent: 5, resetsAt: reset.addingTimeInterval(40), thresholdPercent: 10)
        #expect(!result4)
        let result5 = observation.observe(remainingPercent: 5, resetsAt: reset.addingTimeInterval(80), thresholdPercent: 10)
        #expect(result5)
    }

    @Test func unknownResetDoesNotConsumeTheFirstKnownWarning() {
        var observation = CodexNotificationService.LowQuotaObservation()
        let result6 = observation.observe(remainingPercent: 5, resetsAt: nil, thresholdPercent: 10)
        #expect(!result6)
        let result7 = observation.observe(remainingPercent: 5, resetsAt: TestFixtures.now, thresholdPercent: 10)
        #expect(result7)
    }
}
