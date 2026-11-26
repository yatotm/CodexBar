import Foundation

@main
struct UsageAnalyticsSmoke {
    static func main() throws {
        let decoder = JSONDecoder()
        let currentPrices = try decoder.decode(UsagePriceBook.self, from: Data(contentsOf: URL(fileURLWithPath: "CodexBar/Resources/UsagePrices.json")))
        UsageLogValuationSmoke.run(prices: currentPrices)
        verifyCurrentCodexPricing(currentPrices)
        verifyReportedCredits(currentPrices)
        let sol61 = currentPrices.rate(for: "gpt-6.1-sol")!
        precondition(sol61.input == 2 && sol61.cachedInput == 0.1 && sol61.cacheWrite == 2.5 && sol61.output == 10)
        precondition(sol61.creditInput == 50 && sol61.creditCachedInput == 2.5 && sol61.creditOutput == 250)
        precondition(currentPrices.rate(for: "gpt-6-sol")?.cachedInput == 0.2, "新 Sol 的缓存降价不能改写旧 Sol 历史")
        precondition(currentPrices.rate(for: "gpt-6.1-sol-2026-09-29")?.model == "gpt-6.1-sol")
        precondition(currentPrices.rate(for: "gpt-6.1-sol-preview") == nil)
        precondition(currentPrices.rate(for: "gpt-6.3-sol") == nil, "新代际不能套用旧型号价格")
        let sol61Day = AnalyticsDay(
            date: "2026-09-30", tokens: .init(input: 3000000, cached: 3000000, output: 3000000),
            models: [
                .init(model: "gpt-6-sol", speed: "standard", weight: 305),
                .init(model: "gpt-6.1-sol", speed: "standard", weight: 302.5),
                .init(model: "gpt-6.1-sol", speed: "fast", weight: 756.25)
            ]
        )
        let sol61Estimates = UsageModelAllocation.estimate(day: sol61Day, prices: currentPrices)!
        precondition(sol61Estimates.allSatisfy { $0.tokens == .init(input: 1000000, cached: 1000000, output: 1000000) }, "混合新旧模型及速度模式时各类 Token 必须守恒")
        precondition(abs(sol61Estimates[1].dollars - 12.1) < 0.000001 && sol61Estimates[1].credits == 302.5)
        precondition(abs(sol61Estimates[2].dollars - 30.25) < 0.000001 && sol61Estimates[2].credits == 756.25, "Fast 延续订阅额度的估算口径")
        precondition(UsageModelAllocation.multiplier(model: .init(model: "gpt-6.1-terra", speed: "ultrafast", weight: 1), prices: currentPrices) == nil, "不支持的速度模式不能默认为标准价")
        let newModels = AnalyticsDay(
            date: "2026-09-23", tokens: .init(input: 3000000, cached: 3000000, output: 3000000),
            models: [
                .init(model: "gpt-6-astra", speed: "standard", weight: 500),
                .init(model: "gpt-6-sol", speed: "standard", weight: 100),
                .init(model: "gpt-6-luna", speed: "standard", weight: 5)
            ]
        )
        let newEstimates = UsageModelAllocation.estimate(day: newModels, prices: currentPrices)!
        precondition(newEstimates.allSatisfy { $0.tokens == .init(input: 1000000, cached: 1000000, output: 1000000) }, "新模型混合用量必须按单价还原并守恒")
        let sol = newEstimates.first { $0.model == "gpt-6-sol" }!
        precondition(abs(sol.dollars - 12.2) < 0.000001 && sol.credits == 305, "Sol 使用独立于旧代模型的官方单价")
        precondition(currentPrices.rate(for: "gpt-5.6-sol")?.input == 4, "新增模型不能改写旧模型历史单价")
        precondition(currentPrices.rate(for: "gpt-6-sol-2026-09-22")?.model == "gpt-6-sol")
        precondition(currentPrices.rate(for: "gpt-6-unknown") == nil, "未知型号不能套用同系列价格")
        for model in ["gpt-6-sol", "gpt-6-luna"] {
            precondition(UsageModelAllocation.multiplier(model: .init(model: model, speed: "fast", weight: 1), prices: currentPrices) == 2.5)
        }
        let now = ISO8601DateFormatter().date(from: "2026-08-03T12:00:00Z")!
        let reset = now.addingTimeInterval(6 * 86400).timeIntervalSince1970
        let usage = Data("{\"account_id\":\"account-1\",\"email\":\"user@example.test\",\"rate_limit\":{\"primary_window\":{\"used_percent\":0,\"limit_window_seconds\":604800,\"reset_at\":\(reset)},\"secondary_window\":null}}".utf8)
        let weights = Data("""
        {"units":"percent","group_by":"day","data":[
          {"date":"2026-08-01","models":[{"model":"model-a","speed":"standard","credits":100}]},
          {"date":"2026-08-02","models":[{"model":"model-a","speed":"standard","credits":10}]}]}
        """.utf8)
        let counts = Data("""
        {"group_by":"day","data":[{"date":"2026-08-01","totals":{
        "uncached_text_input_tokens":1000000,"cached_text_input_tokens":1000000,"text_output_tokens":1000000,"text_total_tokens":3000000}}]}
        """.utf8)
        let parsed = try UsageAnalyticsParser.parse(
            usage: usage,
            breakdown: weights,
            counts: counts,
            accountID: "account-1",
            start: "2026-08-01",
            end: "2026-08-04",
            now: now
        )
        precondition(parsed.days.count == 2 && parsed.days[1].tokens == nil, "缺失的官方日期不能被补成零")
        precondition(parsed.windows.first?.lastUsed == 0, "刚重置的零用量是有效值")
        precondition(parsed.days[0].models[0].weight == 100, "权重保留原单位, 不换成绝对 credits")
        do {
            _ = try UsageAnalyticsParser.parse(
                usage: usage,
                breakdown: weights,
                counts: counts,
                accountID: "different-account",
                start: "",
                end: "",
                now: now
            )
            preconditionFailure("应拒绝串账号")
        } catch {}
        let badUnits = Data(String(decoding: weights, as: UTF8.self).replacingOccurrences(of: "percent", with: "unknown").utf8)
        let unweighted = try UsageAnalyticsParser.parse(usage: usage, breakdown: badUnits, counts: counts, accountID: "account-1", start: "", end: "", now: now)
        precondition(unweighted.days.first?.models.isEmpty == true && unweighted.days.first?.tokens != nil, "未知单位不能污染独立的日总量")
        let daily = Data("""
        {"group_by":"day","balance_unit":"credit","data":[
          {"date":"2026-08-01","totals":{"credits":513.69344,"uncached_text_input_tokens":"changed"}},
          {"date":"2026-08-02","totals":{"credits":0}},{"date":"2026-08-03","totals":{"credits":-1}},
          {"date":"2026-08-04","totals":{}},{"unexpected":true}]}
        """.utf8)
        let verified = try UsageAnalyticsParser.parse(
            usage: usage,
            breakdown: nil,
            counts: daily,
            accountID: "account-1",
            start: "2026-08-01",
            end: "2026-08-05",
            now: now
        )
        precondition(verified.days.map(\.reportedCredits) == [513.69344, 0, nil, nil] && verified.days.first?.tokens == nil)
        let money = Data(String(decoding: daily, as: UTF8.self).replacingOccurrences(of: "\"credit\"", with: "\"usd\"").utf8)
        let unknownUnit = try UsageAnalyticsParser.parse(
            usage: usage,
            breakdown: weights,
            counts: money,
            accountID: "account-1",
            start: "2026-08-01",
            end: "2026-08-05",
            now: now
        )
        precondition(unknownUnit.days.allSatisfy { $0.reportedCredits == nil })
        var cached = unknownUnit
        cached.retainSettledCredits(from: verified)
        precondition(cached.days.map(\.reportedCredits) == [513.69344, 0, nil, nil])
        var corrected = cached
        corrected.days[0].reportedCredits = 0
        corrected.retainSettledCredits(from: verified)
        precondition(corrected.days[0].reportedCredits == 0, "官方的明确更正优先于缓存")
        let prices = try decoder.decode(UsagePriceBook.self, from: Data("""
        {"schema":1,"asOf":"2026-09-09","apiSource":"https://developers.openai.com/api/docs/pricing",
        "creditSource":"https://learn.chatgpt.com/docs/pricing","rates":[
        {"model":"model-a","input":1,"cachedInput":0.1,"output":2}]}
        """.utf8))
        let first = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!.timeIntervalSince1970
        let points = [UsageQuotaPoint(at: first, used: 0), UsageQuotaPoint(at: first + 2 * 86400 - 1, used: 40)]
        let old = UsageObservedWindow(
            resetsAt: first + 7 * 86400,
            firstAt: first,
            firstUsed: 0,
            lastAt: points[1].at,
            lastUsed: 40,
            maxUsed: 40,
            decreased: false,
            observations: points
        )
        let second = UsageObservedWindow(
            resetsAt: first + 9 * 86400,
            firstAt: first + 2 * 86400,
            firstUsed: 0,
            lastAt: first + 2 * 86400,
            lastUsed: 0,
            maxUsed: 0,
            decreased: false,
            observations: [UsageQuotaPoint(at: first + 2 * 86400, used: 0)]
        )
        let completeDays = [
            AnalyticsDay(date: "2026-08-01", tokens: parsed.days[0].tokens, models: parsed.days[0].models),
            AnalyticsDay(date: "2026-08-02", tokens: parsed.days[0].tokens, models: parsed.days[0].models)
        ]
        let snapshot = UsageAnalyticsSnapshot(
            schema: 1,
            accountKey: "test",
            emailKey: "test",
            fetchedAt: now,
            queryStart: "2026-08-01",
            queryEnd: "2026-08-04",
            days: completeDays,
            windows: [old, second],
            importedHistory: true
        )
        let periods = UsageAnalyticsValuation.periods(snapshot: snapshot, prices: prices, now: now)
        precondition(periods.count == 2 && periods[1].earlyReset)
        precondition(periods[1].end.timeIntervalSince1970 == first + 2 * 86400, "提前重置必须切断前一个周期")
        precondition(abs(periods[1].dollars! - 6.2) < 0.001)
        precondition(abs(periods[1].projected! - 15.5) < 0.001, "按已用 40% 外推单值")
        let single = UsageModelAllocation.estimate(day: completeDays[0], prices: prices)!
        precondition(single[0].tokens == completeDays[0].tokens)
        precondition(abs(single[0].dollars - 3.1) < 0.001)
        let mixedPrices = try decoder.decode(UsagePriceBook.self, from: Data("""
        {"schema":1,"asOf":"2026-09-09","apiSource":"test","creditSource":"test","rates":[
        {"model":"model-a","input":1,"cachedInput":0.1,"output":2},
        {"model":"model-b","input":10,"cachedInput":1,"output":20}]}
        """.utf8))
        let mixedDay = AnalyticsDay(
            date: "2026-08-01",
            tokens: AnalyticsTokens(input: 11000000, cached: 11000000, output: 11000000),
            models: [
                AnalyticsModel(model: "model-a", speed: "standard", weight: 50),
                AnalyticsModel(model: "model-b", speed: "standard", weight: 50)
            ]
        )
        let mixed = UsageModelAllocation.estimate(day: mixedDay, prices: mixedPrices)!
        precondition(mixed[0].tokens.input == 10000000 && mixed[1].tokens.input == 1000000, "相同额度权重不能直接当 Token 比例")
        precondition(abs(mixed.reduce(0) { $0 + $1.dollars } - 62) < 0.001, "与脚本混合单价反推公式一致")
        precondition(mixed.reduce(.zero) { $0 + $1.tokens } == mixedDay.tokens, "每日分配必须保留三类 Token 总数")
        var halfDayOld = old
        halfDayOld.observations = [UsageQuotaPoint(at: first, used: 0), UsageQuotaPoint(at: first + 43200 - 1, used: 40)]
        var halfDayNew = second
        halfDayNew.resetsAt = first + 43200 + 604800
        halfDayNew.observations = [UsageQuotaPoint(at: first + 43200, used: 0), UsageQuotaPoint(at: first + 86400 - 1, used: 10)]
        let splitSnapshot = UsageAnalyticsSnapshot(
            schema: 1,
            accountKey: "test",
            emailKey: "test",
            fetchedAt: Date(timeIntervalSince1970: first + 86400),
            queryStart: "2026-08-01",
            queryEnd: "2026-08-02",
            days: [completeDays[0]],
            windows: [halfDayOld, halfDayNew],
            importedHistory: true
        )
        let split = UsageAnalyticsValuation.periods(snapshot: splitSnapshot, prices: prices, now: now)
        precondition(split.count == 2 && split.allSatisfy { $0.dollars! > 0 }, "边界日不再制造零下界")
        precondition(abs(split.reduce(0) { $0 + $1.dollars! } - 3.1) < 0.001, "重置两侧不得重复分配整天金额")
        precondition(split.allSatisfy { abs($0.projected! - 6.2) < 0.001 }, "按同日额度增量拆分后外推一致")
        var staleWindow = old
        staleWindow.observations = [UsageQuotaPoint(at: first, used: 0), UsageQuotaPoint(at: first + 60, used: 40)]
        var staleSnapshot = snapshot
        staleSnapshot.windows = [staleWindow, second]
        let stalePeriods = UsageAnalyticsValuation.periods(snapshot: staleSnapshot, prices: prices, now: now)
        precondition(stalePeriods[1].projected != nil, "末日未使用不能阻断按已有记录外推")

        let partialDays = [completeDays[0], AnalyticsDay(date: "2026-08-02", tokens: nil, models: completeDays[1].models)]
        let partialSnapshot = UsageAnalyticsSnapshot(
            schema: 1,
            accountKey: "test",
            emailKey: "test",
            fetchedAt: now,
            queryStart: "2026-08-01",
            queryEnd: "2026-08-04",
            days: partialDays,
            windows: [old, second],
            importedHistory: true
        )
        let partial = UsageAnalyticsValuation.periods(snapshot: partialSnapshot, prices: prices, now: now)[1]
        precondition(partial.dollars != nil && partial.projected != nil && partial.missingDays == 1, "部分 Token 缺失时用已有样本继续估算")
        precondition(abs(partial.samplePercent - 20) < 0.01 && abs(partial.projected! - 15.5) < 0.01)
        let quietSnapshot = UsageAnalyticsSnapshot(
            schema: 1,
            accountKey: "test",
            emailKey: "test",
            fetchedAt: now,
            queryStart: "2026-08-01",
            queryEnd: "2026-08-04",
            days: [completeDays[0], AnalyticsDay(date: "2026-08-02", tokens: nil, models: [])],
            windows: [old, second],
            importedHistory: true
        )
        let quiet = UsageAnalyticsValuation.periods(snapshot: quietSnapshot, prices: prices, now: now)[1]
        precondition(quiet.missingDays == 0 && quiet.projected != nil, "没有 Token 和额度消耗的空白日不阻断估算")
        var plans = UsagePlanHistory()
        plans.observe(plan: "prolite", at: first, resetsAt: old.resetsAt)
        plans.observe(plan: "pro", at: first + 100, resetsAt: second.resetsAt)
        precondition(plans.entries(for: old.resetsAt).last?.reference == .pro5x, "升级不得重写历史周期档位")
        precondition(plans.entries(for: second.resetsAt).last?.reference == .pro20x, "新周期自动使用 20x 参考范围")
        plans.observe(plan: "prolite", at: first + 101, resetsAt: second.resetsAt)
        precondition(plans.entries(for: second.resetsAt).count == 2, "同周期升级降级保留变化证据")
        plans.observe(plan: "unknown-future-plan", at: first + 102, resetsAt: second.resetsAt)
        precondition(plans.entries(for: second.resetsAt).last?.reference == .disabled, "不能把未知档位猜成 20x")
        var drifting = second
        drifting.resetsAt -= 43
        var driftSnapshot = snapshot
        driftSnapshot.windows = [old, drifting, second]
        let settled = UsageAnalyticsValuation.periods(snapshot: driftSnapshot, prices: prices, now: now)
        precondition(settled.count == 2, "零用量的秒级截止时间漂移不能制造额外消费周期")
        precondition(settled[1].end == periods[1].end)
        var corrupt = old
        corrupt.observations += [UsageQuotaPoint(at: first + 86400, used: 60)]
        precondition(UsageAnalyticsValuation.merge([corrupt]).first?.decreased == true)
        let repeated = UsageAnalyticsValuation.merge([old, old])
        precondition(repeated.count == 1 && repeated[0].observations.count == 2, "重复读取不能重复累计观测")
        var mac = old
        mac.observations = [UsageQuotaPoint(at: first, used: 0), UsageQuotaPoint(at: first + 100, used: 9)]
        var remote = old
        remote.observations = [UsageQuotaPoint(at: first + 50, used: 4), UsageQuotaPoint(at: first + 1000, used: 45)]
        let combined = UsageAnalyticsValuation.merge([mac, remote, remote])
        precondition(combined.count == 1 && combined[0].lastUsed == 45 && combined[0].maxUsed == 45, "跨设备只更新末次比例, 不能相加或重复累计")
        var delayed = remote
        delayed.observations = [UsageQuotaPoint(at: first + 50, used: 4), UsageQuotaPoint(at: first + 1001, used: 44)]
        let concurrent = UsageAnalyticsValuation.merge([remote, delayed], acrossSources: true)
        precondition(concurrent[0].lastUsed == 45 && !concurrent[0].decreased, "另一设备的迟到快照不能让已确认的用量回退")
        var realDrop = remote
        realDrop.observations += [UsageQuotaPoint(at: first + 1002, used: 10)]
        let changedQuota = UsageAnalyticsValuation.merge([remote, realDrop], acrossSources: true)
        precondition(changedQuota[0].decreased && changedQuota[0].lastUsed == 10, "单来源真实回落仍应保留, 不能用最大值掩盖")
        var compressedDecline = remote
        compressedDecline.decreased = true
        compressedDecline.observations += [.init(at: first + 1001, used: 0), .init(at: first + 1007, used: 45)]
        precondition(
            UsageAnalyticsValuation.merge([mac, compressedDecline], acrossSources: true)[0].decreased,
            "压缩缓存可能丢失长期下降的中间证据, 不能擅自解除旧标记"
        )
        let reexported = UsageAnalyticsValuation.merge([mac, remote], acrossSources: true)
        precondition(
            !reexported[0].decreased && reexported[0].lastUsed == 45,
            "原始账本重新导出并替换来源后, 旧回落标记不能继续污染计算"
        )
        var jitter = remote
        jitter.resetsAt += 4
        jitter.observations = [UsageQuotaPoint(at: first + 500, used: 20)]
        precondition(UsageAnalyticsValuation.merge([mac, remote, jitter]).count == 1, "观察时段重叠的秒级截止抖动不能制造新周期")
        var nearReset = remote
        nearReset.resetsAt += 30
        nearReset.observations = [UsageQuotaPoint(at: first + 1001, used: 0)]
        precondition(UsageAnalyticsValuation.merge([remote, nearReset]).count == 2, "没有重叠的相邻实际重置必须保留")
        let evidence = UsageSourceQuotaEvidence(
            schema: 1,
            ready: true,
            complete: true,
            generatedAt: first + 2000,
            scannedAt: first + 2000,
            accountKey: UsageAnalyticsIdentity.hash("codex-account", "one"),
            windows: combined,
            plans: []
        )
        precondition(evidence.isValid && !evidence.matches(UsageAnalyticsIdentity.hash("codex-account", "two")), "不得把不同账号的来源合并")
        print("Analytics parsing, account isolation, missing data, early reset and valuation tests passed")
    }

    private static func verifyReportedCredits(_ prices: UsagePriceBook) {
        let start = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!.timeIntervalSince1970
        let day = 86400.0
        let mode = AnalyticsModel(model: "gpt-6-astra", speed: "standard", weight: 100)
        func daily(_ index: Int, _ credits: Double?, _ n: Int64 = 1000000) -> AnalyticsDay {
            AnalyticsDay(date: "2026-11-0" + String(index + 1), tokens: .init(input: n, cached: 0, output: 0), models: [mode], reportedCredits: credits)
        }
        func window(_ cycleStart: Double, _ observations: [(Double, Double)]) -> UsageObservedWindow {
            let points = observations.map { UsageQuotaPoint(at: start + $0.0, used: $0.1) }
            return .init(
                resetsAt: start + cycleStart + 7 * day,
                firstAt: points.first!.at,
                firstUsed: points.first!.used,
                lastAt: points.last!.at,
                lastUsed: points.last!.used,
                maxUsed: points.last!.used,
                decreased: false,
                observations: points
            )
        }
        func periods(_ rows: [AnalyticsDay], _ windows: [UsageObservedWindow], logs: [(Double, Int64)], fetched: Double) -> [UsageAnalyticsPeriod] {
            let now = Date(timeIntervalSince1970: start + fetched)
            let snapshot = UsageAnalyticsSnapshot(
                schema: 1,
                accountKey: "a",
                emailKey: "e",
                fetchedAt: now,
                queryStart: "2026-11-01",
                queryEnd: "2026-11-08",
                days: rows,
                windows: windows,
                importedHistory: false,
                readCreditReports: true
            )
            let records = logs.enumerated().map { index, item in
                UsageTokenRecord(
                    id: String(index),
                    at: start + item.0,
                    model: "gpt-6.2-astra",
                    speed: "standard",
                    tokens: .init(input: item.1, cached: 0, output: 0)
                )
            }
            let source = UsageTokenSource(name: "Mac", evidence: .init(
                schema: 1,
                ready: true,
                complete: true,
                generatedAt: now.timeIntervalSince1970,
                scannedAt: now.timeIntervalSince1970,
                accountKey: nil,
                truncated: false,
                unattributedCount: 0,
                records: records
            ))
            return UsageAnalyticsValuation.periods(snapshot: snapshot, prices: prices, now: now, tokenSources: logs.isEmpty ? [] : [source])
        }
        let quota = window(0, [(0, 0), (day, 10), (2 * day, 20), (2.5 * day, 30), (3 * day, 40)])
        let records: [(Double, Int64)] = [(100, 1000000), (day + 100, 1000000), (2 * day + 100, 1000000)]
        let mixed = periods([daily(0, 150), daily(1, nil), daily(2, 9999)], [quota], logs: records, fetched: 2.5 * day)[0].creditEstimate!
        precondition(mixed.hasDevice && mixed.hasOfficial && mixed.recorded.credits == 550 ... 550)
        precondition(abs(mixed.projected!.lowerBound - 550 / 0.30 / 25) < 1e-8, "进行中周期合并全部已观测区段外推")
        let settled = periods([daily(0, 150), daily(1, 300), daily(2, 9999)], [quota], logs: records, fetched: 2.5 * day)[0].creditEstimate!
        precondition(settled.recorded.credits == 650 ... 650, "日报只替换对应自然日, 当前日临时数不叠加")
        precondition(abs(settled.projected!.lowerBound - 650 / 0.30 / 25) < 1e-8)
        let sparse = window(0, [(0, 0), (day, 1), (2 * day, 20)])
        let tooLittle = periods([daily(0, 150)], [sparse], logs: Array(records.prefix(2)), fetched: 2 * day)[0].creditEstimate!
        precondition(tooLittle.projected == 70 ... 70, "合并已结算日报与次日设备样本外推")
        let missing = periods([daily(0, 100), daily(2, 300)], [quota], logs: [], fetched: 3 * day)[0].creditEstimate!
        precondition(
            missing.recorded.credits == 400 ... 400 && abs(missing.projected!.lowerBound - 400 / 0.30 / 25) < 1e-8,
            "中间缺报日的周限增量不进入分母"
        )
        let creditsOnly = AnalyticsDay(date: "2026-11-02", tokens: nil, models: [], reportedCredits: 25)
        let available = periods([daily(0, 150), creditsOnly], [quota], logs: [], fetched: 2 * day)[0].creditEstimate!
        precondition(available.recorded.tokens?.input == 1000000 && available.recorded.credits == 175 ... 175)
        precondition(periods([creditsOnly], [quota], logs: [], fetched: 2 * day)[0].creditEstimate!.recorded.tokens == nil)
        let fallback = periods([], [quota], logs: records, fetched: 2.5 * day)[0].creditEstimate!
        precondition(!fallback.hasOfficial && fallback.recorded.credits == 600 ... 600)
        let delayed = periods([daily(0, 50, 250000)], [quota], logs: [records[0]], fetched: day + 60)[0].creditEstimate!
        precondition(!delayed.hasOfficial && delayed.recorded.credits == 200 ... 200, "最近日报已经落后时, 零输出和零缓存不妨碍识别延迟")
        let early = window(0, [(0, 0), (day / 2 - 1, 40)])
        let restarted = window(day / 2, [(day / 2, 0), (day - 1, 10)])
        let split = periods([daily(0, 500)], [early, restarted], logs: [], fetched: day)
        precondition(split.map { $0.creditEstimate!.recorded.credits.lowerBound } == [100, 400], "同一 UTC 日按实际重置和周限增量分摊")
        let aligned = periods([daily(0, 500, 4000000)], [early, restarted], logs: [(100, 1000000), (day / 2, 3000000)], fetched: day)
        precondition(aligned.map { $0.creditEstimate!.recorded.credits.lowerBound } == [375, 125], "三类 Token 对齐时按重置两侧的逐请求份额分摊")
        let noSplit = periods([daily(0, 500, 4000000)], [restarted], logs: [(day / 2, 1000000)], fetched: day)[0].creditEstimate!
        precondition(noSplit.recorded.credits == 200 ... 200 && !noSplit.hasOfficial, "不能用整个报告日给半天的周期计费")

        let closed = window(0, [(0, 0), (day, 10), (2 * day, 20), (3 * day - 30, 39), (3 * day + 15, 40)])
        let next = window(3 * day, [(3 * day, 0), (4 * day, 5)])
        let history = [daily(0, 150), daily(1, nil), daily(2, 300)]
        for days in [history, history + [daily(3, 9000)]] {
            let result = periods(days, [closed, next], logs: [(day + 10, 1000000)], fetched: 4 * day).last!.creditEstimate!
            precondition(
                result.recorded.credits == 650 ... 650 && result.projected == 65 ... 65,
                "结算整期并采用原窗口的末次回执, 下一期日报不能改变上一期"
            )
        }
        let corrected = periods(
            [daily(0, 150), daily(1, 250), daily(2, 300)],
            [closed, next],
            logs: [(day + 10, 1000000)],
            fetched: 4 * day
        ).last!.creditEstimate!
        precondition(corrected.recorded.credits == 700 ... 700 && corrected.projected == 70 ... 70, "官方补报只替换同一天的设备估算")
        let middle = window(day / 2, [(day / 2, 0), (0.75 * day - 1, 20)])
        let last = window(0.75 * day, [(0.75 * day, 0), (day, 40)])
        let three = periods([daily(0, 500)], [early, middle, last], logs: [], fetched: day)
        precondition(three.map { $0.creditEstimate!.recorded.credits.lowerBound } == [200, 100, 200], "一天内多次重置只分一笔日报")
        let uncertain = window(0.25 * day, [(0.25 * day, 0), (0.75 * day, 5)])
        let capped = periods([daily(0, 500)], [uncertain, last], logs: [(day / 2, 3000000), (0.8 * day, 2000000)], fetched: 2 * day)
        precondition(capped.allSatisfy { $0.creditEstimate?.hasOfficial == false })
        precondition(capped.reduce(0) { $0 + $1.creditEstimate!.recorded.credits.upperBound } <= 500, "部分设备估算加总不能超过已结算的日报")

        // 方案 B: 官方日报按 2x 记账的 gpt-6-astra Fast 折算到订阅 2.5x 口径
        let fastDay = AnalyticsDay(
            date: "2026-11-01",
            tokens: .init(input: 1000000, cached: 0, output: 0),
            models: [
                .init(model: "gpt-6-astra", speed: "standard", weight: 20),
                .init(model: "gpt-6-astra", speed: "fast", weight: 80)
            ],
            reportedCredits: 1000
        )
        let adjustedFast = periods([fastDay], [quota], logs: [], fetched: 2 * day)[0].creditEstimate!
        precondition(abs(adjustedFast.recorded.credits.lowerBound - 1200) < 1e-6, "Fast 权重部分需按 2.5/2.0 折算为订阅等效积分")

        // 官方将 gpt-6.2-astra:fast 折叠为 gpt-6-astra:fast 时, 匹配设备日志不应误乘 1.25 且保留真实模型名
        let foldedFastDay = AnalyticsDay(
            date: "2026-11-01",
            tokens: .init(input: 1000000, cached: 0, output: 0),
            models: [.init(model: "gpt-6-astra", speed: "fast", weight: 100)],
            reportedCredits: 400
        )
        let fastRecord = UsageTokenRecord(
            id: "fast-62",
            at: start + 100,
            model: "gpt-6.2-astra",
            speed: "fast",
            tokens: .init(input: 1000000, cached: 0, output: 0)
        )
        let fastSource = UsageTokenSource(name: "Mac", evidence: .init(
            schema: 1, ready: true, complete: true, generatedAt: start + 2 * day, scannedAt: start + 2 * day,
            accountKey: nil, truncated: false, unattributedCount: 0, records: [fastRecord]
        ))
        let foldedSnapshot = UsageAnalyticsSnapshot(
            schema: 1, accountKey: "a", emailKey: "e", fetchedAt: Date(timeIntervalSince1970: start + 2 * day),
            queryStart: "2026-11-01", queryEnd: "2026-11-08", days: [foldedFastDay], windows: [quota],
            importedHistory: false, readCreditReports: true
        )
        let unfolded = UsageAnalyticsValuation.periods(
            snapshot: foldedSnapshot, prices: prices, now: Date(timeIntervalSince1970: start + 2 * day), tokenSources: [fastSource]
        )[0].creditEstimate!
        precondition(abs(unfolded.recorded.credits.lowerBound - 400) < 1e-6, "真实 gpt-6.2-astra:fast 的订阅与官方倍率一致, 不能误乘 1.25")
        precondition(unfolded.recorded.modelCredits["gpt-6.2-astra"] == 400 ... 400, "折叠模型应采用核对后的设备真实模型名")

        // 自然满周重置后的空闲间隙不应阻断跨期日按周限增量分摊, 间隙内存在设备请求时则拒绝整日分摊
        let naturalEnd = window(-6.6 * day, [(-6.6 * day, 0), (0, 20), (0.4 * day - 1, 60)])
        let reopened = window(0.6 * day, [(0.6 * day, 0), (day - 1, 10)])
        let idleGapSplit = periods([daily(0, 500)], [naturalEnd, reopened], logs: [], fetched: 2 * day)
        precondition(idleGapSplit.allSatisfy { $0.creditEstimate?.hasOfficial == true })
        precondition(idleGapSplit.map { $0.creditEstimate!.recorded.credits.lowerBound } == [100, 400], "自然重置后的空闲间隙仍应按增量分摊")
        let busyGap = periods(
            [daily(0, 500, 2000000)],
            [naturalEnd, reopened],
            logs: [(0.1 * day, 500000), (0.5 * day, 500000), (0.7 * day, 500000)],
            fetched: 2 * day
        )
        precondition(busyGap.allSatisfy { $0.creditEstimate?.hasOfficial == false }, "间隙内出现设备活动时不能视为空闲间隙")

        // Token 接近 (<= 2%) 且积分对齐 (<= 5%) 时允许按设备请求份额拆分跨期日
        let closeLogs: [(Double, Int64)] = [(100, 1980000), (day / 2 + 100, 7920000)]
        let closeSplit = periods([daily(0, 2000, 10000000)], [early, restarted], logs: closeLogs, fetched: 2 * day)
        precondition(closeSplit.allSatisfy { $0.creditEstimate?.hasOfficial == true })
        precondition(
            abs(closeSplit[0].creditEstimate!.recorded.credits.lowerBound - 1600) < 1e-6
                && abs(closeSplit[1].creditEstimate!.recorded.credits.lowerBound - 400) < 1e-6,
            "微小后台差额不影响按设备请求份额精准拆分"
        )
    }

    private static func verifyCurrentCodexPricing(_ prices: UsagePriceBook) {
        let tokens = AnalyticsTokens(input: 1000000, cached: 1000000, output: 1000000)
        for (name, input, cached, write, output, factor) in [
            ("gpt-6.2-astra", 8.0, 0.4, 10.0, 40.0, 2.0),
            ("gpt-6.2-sol", 2.0, 0.1, 2.5, 10.0, 2.0),
            ("gpt-6.1-terra", 1.0, 0.05, 1.25, 5.0, 2.5)
        ] {
            let rate = prices.rate(for: name + "-2026-11-17")!
            precondition(rate.model == name && rate.input == input && rate.cachedInput == cached && rate.cacheWrite == write && rate.output == output)
            precondition(rate.cacheWrite12h == write * 2)
            precondition(prices.rate(for: name + "-preview") == nil && rate.subscriptionMultiplier(for: "priority") == factor)
            let modes = name == "gpt-6.1-terra" ? [("standard", 1.0), ("priority", factor)] : [("default", 1.0), ("fast", factor), ("ultrafast", 6.0)]
            let total = modes.reduce(AnalyticsTokens.zero) { sum, _ in sum + tokens }
            let day = AnalyticsDay(date: "2026-11-17", tokens: total, models: modes.map {
                AnalyticsModel(model: name, speed: $0.0, weight: $0.1 * (input + cached + output) * 25)
            })
            let rows = UsageModelAllocation.estimate(day: day, prices: prices)!
            precondition(rows.map(\.tokens) == modes.map { _ in tokens })
            for (row, mode) in zip(rows, modes) {
                precondition(abs(row.dollars - (input + cached + output) * mode.1) < 0.000001)
                precondition(abs(row.credits! - row.dollars * 25) < 0.000001)
            }
            precondition(rate.subscriptionMultiplier(for: "unrecognized") == nil)
            precondition(rate.unrecordedSpeedRange(at: 1794960000) == 1 ... (modes.last!.1))
        }
        let change = ISO8601DateFormatter().date(from: "2027-03-01T08:00:00Z")!
        let astra = prices.rate(for: "gpt-6.2-astra")!
        precondition(astra.unrecordedSpeedRange(at: change.timeIntervalSince1970, plan: .pro20x) == 1 ... 2)
        let sol = prices.rate(for: "gpt-6.2-sol")!
        precondition(sol.unrecordedSpeedRange(at: change.timeIntervalSince1970, plan: .pro20x) == 1 ... 6)
        precondition(sol.unrecordedSpeedRange(at: change.timeIntervalSince1970, plan: .pro5x) == 1 ... 2)
        precondition(astra.apiMultiplier(for: "ultrafast", start: change.addingTimeInterval(-86400), end: change) == 3 ... 3)
        precondition(astra.apiMultiplier(for: "ultrafast", start: change.addingTimeInterval(-1), end: change.addingTimeInterval(1)) == 3 ... 6)
        precondition(astra.apiMultiplier(for: "ultrafast", start: change, end: change.addingTimeInterval(1)) == 6 ... 6)
        precondition(astra.subscriptionMultiplier(for: "ultrafast") == 6 && astra.subscriptionMultiplier(for: "flex") == nil)
        precondition(prices.rate(for: "gpt-6.1-sol")!.unrecordedSpeedRange(at: 1780000000) == 1 ... 2.5)
    }
}
