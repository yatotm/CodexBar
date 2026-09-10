import Combine
import Foundation

nonisolated struct RemoteActivityTask: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let provider: String
    let state: String
    let project: String
    let updatedAt: TimeInterval
    let startedAt: TimeInterval
    let modelName: String?

    var isActive: Bool {
        state == "running" || state == "waiting"
    }

    var title: String {
        switch state {
        case "running": "运行中"
        case "waiting": "等待批准"
        case "completed": "已完成"
        case "ended": "会话已结束"
        default: "状态待确认"
        }
    }
}

nonisolated struct RemoteActivityFrame: Decodable, Sendable {
    let schema: Int
    let epoch: String
    let revision: Int64
    let sentAt: TimeInterval
    let tasks: [RemoteActivityTask]

    var isValid: Bool {
        schema == 1 && epoch.count == 32 && revision >= 0 && sentAt.isFinite && tasks.count <= 500
            && Set(tasks.map(\.id)).count == tasks.count
            && tasks.allSatisfy {
                $0.id.count == 64 && ["codex", "claude"].contains($0.provider)
                    && ["running", "waiting", "completed", "ended", "unknown"].contains($0.state)
                    && $0.project.count <= 100 && $0.startedAt.isFinite && $0.updatedAt.isFinite
                    && ($0.modelName?.count ?? 0) <= 100
                    && $0.startedAt > 0 && $0.updatedAt >= $0.startedAt
            }
    }
}

/// 取消通过管道唤醒阻塞读取, 空闲连接没有轮询计时器
private final nonisolated class ActivityStreamCancellation: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock {
            guard !cancelled else { return }
            cancelled = true
            try? pipe.fileHandleForWriting.write(contentsOf: Data([1]))
        }
    }
}

nonisolated enum ActivityStreamClient {
    static var python: String {
        let paths = (CodexCLIResolver.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
        return (paths + ["/opt/homebrew/bin/python3", "/usr/bin/python3"]).first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/python3"
    }

    static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func sshArguments(_ source: UsageSource, command: String) -> [String] {
        [
            "-T",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "ForwardAgent=no",
            "-o",
            "ClearAllForwardings=yes",
            "-o",
            "PermitLocalCommand=no",
            "-o",
            "RemoteCommand=none",
            "-o",
            "ControlPath=none",
            "-o",
            "ServerAliveInterval=60",
            "-o",
            "ServerAliveCountMax=2",
            source.address,
            command
        ]
    }

    static func configure(source: UsageSource, install: Bool) async throws {
        guard source.validationError == nil, source.transport != .https,
              let url = Bundle.main.url(forResource: "ActivityCollector", withExtension: "py") else {
            throw UsageCenterError(message: "实时接入需要有效的本机或 SSH 来源")
        }
        let code = try await Task.detached { try Data(contentsOf: url) }.value
        let bootstrap = "import sys; CODEXBAR_SCRIPT_SOURCE=sys.stdin.buffer.read(1048576); exec(compile(CODEXBAR_SCRIPT_SOURCE,'ActivityCollector.py','exec'))"
        let providers = [source.includesCodex && source.transport == .ssh ? "codex" : nil, source.includesClaude ? "claude" : nil].compactMap(\.self)
        guard !providers.isEmpty else { throw UsageCenterError(message: "请至少选择一种工具") }
        let arguments = [
            "python3",
            "-c",
            bootstrap,
            install ? "install" : "uninstall",
            "--providers",
            providers.joined(separator: ","),
            "--codex-home",
            source.codexHome,
            "--claude-home",
            source.claudeHome
        ]
        if source.transport == .local {
            _ = try await UsageCommandRunner.run(executable: python, arguments: Array(arguments.dropFirst()), input: code)
        } else {
            _ = try await UsageCommandRunner.run(executable: "/usr/bin/ssh", arguments: sshArguments(source, command: arguments.map(quote).joined(separator: " ")), input: code)
        }
    }

    static func run(source: UsageSource, receive: @escaping @Sendable (RemoteActivityFrame) async -> Void) async throws {
        let cancellation = ActivityStreamCancellation()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try await stream(source: source, cancellation: cancellation, receive: receive)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func waitForRead(output: Int32, cancellation: Int32) async -> (result: Int32, cancelled: Bool) {
        await withCheckedContinuation { continuation in
            // 长连接不能占住 Swift cooperative executor 的工作线程
            DispatchQueue.global(qos: .utility).async {
                var descriptors = [
                    pollfd(fd: output, events: Int16(POLLIN), revents: 0),
                    pollfd(fd: cancellation, events: Int16(POLLIN), revents: 0)
                ]
                let result = descriptors.withUnsafeMutableBufferPointer { poll($0.baseAddress, 2, 75000) }
                continuation.resume(returning: (result < 0 ? -errno : result, descriptors[1].revents != 0))
            }
        }
    }

    static func readChunk(from descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        guard count >= 0 else { throw UsageCenterError(message: "实时管道读取失败") }
        return Data(bytes.prefix(count))
    }

    private static func stream(
        source: UsageSource,
        cancellation: ActivityStreamCancellation,
        receive: @escaping @Sendable (RemoteActivityFrame) async -> Void
    ) async throws {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: source.transport == .local ? python : "/usr/bin/ssh")
        process.arguments = source.transport == .local
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/codexbar-usage/ActivityCollector.py").path, "stream"]
            : sshArguments(source, command: "exec python3 \"$HOME/.local/share/codexbar-usage/ActivityCollector.py\" stream")
        process.environment = CodexCLIResolver.environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
            if process.isRunning {
                _ = ProcessTermination.terminate(process, gracefulTimeout: 0.2, killTimeout: 0.5)
            }
        }
        var buffer = Data()
        var lastFrame: RemoteActivityFrame?
        while true {
            let result = await waitForRead(output: output.fileHandleForReading.fileDescriptor, cancellation: cancellation.pipe.fileHandleForReading.fileDescriptor)
            if result.cancelled {
                throw CancellationError()
            }
            if result.result == -EINTR {
                continue
            }
            guard result.result > 0 else { throw UsageCenterError(message: "实时连接超时") }
            let data = try readChunk(from: output.fileHandleForReading.fileDescriptor)
            guard !data.isEmpty else { throw UsageCenterError(message: "实时连接已断开") }
            buffer.append(data)
            guard buffer.count <= 512 * 1024 else { throw UsageCenterError(message: "实时数据超出大小限制") }
            while let newline = buffer.firstIndex(of: 10) {
                let frame = try JSONDecoder().decode(RemoteActivityFrame.self, from: buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard frame.isValid,
                      lastFrame == nil || (lastFrame?.epoch == frame.epoch && frame.revision >= lastFrame!.revision) else {
                    throw UsageCenterError(message: "实时状态协议无效")
                }
                // 同一版本的保活帧只确认连接健康, 不反复刷新整个菜单
                if lastFrame?.revision != frame.revision {
                    await receive(frame)
                }
                lastFrame = frame
                let ack = try JSONSerialization.data(withJSONObject: ["epoch": frame.epoch, "ack": frame.revision])
                try input.fileHandleForWriting.write(contentsOf: ack + Data([10]))
            }
        }
    }
}

@MainActor
final class RemoteActivityController: ObservableObject {
    var onTransition: ((String, RemoteActivityTask) -> Void)?
    @Published private(set) var tasks: [String: [RemoteActivityTask]] = [:]
    @Published private(set) var states: [String: String] = [:]
    @Published private(set) var enabledSourceIDs: Set<String>
    private let defaults: UserDefaults
    private var sources: [UsageSource] = []
    private var connections: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var canConnect = false
    private var canReadLocal = false
    private static let settingsKey = "RemoteActivity.enabledSourceIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledSourceIDs = Set(defaults.stringArray(forKey: Self.settingsKey) ?? [])
    }

    func setSources(_ sources: [UsageSource]) {
        for source in self.sources where !sources.contains(source) {
            disconnect(source.id)
        }
        self.sources = sources
        reconcile()
    }

    func setConnectionAllowed(_ allowed: Bool, localAllowed: Bool) {
        canConnect = allowed
        canReadLocal = localAllowed
        reconcile()
    }

    func setEnabled(_ enabled: Bool, sourceID: String) {
        if enabled {
            enabledSourceIDs.insert(sourceID)
        } else {
            enabledSourceIDs.remove(sourceID)
        }
        defaults.set(Array(enabledSourceIDs).sorted(), forKey: Self.settingsKey)
        reconcile()
    }

    func stop() {
        canConnect = false
        canReadLocal = false
        reconcile()
    }

    private func disconnect(_ id: String) {
        generations[id] = nil
        connections.removeValue(forKey: id)?.cancel()
        states[id] = "已暂停"
    }

    private func reconcile() {
        let desired = sources.filter {
            ($0.transport == .local ? canReadLocal : canConnect) && $0.isEnabled && $0.transport != .https
                && enabledSourceIDs.contains($0.id) && $0.validationError == nil
        }
        for id in Array(connections.keys) where !desired.contains(where: { $0.id == id }) {
            disconnect(id)
        }
        for source in desired where connections[source.id] == nil {
            let generation = UUID()
            generations[source.id] = generation
            connections[source.id] = Task { [weak self] in
                var failures = 0
                while !Task.isCancelled {
                    guard let self, generations[source.id] == generation else { return }
                    states[source.id] = "正在连接"
                    let started = ContinuousClock.now
                    do {
                        try await ActivityStreamClient.run(source: source) { [weak self] frame in
                            await self?.receive(frame, sourceID: source.id, generation: generation)
                        }
                    } catch is CancellationError { return } catch {
                        guard !Task.isCancelled, generations[source.id] == generation else { return }
                        states[source.id] = "连接中断, 等待重连"
                    }
                    failures = started.duration(to: .now) > .seconds(60) ? 1 : min(failures + 1, 7)
                    let delay = min(120, pow(2, Double(failures))) * Double.random(in: 0.8 ... 1.2)
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                }
            }
        }
    }

    private func receive(_ frame: RemoteActivityFrame, sourceID: String, generation: UUID) {
        guard generations[sourceID] == generation else { return }
        let previous = Dictionary(uniqueKeysWithValues: (tasks[sourceID] ?? []).map { ($0.id, $0) })
        // 首次和重连只恢复基线, 不把离线期间的旧变化当成新通知
        if states[sourceID] == "实时连接" {
            for task in frame.tasks {
                if let old = previous[task.id], old.state != task.state, old.isActive,
                   task.state == "waiting" || task.state == "completed" {
                    onTransition?(sourceID, task)
                }
            }
        }
        if tasks[sourceID] != frame.tasks {
            tasks[sourceID] = frame.tasks
        }
        if states[sourceID] != "实时连接" {
            states[sourceID] = "实时连接"
        }
    }
}
