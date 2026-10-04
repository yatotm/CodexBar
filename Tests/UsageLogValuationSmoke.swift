import Foundation

nonisolated enum UsageLogValuationSmoke {
    static func run(prices: UsagePriceBook) {
        let start = ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!.timeIntervalSince1970
        let now = Date(timeIntervalSince1970: start + 2 * 86400)
        let window = UsageObservedWindow(
            resetsAt: start + 7 * 86400, firstAt: start, firstUsed: 0, lastAt: now.timeIntervalSince1970, lastUsed: 50,
            maxUsed: 50, decreased: false, observations: [.init(at: start, used: 0), .init(at: now.timeIntervalSince1970, used: 50)]
        )
        let sample = AnalyticsTokens(input: 1000000, cached: 2000000, output: 100000)
        func record(_ id: String, at: Double = start + 100, speed: String? = "fast", model: String = "gpt-6-astra") -> UsageTokenRecord {
            .init(id: UsageAnalyticsIdentity.hash("request", id), at: at, model: model, speed: speed, tokens: sample)
        }
        func source(_ records: [UsageTokenRecord], name: String = "Mac", complete: Bool = true, at: Double = now.timeIntervalSince1970) -> UsageTokenSource {
            .init(name: name, evidence: .init(
                schema: 1,
                ready: true,
                complete: complete,
                generatedAt: at,
                scannedAt: at,
                accountKey: nil,
                truncated: false,
                unattributedCount: 0,
                records: records
            ))
        }
        func snapshot(_ days: [AnalyticsDay] = [], windows: [UsageObservedWindow] = [window], fetched: Date = now) -> UsageAnalyticsSnapshot {
            .init(
                schema: 1,
                accountKey: "account",
                emailKey: "email",
                fetchedAt: fetched,
                queryStart: "2026-10-01",
                queryEnd: "2026-10-04",
                days: days,
                windows: windows,
                importedHistory: false
            )
        }
        func periods(_ data: UsageAnalyticsSnapshot, sources: [UsageTokenSource], expected: Int = 1) -> [UsageAnalyticsPeriod] {
            UsageAnalyticsValuation.periods(
                snapshot: data,
                prices: prices,
                now: now,
                tokenSources: sources,
                expectedTokenSources: expected
            )
        }
        let empty = periods(snapshot(), sources: [])
        precondition(empty[0].dollars == nil, "已消耗周限却没有明细时不能记成零美元")
        let logs = [record("fast"), record("standard", speed: "standard"), record("unknown", speed: nil)]
        let result = periods(snapshot(), sources: [source(logs)])[0].logEstimate!
        precondition(result.tokens == sample + sample + sample)
        precondition(abs(result.dollars.lowerBound - 76.5) < 0.000001 && abs(result.dollars.upperBound - 102) < 0.000001)
        precondition(result.projected == 153 ... 204 && result.usedPercent == 50)
        precondition(result.unknownSpeedCount == 1 && !result.incomplete)
        precondition(result.credits == 1912.5 ... 2550, "缺失速度只对对应记录给出范围")
        let duplicate = periods(snapshot(), sources: [source(logs), source(logs, name: "VPS")], expected: 2)[0].logEstimate!
        precondition(duplicate.dollars == result.dollars, "跨设备复制日志不能重复累加")
        let enriched = periods(snapshot(), sources: [source([record("same", speed: nil)]), source([record("same")])], expected: 2)[0].logEstimate!
        precondition(enriched.dollars == 42.5 ... 42.5, "重复请求优先保留已知速度")
        let conflict = periods(snapshot(), sources: [source([record("same")]), source([record("same", speed: "standard")])], expected: 2)[0].logEstimate!
        precondition(conflict.incomplete && conflict.projected == nil, "冲突记录不能输出看似完整的周限外推")

        let official = AnalyticsDay(
            date: "2026-10-01",
            tokens: sample + sample + sample,
            models: [.init(model: "gpt-6-astra", speed: "standard", weight: 100)]
        )
        let restored = periods(snapshot([official]), sources: [source(logs)])[0]
        precondition(restored.logEstimate == nil && restored.dollars == 51, "官方补齐后整段替换, 不与日志相加")
        let partial = AnalyticsDay(date: "2026-10-01", tokens: sample, models: official.models)
        precondition(periods(snapshot([partial]), sources: [source(logs)])[0].logEstimate != nil, "官方非零但少于已知本地用量时仍应兜底")
        let unknownPrice = periods(snapshot(), sources: [source([record("known"), record("future", model: "unknown-model")])])[0].logEstimate!
        precondition(unknownPrice.unknownModels == ["unknown-model"] && unknownPrice.incomplete)
        let unpricedOnly = periods(snapshot(), sources: [source([record("future", model: "unknown-model")])])[0]
        precondition(unpricedOnly.logEstimate == nil, "未知价格不能冒充零金额")
        let partialSources = periods(snapshot(), sources: [source([record("one")])], expected: 2)[0].logEstimate!
        precondition(partialSources.incomplete && partialSources.projected != nil, "缺少设备时仍给出有标记的部分估算")

        var declined = window
        declined.decreased = true
        precondition(periods(snapshot(windows: [declined]), sources: [source(logs)])[0].logEstimate?.projected == nil)
        let olderScan = source([record("one")], at: start + 86400)
        let aligned = periods(snapshot(), sources: [olderScan])[0].logEstimate!
        precondition(aligned.usedPercent == 25 && aligned.projected == 170 ... 170, "分母必须对齐日志扫描时间")

        let resetAt = start + 86400
        let newWindow = UsageObservedWindow(
            resetsAt: resetAt + 604800,
            firstAt: resetAt,
            firstUsed: 0,
            lastAt: now.timeIntervalSince1970,
            lastUsed: 10,
            maxUsed: 10,
            decreased: false,
            observations: [.init(at: resetAt, used: 0), .init(at: now.timeIntervalSince1970, used: 10)]
        )
        let aroundReset = periods(snapshot(windows: [window, newWindow]), sources: [source([
            record("before", at: resetAt - 0.01), record("after", at: resetAt)
        ])])
        precondition(aroundReset.count == 2 && aroundReset.allSatisfy { $0.logEstimate?.tokens == sample }, "提前重置边界不能重复归属")
        let staleOfficial = periods(
            snapshot(windows: [newWindow], fetched: Date(timeIntervalSince1970: start + 3600)),
            sources: [source([record("after", at: resetAt)])]
        )
        precondition(staleOfficial[0].logEstimate != nil, "官方缓存时间早于新周期也应使用已验证日志")
        var drifted = window
        drifted.resetsAt += 1
        precondition(periods(snapshot(windows: [window, drifted]), sources: [source(logs)]).count == 1, "一秒截止时间抖动不能拆成新周期")
        precondition(source(logs).evidence.isValid)
        precondition(source(logs).evidence.matches("same-confirmed-account"))
        print("Device log fallback, Fast switching, deduplication, aligned quota and official replacement tests passed")
    }
}
