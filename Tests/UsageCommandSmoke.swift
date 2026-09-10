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
        let local = CodexActivitySnapshot(waitingTasks: [], runningTasks: [localTask], recentCompletions: [], recentTerminations: [], isCompletionHighlighted: false)
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
