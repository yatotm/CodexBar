import Foundation

nonisolated enum UsageLogValuation {
    static func estimate(
        context: UsageAnalyticsValuation.PeriodWindow, officialDays: [Int: AnalyticsTokens], needsFallback: Bool,
        prices: UsagePriceBook, sources: [UsageTokenSource], expectedSources: Int, now: Date
    ) -> UsageLogEstimate? {
        let available = sources.filter { $0.evidence.ready && $0.evidence.scannedAt > context.start }
        guard let scannedAt = available.map(\.evidence.scannedAt).max() else { return nil }
        let cutoff = min(context.end, now.timeIntervalSince1970, scannedAt)
        var records: [String: UsageTokenRecord] = [:]
        var conflict = false
        for source in available {
            for record in source.evidence.records where record.at >= context.start && record.at < context.end && record.at <= cutoff {
                if let previous = records[record.id] {
                    // 复制日志只计一次, 相同请求的模型或计数冲突不能伪装成完整证据
                    if previous.model != record.model || previous.tokens != record.tokens {
                        conflict = true
                        continue
                    }
                    if let speed = previous.speed, let other = record.speed, speed != other {
                        conflict = true
                    }
                    if previous.speed != nil {
                        continue
                    }
                }
                records[record.id] = record
            }
        }
        let daily = Dictionary(grouping: records.values, by: { Int($0.at / 86400) }).mapValues { $0.reduce(.zero) { (total: AnalyticsTokens, row) in total + row.tokens } }
        let missing = daily.contains { day, tokens in
            guard let official = officialDays[day] else { return true }
            return tokens.input > official.input || tokens.cached > official.cached || tokens.output > official.output
        }
        guard !records.isEmpty, needsFallback || missing else { return nil }
        let aggregate = aggregate(records.values, prices: prices)
        guard !aggregate.rows.isEmpty else { return nil }
        let rows = aggregate.rows
        let dollars = rows.reduce(0.0 ... 0.0) { sum($0, $1.dollars) }
        let credits = rows.allSatisfy { $0.credits != nil } ? rows.reduce(0.0 ... 0.0) { sum($0, $1.credits!) } : nil
        let used = UsageAnalyticsValuation.consumption(context, at: cutoff)
        let projected = used > 0 && !context.window.decreased && !conflict
            ? dollars.lowerBound * 100 / used ... dollars.upperBound * 100 / used : nil
        let incomplete = conflict || !aggregate.unknown.isEmpty || available.count < expectedSources || available.contains { source in
            let evidence = source.evidence
            let unattributed = evidence.unattributedDays?.contains { day, count in
                let start = (Double(day) ?? 0) * 86400
                return count > 0 && start < cutoff && start + 86400 > context.start
            } ?? (evidence.unattributedCount > 0)
            return !evidence.complete || unattributed || cutoff - evidence.scannedAt > 900
                || (evidence.truncated && (evidence.records.map(\.at).min() ?? cutoff) > context.start)
        }
        return UsageLogEstimate(
            valuedThrough: Date(timeIntervalSince1970: cutoff), usedPercent: used,
            tokens: rows.reduce(.zero) { $0 + $1.tokens }, dollars: dollars, credits: credits, projected: projected,
            models: rows, sources: available.map(\.name), incomplete: incomplete,
            unknownModels: aggregate.unknown, unknownSpeedCount: aggregate.unknownSpeedCount
        )
    }

    private struct ModelTotals {
        let rows: [UsageLogModelEstimate]
        let unknown: [String]
        let unknownSpeedCount: Int
    }

    private static func aggregate(
        _ records: Dictionary<String, UsageTokenRecord>.Values, prices: UsagePriceBook
    ) -> ModelTotals {
        var models: [String: UsageLogModelEstimate] = [:]
        var unknown = Set<String>()
        var unknownSpeedCount = 0
        for record in records {
            guard let rate = prices.rate(for: record.model) else {
                unknown.insert(record.model)
                continue
            }
            let factors: ClosedRange<Double>
            if let speed = record.speed {
                guard let value = UsageModelAllocation.multiplier(model: .init(model: record.model, speed: speed, weight: 1), prices: prices) else {
                    unknown.insert(record.model + " · " + speed)
                    continue
                }
                factors = value ... value
            } else {
                let fast = UsageModelAllocation.multiplier(model: .init(model: record.model, speed: "fast", weight: 1), prices: prices) ?? 1
                factors = 1 ... fast
                unknownSpeedCount += 1
            }
            let tokens = record.tokens
            let cost = (Double(tokens.input) * rate.input + Double(tokens.cached) * rate.cachedInput + Double(tokens.output) * rate.output) / 1000000
            let dollars = cost * factors.lowerBound ... cost * factors.upperBound
            let credits: ClosedRange<Double>?
            if let input = rate.creditInput, let cached = rate.creditCachedInput, let output = rate.creditOutput {
                let amount = (Double(tokens.input) * input + Double(tokens.cached) * cached + Double(tokens.output) * output) / 1000000
                credits = amount * factors.lowerBound ... amount * factors.upperBound
            } else {
                credits = nil
            }
            let key = record.model + ":" + (record.speed ?? "unknown")
            var row = models[key] ?? UsageLogModelEstimate(model: record.model, speed: record.speed, tokens: .zero, dollars: 0 ... 0, credits: credits == nil ? nil : 0 ... 0)
            row.tokens += tokens
            row.dollars = sum(row.dollars, dollars)
            if let previous = row.credits, let credits {
                row.credits = sum(previous, credits)
            }
            models[key] = row
        }
        let rows = models.values.sorted { $0.dollars.upperBound > $1.dollars.upperBound }
        return ModelTotals(rows: rows, unknown: unknown.sorted(), unknownSpeedCount: unknownSpeedCount)
    }

    private static func sum(_ lhs: ClosedRange<Double>, _ rhs: ClosedRange<Double>) -> ClosedRange<Double> {
        (lhs.lowerBound + rhs.lowerBound) ... (lhs.upperBound + rhs.upperBound)
    }
}
