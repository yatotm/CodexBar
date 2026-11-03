import Foundation

nonisolated enum UsageHeatmapTokenState: Equatable {
    case available(Int)
    case pending
    case unavailable

    var count: Int? {
        guard case let .available(count) = self else {
            return nil
        }

        return count
    }
}

/// 热力图单元格模型, 合并 app-server token 数据和本地 Hook 工作流统计
nonisolated struct UsageHeatmapDay: Equatable, Identifiable {
    let startDate: String
    let tokenState: UsageHeatmapTokenState
    let workflow: WorkflowDailyMetrics

    var id: String {
        startDate
    }

    var tokenCount: Int? {
        tokenState.count
    }

    var tokensForHeatmap: Int {
        tokenCount ?? 0
    }

    static func grid(
        usage: CodexUsageSnapshot?,
        workflow: WorkflowSnapshot,
        showsWorkflow: Bool,
        columnCount: Int,
        today: Date
    ) -> [UsageHeatmapDay?] {
        let todayTokenCount = usage?.tokenCount(on: today)
        let hasDailyUsageBuckets = usage?.hasDailyUsageBuckets == true
        // Hook 开启时当天工作流统计可见
        // Hook 关闭时只在 token bucket 已返回时展示今天
        let endingDaysAgo = showsWorkflow || todayTokenCount != nil ? 0 : 1
        let workflowByDate = workflow.dailyMetrics.reduce(into: [String: WorkflowDailyMetrics]()) { result, metrics in
            result[metrics.startDate] = metrics
        }
        let todayString = CodexDateFormat.dayString(from: today)

        return CodexWeekGrid.dates(
            columnCount: columnCount,
            endingDaysAgo: endingDaysAgo,
            today: today
        )
        .map { date -> UsageHeatmapDay? in
            guard let date else {
                return nil
            }

            let startDate = CodexDateFormat.dayString(from: date)
            let tokenState: UsageHeatmapTokenState = if !hasDailyUsageBuckets {
                .unavailable
            } else if startDate == todayString, let todayTokenCount {
                .available(todayTokenCount)
            } else if startDate == todayString {
                .pending
            } else {
                .available(usage?.tokenCount(on: date) ?? 0)
            }
            return UsageHeatmapDay(
                startDate: startDate,
                tokenState: tokenState,
                workflow: workflowByDate[startDate] ?? .empty(startDate: startDate)
            )
        }
    }
}

nonisolated enum UsageHeatmapMode: String {
    case daily
    case weekly

    static let preferenceKey = "UsageHeatmap.displayMode"
}

/// 周汇总只合并当前网格已有日期, 设备日志独立于官方 Token 的可用状态
nonisolated struct UsageHeatmapPeriod: Equatable {
    let day: UsageHeatmapDay
    let endDate: String
    let dayKeys: Set<String>

    var isWeekly: Bool {
        endDate != day.startDate
    }

    var tokensForHeatmap: Int {
        day.tokensForHeatmap
    }

    init(day: UsageHeatmapDay) {
        self.day = day
        endDate = day.startDate
        dayKeys = [day.startDate]
    }

    private init?(weekDays: [UsageHeatmapDay]) {
        guard let first = weekDays.first,
              let start = CodexDateFormat.dayDate(from: first.startDate),
              let end = CodexDateFormat.localGregorianCalendar.date(byAdding: .day, value: CodexWeekGrid.rowCount - 1, to: start) else {
            return nil
        }
        endDate = CodexDateFormat.dayString(from: end)
        dayKeys = Set(weekDays.map(\.startDate))
        day = UsageHeatmapDay(
            startDate: first.startDate,
            tokenState: Self.totalTokenState(weekDays),
            workflow: weekDays.dropFirst().reduce(first.workflow) { $0.adding($1.workflow) }
        )
    }

    func filledRowCount(peakTokens: Int) -> Int {
        guard tokensForHeatmap > 0, peakTokens > 0 else { return 0 }
        return max(1, Int(ceil(min(Double(tokensForHeatmap) / Double(peakTokens), 1) * Double(CodexWeekGrid.rowCount))))
    }

    static func weeks(in days: [UsageHeatmapDay?]) -> [UsageHeatmapPeriod?] {
        stride(from: 0, to: days.count, by: CodexWeekGrid.rowCount).map { start in
            UsageHeatmapPeriod(weekDays: days[start ..< min(start + CodexWeekGrid.rowCount, days.count)].compactMap(\.self))
        }
    }

    func recordedUsage(in days: [UsageDay]) -> UsageDay? {
        let selected = days.filter { dayKeys.contains($0.day) }
        if !isWeekly {
            return selected.first ?? UsageDay(day: day.startDate, tokens: 0)
        }
        var tokens: Int64 = 0
        var models: [String: Int64] = [:]
        for entry in selected {
            let sum = tokens.addingReportingOverflow(entry.tokens)
            guard !sum.overflow else { return nil }
            tokens = sum.partialValue
            for (model, count) in entry.modelTokens {
                let sum = models[model, default: 0].addingReportingOverflow(count)
                guard !sum.overflow else { return nil }
                models[model] = sum.partialValue
            }
        }
        let hasModelBreakdown = selected.allSatisfy { $0.tokens == 0 || !$0.modelTokens.isEmpty }
        let topModel = hasModelBreakdown ? models.filter { $0.value > 0 }.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }.first?.key : nil
        return UsageDay(
            day: day.startDate, tokens: tokens, metrics: Self.totalMetrics(selected), topModel: topModel,
            longestTurnMs: selected.compactMap(\.longestTurnMs).max(), modelTokens: models
        )
    }

    private static func totalTokenState(_ days: [UsageHeatmapDay]) -> UsageHeatmapTokenState {
        var total = 0
        var hasAvailableDay = false
        for day in days {
            switch day.tokenState {
            case let .available(count):
                let sum = total.addingReportingOverflow(count)
                guard !sum.overflow else { return .unavailable }
                total = sum.partialValue
                hasAvailableDay = true
            case .pending: continue
            case .unavailable: return .unavailable
            }
        }
        return hasAvailableDay ? .available(total) : .pending
    }

    private static func totalMetrics(_ days: [UsageDay]) -> UsageMetrics? {
        guard !days.isEmpty else { return nil }
        var total = UsageMetrics(interruptions: 0)
        let fields: [WritableKeyPath<UsageMetrics, Int64>] = [
            \.tokens, \.input, \.output, \.cacheRead, \.cacheWrite, \.sessions,
            \.turns, \.tools, \.permissions, \.compactions, \.subagents, \.durationMs
        ]
        for day in days {
            guard let metrics = day.metrics else { return nil }
            for field in fields {
                let sum = total[keyPath: field].addingReportingOverflow(metrics[keyPath: field])
                guard !sum.overflow else { return nil }
                total[keyPath: field] = sum.partialValue
            }
            if let lhs = total.interruptions, let rhs = metrics.interruptions {
                let sum = lhs.addingReportingOverflow(rhs)
                guard !sum.overflow else { return nil }
                total.interruptions = sum.partialValue
            } else {
                total.interruptions = nil
            }
        }
        return total
    }
}
