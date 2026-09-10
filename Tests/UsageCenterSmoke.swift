import Foundation

@main
struct UsageCenterSmoke {
    static func main() async throws {
        checkMenuScopesAndDates()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageCenterStore(directory: directory)
        var local = UsageSource.local
        local.codexAuthentication = .oauth
        let remote = UsageSource(id: "remote", name: "Remote", address: "example", includesClaude: true)
        try await store.save(local)
        try await store.save(remote)
        let now = Date().timeIntervalSince1970
        let formatter = ISO8601DateFormatter()
        let day = String(formatter.string(from: Date()).prefix(10))
        let epoch = UUID().uuidString
        func envelope(provider: String, output: Int, reset: Bool = true) throws -> UsageEnvelope {
            let record: [String: Any] = [
                "id": String(repeating: provider == "claude" ? "c" : "a", count: 64), "session": String(repeating: "s", count: 64),
                "provider": provider, "auth": provider == "claude" ? "oauth" : "unknown", "day": day,
                "model": "test", "project": "project", "kind": "usage", "state": "", "observedAt": now,
                "input": 10, "output": output, "cacheRead": 3, "cacheWrite": 4, "reasoning": 0,
                "turns": 0, "tools": 0, "permissions": 0, "compactions": 0, "subagents": 0, "durationMs": 0
            ]
            let value: [String: Any] = [
                "protocol": 1,
                "epoch": epoch,
                "cursor": 2,
                "reset": reset,
                "hasMore": false,
                "generatedAt": now,
                "records": [record],
                "warnings": [],
                "quotas": [],
                "retentionDays": 210
            ]
            return try JSONDecoder().decode(UsageEnvelope.self, from: JSONSerialization.data(withJSONObject: value))
        }
        try await store.apply(envelope(provider: "codex", output: 1), source: local)
        try await store.apply(envelope(provider: "codex", output: 5), source: remote)
        var dashboard = try await store.dashboard(filter: UsageFilter())
        precondition(dashboard.totals.tokens == 15, "跨设备重复请求必须保留完整计数且只计算一次")
        try await store.apply(envelope(provider: "claude", output: 2, reset: false), source: local)
        dashboard = try await store.dashboard(filter: UsageFilter())
        precondition(dashboard.totals.tokens == 34, "Codex 缓存不重复加总, Claude 缓存单独计入")
        precondition(dashboard.days.first?.metrics?.tokens == 34, "每日详情应使用与总量相同的去重规则")
        precondition(dashboard.days.first?.topModel == "test", "每日主要模型从已有 usage 记录计算")
        precondition(dashboard.days.first?.longestTurnMs == nil, "缺少单轮时长不能伪造为零")
        let filtered = try await store.dashboard(filter: UsageFilter(sourceID: "local"))
        precondition(filtered.totals.tokens == 30, "单机筛选仅计算该机器可见记录")
        var invalid = remote
        invalid.address = "host; touch /tmp/should-not-exist"
        precondition(invalid.validationError != nil, "SSH 别名必须限制为数据")
        try await store.remove(remote)
        dashboard = try await store.dashboard(filter: UsageFilter())
        precondition(dashboard.totals.tokens == 30, "移除来源应同步清理本机贡献")
        print("UsageCenter store smoke tests passed")
    }

    private static func checkMenuScopesAndDates() {
        var codexOnly = UsageSource(id: "codex-only", name: "Codex only", includesClaude: false)
        precondition(UsageMenuScope.all.includes(codexOnly))
        precondition(UsageMenuScope.codex.includes(codexOnly))
        precondition(!UsageMenuScope.claude.includes(codexOnly))
        precondition(UsageMenuScope.claude.includes(.local))
        codexOnly.isEnabled = false
        precondition(!UsageMenuScope.all.includes(codexOnly))
        let now = ISO8601DateFormatter().date(from: "2026-01-01T23:30:00Z")!
        let dashboard = UsageDashboard(days: [
            UsageDay(day: "2025-12-25", tokens: 100), UsageDay(day: "2025-12-26", tokens: 10),
            UsageDay(day: "2026-01-01", tokens: 1), UsageDay(day: "2026-01-02", tokens: 1000)
        ])
        precondition(dashboard.tokenCount(lastDays: 1, now: now) == 1)
        precondition(dashboard.tokenCount(lastDays: 7, now: now) == 11)
        precondition(dashboard.tokenCount(lastDays: 30, now: now) == 111)
        precondition(dashboard.streaks(now: now).current == 1)
        precondition(dashboard.streaks(now: now).longest == 2)
        let durations = UsageDashboard(days: [
            UsageDay(day: "2026-01-01", tokens: 1, longestTurnMs: 12000),
            UsageDay(day: "2025-12-31", tokens: 1, longestTurnMs: 9000)
        ])
        precondition(durations.streaks(now: now).current == 2)
        precondition(durations.longestTurnMs == 12000, "最长单轮不能把多轮时长相加")
    }
}
