import Foundation

nonisolated enum CodexCLIResolver {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }
}

@main
struct UsageAnalyticsLive {
    static func main() async throws {
        let start = ContinuousClock.now
        let snapshot = try await UsageAnalyticsClient().fetch()
        print("官方统计读取成功: \(snapshot.days.count) 天, \(snapshot.windows.count) 个当前周限, \(start.duration(to: .now))")
    }
}
