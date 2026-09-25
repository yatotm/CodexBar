import Foundation

@main
struct RefreshSleepSmoke {
    static func main() async throws {
        verifyDisplayPolicy()
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

    private static func verifyDisplayPolicy() {
        let displays: [(name: String, builtin: Bool, active: Bool, asleep: Bool, mirrored: Bool, expected: Bool)] = [
            ("内屏仍被枚举不能放行合盖", true, true, false, false, false),
            ("外接屏独立工作", false, true, false, false, true),
            ("虚拟屏作为唯一屏幕工作", false, true, false, false, true),
            ("硬件镜像副屏未标为 active", false, false, false, true, true),
            ("外接屏已熄灭", false, true, true, false, false),
            ("镜像屏已熄灭", false, false, true, true, false),
            ("仅注册但未工作的虚拟屏", false, false, false, false, false)
        ]
        for display in displays {
            precondition(SystemConnectionGate.isAwakeExternalDisplay(
                isBuiltin: display.builtin, isActive: display.active,
                isAsleep: display.asleep, isMirrored: display.mirrored
            ) == display.expected, display.name)
        }
        let cases: [(name: String, sleeping: Bool, closed: Bool, screensSleeping: Bool, external: Bool, expected: Bool)] = [
            ("开盖保留原有刷新行为", false, false, false, false, true),
            ("开盖熄屏保留原有刷新行为", false, false, true, false, true),
            ("合盖且没有外部工作屏幕", false, true, false, false, false),
            ("合盖后外接或虚拟屏继续工作", false, true, false, true, true),
            ("外接屏全部熄灭", false, true, true, true, false),
            ("系统睡眠优先于显示器枚举结果", true, true, false, true, false),
            ("开盖时系统睡眠仍暂停", true, false, false, true, false),
            ("DarkWake 保留屏幕睡眠门槛", false, true, true, true, false)
        ]
        for scenario in cases {
            let localAllowed = SystemConnectionGate.allowsLocalActivity(
                isSleeping: scenario.sleeping, lidClosed: scenario.closed,
                areDisplaysSleeping: scenario.screensSleeping,
                hasAwakeExternalDisplay: scenario.external
            )
            precondition(localAllowed == scenario.expected, scenario.name)
        }
    }
}
