import Foundation

nonisolated enum UsageLogValuation {
    static func estimate(
        context: UsageAnalyticsValuation.PeriodWindow, officialDays: [Int: AnalyticsDay], needsFallback: Bool,
        prices: UsagePriceBook, sources: [UsageTokenSource], expectedSources: Int, now: Date, plans: [UsagePlanObservation] = []
    ) -> UsageLogEstimate? {
        let available = sources.filter { $0.evidence.ready && $0.evidence.scannedAt > context.start }
        guard let scannedAt = available.map(\.evidence.scannedAt).max() else { return nil }
        let quotaCutoff = context.end > now.timeIntervalSince1970 ? context.window.lastAt : context.end
        let cutoff = min(context.end, now.timeIntervalSince1970, scannedAt, quotaCutoff)
        var records: [String: UsageTokenRecord] = [:]
        var conflicts = Set<Int>()
        for source in available {
            let sourceCutoff = min(cutoff, source.evidence.scannedAt)
            for record in source.evidence.records where record.at >= context.start && record.at < context.end && record.at <= sourceCutoff {
                if let previous = records[record.id] {
                    // 复制日志只计一次, 相同请求的模型或计数冲突不能伪装成完整证据
                    if previous.model != record.model || previous.tokens != record.tokens {
                        conflicts.insert(Int(record.at / 86400))
                        conflicts.insert(Int(previous.at / 86400))
                        continue
                    }
                    if let speed = previous.speed, let other = record.speed, speed != other {
                        conflicts.insert(Int(record.at / 86400))
                        conflicts.insert(Int(previous.at / 86400))
                    }
                    var merged = previous.speed == nil && record.speed != nil ? record : previous
                    merged.requestInputTokens = previous.requestInputTokens ?? record.requestInputTokens
                    records[record.id] = merged
                    continue
                }
                records[record.id] = record
            }
        }
        let daily = Dictionary(grouping: records.values, by: { Int($0.at / 86400) })
        let missing = daily.contains { day, logs in
            guard let official = officialDays[day]?.tokens else { return true }
            let tokens = logs.reduce(.zero) { (total: AnalyticsTokens, row) in total + row.tokens }
            return tokens.input > official.input || tokens.cached > official.cached || tokens.output > official.output
        }
        guard !records.isEmpty else { return nil }
        let windowPlans = plans.filter { abs($0.resetsAt - context.window.resetsAt) <= 2 && $0.at >= context.start }.sorted { $0.at < $1.at }
        let aggregate = aggregate(records.values, prices: prices, plans: windowPlans)
        guard !aggregate.rows.isEmpty else { return nil }
        let rows = aggregate.rows
        let dollars = rows.reduce(0.0 ... 0.0) { sum($0, $1.dollars) }
        let apiDollars = aggregate.unknown.isEmpty && rows.allSatisfy { $0.apiDollars != nil }
            ? rows.reduce(0.0 ... 0.0) { sum($0, $1.apiDollars!) } : nil
        let credits = rows.allSatisfy { $0.credits != nil } ? rows.reduce(0.0 ... 0.0) { sum($0, $1.credits!) } : nil
        let used = UsageAnalyticsValuation.consumption(context, at: cutoff)
        let projected = used > 0 && !context.window.decreased && conflicts.isEmpty
            ? dollars.lowerBound * 100 / used ... dollars.upperBound * 100 / used : nil
        let incomplete = !conflicts.isEmpty || !aggregate.unknown.isEmpty || available.count < expectedSources || available.contains { source in
            let evidence = source.evidence
            let unattributed = evidence.unattributedDays?.contains { day, count in
                let start = (Double(day) ?? 0) * 86400
                return count > 0 && start < cutoff && start + 86400 > context.start
            } ?? (evidence.unattributedCount > 0)
            return !evidence.complete || unattributed || min(context.end, now.timeIntervalSince1970) - evidence.scannedAt > 900
                || (evidence.truncated && (evidence.records.map(\.at).min() ?? cutoff) > context.start)
        }
        return UsageLogEstimate(
            replacesOfficial: needsFallback || missing, valuedThrough: Date(timeIntervalSince1970: cutoff), usedPercent: used,
            tokens: rows.reduce(.zero) { $0 + $1.tokens }, dollars: dollars, credits: credits, projected: projected,
            models: rows, sources: available.map(\.name), incomplete: incomplete,
            unknownModels: aggregate.unknown, unknownSpeedCount: aggregate.unknownSpeedCount,
            apiDollars: apiDollars, days: aggregate.dailyCredits, conflictingDays: conflicts.union(aggregate.unpricedDays)
        )
    }

    private struct ModelTotals {
        let rows: [UsageLogModelEstimate]
        let unknown: [String]
        let unknownSpeedCount: Int
        let dailyCredits: [Int: UsageCreditPart]
        let unpricedDays: Set<Int>
    }

    private static func aggregate(
        _ records: Dictionary<String, UsageTokenRecord>.Values, prices: UsagePriceBook, plans: [UsagePlanObservation]
    ) -> ModelTotals {
        var models: [String: UsageLogModelEstimate] = [:]
        var unknown = Set<String>()
        var unknownSpeedCount = 0
        var dailyCredits: [Int: UsageCreditPart] = [:]
        var unpricedDays = Set<Int>()
        for record in records {
            let day = Int(record.at / 86400)
            guard let rate = prices.rate(for: record.model) else {
                unknown.insert(record.model)
                unpricedDays.insert(day)
                continue
            }
            let factors: ClosedRange<Double>
            let plan = plans.last(where: { $0.at <= record.at })?.reference
            if let speed = record.speed {
                guard let value = UsageModelAllocation.multiplier(model: .init(model: record.model, speed: speed, weight: 1), prices: prices) else {
                    unknown.insert(record.model + " · " + speed)
                    unpricedDays.insert(day)
                    continue
                }
                factors = value ... value
            } else {
                factors = rate.unrecordedSpeedRange(at: record.at, plan: plan)
                unknownSpeedCount += 1
            }
            let tokens = record.tokens
            let shortCost = rate.shortContext.dollars(for: tokens)
            let dollars = shortCost * factors.lowerBound ... shortCost * factors.upperBound
            let credits: ClosedRange<Double>?
            let reportedCredits: Double?
            if let input = rate.creditInput, let cached = rate.creditCachedInput, let output = rate.creditOutput {
                let amount = (Double(tokens.input) * input + Double(tokens.cached) * cached + Double(tokens.output) * output) / 1000000
                credits = amount * factors.lowerBound ... amount * factors.upperBound
                reportedCredits = record.speed.flatMap { rate.reportedCreditMultiplier(for: $0) }.map { amount * $0 }
            } else {
                credits = nil
                reportedCredits = nil
            }
            if let credits {
                dailyCredits[day, default: UsageCreditPart()].record(
                    credits,
                    tokens: tokens,
                    model: record.model,
                    speed: record.speed,
                    reportedCredits: reportedCredits
                )
            } else {
                unpricedDays.insert(day)
            }
            let key = record.model + ":" + (record.speed ?? "unknown")
            var row = models[key] ?? UsageLogModelEstimate(model: record.model, speed: record.speed, tokens: .zero, dollars: 0 ... 0, credits: credits == nil ? nil : 0 ... 0)
            row.tokens += tokens
            row.dollars = sum(row.dollars, dollars)
            row.apiDollars = row.apiDollars.flatMap { total in rate.apiCost(for: record, plan: plan).map { sum(total, $0) } }
            if let threshold = rate.longThreshold, tokens.input + tokens.cached > threshold {
                if record.requestInputTokens != nil {
                    row.longRequestCount += 1
                } else {
                    row.uncertainContextCount += 1
                }
            }
            if let previous = row.credits, let credits {
                row.credits = sum(previous, credits)
            }
            models[key] = row
        }
        let rows = models.values.sorted { $0.dollars.upperBound > $1.dollars.upperBound }
        return ModelTotals(rows: rows, unknown: unknown.sorted(), unknownSpeedCount: unknownSpeedCount, dailyCredits: dailyCredits, unpricedDays: unpricedDays)
    }

    private static func sum(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> ClosedRange<Double> {
        (lhs.lowerBound + rhs.lowerBound) ... (lhs.upperBound + rhs.upperBound)
    }
}
