import Foundation

@main
struct RefreshSleepSmoke {
    static func main() async throws {
        let coordinator = RefreshTaskCoordinator()
        var requests = 0
        var commits = 0
        var refreshing = false
        coordinator.suspend()
        for _ in 0 ..< 3 {
            coordinator.run(setRefreshing: { refreshing = $0 }, operation: { requests += 1
                return 1
            }, commit: { _ in commits += 1 })
        }
        await Task.yield()
        precondition(requests == 0 && !refreshing, "后台恢复执行不等于正式唤醒, 暂停时不得发起刷新")

        coordinator.resume()
        coordinator.run(setRefreshing: { refreshing = $0 }, operation: { requests += 1
            return 1
        }, commit: { _ in commits += 1 })
        coordinator.suspend()
        refreshing = false
        try await Task.sleep(for: .milliseconds(20))
        precondition(requests == 0, "入睡前排队但尚未开始的请求必须取消")

        coordinator.resume()
        coordinator.run(setRefreshing: { refreshing = $0 }, operation: {
            requests += 1
            try? await Task.sleep(for: .milliseconds(100))
            return 1
        }, commit: { _ in commits += 1 })
        try await Task.sleep(for: .milliseconds(20))
        precondition(requests == 1)
        coordinator.suspend()
        refreshing = false
        try await Task.sleep(for: .milliseconds(120))
        precondition(commits == 0, "睡眠前的在途结果不能覆盖暂停后的状态")
        coordinator.run(setRefreshing: { refreshing = $0 }, operation: { requests += 1
            return 1
        }, commit: { _ in commits += 1 })
        await Task.yield()
        precondition(requests == 1 && !refreshing)

        coordinator.resume()
        coordinator.run(setRefreshing: { refreshing = $0 }, operation: { requests += 1
            return 1
        }, commit: { _ in commits += 1 })
        try await Task.sleep(for: .milliseconds(20))
        precondition(requests == 2 && commits == 1 && !refreshing, "正式唤醒后恢复正常刷新")
        print("Refresh suspension, background wake attempts, cancelled results and resume tests passed")
    }
}
