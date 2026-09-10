import Foundation

@main
struct UsageAnalyticsSmoke {
    static func main() throws {
        let decoder = JSONDecoder()
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
        do {
            _ = try UsageAnalyticsParser.parse(
                usage: usage,
                breakdown: badUnits,
                counts: counts,
                accountID: "account-1",
                start: "",
                end: "",
                now: now
            )
            preconditionFailure("应拒绝未知单位")
        } catch {}
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
}
