import Foundation

@main
struct UsagePerformance {
    static func main() async throws {
        let store = UsageCenterStore()
        for filter in [UsageFilter(days: 210), UsageFilter(provider: "codex"), UsageFilter(provider: "claude"), UsageFilter(days: 210)] {
            let start = ContinuousClock.now
            let result = try await store.dashboard(filter: filter)
            print("provider=\(filter.provider), days=\(filter.days), tokens=\(result.totals.tokens), elapsed=\(start.duration(to: .now))")
        }
    }
}
