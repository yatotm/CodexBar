import Foundation

/// 只适配已验证的字段, 不把未知单位或缺失值猜成零
nonisolated enum UsageAnalyticsParser {
    static func parse(usage: Data, breakdown: Data?, counts: Data?, accountID: String, start: String, end: String, now: Date = Date()) throws -> UsageAnalyticsSnapshot {
        let decoder = JSONDecoder()
        let account = try decoder.decode(AnalyticsUsageResponse.self, from: usage)
        guard account.accountID == accountID else {
            throw UsageCenterError(message: "官方统计的账号不符合预期")
        }
        var days: [String: AnalyticsDay] = [:]
        let totals = counts.flatMap { try? decoder.decode(AnalyticsCountsResponse.self, from: $0) }
        if let totals, totals.groupBy == "day", totals.data.count <= 400 {
            for case let day? in totals.data.map(\.value) where validDate(day.date) {
                let values = day.totals
                let reported = totals.balanceUnit == "credit" ? values?.credits : nil
                let credits = reported.flatMap { $0.isFinite && (0 ... 1000000000000).contains($0) ? $0 : nil }
                var tokens: AnalyticsTokens?
                if let input = values?.input, let cached = values?.cached, let output = values?.output,
                   [input, cached, output].allSatisfy({ (0 ... 1000000000000000).contains($0) }),
                   values?.total == nil || values?.total == input + cached + output {
                    tokens = AnalyticsTokens(input: input, cached: cached, output: output)
                }
                days[day.date] = AnalyticsDay(date: day.date, tokens: tokens, models: [], reportedCredits: credits)
            }
        }
        let weights = breakdown.flatMap { try? decoder.decode(AnalyticsBreakdownResponse.self, from: $0) }
        if let weights, weights.units == "percent", weights.groupBy == "day", weights.data.count <= 400 {
            for case let day? in weights.data.map(\.value) where validDate(day.date) {
                guard day.models.count <= 200, day.models.allSatisfy({
                    $0.credits.isFinite && (0 ... 1000000000000).contains($0.credits)
                        && $0.model.count <= 120 && ($0.speed?.count ?? 0) <= 40
                }) else { continue }
                let models = day.models.map { AnalyticsModel(model: $0.model, speed: $0.speed ?? "unknown", weight: $0.credits) }
                let counts = days[day.date]
                days[day.date] = AnalyticsDay(date: day.date, tokens: counts?.tokens, models: models, reportedCredits: counts?.reportedCredits)
            }
        }
        let weekly = [account.rateLimit?.primaryWindow, account.rateLimit?.secondaryWindow]
            .compactMap(\.self).first { $0.duration == 604800 }
        var windows: [UsageObservedWindow] = []
        let at = now.timeIntervalSince1970
        if let weekly, weekly.resetAt.isFinite, (0 ... 100).contains(weekly.usedPercent),
           (at - 60 ... at + 8 * 86400).contains(weekly.resetAt) {
            windows = [UsageObservedWindow(
                resetsAt: weekly.resetAt,
                firstAt: at,
                firstUsed: weekly.usedPercent,
                lastAt: at,
                lastUsed: weekly.usedPercent,
                maxUsed: weekly.usedPercent,
                decreased: false,
                observations: [UsageQuotaPoint(at: at, used: weekly.usedPercent)]
            )]
        }
        return UsageAnalyticsSnapshot(
            schema: 1,
            accountKey: UsageAnalyticsIdentity.hash("codex-account", accountID),
            emailKey: UsageAnalyticsIdentity.hash("codex-email", account.email.lowercased()),
            fetchedAt: now,
            queryStart: start,
            queryEnd: end,
            days: days.values.sorted { $0.date < $1.date },
            windows: windows,
            importedHistory: false, readCreditReports: true
        )
    }

    private static func validDate(_ date: String) -> Bool {
        date.range(of: "^20[0-9]{2}-[01][0-9]-[0-3][0-9]$", options: .regularExpression) != nil
    }
}

private nonisolated struct AnalyticsRow<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) {
        value = try? Value(from: decoder)
    }
}

private nonisolated struct AnalyticsBreakdownResponse: Decodable {
    let units: String
    let groupBy: String
    let data: [AnalyticsRow<AnalyticsWeightDay>]
    enum CodingKeys: String, CodingKey { case units, data
        case groupBy = "group_by"
    }
}

private nonisolated struct AnalyticsWeightDay: Decodable {
    let date: String
    let models: [AnalyticsWeightModel]
}

private nonisolated struct AnalyticsWeightModel: Decodable {
    let model: String
    let speed: String?
    let credits: Double
}

private nonisolated struct AnalyticsCountsResponse: Decodable {
    let groupBy: String
    let balanceUnit: String?
    let data: [AnalyticsRow<AnalyticsCountDay>]
    enum CodingKeys: String, CodingKey { case data
        case groupBy = "group_by"
        case balanceUnit = "balance_unit"
    }
}

private nonisolated struct AnalyticsCountDay: Decodable {
    let date: String
    let totals: AnalyticsCountTotals?
}

private nonisolated struct AnalyticsCountTotals: Decodable {
    let input: Int64?
    let cached: Int64?
    let output: Int64?
    let total: Int64?
    let credits: Double?
    enum CodingKeys: String, CodingKey {
        case input = "uncached_text_input_tokens"
        case cached = "cached_text_input_tokens"
        case output = "text_output_tokens"
        case total = "text_total_tokens"
        case credits
    }

    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        input = try? row.decode(Int64.self, forKey: .input)
        cached = try? row.decode(Int64.self, forKey: .cached)
        output = try? row.decode(Int64.self, forKey: .output)
        total = try? row.decode(Int64.self, forKey: .total)
        credits = try? row.decode(Double.self, forKey: .credits)
    }
}

private nonisolated struct AnalyticsUsageResponse: Decodable {
    let accountID: String
    let email: String
    let rateLimit: AnalyticsRateLimit?
    enum CodingKeys: String, CodingKey { case email
        case accountID = "account_id"
        case rateLimit = "rate_limit"
    }

    init(from decoder: Decoder) throws {
        let row = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try row.decode(String.self, forKey: .accountID)
        email = try row.decode(String.self, forKey: .email)
        rateLimit = try? row.decode(AnalyticsRateLimit.self, forKey: .rateLimit)
    }
}

private nonisolated struct AnalyticsRateLimit: Decodable {
    let primaryWindow: AnalyticsRateWindow?
    let secondaryWindow: AnalyticsRateWindow?
    enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private nonisolated struct AnalyticsRateWindow: Decodable {
    let usedPercent: Double
    let duration: Int
    let resetAt: Double
    enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"
        case duration = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}
