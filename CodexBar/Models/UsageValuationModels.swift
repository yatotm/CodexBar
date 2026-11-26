import CryptoKit
import Foundation

nonisolated enum UsageQuotaReference: String, CaseIterable, Identifiable {
    case disabled
    case pro5x
    case pro20x

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .disabled: "不使用参考额度"
        case .pro5x: "Pro 5x · 12,500–15,000 credits"
        case .pro20x: "Pro 20x · 50,000–60,000 credits"
        }
    }

    var dollarRange: ClosedRange<Double>? {
        switch self {
        case .disabled: nil
        case .pro5x: UsageCreditEstimate.dollars(12500 ... 15000)
        case .pro20x: UsageCreditEstimate.dollars(50000 ... 60000)
        }
    }
}

nonisolated struct UsagePlanObservation: Codable, Equatable {
    let at: Double
    let resetsAt: Double
    let plan: String

    var reference: UsageQuotaReference {
        switch plan.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "prolite": .pro5x
        case "pro": .pro20x
        default: .disabled
        }
    }

    var title: String {
        switch reference {
        case .pro5x: "Pro 5x"
        case .pro20x: "Pro 20x"
        case .disabled: plan.uppercased()
        }
    }
}

nonisolated struct UsagePlanHistory: Codable {
    var observations: [UsagePlanObservation] = []

    mutating func observe(plan: String, at: Double, resetsAt: Double) {
        guard !plan.isEmpty, plan.count <= 64, at.isFinite, resetsAt.isFinite, at >= (observations.last?.at ?? 0) else { return }
        let value = UsagePlanObservation(at: at, resetsAt: resetsAt, plan: plan.lowercased())
        if let last = observations.last, last.plan == value.plan, abs(last.resetsAt - resetsAt) <= 2 {
            return
        }
        observations.append(value)
        observations = observations.filter { $0.at > at - 210 * 86400 }.suffix(512).map(\.self)
    }

    func entries(for reset: Double) -> [UsagePlanObservation] {
        observations.filter { abs($0.resetsAt - reset) <= 2 }
    }
}

nonisolated struct UsagePriceBook: Decodable {
    struct TokenRates: Decodable {
        let input: Double
        let cachedInput: Double
        let output: Double

        func dollars(for tokens: AnalyticsTokens) -> Double {
            (Double(tokens.input) * input + Double(tokens.cached) * cachedInput + Double(tokens.output) * output) / 1000000
        }
    }

    struct APIPromotion: Decodable {
        let factor: Double
        let endExclusive: TimeInterval
    }

    struct Rate: Decodable {
        let model: String
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double?
        let cacheWrite12h: Double?
        let output: Double
        let longThreshold: Int64?
        let longContext: TokenRates?
        let creditInput: Double?
        let creditCachedInput: Double?
        let creditOutput: Double?
        let includedSpeed: [String: Double]?
        let ultrafastFrom: TimeInterval?
        let ultrafastOnPro20x: Bool?
        let apiSpeed: [String: Double]?
        let apiUltrafastPromo: APIPromotion?
        let shortOnlyAPISpeeds: [String]?

        var shortContext: TokenRates {
            TokenRates(input: input, cachedInput: cachedInput, output: output)
        }

        func apiMultiplier(for speed: String, start: Date, end: Date) -> ClosedRange<Double>? {
            let tier = speed.lowercased()
            if ["standard", "default", ""].contains(tier) {
                return 1 ... 1
            }
            guard let factor = apiSpeed?[tier == "priority" ? "fast" : tier] else { return nil }
            guard tier == "ultrafast", let promo = apiUltrafastPromo,
                  start.timeIntervalSince1970 < promo.endExclusive else { return factor ... factor }
            return end.timeIntervalSince1970 <= promo.endExclusive ? promo.factor ... promo.factor : promo.factor ... factor
        }

        func unrecordedSpeedRange(at timestamp: TimeInterval, plan: UsageQuotaReference? = nil) -> ClosedRange<Double> {
            // 只用当时已知的订阅档位收窄未记录速度的范围
            let modes = unrecordedSpeeds(at: timestamp, plan: plan)
            return 1 ... (modes.compactMap { subscriptionMultiplier(for: $0) }.max() ?? 1)
        }

        private func unrecordedSpeeds(at timestamp: TimeInterval, plan: UsageQuotaReference?) -> [String] {
            var modes = ["standard"]
            if includedSpeed?["fast"] != nil {
                modes.append("fast")
            }
            if includedSpeed?["ultrafast"] != nil, timestamp >= (ultrafastFrom ?? 0),
               plan != .pro5x, plan != .pro20x || ultrafastOnPro20x == true {
                modes.append("ultrafast")
            }
            return modes
        }

        func apiCost(for record: UsageTokenRecord, plan: UsageQuotaReference?) -> ClosedRange<Double>? {
            let tokens = record.tokens
            let short = shortContext.dollars(for: tokens)
            let canBeLong = longThreshold.map { tokens.input + tokens.cached > $0 } ?? false
            let date = Date(timeIntervalSince1970: record.at)
            let modes = record.speed.map { [$0.lowercased()] } ?? unrecordedSpeeds(at: record.at, plan: plan)
            var low = Double.infinity
            var high = 0.0
            for mode in modes {
                guard let factors = apiMultiplier(for: mode, start: date, end: date) else { return nil }
                var minimum = short
                var maximum = short
                if canBeLong {
                    guard let longContext, shortOnlyAPISpeeds?.contains(mode == "priority" ? "fast" : mode) != true else { return nil }
                    maximum = longContext.dollars(for: tokens)
                    // 累计差值可跨多次请求, 无逐请求凭证时保留短价至长价的范围
                    if record.requestInputTokens != nil {
                        minimum = maximum
                    }
                }
                low = min(low, minimum * factors.lowerBound)
                high = max(high, maximum * factors.upperBound)
            }
            return low ... high
        }

        func subscriptionMultiplier(for speed: String) -> Double? {
            switch speed.lowercased() {
            case "", "standard", "default": 1
            case "priority": includedSpeed?["fast"]
            default: includedSpeed?[speed.lowercased()]
            }
        }

        func reportedCreditMultiplier(for speed: String) -> Double? {
            switch speed.lowercased() {
            case "", "standard", "default": 1
            case "priority": apiSpeed?["fast"] ?? includedSpeed?["fast"]
            default: apiSpeed?[speed.lowercased()] ?? includedSpeed?[speed.lowercased()]
            }
        }

        /// 官方日报按购买积分倍率记账, 方案 B 将其折算为订阅周限等效倍率
        func creditSubscriptionAdjustment(for speed: String) -> Double {
            guard let included = subscriptionMultiplier(for: speed),
                  let reported = reportedCreditMultiplier(for: speed),
                  reported > 0 else { return 1 }
            return included / reported
        }
    }

    let schema: Int
    let asOf: String
    let apiSource: String
    let creditSource: String
    let rates: [Rate]

    func rate(for model: String) -> Rate? {
        let name = model == "gpt-5.6" ? "gpt-5.6-sol" : model
        if let exact = rates.first(where: { $0.model == name }) {
            return exact
        }
        let base = name.replacingOccurrences(of: "-20[0-9]{2}-[0-9]{2}-[0-9]{2}$", with: "", options: .regularExpression)
        return rates.first { $0.model == base }
    }
}

nonisolated struct UsageQuotaPoint: Codable, Equatable {
    let at: Double
    let used: Double
}

nonisolated struct UsageObservedWindow: Codable, Equatable {
    var resetsAt: Double
    var firstAt: Double
    var firstUsed: Double
    var lastAt: Double
    var lastUsed: Double
    var maxUsed: Double
    var decreased: Bool
    var observations: [UsageQuotaPoint]
}

nonisolated struct UsageValueEvidence: Decodable {
    let schema: Int
    let complete: Bool
    let generatedAt: Double
    let accountKey: String?
    let windows: [UsageObservedWindow]
}

nonisolated struct UsageSourceQuotaEvidence: Codable {
    let schema: Int
    let ready: Bool
    let complete: Bool
    let generatedAt: Double
    let scannedAt: Double
    let accountKey: String?
    let windows: [UsageObservedWindow]
    let plans: [UsagePlanObservation]

    var isValid: Bool {
        schema == 1 && generatedAt.isFinite && generatedAt > 0 && scannedAt.isFinite && scannedAt >= 0
            && scannedAt <= generatedAt + 60 && windows.count <= 1000 && plans.count <= 1000
            && (accountKey == nil || accountKey?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
            && windows.reduce(0) { $0 + $1.observations.count } <= 100000
            && windows.allSatisfy { window in
                window.resetsAt.isFinite && window.resetsAt > 0 && !window.observations.isEmpty
                    && window.observations.allSatisfy {
                        $0.at.isFinite && $0.at > 0 && $0.at <= generatedAt + 60 && $0.used.isFinite && (0 ... 100).contains($0.used)
                            && window.resetsAt >= $0.at - 60 && window.resetsAt <= $0.at + 8 * 86400
                    }
            }
            && plans.allSatisfy { $0.at.isFinite && $0.at > 0 && $0.at <= generatedAt + 60 && $0.resetsAt.isFinite && $0.plan.count <= 64 }
    }

    func matches(_ account: String) -> Bool {
        accountKey == nil || accountKey == account
    }
}

nonisolated struct AnalyticsTokens: Codable, Equatable {
    let input: Int64
    let cached: Int64
    let output: Int64
    var total: Int64 {
        input + cached + output
    }

    static let zero = AnalyticsTokens(input: 0, cached: 0, output: 0)
    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(input: lhs.input + rhs.input, cached: lhs.cached + rhs.cached, output: lhs.output + rhs.output)
    }
}

nonisolated struct AnalyticsModel: Codable, Identifiable, Equatable {
    let model: String
    let speed: String
    var weight: Double
    var id: String {
        model + ":" + speed
    }
}

nonisolated struct AnalyticsDay: Codable, Identifiable, Equatable {
    let date: String
    let tokens: AnalyticsTokens?
    let models: [AnalyticsModel]
    var reportedCredits: Double?
    var id: String {
        date
    }
}

nonisolated struct UsageAnalyticsSnapshot: Codable {
    let schema: Int
    let accountKey: String
    let emailKey: String
    let fetchedAt: Date
    let queryStart: String
    let queryEnd: String
    var days: [AnalyticsDay]
    var windows: [UsageObservedWindow]
    var importedHistory: Bool
    var readCreditReports: Bool?

    mutating func retainSettledCredits(from previous: Self) {
        guard accountKey == previous.accountKey else { return }
        let closedBefore = min(previous.fetchedAt, fetchedAt)
        let firstOpenDay = String(ISO8601DateFormatter().string(from: closedBefore).prefix(10))
        let saved = previous.days.filter { $0.reportedCredits != nil && $0.date >= queryStart && $0.date <= queryEnd && $0.date < firstOpenDay }
        guard !saved.isEmpty else { return }
        var indexed = Dictionary(days.map { ($0.date, $0) }, uniquingKeysWith: { _, last in last })
        for day in saved where indexed[day.date]?.reportedCredits == nil {
            let current = indexed[day.date]
            indexed[day.date] = AnalyticsDay(date: day.date, tokens: current?.tokens ?? day.tokens, models: current?.models ?? [], reportedCredits: day.reportedCredits)
        }
        days = indexed.values.sorted { $0.date < $1.date }
    }
}

nonisolated struct UsageModelEstimate: Identifiable {
    let model: String
    let speed: String
    var tokens: AnalyticsTokens
    var dollars: Double
    var credits: Double?
    var weight: Double
    var id: String {
        model + ":" + speed
    }
}

nonisolated struct UsageCreditPart {
    var credits = 0.0 ... 0.0
    var tokens: AnalyticsTokens? = .zero
    var modelTokens: [String: AnalyticsTokens] = [:]
    var modelCredits: [String: ClosedRange<Double>] = [:]
    /// 设备日志按官方日报速度倍率算出的积分, 用于按速度核对官方模型折叠后的调整系数
    var speedSubscriptionCredits: [String: Double] = [:]
    var speedReportedCredits: [String: Double] = [:]

    func scalingCredits(by factor: Double) -> Self {
        guard factor != 1 else { return self }
        var result = self
        result.credits = credits.lowerBound * factor ... credits.upperBound * factor
        result.modelCredits = modelCredits.mapValues { $0.lowerBound * factor ... $0.upperBound * factor }
        return result
    }

    mutating func record(
        _ amount: ClosedRange<Double>,
        tokens count: AnalyticsTokens,
        model: String,
        speed: String? = nil,
        reportedCredits: Double? = nil
    ) {
        credits = (credits.lowerBound + amount.lowerBound) ... (credits.upperBound + amount.upperBound)
        tokens = (tokens ?? .zero) + count
        modelTokens[model, default: .zero] += count
        addModelCredits(amount, for: model)
        if let speed, let reportedCredits, amount.lowerBound == amount.upperBound {
            let tier = Self.normalizedSpeed(speed)
            speedSubscriptionCredits[tier, default: 0] += amount.lowerBound
            speedReportedCredits[tier, default: 0] += reportedCredits
        }
    }

    mutating func add(_ part: Self) {
        credits = (credits.lowerBound + part.credits.lowerBound) ... (credits.upperBound + part.credits.upperBound)
        if let count = part.tokens {
            tokens = (tokens ?? .zero) + count
        }
        for (model, count) in part.modelTokens {
            modelTokens[model, default: .zero] += count
        }
        for (model, amount) in part.modelCredits {
            addModelCredits(amount, for: model)
        }
        for (tier, amount) in part.speedSubscriptionCredits {
            speedSubscriptionCredits[tier, default: 0] += amount
        }
        for (tier, amount) in part.speedReportedCredits {
            speedReportedCredits[tier, default: 0] += amount
        }
    }

    static func normalizedSpeed(_ speed: String) -> String {
        switch speed.lowercased() {
        case "", "standard", "default": "standard"
        case "priority": "fast"
        default: speed.lowercased()
        }
    }

    mutating func addModelCredits(_ amount: ClosedRange<Double>, for model: String) {
        let previous = modelCredits[model] ?? 0 ... 0
        modelCredits[model] = (previous.lowerBound + amount.lowerBound) ... (previous.upperBound + amount.upperBound)
    }
}

nonisolated struct UsageCreditEstimate {
    let recorded: UsageCreditPart
    let projected: ClosedRange<Double>?
    let hasOfficial: Bool
    let hasDevice: Bool

    static func dollars(_ credits: ClosedRange<Double>) -> ClosedRange<Double> {
        (credits.lowerBound / 25) ... (credits.upperBound / 25)
    }
}

nonisolated struct UsageAnalyticsPeriod: Identifiable {
    let start: Date
    let end: Date
    let scheduledEnd: Date
    let usedPercent: Double
    let valuedPercent: Double
    let samplePercent: Double
    let valuedThrough: Date
    let tokens: AnalyticsTokens
    let dollars: Double?
    let projected: Double?
    let credits: Double?
    let models: [UsageModelEstimate]
    let boundaryDays: Int
    let timeAllocatedDays: Int
    let missingDays: Int
    let unknownModels: [String]
    let unreliable: Bool
    var deviceEstimate: UsageLogEstimate?
    var creditEstimate: UsageCreditEstimate?
    var logEstimate: UsageLogEstimate? {
        deviceEstimate.flatMap { $0.replacesOfficial ? $0 : nil }
    }

    var id: Double {
        scheduledEnd.timeIntervalSince1970
    }

    var earlyReset: Bool {
        end < scheduledEnd.addingTimeInterval(-2)
    }
}

nonisolated enum UsageAnalyticsIdentity {
    static func hash(_ kind: String, _ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [kind, value], options: [.withoutEscapingSlashes])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct GeminiStepTokens: Codable, Equatable {
    let input: Int64
    let cached: Int64
    let cacheWrite: Int64?
    var cacheWrite1h: Int64?
    let output: Int64

    init(input: Int64, cached: Int64, cacheWrite: Int64?, cacheWrite1h: Int64? = nil, output: Int64) {
        self.input = input
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h
        self.output = output
    }

    static let zero = GeminiStepTokens(input: 0, cached: 0, cacheWrite: 0, output: 0)

    var cw: Int64 {
        cacheWrite ?? 0
    }

    var cw1h: Int64 {
        min(max(cacheWrite1h ?? 0, 0), cw)
    }

    var cw5m: Int64 {
        max(0, cw - cw1h)
    }

    var promptTotal: Int64 {
        input + cached + cw
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        let total1h = lhs.cw1h + rhs.cw1h
        return Self(
            input: lhs.input + rhs.input,
            cached: lhs.cached + rhs.cached,
            cacheWrite: lhs.cw + rhs.cw,
            cacheWrite1h: total1h > 0 ? total1h : nil,
            output: lhs.output + rhs.output
        )
    }

    static func += (lhs: inout Self, rhs: Self) {
        lhs = lhs + rhs
    }
}

nonisolated struct GeminiStepUsageRecord: Codable, Identifiable, Equatable {
    let id: String
    let at: Double
    let model: String
    let tokens: GeminiStepTokens
}
