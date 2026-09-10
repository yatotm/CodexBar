import Foundation

@main
struct WorkflowLocalSmoke {
    static func main() async throws {
        let fixture = Data(#"{"date":"2026-09-09","sourceGeneration":"legacy-generation","sourceIsFresh":false,"sessionIds":["s1","s1","s2"],"turnIds":["t1"],"modelCounts":{"model-a":3}}"#.utf8)
        let legacy = try JSONDecoder().decode(WorkflowDailyAggregate.self, from: fixture)
        precondition(legacy.sessionStartCount == nil && legacy.eventCount == nil)
        let encoded = try legacy.jsonLineData()
        let restored = try JSONDecoder().decode(WorkflowDailyAggregate.self, from: encoded)
        precondition(restored == legacy, "本地聚合文件格式保持不变")
        let fields = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        precondition(fields["sessionStartCount"] == nil, "历史缺失字段不能变成明确的零")
        var current = WorkflowDailyAggregate(date: "2026-09-10")
        current.sessionCount = 5
        current.turnCount = 8
        current.postToolUseCount = 13
        let snapshot = WorkflowSnapshot(localAggregates: [current, legacy])
        precondition(snapshot.dailyMetrics.map(\.startDate) == ["2026-09-09", "2026-09-10"])
        precondition(snapshot.dailyMetrics[0].sessionCount == 2)
        precondition(snapshot.dailyMetrics[0].turnCount == 1)
        precondition(snapshot.dailyMetrics[1].sessionCount == 5)
        precondition(snapshot.dailyMetrics[1].toolCallCount == 13)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        current = WorkflowDailyAggregate(date: CodexDateFormat.dayString(from: Date()))
        current.sessionCount = 5
        let daily = directory.appendingPathComponent("daily.jsonl")
        try current.jsonLineData().write(to: daily)
        let service = WorkflowService(eventsDirectoryURL: directory.appendingPathComponent("events"), dailyLogURL: daily)
        let loaded = await service.loadSnapshot()
        precondition(loaded.dailyMetrics.first?.sessionCount == 5, "无云服务时仍能读取本地统计")
        print("Local workflow history, missing counts, identity deduplication and date ordering verified")
    }
}
