import Foundation

nonisolated enum CodexCLIResolver {
    static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }
}

@main
struct UsageCommandSmoke {
    static func main() async throws {
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
}
