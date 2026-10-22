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
    var stateChangedAt: TimeInterval?
    var effort: String?
    var eventName: String?
    var toolName: String?
    var activeSubagentCount: Int?
    var tokenUsage: CodexTokenUsage?
    var isHistoricalTerminal: Bool?
    var stage: String?
    var recentEvent: String?
    var recentEventAt: TimeInterval?
    var planCompleted: Int?
    var planTotal: Int?
    var pendingInputCount: Int?
    var hasBlockingInputRequest: Bool?
    var lifecycleComplete: Bool?
    var lastProgressAt: TimeInterval?
    var protectionIdentifier: String?
    var tokenUsageComplete: Bool?

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
    var sourceAvailable: Bool?
    var sourceReason: String?
    var backend: String?
    var serverVersion: String?

    var isValid: Bool {
        schema == 1 && epoch.count == 32 && revision >= 0 && sentAt.isFinite && tasks.count <= 500
            && (backend?.count ?? 0) <= 40 && (sourceReason?.count ?? 0) <= 80 && (serverVersion?.count ?? 0) <= 100
            && Set(tasks.map(\.id)).count == tasks.count
            && tasks.allSatisfy {
                $0.id.count == 64 && ["codex", "claude"].contains($0.provider)
                    && ["running", "waiting", "completed", "ended", "unknown"].contains($0.state)
                    && $0.project.count <= 100 && $0.startedAt.isFinite && $0.updatedAt.isFinite
                    && ($0.modelName?.count ?? 0) <= 100 && ($0.eventName?.count ?? 0) <= 50
                    && ($0.effort?.count ?? 0) <= 40 && ($0.toolName?.count ?? 0) <= 120 && (0 ... 1000).contains($0.activeSubagentCount ?? 0)
                    && $0.startedAt > 0 && $0.updatedAt >= $0.startedAt
                    && ($0.stateChangedAt.map(\.isFinite) ?? true)
                    && ($0.tokenUsage?.isValid ?? true)
                    && ($0.stage?.count ?? 0) <= 60 && ($0.recentEvent?.count ?? 0) <= 240
                    && ($0.protectionIdentifier.map { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil } ?? true)
                    && ($0.lastProgressAt.map { $0.isFinite && $0 > 0 && $0 <= sentAt + 60 } ?? true)
                    && (0 ... 1000).contains($0.pendingInputCount ?? 0)
                    && (0 ... 1000).contains($0.planCompleted ?? 0) && (0 ... 1000).contains($0.planTotal ?? 0)
            }
    }
}

nonisolated enum ActivityBackend: String, CaseIterable {
    case sharedCodex
    case claudeHooks

    var provider: String {
        self == .sharedCodex ? "codex" : "claude"
    }

    var installedScript: String {
        self == .sharedCodex ? ".local/share/codexbar-shared-codex/collector.py" : ".local/share/codexbar-usage/ActivityCollector.py"
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
        if source.includesCodex {
            try await configure(source: source, backend: .sharedCodex, install: install)
        }
        if source.includesClaude {
            try await configure(source: source, backend: .claudeHooks, install: install)
        }
    }

    static func configure(source: UsageSource, backend: ActivityBackend, install: Bool) async throws {
        let resource = backend == .sharedCodex ? "SharedCodexCollector" : "ActivityCollector"
        guard source.validationError == nil, source.transport != .https,
              let url = Bundle.main.url(forResource: resource, withExtension: "py") else {
            throw UsageCenterError(message: "实时接入需要有效的本机或 SSH 来源")
        }
        let code = try await Task.detached { try Data(contentsOf: url) }.value
        let bootstrap = "import sys; CODEXBAR_SCRIPT_SOURCE=sys.stdin.buffer.read(1048576); exec(compile(CODEXBAR_SCRIPT_SOURCE,'\(resource).py','exec'))"
        var arguments = ["python3", "-c", bootstrap, install ? "install" : "uninstall"]
        if backend == .sharedCodex {
            if !source.codexHome.isEmpty {
                arguments += ["--codex-home", source.codexHome]
            }
            if install {
                arguments.append("--retire-legacy-hooks")
            }
        } else {
            arguments += ["--providers", "claude", "--codex-home", source.codexHome, "--claude-home", source.claudeHome]
        }
        if source.transport == .local {
            _ = try await UsageCommandRunner.run(executable: python, arguments: Array(arguments.dropFirst()), input: code)
        } else {
            _ = try await UsageCommandRunner.run(executable: "/usr/bin/ssh", arguments: sshArguments(source, command: arguments.map(quote).joined(separator: " ")), input: code)
        }
    }

    static func run(source: UsageSource, backend: ActivityBackend = .claudeHooks, receive: @escaping @Sendable (RemoteActivityFrame) async -> Void) async throws {
        let cancellation = ActivityStreamCancellation()
        try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try await stream(source: source, backend: backend, cancellation: cancellation, receive: receive)
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
        backend: ActivityBackend,
        cancellation: ActivityStreamCancellation,
        receive: @escaping @Sendable (RemoteActivityFrame) async -> Void
    ) async throws {
        let process = Process()
        let input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: source.transport == .local ? python : "/usr/bin/ssh")
        process.arguments = source.transport == .local
            ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(backend.installedScript).path, "stream"]
            : sshArguments(source, command: "exec python3 \"$HOME/\(backend.installedScript)\" stream")
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
                if backend == .sharedCodex || lastFrame?.revision != frame.revision || lastFrame?.tasks != frame.tasks {
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
    var onLocalCodexUpdate: (([RemoteActivityTask], Bool, Bool) -> Void)?
    private let terminalSubject = PassthroughSubject<(String, RemoteActivityTask), Never>()
    var terminalPublisher: AnyPublisher<(String, RemoteActivityTask), Never> {
        terminalSubject.eraseToAnyPublisher()
    }

    @Published private(set) var tasks: [String: [RemoteActivityTask]] = [:]
    @Published private(set) var states: [String: String] = [:]
    @Published private(set) var enabledSourceIDs: Set<String>
    private let defaults: UserDefaults
    private var sources: [UsageSource] = []
    private var connections: [String: Task<Void, Never>] = [:]
    private var generations: [String: UUID] = [:]
    private var backendTasks: [String: [RemoteActivityTask]] = [:]
    private var preparedBackends: Set<String> = []
    private var canConnect = false
    private var canReadLocal = false
    private static let settingsKey = "RemoteActivity.enabledSourceIDs"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledSourceIDs = Set(defaults.stringArray(forKey: Self.settingsKey) ?? [])
    }

    func setSources(_ sources: [UsageSource]) {
        for source in self.sources where !sources.contains(source) {
            for backend in ActivityBackend.allCases {
                let key = Self.connectionKey(source.id, provider: backend.provider)
                disconnect(source: source, backend: backend)
                preparedBackends.remove(key)
                backendTasks[key] = nil
            }
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

    nonisolated static func connectionKey(_ sourceID: String, provider: String) -> String {
        sourceID + ":" + provider
    }

    private func disconnect(source: UsageSource, backend: ActivityBackend) {
        let key = Self.connectionKey(source.id, provider: backend.provider)
        generations[key] = nil
        connections.removeValue(forKey: key)?.cancel()
        setState("已暂停", source: source, backend: backend)
        if source.transport == .local, backend == .sharedCodex {
            onLocalCodexUpdate?([], false, true)
        }
    }

    private func setState(_ value: String, source: UsageSource, backend: ActivityBackend) {
        let key = Self.connectionKey(source.id, provider: backend.provider)
        if states[key] != value {
            states[key] = value
        }
        let health = ActivityBackend.allCases.compactMap { candidate -> String? in
            guard candidate == .sharedCodex ? source.includesCodex : source.includesClaude else { return nil }
            return states[Self.connectionKey(source.id, provider: candidate.provider)]
        }
        let summary = health.allSatisfy { $0 == "实时连接" } ? "实时连接"
            : health.contains("实时连接") ? "部分连接" : value
        if states[source.id] != summary {
            states[source.id] = summary
        }
    }

    private func reconcile() {
        for source in sources {
            for backend in ActivityBackend.allCases {
                let key = Self.connectionKey(source.id, provider: backend.provider)
                let includesProvider = backend == .sharedCodex ? source.includesCodex : source.includesClaude
                let enabled = enabledSourceIDs.contains(source.id) || (source.transport == .local && backend == .sharedCodex)
                let desired = includesProvider && enabled && source.isEnabled && source.validationError == nil
                    && source.transport != .https && (source.transport == .local ? canReadLocal : canConnect)
                if desired, connections[key] == nil {
                    connect(source: source, backend: backend)
                } else if !desired, connections[key] != nil {
                    disconnect(source: source, backend: backend)
                }
            }
        }
    }

    private func connect(source: UsageSource, backend: ActivityBackend) {
        let key = Self.connectionKey(source.id, provider: backend.provider)
        let generation = UUID()
        generations[key] = generation
        connections[key] = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, generations[key] == generation else { return }
                setState("正在连接", source: source, backend: backend)
                let started = ContinuousClock.now
                do {
                    if backend == .sharedCodex, !preparedBackends.contains(key) {
                        try await ActivityStreamClient.configure(source: source, backend: backend, install: true)
                        try Task.checkCancellation()
                        guard generations[key] == generation else { return }
                        preparedBackends.insert(key)
                    }
                    try await ActivityStreamClient.run(source: source, backend: backend) { [weak self] frame in
                        await self?.receive(frame, source: source, backend: backend, generation: generation)
                    }
                } catch is CancellationError { return } catch {
                    guard !Task.isCancelled, generations[key] == generation else { return }
                    setState("连接中断, 等待重连", source: source, backend: backend)
                    if source.transport == .local, backend == .sharedCodex {
                        onLocalCodexUpdate?([], false, true)
                    }
                }
                failures = started.duration(to: .now) > .seconds(60) ? 1 : min(failures + 1, 7)
                let delay = min(120, pow(2, Double(failures))) * Double.random(in: 0.8 ... 1.2)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    static func liveTerminals(previous: [RemoteActivityTask], frame: RemoteActivityFrame, wasConnected: Bool) -> [RemoteActivityTask] {
        guard wasConnected else { return [] }
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        return frame.tasks.filter { task in
            guard task.isHistoricalTerminal != true,
                  let old = oldByID[task.id], old.isActive, old.startedAt == task.startedAt,
                  task.state == "completed" || task.state == "ended" else { return false }
            return (0 ... 10).contains(frame.sentAt - task.updatedAt)
        }
    }

    static func liveTransitions(previous: [RemoteActivityTask], frame: RemoteActivityFrame, wasConnected: Bool) -> [RemoteActivityTask] {
        guard wasConnected else { return [] }
        let completed = liveTerminals(previous: previous, frame: frame, wasConnected: true).filter { $0.state == "completed" }
        let oldByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        let waiting = frame.tasks.filter { task in
            guard task.state == "waiting", task.isHistoricalTerminal != true,
                  let old = oldByID[task.id], old.isActive, old.state != "waiting",
                  old.startedAt == task.startedAt else { return false }
            return (0 ... 10).contains(frame.sentAt - (task.stateChangedAt ?? task.updatedAt))
        }
        return completed + waiting
    }

    private func receive(_ incoming: RemoteActivityFrame, source: UsageSource, backend: ActivityBackend, generation: UUID) {
        let sourceID = source.id
        let key = Self.connectionKey(sourceID, provider: backend.provider)
        guard generations[key] == generation else { return }
        let frame = incoming.filtered(provider: backend.provider)
        let previous = Dictionary(uniqueKeysWithValues: (backendTasks[key] ?? []).map { ($0.id, $0) })
        let available = backend == .sharedCodex ? frame.sourceAvailable == true && frame.backend == "sharedCodex" : frame.sourceAvailable != false
        let wasConnected = states[key] == "实时连接"
        let isLocalCodex = source.transport == .local && backend == .sharedCodex
        let liveTerminals = Self.liveTerminals(previous: Array(previous.values), frame: frame, wasConnected: wasConnected && available)
        // 首次和重连只恢复基线, 不把离线期间的旧变化当成新通知
        if wasConnected, available, !isLocalCodex {
            for task in Self.liveTransitions(previous: Array(previous.values), frame: frame, wasConnected: true) {
                onTransition?(sourceID, task)
            }
        }
        backendTasks[key] = frame.tasks
        let merged = ActivityBackend.allCases.flatMap { backendTasks[Self.connectionKey(sourceID, provider: $0.provider)] ?? [] }
        if tasks[sourceID] != merged {
            tasks[sourceID] = merged
        }
        let state = available ? "实时连接" : frame.sourceReason == "unsupported-server-version" ? "需升级 Codex 至 0.162.0" : "后台暂不可用"
        setState(state, source: source, backend: backend)
        if isLocalCodex {
            onLocalCodexUpdate?(frame.tasks, available, !wasConnected)
        } else {
            for task in liveTerminals {
                terminalSubject.send((sourceID, task))
            }
        }
    }
}

private extension RemoteActivityFrame {
    func filtered(provider: String) -> Self {
        Self(
            schema: schema,
            epoch: epoch,
            revision: revision,
            sentAt: sentAt,
            tasks: tasks.filter { $0.provider == provider },
            sourceAvailable: sourceAvailable,
            sourceReason: sourceReason,
            backend: backend,
            serverVersion: serverVersion
        )
    }
}
