import Foundation
import Testing

struct UsageHeatmapTests {
    @Test func weeklyRangeKeepsFutureDaysOutOfTotalsAcrossYearBoundary() throws {
        let days: [UsageHeatmapDay?] = [
            day("2026-12-27", tokens: .available(10)),
            day("2026-12-28", tokens: .available(20)),
            day("2026-12-29", tokens: .pending), nil, nil, nil, nil
        ]
        let weeks = UsageHeatmapPeriod.weeks(in: days)
        let week = try #require(weeks.first ?? nil)
        #expect(week.day.startDate == "2026-12-27")
        #expect(week.endDate == "2027-01-02")
        #expect(week.day.tokenCount == 30)
        #expect(week.filledRowCount(peakTokens: 30) == 7)
        #expect(week.filledRowCount(peakTokens: 60) == 4)
        #expect(week.filledRowCount(peakTokens: 0) == 0)
    }

    @Test func unavailableOfficialTotalsDoNotDiscardDeviceLogs() throws {
        let days = [day("2026-11-01", tokens: .unavailable), day("2026-11-02", tokens: .available(20))]
        let week = try #require(UsageHeatmapPeriod.weeks(in: days).first ?? nil)
        #expect(week.day.tokenState == .unavailable)
        let recorded = try #require(week.recordedUsage(in: [
            UsageDay(day: "2026-10-31", tokens: 1000),
            UsageDay(day: "2026-11-01", tokens: 30, metrics: UsageMetrics(tokens: 30, turns: 1)),
            UsageDay(day: "2026-11-02", tokens: 40, metrics: UsageMetrics(tokens: 40, turns: 2)),
            UsageDay(day: "2026-11-03", tokens: 3000),
            UsageDay(day: "2026-11-08", tokens: 2000)
        ]))
        #expect(recorded.tokens == 70)
        #expect(recorded.metrics?.turns == 3)
        #expect(recorded.metrics?.interruptions == nil)
    }

    @Test func weeklyMainModelUsesAllModelTotalsInsteadOfDailyWinners() throws {
        let week = try #require(UsageHeatmapPeriod.weeks(in: [day("2026-11-01", tokens: .available(0)), day("2026-11-02", tokens: .available(0))]).first ?? nil)
        let recorded = try #require(week.recordedUsage(in: [
            UsageDay(
                day: "2026-11-01",
                tokens: 190,
                metrics: UsageMetrics(tokens: 190, sessions: 2, interruptions: 0),
                topModel: "first",
                longestTurnMs: 100,
                modelTokens: ["first": 100, "shared": 90]
            ),
            UsageDay(
                day: "2026-11-02",
                tokens: 190,
                metrics: UsageMetrics(tokens: 190, sessions: 3, interruptions: 1),
                topModel: "second",
                longestTurnMs: 80,
                modelTokens: ["second": 100, "shared": 90]
            )
        ]))
        #expect(recorded.topModel == "shared")
        #expect(recorded.modelTokens["shared"] == 180)
        #expect(recorded.metrics?.sessions == 5)
        #expect(recorded.metrics?.interruptions == 1)
        #expect(recorded.longestTurnMs == 100)
    }

    @Test func weeklyUnknownCountersRemainUnknownWhileKnownZerosStayZero() throws {
        let week = try #require(UsageHeatmapPeriod.weeks(in: [day("2026-11-01", tokens: .available(0)), day("2026-11-02", tokens: .available(0))]).first ?? nil)
        let unknown = try #require(week.recordedUsage(in: [
            UsageDay(day: "2026-11-01", tokens: 10, topModel: "only-daily-winner"),
            UsageDay(day: "2026-11-02", tokens: 20, metrics: UsageMetrics(tokens: 20, interruptions: 0))
        ]))
        #expect(unknown.tokens == 30)
        #expect(unknown.metrics == nil)
        #expect(unknown.topModel == nil)
        let zero = try #require(week.recordedUsage(in: [
            UsageDay(day: "2026-11-01", tokens: 0, metrics: UsageMetrics(interruptions: 0))
        ]))
        #expect(zero.metrics?.turns == 0)
        #expect(zero.metrics?.interruptions == 0)
    }

    @Test func overflowingWeeklyCountsDoNotWrapOrCrash() throws {
        let days = [day("2026-11-01", tokens: .available(.max)), day("2026-11-02", tokens: .available(1))]
        let week = try #require(UsageHeatmapPeriod.weeks(in: days).first ?? nil)
        #expect(week.day.tokenState == .unavailable)
        #expect(week.recordedUsage(in: [UsageDay(day: "2026-11-01", tokens: .max), UsageDay(day: "2026-11-02", tokens: 1)]) == nil)
        let metrics = try #require(week.recordedUsage(in: [
            UsageDay(day: "2026-11-01", tokens: 1, metrics: UsageMetrics(turns: .max)),
            UsageDay(day: "2026-11-02", tokens: 1, metrics: UsageMetrics(turns: 1))
        ]))
        #expect(metrics.tokens == 2)
        #expect(metrics.metrics == nil)
    }

    @Test func dailyDetailKeepsItsOriginalMetricsAndModel() {
        let period = UsageHeatmapPeriod(day: day("2026-11-02", tokens: .pending))
        let source = UsageDay(day: "2026-11-02", tokens: 22, metrics: UsageMetrics(tokens: 22, interruptions: nil), topModel: "daily")
        #expect(!period.isWeekly)
        #expect(period.recordedUsage(in: [source]) == source)
        #expect(period.day.tokenState == .pending)
        #expect(period.recordedUsage(in: [])?.tokens == 0)
        #expect(period.recordedUsage(in: [])?.metrics == nil)
    }

    @Test func weekSelectionUsesWholeColumnAndTracksDateAfterGridMoves() throws {
        let days: [UsageHeatmapDay?] = [day("2026-11-01", tokens: .available(1)), day("2026-11-02", tokens: .available(2)), nil, nil, nil, nil, nil]
        let selection = try #require(UsageHeatmapSelection.at(column: 0, row: 0, in: days, mode: .weekly))
        for row in 0 ..< 7 {
            #expect(UsageHeatmapSelection.at(column: 0, row: row, in: days, mode: .weekly) == selection)
        }
        #expect(UsageHeatmapSelection.at(column: 0, row: 6, in: days, mode: .daily) == nil)
        #expect(UsageHeatmapSelection.at(column: 1, row: 0, in: days, mode: .weekly) == nil)
        let moved: [UsageHeatmapDay?] = Array(repeating: nil, count: 7) + days
        #expect(selection.column(in: moved) == 1)
        #expect(selection.period(in: moved, weeks: UsageHeatmapPeriod.weeks(in: moved))?.day.tokenCount == 3)
        #expect(selection.period(in: [], weeks: []) == nil)
    }

    @Test func emptyWeeksAndPendingTotalsStayDistinctFromKnownZero() throws {
        #expect(UsageHeatmapPeriod.weeks(in: []).isEmpty)
        #expect(UsageHeatmapPeriod.weeks(in: Array(repeating: nil, count: 7)) == [nil])
        let pending = try #require(UsageHeatmapPeriod.weeks(in: [day("2026-11-01", tokens: .pending)]).first ?? nil)
        let zero = try #require(UsageHeatmapPeriod.weeks(in: [day("2026-11-01", tokens: .available(0))]).first ?? nil)
        #expect(pending.day.tokenState == .pending)
        #expect(zero.day.tokenState == .available(0))
    }

    private func day(_ key: String, tokens: UsageHeatmapTokenState) -> UsageHeatmapDay {
        UsageHeatmapDay(startDate: key, tokenState: tokens, workflow: .empty(startDate: key))
    }
}
