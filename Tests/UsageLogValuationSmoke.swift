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
        precondition(abs(result.dollars.lowerBound - 76.5) < 0.000001 && abs(result.dollars.upperBound - 195.5) < 0.000001)
        precondition(result.projected == 153 ... 391 && result.usedPercent == 50)
        precondition(result.unknownSpeedCount == 1 && !result.incomplete)
        precondition(result.credits == 1912.5 ... 4887.5, "缺失速度只对对应记录给出范围")
        var verified = record("same", speed: nil)
        verified.requestInputTokens = sample.input + sample.cached
        let legacy = record("same", speed: "standard")
        let old = periods(snapshot(), sources: [source([legacy])])[0].logEstimate!
        precondition(old.dollars == 17 ... 17 && old.apiDollars == 17 ... 31.5 && old.models[0].uncertainContextCount == 1)
        for sources in [[source([verified]), source([legacy])], [source([legacy]), source([verified])]] {
            let priced = periods(snapshot(), sources: sources)[0].logEstimate!
            precondition(priced.tokens == sample && priced.unknownSpeedCount == 0 && priced.models[0].longRequestCount == 1)
            precondition(priced.dollars == 17 ... 17 && priced.projected == 34 ... 34 && priced.credits == 425 ... 425)
            precondition(priced.apiDollars == 31.5 ... 31.5 && priced.projectedAPI == 63 ... 63)
        }
        let astra = prices.rate(for: "gpt-6.2-astra")!
        for count: Int64 in [272000, 272001] {
            let t = AnalyticsTokens(input: 1, cached: count - 1, output: 1000)
            let r = UsageTokenRecord(id: "bound", at: start, model: astra.model, speed: "priority", tokens: t, requestInputTokens: count)
            let standard = (count > 272000 ? astra.longContext! : astra.shortContext).dollars(for: t)
            precondition(astra.apiCost(for: r, plan: nil) == (2 * standard) ... (2 * standard))
        }
        let solar = prices.rate(for: "gpt-6.2-sol")!
        let promoEnd = solar.apiUltrafastPromo!.endExclusive
        for (timestamp, factor) in [(promoEnd - 1, 3.0), (promoEnd, 6.0)] {
            let request = UsageTokenRecord(
                id: "promo",
                at: timestamp,
                model: solar.model,
                speed: "ultrafast",
                tokens: sample,
                requestInputTokens: sample.input + sample.cached
            )
            let amount = solar.longContext!.dollars(for: sample) * factor
            precondition(solar.apiCost(for: request, plan: .pro20x) == amount ... amount)
            precondition(solar.subscriptionMultiplier(for: "ultrafast") == 6)
        }
        let accelerated = periods(snapshot(), sources: [source([
            record("astra", speed: "priority", model: "gpt-6.2-astra"), record("sol", speed: "ultrafast", model: "gpt-6.2-sol")
        ])])[0].logEstimate!
        precondition(abs(accelerated.dollars.lowerBound - 44.8) < 0.000001 && accelerated.dollars.upperBound == accelerated.dollars.lowerBound)
        precondition(accelerated.tokens == sample + sample && accelerated.unknownModels.isEmpty)
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
        precondition(restored.deviceEstimate?.apiDollars != nil && restored.deviceEstimate?.replacesOfficial == false)
        var apiSample = record("priced", speed: "standard", model: "gpt-6.2-astra")
        apiSample.requestInputTokens = sample.input + sample.cached
        let oneDay = AnalyticsDay(date: "2026-10-01", tokens: sample, models: official.models)
        let reported = periods(snapshot([oneDay]), sources: [source([apiSample])])[0]
        precondition(reported.dollars == 17 && reported.deviceEstimate?.apiDollars == 23.6 ... 23.6)
        var absolute = oneDay
        absolute.reportedCredits = 320
        let withOfficial = periods(snapshot([absolute]), sources: [source([apiSample])])[0].creditEstimate!
        precondition(withOfficial.recorded.credits == 320 ... 320 && withOfficial.hasOfficial && !withOfficial.hasDevice)
        precondition(withOfficial.recorded.modelCredits["gpt-6-astra"] == 320 ... 320, "百分比只分配已记录日总额")
        let late = AnalyticsDay(date: absolute.date, tokens: nil, models: [], reportedCredits: 0)
        let withLog = periods(snapshot([late]), sources: [source([apiSample])])[0].creditEstimate!
        precondition(withLog.hasDevice && !withLog.hasOfficial && withLog.recorded.credits == 320 ... 320)
        let partial = AnalyticsDay(date: "2026-10-01", tokens: sample, models: official.models)
        precondition(periods(snapshot([partial]), sources: [source(logs)])[0].logEstimate != nil, "官方非零但少于已知本地用量时仍应兜底")
        let unknownPrice = periods(snapshot(), sources: [source([record("known"), record("future", model: "unknown-model")])])[0].logEstimate!
        precondition(unknownPrice.unknownModels == ["unknown-model"] && unknownPrice.incomplete)
        let unpricedOnly = periods(snapshot(), sources: [source([record("future", model: "unknown-model")])])[0]
        precondition(unpricedOnly.logEstimate == nil, "未知价格不能冒充零金额")
        let partialSources = periods(snapshot(), sources: [source([record("one")])], expected: 2)[0].logEstimate!
        precondition(partialSources.incomplete && partialSources.projected != nil, "缺少设备时仍给出有标记的部分估算")
        let recent = record("recent", at: start + 86400 + 50, speed: "standard")
        let archive = source([record("archived", speed: "standard")], name: "旧来源", at: start + 3600)
        let mixedAges = periods(snapshot(), sources: [archive, source([recent])], expected: 2)[0].deviceEstimate!
        precondition(
            mixedAges.tokens == sample + sample && mixedAges.valuedThrough == now && mixedAges.incomplete,
            "一台设备的旧缓存不能截断其他设备的新请求"
        )

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
