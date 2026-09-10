import Foundation

/// 只适配已验证的字段, 不把未知单位或缺失值猜成零
nonisolated enum UsageAnalyticsParser {
    static func parse(usage: Data, breakdown: Data, counts: Data, accountID: String, start: String, end: String, now: Date = Date()) throws -> UsageAnalyticsSnapshot {
        let decoder = JSONDecoder()
        let account = try decoder.decode(AnalyticsUsageResponse.self, from: usage)
        let weights = try decoder.decode(AnalyticsBreakdownResponse.self, from: breakdown)
        let totals = try decoder.decode(AnalyticsCountsResponse.self, from: counts)
        guard account.accountID == accountID, weights.units == "percent", weights.groupBy == "day", totals.groupBy == "day",
              weights.data.count <= 400, totals.data.count <= 400 else {
            throw UsageCenterError(message: "官方统计的账号或单位不符合预期, 已停止换算")
        }
        var tokens: [String: AnalyticsTokens] = [:]
        for day in totals.data {
            if let input = day.totals?.input, let cached = day.totals?.cached,
               let output = day.totals?.output {
                guard [input, cached, output].allSatisfy({ (0 ... 1000000000000000).contains($0) }) else {
                    throw UsageCenterError(message: "官方 Token 数据超出有效范围")
                }
                if let total = day.totals?.total, total != input + cached + output {
                    throw UsageCenterError(message: "官方 Token 分类与合计不一致, 暂停换算")
                }
                tokens[day.date] = AnalyticsTokens(input: input, cached: cached, output: output)
            }
        }
        var models: [String: [AnalyticsModel]] = [:]
        for day in weights.data {
            guard day.models.count <= 200, day.models.allSatisfy({
                $0.credits.isFinite && (0 ... 1000000000000).contains($0.credits)
                    && $0.model.count <= 120 && ($0.speed?.count ?? 0) <= 40
            }) else {
                throw UsageCenterError(message: "官方模型额度字段发生变化")
            }
            models[day.date] = day.models.map { AnalyticsModel(model: $0.model, speed: $0.speed ?? "unknown", weight: $0.credits) }
        }
        let keys = Set(weights.data.map(\.date) + totals.data.map(\.date))
        let days = try keys.sorted().map { key -> AnalyticsDay in
            guard key.range(of: "^20[0-9]{2}-[01][0-9]-[0-3][0-9]$", options: .regularExpression) != nil else {
                throw UsageCenterError(message: "官方统计返回了未知日期格式")
            }
            return AnalyticsDay(date: key, tokens: tokens[key], models: models[key] ?? [])
        }
        let weekly = [account.rateLimit?.primaryWindow, account.rateLimit?.secondaryWindow]
            .compactMap(\.self).first { $0.duration == 604800 }
        var windows: [UsageObservedWindow] = []
        if let weekly, weekly.resetAt.isFinite, (0 ... 100).contains(weekly.usedPercent) {
            let at = now.timeIntervalSince1970
            guard (at - 60 ... at + 8 * 86400).contains(weekly.resetAt) else {
                throw UsageCenterError(message: "官方周限时间超出有效范围")
            }
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
            days: days,
            windows: windows,
            importedHistory: false
        )
    }
}

private nonisolated struct AnalyticsBreakdownResponse: Decodable {
    let units: String
    let groupBy: String
    let data: [AnalyticsWeightDay]
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
    let data: [AnalyticsCountDay]
    enum CodingKeys: String, CodingKey { case data
        case groupBy = "group_by"
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
    enum CodingKeys: String, CodingKey {
        case input = "uncached_text_input_tokens"
        case cached = "cached_text_input_tokens"
        case output = "text_output_tokens"
        case total = "text_total_tokens"
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
