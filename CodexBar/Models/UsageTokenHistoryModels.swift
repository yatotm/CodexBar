import Foundation

nonisolated struct UsageTokenRecord: Codable {
    let id: String
    let at: Double
    let model: String
    let speed: String?
    let tokens: AnalyticsTokens
    var requestInputTokens: Int64?
}

nonisolated struct UsageSourceTokenEvidence: Codable {
    let schema: Int
    let ready: Bool
    let complete: Bool
    let generatedAt: Double
    let scannedAt: Double
    let accountKey: String?
    let truncated: Bool
    let unattributedCount: Int
    let records: [UsageTokenRecord]
    var unattributedDays: [String: Int]?
    var requestContextVersion: Int?

    var isValid: Bool {
        schema == 1 && generatedAt.isFinite && generatedAt > 0 && scannedAt.isFinite && scannedAt >= 0
            && scannedAt <= generatedAt + 60 && records.count <= 20000 && unattributedCount >= 0
            && (accountKey == nil || accountKey?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil)
            && (unattributedDays == nil || (unattributedDays!.count <= 72 && unattributedDays!.allSatisfy { Int($0.key) != nil && $0.value >= 0 }))
            && records.allSatisfy {
                $0.id.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil
                    && $0.at.isFinite && $0.at > 0 && $0.at <= generatedAt + 60
                    && !$0.model.isEmpty && $0.model.count <= 120 && ($0.speed?.count ?? 0) <= 40
                    && [$0.tokens.input, $0.tokens.cached, $0.tokens.output].allSatisfy { (0 ... 1000000000000000).contains($0) }
                    && ($0.requestInputTokens == nil || $0.requestInputTokens == $0.tokens.input + $0.tokens.cached)
            }
    }

    func matches(_ account: String) -> Bool {
        accountKey == nil || accountKey == account
    }
}

nonisolated struct UsageTokenSource {
    let name: String
    let evidence: UsageSourceTokenEvidence
}

nonisolated struct UsageLogModelEstimate: Identifiable {
    let model: String
    let speed: String?
    var tokens: AnalyticsTokens
    var dollars: ClosedRange<Double>
    var credits: ClosedRange<Double>?
    var apiDollars: ClosedRange<Double>? = 0 ... 0
    var longRequestCount = 0
    var uncertainContextCount = 0

    var id: String {
        model + ":" + (speed ?? "unknown")
    }
}

nonisolated struct UsageModelDayComparison: Identifiable {
    let day: String
    let deviceModels: [String]
    let reportedModels: [String]
    let deviceTokens: Int64
    let officialTokens: Int64
    let deviceDollars: ClosedRange<Double>
    let officialDollars: Double

    var id: String {
        day
    }
}

nonisolated struct UsageLogEstimate {
    let replacesOfficial: Bool
    let valuedThrough: Date
    let usedPercent: Double
    let tokens: AnalyticsTokens
    let dollars: ClosedRange<Double>
    let credits: ClosedRange<Double>?
    let projected: ClosedRange<Double>?
    let models: [UsageLogModelEstimate]
    let sources: [String]
    let incomplete: Bool
    let unknownModels: [String]
    let unknownSpeedCount: Int
    let apiDollars: ClosedRange<Double>?
    let dayComparisons: [UsageModelDayComparison]

    var projectedAPI: ClosedRange<Double>? {
        guard projected != nil, let apiDollars, usedPercent > 0 else { return nil }
        return apiDollars.lowerBound * 100 / usedPercent ... apiDollars.upperBound * 100 / usedPercent
    }
}
