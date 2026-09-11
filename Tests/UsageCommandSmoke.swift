import Combine
import Foundation

@MainActor final class CodexActivityMonitor: ObservableObject {
    @Published var snapshot = CodexActivitySnapshot.empty
}

@MainActor final class UsageCenterViewModel: ObservableObject {
    @Published var sources = [UsageSource]()
    @Published var menuScope = UsageMenuScope.all
    let remoteActivity = RemoteActivityController()
}

nonisolated enum CodexCLIResolver {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }
}

@main
struct UsageCommandSmoke {
    static func main() async throws {
        verifyPresentation()
        verifyTerminalPresentation()
        verifyStatusItemLifetime()
        verifyTaskLayoutRestoration()
        verifyScopeIsolation()
        let streamPipe = Pipe()
        try streamPipe.fileHandleForWriting.write(contentsOf: Data("small frame\n".utf8))
        let partial = try ActivityStreamClient.readChunk(from: streamPipe.fileHandleForReading.fileDescriptor)
        precondition(partial == Data("small frame\n".utf8), "长连接必须立即返回短帧, 不能等待管道填满或写端关闭")
        try streamPipe.fileHandleForWriting.close()
        try streamPipe.fileHandleForReading.close()
        let payload = Data(repeating: 65, count: 200000)
        let output = try await UsageCommandRunner.run(
            executable: "/usr/bin/python3",
            arguments: ["-c", "import sys; data=sys.stdin.buffer.read(); sys.stderr.write('diagnostic'); sys.stdout.buffer.write(data)"],
            input: payload
        )
        precondition(output == payload, "管道输入和输出必须完整")
        let started = ContinuousClock.now
        do {
            _ = try await UsageCommandRunner.run(executable: "/bin/sleep", arguments: ["30"], timeout: 0.1)
            preconditionFailure("应触发超时")
        } catch is UsageCenterError {}
        precondition(started.duration(to: .now) < .seconds(2), "超时后应及时结束子进程")
        let task = Task { try await UsageCommandRunner.run(executable: "/bin/sleep", arguments: ["30"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            preconditionFailure("应响应取消")
        } catch is CancellationError {}
        do {
            _ = try await UsageCommandRunner.run(
                executable: "/usr/bin/python3", arguments: ["-c", "import sys; sys.stdout.buffer.write(b'x' * 9000000)"]
            )
            preconditionFailure("应拒绝超大响应")
        } catch is UsageCenterError {}
        print("Usage command pipe, timeout, cancellation and size tests passed")
    }

    static func verifyStatusItemLifetime() {
        let completion = CodexActivityCompletion(
            id: UUID(),
            isAnonymous: false,
            projectName: nil,
            modelName: "claude-test",
            effort: nil,
            completedAt: Date(timeIntervalSince1970: 1000),
            duration: 5,
            machineName: "remote"
        )
        let termination = CodexActivityTermination(
            id: UUID(),
            isAnonymous: false,
            projectName: nil,
            modelName: "codex-test",
            effort: nil,
            terminatedAt: Date(timeIntervalSince1970: 1005),
            duration: 6,
            machineName: "local"
        )
        let state = CodexActivitySnapshot(waitingTasks: [], runningTasks: [], recentCompletions: [completion], recentTerminations: [termination])
        guard case .terminated = state.statusItemActivity(at: Date(timeIntervalSince1970: 1014)) else {
            preconditionFailure("菜单栏应优先显示较新的终止, 不能被旧完成遮盖")
        }
        guard case .idle = state.statusItemActivity(at: Date(timeIntervalSince1970: 1015)) else {
            preconditionFailure("终态提示应在十秒后恢复空闲")
        }
        precondition(state.recentCompletions.count == 1 && state.recentTerminations.count == 1, "图标过期不得删除最近历史")
    }

    static func verifyTaskLayoutRestoration() {
        let name = "CodexBar.upstream-test." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = MainPanelSettings(defaults: defaults)
        settings.updateHookEnabled(false)
        settings.updateHookEnabled(false, hasRemote: true)
        precondition(settings.layout.isVisible(.activity), "只接入远程任务也应自动显示任务卡片")
        settings.setSection(.activity, isVisible: false, undoManager: UndoManager())
        let restored = MainPanelSettings(defaults: defaults)
        restored.updateHookEnabled(false, hasRemote: true)
        precondition(!restored.layout.isVisible(.activity), "重启恢复来源不得覆盖用户隐藏任务卡片的选择")
        restored.updateHookEnabled(false)
        restored.updateHookEnabled(true)
        precondition(restored.layout.isVisible(.activity), "重新开启本机 Hook 应恢复任务入口")
    }

    static func verifyScopeIsolation() {
        let local = CodexActivityMonitor()
        let usage = UsageCenterViewModel()
        let model = ActivityPresentationModel(local: local, usage: usage)
        let task = CodexActivityTaskSnapshot(
            id: UUID(),
            isAnonymous: false,
            latestEvent: .promptSubmitted,
            projectName: nil,
            modelName: "codex-test",
            effort: nil,
            toolName: nil,
            startedAt: Date(),
            stateChangedAt: Date(),
            showsPreciseDuration: true,
            activeSubagentCount: 0
        )
        local.snapshot = CodexActivitySnapshot(waitingTasks: [], runningTasks: [task], recentCompletions: [], recentTerminations: [])
        usage.menuScope = .claude
        precondition(
            model.snapshot.runningTasks.isEmpty && model.statusItemSnapshot.runningTasks.count == 1,
            "Claude 标签只筛选面板, 菜单栏仍需显示其他工具运行状态"
        )
    }

    static func verifyTerminalPresentation() {
        let source = UsageSource(id: "remote", name: "remote", address: "remote")
        func task(_ id: String, _ state: String, _ start: Double, _ end: Double) -> RemoteActivityTask {
            RemoteActivityTask(
                id: String(repeating: id, count: 64),
                provider: "codex",
                state: state,
                project: "project",
                updatedAt: end,
                startedAt: start,
                modelName: nil
            )
        }
        let tasks = [source.id: [
            task("a", "ended", 1000, 1000), task("b", "ended", 900, 1000),
            task("c", "completed", 950, 1000), task("d", "ended", 10, 100),
            task("e", "running", 900, 1000)
        ]]
        for scope in [UsageMenuScope.all, .codex] {
            func merged(_ now: Double, online: Bool) -> CodexActivitySnapshot {
                ActivityPresentationModel.merge(
                    local: .empty,
                    tasks: tasks,
                    states: online ? [source.id: "实时连接"] : [:],
                    enabled: [source.id],
                    sources: [source],
                    scope: scope,
                    now: Date(timeIntervalSince1970: now)
                )
            }
            let initial = merged(1001, online: true)
            precondition(
                initial.recentTerminations.count == 1 && initial.recentCompletions.count == 1,
                "孤立结束和过期记录应隐藏, 真实任务即使缺模型也必须保留"
            )
            let offline = merged(1002, online: false)
            precondition(
                offline.unconfirmedTasks.count == 1 && offline.recentTerminations.count == 1,
                "断线不得新增任务终止"
            )
            let expired = merged(1600, online: true)
            precondition(
                expired.recentTerminations.isEmpty && expired.recentCompletions.isEmpty && expired.runningTasks.count == 1,
                "历史到期或重连后不得重新展示, 活跃任务不受影响"
            )
        }
        print("Remote terminal evidence, retention and reconnect tests passed")
    }

    static func verifyPresentation() {
        let localTask = CodexActivityTaskSnapshot(
            id: UUID(),
            isAnonymous: false,
            latestEvent: .promptSubmitted,
            projectName: "local",
            modelName: "test-model",
            effort: "high",
            toolName: nil,
            startedAt: Date(),
            stateChangedAt: Date(),
            showsPreciseDuration: true,
            activeSubagentCount: nil
        )
        let local = CodexActivitySnapshot(waitingTasks: [], runningTasks: [localTask], recentCompletions: [], recentTerminations: [])
        let remoteTask = RemoteActivityTask(
            id: String(repeating: "a", count: 64),
            provider: "codex",
            state: "running",
            project: "remote",
            updatedAt: 1001,
            startedAt: 1000,
            modelName: "remote-model", eventName: "PreToolUse", toolName: "Bash", activeSubagentCount: 1
        )
        let sources = [UsageSource(id: "a", name: "machine-a", address: "a"), UsageSource(id: "b", name: "machine-b", address: "b")]
        let tasks = ["a": [remoteTask], "b": [remoteTask]]
        let online = ["a": "实时连接", "b": "实时连接"]
        let all = ActivityPresentationModel.merge(local: local, tasks: tasks, states: online, enabled: ["a", "b"], sources: sources, scope: .all)
        precondition(all.activeCount == 3 && Set(all.runningTasks.map(\.id)).count == 3, "同一会话标识在不同机器上不得覆盖")
        precondition(all.runningTasks.contains { $0.modelName == "remote-model" && $0.machineName == "machine-a" && $0.latestEvent == .toolStarted && $0.toolName == "Bash" })
        precondition(CodexActivityDisplayFormat.modelMetadata(modelName: "test-model", effort: "high", machineName: "本机") == "test-model • high • 本机")
        precondition(local.runningTasks[0].modelName == "test-model", "合并展示不得改写本机任务与防睡眠输入")
        let disconnected = ActivityPresentationModel.merge(local: local, tasks: tasks, states: [:], enabled: ["a", "b"], sources: sources, scope: .all)
        precondition(disconnected.activeCount == 1 && disconnected.unconfirmedTasks.count == 2 && disconnected.recentCompletions.isEmpty)
        let claude = ActivityPresentationModel.merge(local: local, tasks: tasks, states: online, enabled: ["a", "b"], sources: sources, scope: .claude)
        precondition(!claude.hasTaskCenterContent, "Claude 标签不得混入 Codex 任务")
        print("Merged task identity, machine labels, scope filtering and disconnected-state isolation passed")
    }
}
