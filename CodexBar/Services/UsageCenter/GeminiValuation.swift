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
    var accountKey: String?
    var accountScoped: Bool?
    var planTier: String?
    var truncated: Bool?
    var windows: [UsageObservedWindow]
    var plans: [UsagePlanObservation]?
    var records: [GeminiStepUsageRecord]

    static let empty = GeminiValuationEvidence(windows: [], records: [])

    var confirmedAccount: String? {
        guard accountScoped == true, let accountKey,
              accountKey.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { return nil }
        return accountKey
    }
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
        liveWeeklyObservation: UsageQuotaObservation?,
        preferredGeminiAccount: String? = nil,
        priceBook: GeminiPriceBook = .loadBundled(),
        now: Date = Date(),
        forEachStoredRecord: (Double, (GeminiStepUsageRecord) -> Void) throws -> Void
    ) rethrows -> [GeminiValuationPeriod] {
        let nowTs = now.timeIntervalSince1970
        let isGemini = provider == "gemini"
        let account = preferredGeminiAccount ?? evidences.compactMap(\.confirmedAccount).first ?? liveWeeklyObservation?.accountKey
        if isGemini, account == nil {
            return []
        }
        let selected = isGemini ? evidences.filter { $0.confirmedAccount == account } : evidences
        var rawWindows = selected.flatMap(\.windows)
        if let obs = liveWeeklyObservation,
           obs.provider == provider,
           !isGemini || obs.accountKey == account,
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
        let settled = UsageAnalyticsValuation.settledWindows(rawWindows, acrossSources: !isGemini || selected.count > 1)
        var periods = settled.enumerated().compactMap { index, window -> PeriodTotals? in
            let start = window.resetsAt - 604800
            let nextStart = settled.indices.contains(index + 1) ? settled[index + 1].resetsAt - 604800 : window.resetsAt
            let end = min(nextStart, window.resetsAt)
            guard start < nowTs, start < end else { return nil }
            return PeriodTotals(window: window, start: start, end: end, through: min(end, nowTs))
        }
        guard let firstStart = periods.first?.start else { return [] }
        var rates: [String: GeminiPriceBook.Rate] = [:]
        func accumulate(_ record: GeminiStepUsageRecord) {
            guard let index = periods.lastIndex(where: { $0.start <= record.at }),
                  record.at < periods[index].end, record.at <= periods[index].through else { return }
            let rate = rates[record.model] ?? priceBook.rate(for: record.model, provider: provider)
            rates[record.model] = rate
            periods[index].add(record, rate: rate)
        }

        var evidenceRecords: [String: GeminiStepUsageRecord] = [:]
        for evidence in selected {
            for item in evidence.records where evidenceRecords[item.id] == nil {
                if isGemini, ["claude", "opus", "sonnet", "haiku", "fable", "mythos", "gpt"].contains(where: item.model.lowercased().contains) {
                    continue
                }
                evidenceRecords[item.id] = item
            }
        }
        if !isGemini {
            try forEachStoredRecord(firstStart) { record in
                evidenceRecords.removeValue(forKey: record.id)
                accumulate(record)
            }
        }
        for item in evidenceRecords.values.sorted(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            accumulate(item)
        }
        let plan = selected.compactMap(\.planTier).first { !$0.isEmpty }
        return periods.reversed().map { $0.result(plan: plan) }
    }

    private struct PeriodTotals {
        let window: UsageObservedWindow
        let start: Double
        let end: Double
        let through: Double
        var tokens = GeminiStepTokens.zero
        var dollars = 0.0
        var models: [String: GeminiModelPeriodBreakdown] = [:]

        mutating func add(_ record: GeminiStepUsageRecord, rate: GeminiPriceBook.Rate) {
            let unit = rate.unitRates(at: through, promptTokens: record.tokens.promptTotal)
            let cost = (
                Double(record.tokens.input) * unit.inRate
                    + Double(record.tokens.cached) * unit.crRate
                    + Double(record.tokens.cw) * unit.cwRate
                    + Double(record.tokens.output) * unit.outRate
            ) / 1000000
            tokens += record.tokens
            dollars += cost
            var model = models[record.model] ?? GeminiModelPeriodBreakdown(model: record.model, tokens: .zero, dollars: 0)
            model.tokens += record.tokens
            model.dollars += cost
            models[record.model] = model
        }

        func result(plan: String?) -> GeminiValuationPeriod {
            let used = max(window.lastUsed, window.maxUsed)
            return GeminiValuationPeriod(
                start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: end),
                scheduledEnd: Date(timeIntervalSince1970: window.resetsAt), usedPercent: used,
                valuedThrough: Date(timeIntervalSince1970: through), tokens: tokens, dollars: dollars,
                projectedDollars: !window.decreased && used >= 1 && dollars >= 0.03 ? dollars * 100 / used : nil,
                models: models.values.sorted { $0.dollars > $1.dollars }, unreliable: window.decreased, planTitle: plan
            )
        }
    }
}

extension UsageCenterStore {
    func claudeValuationPeriods(
        evidences: [GeminiValuationEvidence], weekly: UsageQuotaObservation?, localOnly: Bool, prices: GeminiPriceBook, now: Date = Date()
    ) throws -> [GeminiValuationPeriod] {
        try Task.checkCancellation()
        return try GeminiValuationCalculator.computePeriods(
            provider: "claude", evidences: evidences, liveWeeklyObservation: weekly, priceBook: prices, now: now
        ) { start, visit in
            try forEachClaudeUsageRecord(since: start, localOnly: localOnly, visit: visit)
        }
    }
}
