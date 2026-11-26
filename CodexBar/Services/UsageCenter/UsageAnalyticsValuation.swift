import Foundation

/// 按日额度权重和混合单价反推模型 Token, 缓存仍只保存官方原值
nonisolated enum UsageAnalyticsValuation {
    static func merge(_ windows: [UsageObservedWindow], acrossSources: Bool = false) -> [UsageObservedWindow] {
        var result: [UsageObservedWindow] = []
        for raw in windows.sorted(by: { $0.resetsAt < $1.resetsAt }) {
            let window = normalized(raw)
            if let previous = result.last, sameWindow(previous, window) {
                var combined = previous
                if previous.maxUsed == 0 {
                    combined.resetsAt = window.resetsAt
                }
                combined.observations += window.observations
                combined.decreased = previous.decreased || window.decreased
                if acrossSources, !combined.decreased {
                    // 不同设备会收到迟到的较旧回执, 单来源真实回落仍由质量标记保留
                    var highest = -1.0
                    combined.observations = combined.observations.sorted { ($0.at, $0.used) < ($1.at, $1.used) }.filter { point in
                        guard point.used >= highest else { return false }
                        highest = point.used
                        return true
                    }
                }
                result[result.count - 1] = normalized(combined, detectsRegression: !acrossSources)
            } else {
                result.append(normalized(window))
            }
        }
        return result
    }

    private static func sameWindow(_ lhs: UsageObservedWindow, _ rhs: UsageObservedWindow) -> Bool {
        let difference = abs(lhs.resetsAt - rhs.resetsAt)
        if difference <= 2 {
            return true
        }
        // 截止时间有秒级抖动时, 用观察时段重叠确认是同一窗口, 不吞掉实际相邻重置
        return difference <= 60 && lhs.firstAt <= rhs.lastAt && rhs.firstAt <= lhs.lastAt
    }

    private static func normalized(_ window: UsageObservedWindow, detectsRegression: Bool = true) -> UsageObservedWindow {
        var result = window
        let points = Dictionary(window.observations.map { ("\($0.at):\($0.used)", $0) }, uniquingKeysWith: { first, _ in first })
            .values.sorted { ($0.at, $0.used) < ($1.at, $1.used) }
        guard let first = points.first, let last = points.last else { return result }
        result.firstAt = first.at
        result.firstUsed = first.used
        result.lastAt = last.at
        result.lastUsed = last.used
        result.maxUsed = points.map(\.used).max() ?? last.used
        result.decreased = result.decreased || (detectsRegression && zip(points, points.dropFirst()).contains { $1.used + 1 < $0.used })
        // 同一天相同百分比只保留首尾, 避免分钟级观测无限增长
        var buckets: [String: [UsageQuotaPoint]] = [:]
        for point in points {
            let key = "\(Int(point.at / 86400)):\(point.used)"
            if buckets[key] == nil {
                buckets[key] = [point]
            } else if buckets[key]?.count == 1 {
                buckets[key]?.append(point)
            } else {
                buckets[key]?[1] = point
            }
        }
        result.observations = buckets.values.flatMap(\.self).sorted { ($0.at, $0.used) < ($1.at, $1.used) }
        return result
    }

    static func settledWindows(_ windows: [UsageObservedWindow], acrossSources: Bool = false) -> [UsageObservedWindow] {
        var result: [UsageObservedWindow] = []
        for window in merge(windows, acrossSources: acrossSources) {
            // 零用量时重置时间可能在首次请求前后漂移, 原始证据保留在缓存中
            if let previous = result.last, previous.maxUsed == 0, window.firstUsed == 0,
               window.resetsAt - previous.resetsAt <= 300 {
                var settled = window
                settled.observations += previous.observations
                result[result.count - 1] = normalized(settled, detectsRegression: !acrossSources)
            } else {
                result.append(window)
            }
        }
        return result
    }

    private static func dayDate(_ key: String) -> Date? {
        ISO8601DateFormatter().date(from: key + "T00:00:00Z")
    }

    struct PeriodWindow {
        let window: UsageObservedWindow
        let start: Double
        let end: Double
    }

    private static func periodWindows(_ source: [UsageObservedWindow], acrossSources: Bool) -> [PeriodWindow] {
        let windows = settledWindows(source, acrossSources: acrossSources)
        return windows.enumerated().map { index, window in
            let next = windows.indices.contains(index + 1) ? windows[index + 1].resetsAt - 604800 : window.resetsAt
            return PeriodWindow(window: window, start: window.resetsAt - 604800, end: min(window.resetsAt, next))
        }
    }

    static func periods(
        snapshot: UsageAnalyticsSnapshot, prices: UsagePriceBook, now: Date = Date(), sourceWindows: [UsageObservedWindow] = [],
        tokenSources: [UsageTokenSource] = [], expectedTokenSources: Int = 0, plans: [UsagePlanObservation] = []
    ) -> [UsageAnalyticsPeriod] {
        let cutoff = min(now.timeIntervalSince1970, snapshot.fetchedAt.timeIntervalSince1970)
        let contexts = periodWindows(snapshot.windows + sourceWindows, acrossSources: !sourceWindows.isEmpty)
        let days = indexedDays(snapshot.days)
        let estimates = days.mapValues { UsageModelAllocation.estimate(day: $0, prices: prices) }
        let officialDays = days.filter { key, day in (day.tokens?.total ?? 0) > 0 && (estimates[key] ?? nil) != nil }
        let valued = contexts.compactMap { context -> UsageAnalyticsPeriod? in
            guard !Task<Never, Never>.isCancelled, context.start < now.timeIntervalSince1970, context.end > context.start,
                  context.end > (dayDate(snapshot.queryStart)?.timeIntervalSince1970 ?? 0) else { return nil }
            var period = modelBasedPeriod(context, contexts: contexts, days: days, estimates: estimates, prices: prices, cutoff: cutoff)
            period.deviceEstimate = UsageLogValuation.estimate(
                context: context, officialDays: officialDays, needsFallback: period.missingDays > 0 || !period.unknownModels.isEmpty || (period.dollars ?? 0) <= 0,
                prices: prices, sources: tokenSources, expectedSources: expectedTokenSources, now: now, plans: plans
            )
            return period
        }
        let ledger = CreditLedger(
            days: days,
            estimates: estimates,
            contexts: contexts,
            periods: valued,
            plans: plans,
            fetchedAt: cutoff,
            now: now.timeIntervalSince1970
        )
        let byReset = Dictionary(contexts.map { ($0.window.resetsAt, $0) }, uniquingKeysWith: { first, _ in first })
        return valued.reversed().map { value in
            var period = value
            if let context = byReset[period.id] {
                period.creditEstimate = ledger.estimate(context, device: period.deviceEstimate)
            }
            return period
        }
    }

    private static func modelBasedPeriod(
        _ context: PeriodWindow,
        contexts: [PeriodWindow],
        days: [Int: AnalyticsDay],
        estimates: [Int: [UsageModelEstimate]?],
        prices: UsagePriceBook,
        cutoff: Double
    ) -> UsageAnalyticsPeriod {
        var models: [String: UsageModelEstimate] = [:]
        var tokens = AnalyticsTokens.zero
        var missing = 0
        var boundaries = 0
        var timeAllocated = 0
        var unknown: Set<String> = []
        var totalWeight = 0.0
        var dayStart = floor(context.start / 86400) * 86400
        while dayStart < min(context.end, cutoff) {
            let dayEnd = min(dayStart + 86400, cutoff)
            let key = Int(dayStart / 86400)
            let allocation = dayShare(context, among: contexts, start: dayStart, end: dayEnd)
            if allocation.boundary {
                boundaries += 1
            }
            if allocation.usedTime {
                timeAllocated += 1
            }
            let dayWeight = (days[key]?.models.reduce(0) { $0 + max(0, $1.weight) } ?? 0) * allocation.share
            totalWeight += dayWeight
            if let day = days[key], let total = day.tokens,
               total.total > 0 || !day.models.contains(where: { $0.weight > 0 }) {
                tokens += UsageModelAllocation.scaled(total, by: allocation.share)
                if let rows = estimates[key] ?? nil {
                    for row in rows {
                        var item = models[row.id] ?? UsageModelEstimate(
                            model: row.model, speed: row.speed, tokens: .zero, dollars: 0, credits: row.credits == nil ? nil : 0, weight: 0
                        )
                        item.tokens += UsageModelAllocation.scaled(row.tokens, by: allocation.share)
                        item.dollars += row.dollars * allocation.share
                        item.weight += row.weight * allocation.share
                        if let credits = row.credits {
                            item.credits = (item.credits ?? 0) + credits * allocation.share
                        }
                        models[row.id] = item
                    }
                } else if total.total > 0 {
                    for model in day.models where UsageModelAllocation.multiplier(model: model, prices: prices) == nil {
                        unknown.insert(model.model + (model.speed == "standard" ? "" : " · " + model.speed))
                    }
                    if !day.models.contains(where: { $0.weight > 0 }) {
                        unknown.insert("未提供有效模型")
                    }
                }
            } else if dayWeight > 0 {
                missing += 1
            }
            dayStart += 86400
        }
        let rows = models.values.sorted { $0.dollars > $1.dollars }
        let hasUnpricedData = missing > 0 || !unknown.isEmpty
        let used = consumption(context, at: min(context.end, cutoff))
        let dollars = rows.isEmpty && (hasUnpricedData || used > 0 || context.window.lastUsed > 0) ? nil : rows.reduce(0) { $0 + $1.dollars }
        let credits = !rows.isEmpty && rows.allSatisfy { $0.credits != nil } ? rows.reduce(0) { $0 + ($1.credits ?? 0) } : nil
        let pricedWeight = rows.reduce(0) { $0 + $1.weight }
        let coverage = hasUnpricedData && totalWeight > 0 ? min(1, pricedWeight / totalWeight) : 1
        let samplePercent = used * coverage
        return UsageAnalyticsPeriod(
            start: Date(timeIntervalSince1970: context.start), end: Date(timeIntervalSince1970: context.end),
            scheduledEnd: Date(timeIntervalSince1970: context.window.resetsAt), usedPercent: context.window.lastUsed,
            valuedPercent: used, samplePercent: samplePercent, valuedThrough: Date(timeIntervalSince1970: min(context.end, cutoff)),
            tokens: tokens, dollars: dollars, projected: !context.window.decreased && samplePercent > 0 ? dollars.map { $0 * 100 / samplePercent } : nil,
            credits: credits, models: rows,
            boundaryDays: boundaries, timeAllocatedDays: timeAllocated, missingDays: missing,
            unknownModels: unknown.sorted(), unreliable: context.window.decreased
        )
    }

    private struct CreditSpan {
        let start: Double
        var end: Double
        var low: Double
        var high: Double
    }

    private struct SettledDay {
        let day: AnalyticsDay
        let credits: Double
        let shares: [Double: Double]
        let fallbackScale: Double
        let matchedTokens: Bool
    }

    private struct CreditLedger {
        private let reports: [Int: SettledDay]
        let estimates: [Int: [UsageModelEstimate]?]
        let now: Double

        init(
            days: [Int: AnalyticsDay],
            estimates: [Int: [UsageModelEstimate]?],
            contexts: [PeriodWindow],
            periods: [UsageAnalyticsPeriod],
            plans: [UsagePlanObservation],
            fetchedAt: Double,
            now: Double
        ) {
            self.estimates = estimates
            self.now = now
            var parts: [Int: [Double: UsageCreditPart]] = [:]
            var conflicts = Set<Int>()
            for period in periods {
                guard let device = period.deviceEstimate else { continue }
                conflicts.formUnion(device.conflictingDays)
                for (key, part) in device.days {
                    parts[key, default: [:]][period.id] = part
                }
            }
            var settled: [Int: SettledDay] = [:]
            for (key, day) in days {
                let start = Double(key) * 86400
                let end = start + 86400
                guard end <= fetchedAt, let credits = day.reportedCredits, credits.isFinite, credits >= 0 else { continue }
                let windows = contexts.filter { $0.start < end && $0.end > start }
                let slices = parts[key] ?? [:]
                var total = UsageCreditPart()
                for part in slices.values {
                    total.add(part)
                }
                if credits == 0, (day.tokens?.total ?? 0) == 0,
                   total.credits.upperBound > 0 || day.models.contains(where: { $0.weight > 0 }) || windows.contains(where: {
                       (Self.delta($0, from: start, to: end) ?? 0) > 0
                   }) {
                    continue
                }
                if fetchedAt - end < 86400, !conflicts.contains(key), let local = total.tokens, let official = day.tokens,
                   local != official, local.input >= official.input, local.cached >= official.cached, local.output >= official.output {
                    continue
                }
                let matched = !conflicts.contains(key) && day.tokens != nil && total.tokens == day.tokens
                let shares = Self.shares(windows: windows, day: start ..< end, parts: slices, total: total, matched: matched, plans: plans)
                // 无法拆分的日报仍约束所有设备估算之和, 剩余金额留在未归属的报告日
                let scale = total.credits.upperBound > credits ? credits / total.credits.upperBound : 1
                settled[key] = SettledDay(day: day, credits: credits, shares: shares, fallbackScale: scale, matchedTokens: matched)
            }
            reports = settled
        }

        private static func shares(
            windows: [PeriodWindow],
            day: Range<Double>,
            parts: [Double: UsageCreditPart],
            total: UsageCreditPart,
            matched: Bool,
            plans: [UsagePlanObservation]
        ) -> [Double: Double] {
            if let single = windows.first, single.start <= day.lowerBound, single.end >= day.upperBound {
                return [single.window.resetsAt: 1]
            }
            if matched, total.credits.lowerBound > 0, total.credits.lowerBound == total.credits.upperBound {
                return Dictionary(uniqueKeysWithValues: windows.map {
                    ($0.window.resetsAt, (parts[$0.window.resetsAt]?.credits.lowerBound ?? 0) / total.credits.lowerBound)
                })
            }
            // 只有完整覆盖报告日的相邻周期才能分走整笔日报, 周限比例必须使用同一档位
            guard let first = windows.first, let last = windows.last, first.start <= day.lowerBound, last.end >= day.upperBound,
                  zip(windows, windows.dropFirst()).allSatisfy({ $0.end == $1.start }),
                  Set(plans.filter { entry in windows.contains { abs($0.window.resetsAt - entry.resetsAt) <= 2 } }.map(\.plan)).count <= 1 else { return [:] }
            var weights: [Double: Double] = [:]
            for context in windows {
                guard let change = delta(context, from: day.lowerBound, to: day.upperBound) else { return [:] }
                weights[context.window.resetsAt] = change
            }
            let sum = weights.values.reduce(0, +)
            return sum > 0 ? weights.mapValues { $0 / sum } : [:]
        }

        private static func delta(_ context: PeriodWindow, from start: Double, to end: Double) -> Double? {
            guard !context.window.decreased, let a = alignedPercent(context, at: max(start, context.start)),
                  let b = alignedPercent(context, at: min(end, context.end)), b >= a else { return nil }
            return b - a
        }

        func estimate(_ context: PeriodWindow, device: UsageLogEstimate?) -> UsageCreditEstimate? {
            let limit = min(context.end, now)
            var recorded = UsageCreditPart(tokens: nil)
            var spans: [CreditSpan] = []
            var settledWholeDays: [CreditSpan] = []
            var hasOfficial = false
            var hasDevice = false
            var dayStart = floor(context.start / 86400) * 86400
            while dayStart < limit {
                defer { dayStart += 86400 }
                let key = Int(dayStart / 86400)
                let lower = max(context.start, dayStart)
                let upper = min(limit, dayStart + 86400)
                let part: UsageCreditPart
                let through: Double
                if let report = reports[key], let share = report.shares[context.window.resetsAt] {
                    let official = officialPart(report, key: key, share: share, device: device?.days[key])
                    part = official
                    through = upper
                    hasOfficial = true
                    if lower == dayStart, upper == dayStart + 86400 {
                        append(official.credits, from: lower, to: through, into: &settledWholeDays)
                    }
                } else if let device, let local = device.days[key], !device.conflictingDays.contains(key) {
                    part = local.scalingCredits(by: reports[key]?.fallbackScale ?? 1)
                    through = min(upper, device.valuedThrough.timeIntervalSince1970)
                    hasDevice = true
                } else {
                    continue
                }
                guard through > lower else { continue }
                recorded.add(part)
                append(part.credits, from: lower, to: through, into: &spans)
            }
            guard !spans.isEmpty else { return nil }
            // 进行中的周期优先用完整日报预测, 已结束的周期结算所有有对应额度读数的区段
            let settled = limit < context.end ? forecast(settledWholeDays, context: context, minimumChange: 1) : nil
            let projected = settled ?? forecast(spans, context: context, minimumChange: 0)
            return UsageCreditEstimate(recorded: recorded, projected: projected, hasOfficial: hasOfficial, hasDevice: hasDevice)
        }

        private func append(_ amount: ClosedRange<Double>, from start: Double, to end: Double, into spans: inout [CreditSpan]) {
            if spans.last?.end == start {
                spans[spans.count - 1].end = end
                spans[spans.count - 1].low += amount.lowerBound
                spans[spans.count - 1].high += amount.upperBound
            } else {
                spans.append(CreditSpan(start: start, end: end, low: amount.lowerBound, high: amount.upperBound))
            }
        }

        private func forecast(_ spans: [CreditSpan], context: PeriodWindow, minimumChange: Double) -> ClosedRange<Double>? {
            guard !context.window.decreased else { return nil }
            var low = 0.0
            var high = 0.0
            var used = 0.0
            for span in spans {
                guard let first = Self.alignedPercent(context, at: span.start), let last = Self.alignedPercent(context, at: span.end),
                      last > first, span.high > 0 else { continue }
                low += span.low
                high += span.high
                used += last - first
            }
            guard used > minimumChange else { return nil }
            let factor = 100 / used
            return UsageCreditEstimate.dollars(low * factor ... high * factor)
        }

        private func officialPart(_ report: SettledDay, key: Int, share: Double, device: UsageCreditPart?) -> UsageCreditPart {
            let day = report.day
            let amount = report.credits * share
            if report.matchedTokens, let device, device.credits.lowerBound > 0,
               device.credits.lowerBound == device.credits.upperBound, report.shares.count > 1 {
                return device.scalingCredits(by: amount / device.credits.lowerBound)
            }
            var part = UsageCreditPart(credits: amount ... amount, tokens: day.tokens.map { UsageModelAllocation.scaled($0, by: share) } ?? device?.tokens)
            let weight = day.models.reduce(0) { $0 + $1.weight }
            for model in day.models where model.weight > 0 && weight > 0 {
                let modelAmount = amount * model.weight / weight
                part.addModelCredits(modelAmount ... modelAmount, for: model.model)
            }
            for row in (estimates[key] ?? nil) ?? [] {
                part.modelTokens[row.model, default: .zero] += UsageModelAllocation.scaled(row.tokens, by: share)
            }
            if day.tokens == nil, let device {
                part.modelTokens = device.modelTokens
            }
            return part
        }

        private static func alignedPercent(_ context: PeriodWindow, at time: Double) -> Double? {
            if time == context.start {
                return 0
            }
            // 旧窗口回执可能在重置后才送达, 它携带的截止标识仍属于原周期
            if time == context.end {
                return context.window.lastUsed
            }
            let points = context.window.observations
            guard let before = points.last(where: { $0.at <= time && $0.at >= context.start }) else {
                return points.first(where: { $0.at >= context.start })?.used == 0 ? 0 : nil
            }
            guard before.at < time, let after = points.first(where: { $0.at >= time }) else { return before.used }
            if before.used == after.used {
                return before.used
            }
            // 缺报段边缘只在同一读数或一次正常刷新间隔内对齐, 不跨长空档摊百分比
            guard after.at - before.at <= 900 else { return nil }
            return before.used + (after.used - before.used) * (time - before.at) / (after.at - before.at)
        }
    }

    private static func indexedDays(_ source: [AnalyticsDay]) -> [Int: AnalyticsDay] {
        let formatter = ISO8601DateFormatter()
        let values = source.compactMap { day -> (Int, AnalyticsDay)? in
            guard let date = formatter.date(from: day.date + "T00:00:00Z") else { return nil }
            return (Int(date.timeIntervalSince1970 / 86400), day)
        }
        return Dictionary(values, uniquingKeysWith: { _, last in last })
    }

    static func consumption(_ context: PeriodWindow, at time: Double) -> Double {
        let points = context.window.observations.filter { $0.at >= context.start && $0.at <= context.end }
        var previous = UsageQuotaPoint(at: context.start, used: 0)
        for point in points {
            if point.at >= time {
                let fraction = point.at > previous.at ? max(0, min(1, (time - previous.at) / (point.at - previous.at))) : 1
                return previous.used + (point.used - previous.used) * fraction
            }
            previous = point
        }
        return previous.used
    }

    private struct DayShare {
        let share: Double
        let boundary: Bool
        let usedTime: Bool
    }

    private static func dayShare(_ current: PeriodWindow, among contexts: [PeriodWindow], start: Double, end: Double) -> DayShare {
        let overlap = max(0, min(end, current.end) - max(start, current.start))
        guard end > start, overlap > 0 else { return DayShare(share: 0, boundary: true, usedTime: false) }
        if current.start <= start, current.end >= end {
            return DayShare(share: 1, boundary: false, usedTime: false)
        }
        let candidates = contexts.filter { $0.start < end && $0.end > start }
        let coverage = candidates.reduce(0) { $0 + max(0, min(end, $1.end) - max(start, $1.start)) }
        let deltas = candidates.map { context in
            max(0, consumption(context, at: min(end, context.end)) - consumption(context, at: max(start, context.start)))
        }
        let sum = deltas.reduce(0, +)
        if coverage >= end - start - 1, sum > 0, !candidates.contains(where: \.window.decreased),
           let index = candidates.firstIndex(where: { $0.window.resetsAt == current.window.resetsAt }) {
            return DayShare(share: deltas[index] / sum, boundary: true, usedTime: false)
        }
        return DayShare(share: overlap / (end - start), boundary: true, usedTime: true)
    }
}
