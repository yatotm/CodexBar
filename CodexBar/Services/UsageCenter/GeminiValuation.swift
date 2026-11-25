import Foundation

nonisolated struct GeminiPriceBook: Decodable {
    struct Promotion: Decodable {
        let endExclusive: Double
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double
        let output: Double
    }

    struct UnitRates {
        let inRate: Double
        let crRate: Double
        let cwRate: Double
        let outRate: Double
    }

    struct Rate: Decodable {
        let id: String
        var provider: String?
        let match: [String]
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double
        let output: Double
        let longThreshold: Int64?
        let longInput: Double?
        let longCachedInput: Double?
        let longCacheWrite: Double?
        let longOutput: Double?
        let promo: Promotion?

        func unitRates(at timestamp: Double, promptTokens: Int64) -> UnitRates {
            if let promo, timestamp < promo.endExclusive {
                return UnitRates(inRate: promo.input, crRate: promo.cachedInput, cwRate: promo.cacheWrite, outRate: promo.output)
            }
            if let threshold = longThreshold, promptTokens > threshold {
                return UnitRates(
                    inRate: longInput ?? input,
                    crRate: longCachedInput ?? cachedInput,
                    cwRate: longCacheWrite ?? cacheWrite,
                    outRate: longOutput ?? output
                )
            }
            return UnitRates(inRate: input, crRate: cachedInput, cwRate: cacheWrite, outRate: output)
        }
    }

    let schema: Int
    let asOf: String
    var geminiApiSource: String?
    var claudeApiSource: String?
    let rates: [Rate]

    static let fallback = GeminiPriceBook(
        schema: 1,
        asOf: "2026-11-25",
        geminiApiSource: "https://ai.google.dev/gemini-api/docs/pricing",
        claudeApiSource: "https://docs.anthropic.com/en/docs/about-claude/pricing",
        rates: [
            Rate(
                id: "gemini-4-neon", provider: "gemini", match: ["neon"],
                input: 3.0, cachedInput: 0.15, cacheWrite: 3.0, output: 15.0,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil, promo: nil
            ),
            Rate(
                id: "gemini-4-hydrogen", provider: "gemini", match: ["hydrogen"],
                input: 1.5, cachedInput: 0.075, cacheWrite: 1.5, output: 7.5,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil, promo: nil
            ),
            Rate(
                id: "gemini-4-carbon", provider: "gemini", match: ["carbon", "argon", "orchestrator"],
                input: 4.0, cachedInput: 0.2, cacheWrite: 4.0, output: 20.0,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil,
                promo: Promotion(endExclusive: 1796083200, input: 2.0, cachedInput: 0.1, cacheWrite: 2.0, output: 10.0)
            ),
            Rate(
                id: "gemini-3.8-flash", provider: "gemini", match: ["flash"],
                input: 1.5, cachedInput: 0.15, cacheWrite: 1.5, output: 7.5,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil,
                promo: Promotion(endExclusive: 1798761600, input: 0.75, cachedInput: 0.075, cacheWrite: 0.75, output: 3.75)
            ),
            Rate(
                id: "claude-mythos-5", provider: "claude", match: ["fable", "mythos"],
                input: 8.0, cachedInput: 0.2, cacheWrite: 10.0, output: 40.0,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil, promo: nil
            ),
            Rate(
                id: "claude-opus-5.5", provider: "claude", match: ["opus-5", "opus 5"],
                input: 4.0, cachedInput: 0.2, cacheWrite: 5.0, output: 20.0,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil, promo: nil
            ),
            Rate(
                id: "claude-opus-legacy", provider: "claude", match: ["opus"],
                input: 5.0, cachedInput: 0.5, cacheWrite: 6.25, output: 25.0,
                longThreshold: 200000, longInput: 10.0, longCachedInput: 1.0, longCacheWrite: 12.5, longOutput: 37.5, promo: nil
            ),
            Rate(
                id: "claude-sonnet-5.5", provider: "claude", match: ["sonnet-5", "sonnet 5"],
                input: 2.0, cachedInput: 0.1, cacheWrite: 2.5, output: 10.0,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil, promo: nil
            ),
            Rate(
                id: "claude-sonnet-legacy", provider: "claude", match: ["sonnet"],
                input: 3.0, cachedInput: 0.3, cacheWrite: 3.75, output: 15.0,
                longThreshold: 200000, longInput: 6.0, longCachedInput: 0.6, longCacheWrite: 7.5, longOutput: 22.5, promo: nil
            ),
            Rate(
                id: "claude-haiku-legacy", provider: "claude", match: ["haiku"],
                input: 1.0, cachedInput: 0.1, cacheWrite: 1.25, output: 5.0,
                longThreshold: nil, longInput: nil, longCachedInput: nil, longCacheWrite: nil, longOutput: nil, promo: nil
            )
        ]
    )

    static func loadBundled() -> Self {
        guard let url = Bundle.main.url(forResource: "GeminiPrices", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let parsed = try? JSONDecoder().decode(Self.self, from: data),
              parsed.schema == 1 else {
            return .fallback
        }
        return parsed
    }

    func rate(for model: String, provider: String = "gemini") -> Rate {
        let lower = model.lowercased()
        let candidates = rates.filter { $0.provider == nil || $0.provider == provider }
        if let hit = candidates.first(where: { candidate in candidate.match.contains { lower.contains($0) } }) {
            return hit
        }
        if provider == "claude" {
            return candidates.first { $0.id.contains("sonnet") } ?? Self.fallback.rates.last!
        }
        return candidates.first { $0.id == "gemini-4-carbon" } ?? Self.fallback.rates[2]
    }
}

nonisolated struct GeminiValuationEvidence: Codable {
    var schema: Int?
    var ready: Bool?
    var complete: Bool?
    var generatedAt: Double?
    var scannedAt: Double?
    var planTier: String?
    var truncated: Bool?
    var windows: [UsageObservedWindow]
    var plans: [UsagePlanObservation]?
    var records: [GeminiStepUsageRecord]

    static let empty = GeminiValuationEvidence(windows: [], records: [])
}

nonisolated struct GeminiModelPeriodBreakdown: Identifiable, Equatable {
    let model: String
    var tokens: GeminiStepTokens
    var dollars: Double

    var id: String {
        model
    }
}

nonisolated struct GeminiValuationPeriod: Identifiable, Equatable {
    let start: Date
    let end: Date
    let scheduledEnd: Date
    let usedPercent: Double
    let valuedThrough: Date
    let tokens: GeminiStepTokens
    let dollars: Double
    let projectedDollars: Double?
    let models: [GeminiModelPeriodBreakdown]
    let unreliable: Bool
    let planTitle: String?

    var id: Double {
        scheduledEnd.timeIntervalSince1970
    }

    var earlyReset: Bool {
        end < scheduledEnd.addingTimeInterval(-2)
    }
}

nonisolated enum GeminiValuationCalculator {
    static func computePeriods(
        provider: String = "gemini",
        evidences: [GeminiValuationEvidence],
        storeRecords: [GeminiStepUsageRecord] = [],
        liveWeeklyObservation: UsageQuotaObservation?,
        priceBook: GeminiPriceBook = .loadBundled(),
        now: Date = Date()
    ) -> [GeminiValuationPeriod] {
        let nowTs = now.timeIntervalSince1970
        var rawWindows = evidences.flatMap(\.windows)
        if let obs = liveWeeklyObservation,
           obs.provider == provider,
           let win = obs.windows.first(where: { $0.name == "7d" }),
           let reset = win.resetsAt,
           reset > obs.observedAt - 60 {
            rawWindows.append(UsageObservedWindow(
                resetsAt: reset,
                firstAt: obs.observedAt,
                firstUsed: win.usedPercent,
                lastAt: obs.observedAt,
                lastUsed: win.usedPercent,
                maxUsed: win.usedPercent,
                decreased: false,
                observations: [UsageQuotaPoint(at: obs.observedAt, used: win.usedPercent)]
            ))
        }
        guard !rawWindows.isEmpty else { return [] }
        let settled = UsageAnalyticsValuation.settledWindows(rawWindows, acrossSources: evidences.count > 1)
        var dedupRecords: [String: GeminiStepUsageRecord] = [:]
        for item in storeRecords + evidences.flatMap(\.records) {
            if provider == "gemini" {
                let low = item.model.lowercased()
                if ["claude", "opus", "sonnet", "haiku", "fable", "mythos", "gpt"].contains(where: { low.contains($0) }) {
                    continue
                }
            }
            if dedupRecords[item.id] == nil {
                dedupRecords[item.id] = item
            }
        }
        let sortedRecords = dedupRecords.values.sorted { $0.at < $1.at }
        let latestPlan = evidences.compactMap(\.planTier).first { !$0.isEmpty }

        return settled.enumerated().compactMap { index, window in
            let nextStart = settled.indices.contains(index + 1) ? (settled[index + 1].resetsAt - 604800) : window.resetsAt
            return buildPeriod(
                window: window,
                nextStart: nextStart,
                nowTs: nowTs,
                provider: provider,
                sortedRecords: sortedRecords,
                priceBook: priceBook,
                latestPlan: latestPlan
            )
        }.reversed()
    }

    private static func buildPeriod(
        window: UsageObservedWindow,
        nextStart: Double,
        nowTs: Double,
        provider: String,
        sortedRecords: [GeminiStepUsageRecord],
        priceBook: GeminiPriceBook,
        latestPlan: String?
    ) -> GeminiValuationPeriod? {
        let startTs = window.resetsAt - 604800
        let endTs = min(window.resetsAt, nextStart)
        guard startTs < nowTs, endTs > startTs else { return nil }
        let valuedTs = min(endTs, max(window.lastAt, min(nowTs, endTs)))
        let cycleRecords = sortedRecords.filter { $0.at >= startTs - 60 && $0.at <= valuedTs + 30 }
        let priceRefTs = endTs > nowTs ? nowTs : valuedTs
        var byModel: [String: GeminiModelPeriodBreakdown] = [:]
        var totalTokens = GeminiStepTokens.zero
        var totalDollars = 0.0

        for rec in cycleRecords {
            let rate = priceBook.rate(for: rec.model, provider: provider)
            let unit = rate.unitRates(at: priceRefTs, promptTokens: rec.tokens.promptTotal)
            let cost = (
                Double(rec.tokens.input) * unit.inRate
                    + Double(rec.tokens.cached) * unit.crRate
                    + Double(rec.tokens.cw) * unit.cwRate
                    + Double(rec.tokens.output) * unit.outRate
            ) / 1000000.0
            totalTokens += rec.tokens
            totalDollars += cost
            var entry = byModel[rec.model] ?? GeminiModelPeriodBreakdown(model: rec.model, tokens: .zero, dollars: 0)
            entry.tokens += rec.tokens
            entry.dollars += cost
            byModel[rec.model] = entry
        }

        let usedPct = max(window.lastUsed, window.maxUsed)
        let projected: Double? = if !window.decreased, usedPct >= 1.0, totalDollars >= 0.03 {
            totalDollars / (usedPct / 100.0)
        } else {
            nil
        }
        return GeminiValuationPeriod(
            start: Date(timeIntervalSince1970: startTs),
            end: Date(timeIntervalSince1970: endTs),
            scheduledEnd: Date(timeIntervalSince1970: window.resetsAt),
            usedPercent: usedPct,
            valuedThrough: Date(timeIntervalSince1970: valuedTs),
            tokens: totalTokens,
            dollars: totalDollars,
            projectedDollars: projected,
            models: byModel.values.sorted { $0.dollars > $1.dollars },
            unreliable: window.decreased,
            planTitle: latestPlan
        )
    }
}
