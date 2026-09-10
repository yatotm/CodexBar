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
        case .pro5x: (12500.0 / 25) ... (15000.0 / 25)
        case .pro20x: (50000.0 / 25) ... (60000.0 / 25)
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
    struct Rate: Decodable {
        let model: String
        let input: Double
        let cachedInput: Double
        let cacheWrite: Double?
        let output: Double
        let longThreshold: Int64?
        let creditInput: Double?
        let creditCachedInput: Double?
        let creditOutput: Double?
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
    let days: [AnalyticsDay]
    var windows: [UsageObservedWindow]
    var importedHistory: Bool
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
