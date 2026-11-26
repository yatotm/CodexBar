import Foundation
import Security

/// 取消标记只跨线程传递, Process 和文件描述符始终由后台执行线程持有
private final nonisolated class UsageCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.withLock { cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }
}

nonisolated enum UsageCommandRunner {
    static func run(executable: String, arguments: [String], input: Data = Data(), timeout: TimeInterval = 45) async throws -> Data {
        let cancellation = UsageCommandCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try execute(executable: executable, arguments: arguments, input: input, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        executable: String,
        arguments: [String],
        input: Data,
        timeout: TimeInterval,
        cancellation: UsageCommandCancellation
    ) throws -> Data {
        if cancellation.isCancelled {
            throw CancellationError()
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = CodexCLIResolver.environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        signal(SIGPIPE, SIG_IGN)
        try process.run()
        let outputHandle = outputPipe.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        let inputHandle = inputPipe.fileHandleForWriting
        defer {
            if process.isRunning {
                _ = ProcessTermination.terminate(process, gracefulTimeout: 0.2, killTimeout: 0.5)
            }
            try? outputHandle.close()
            try? errorHandle.close()
            try? inputHandle.close()
        }
        for descriptor in [outputHandle.fileDescriptor, errorHandle.fileDescriptor, inputHandle.fileDescriptor] {
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var output = Data()
        var errors = Data()
        var sent = 0
        var inputClosed = false
        var outputClosed = false
        var errorClosed = false
        repeat {
            if cancellation.isCancelled {
                throw CancellationError()
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw UsageCenterError(message: "采集超时, 已停止连接并保留缓存")
            }
            if !inputClosed {
                if sent < input.count {
                    let written = input.withUnsafeBytes { bytes in
                        write(inputHandle.fileDescriptor, bytes.baseAddress!.advanced(by: sent), min(16384, input.count - sent))
                    }
                    if written > 0 {
                        sent += written
                    }
                    if written < 0, errno != EAGAIN, errno != EINTR {
                        sent = input.count
                    }
                }
                if sent == input.count {
                    try? inputHandle.close()
                    inputClosed = true
                }
            }
            outputClosed = try drain(outputHandle.fileDescriptor, into: &output, limit: 8 * 1024 * 1024)
            errorClosed = try drain(errorHandle.fileDescriptor, into: &errors, limit: 32768)
            var descriptors = [
                pollfd(fd: outputClosed ? -1 : outputHandle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errorClosed ? -1 : errorHandle.fileDescriptor, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputClosed ? -1 : inputHandle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            ]
            _ = descriptors.withUnsafeMutableBufferPointer { buffer in
                poll(buffer.baseAddress, nfds_t(buffer.count), 100)
            }
        } while process.isRunning
        _ = try drain(outputHandle.fileDescriptor, into: &output, limit: 8 * 1024 * 1024)
        _ = try drain(errorHandle.fileDescriptor, into: &errors, limit: 32768)
        try checkExitStatus(process.terminationStatus, errors: errors)
        return output
    }

    private static func checkExitStatus(_ status: Int32, errors: Data) throws {
        guard status == 0 else {
            let details = String(data: errors, encoding: .utf8) ?? ""
            if let message = details.split(separator: "\n").first(where: { $0.hasPrefix("CodexBar: ") }) {
                throw UsageCenterError(message: String(message.dropFirst(10).prefix(300)))
            }
            if details.contains("Host key verification failed") || details.contains("REMOTE HOST IDENTIFICATION HAS CHANGED") {
                throw UsageCenterError(message: "SSH 主机密钥未通过校验, 请先在终端核实该主机")
            }
            if details.contains("Permission denied") {
                throw UsageCenterError(message: "SSH 或数据目录权限不足, 请检查终端登录")
            }
            if details.contains("python3"), details.contains("not found") {
                throw UsageCenterError(message: "统计端需要 Python 3.9 或以上")
            }
            throw UsageCenterError(message: "采集进程失败 (退出码 \(status)), 请检查连接和数据目录")
        }
    }

    private static func drain(_ descriptor: Int32, into result: inout Data, limit: Int) throws -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 {
                return count == 0
            }
            guard result.count + count <= limit else { throw UsageCenterError(message: "统计端响应超出大小限制") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }
}

private final nonisolated class UsageHTTPDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor UsageCollectorClient {
    private static let keychainService = "io.github.yatotm.codexbar.usage-center"
    private var claudeClockHome: String?
    private var claudeClockMemo = Data()

    func saveToken(_ token: String, for sourceID: String) throws {
        guard !token.isEmpty else { return }
        guard token.utf8.count >= 32, token.utf8.count <= 512,
              token.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
            throw UsageCenterError(message: "统计服务令牌需要 32 到 512 个非空白 ASCII 字符")
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: sourceID
        ]
        let data = Data(token.utf8)
        let result = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw UsageCenterError(message: "无法保存统计服务令牌到钥匙串") }
        } else if result != errSecSuccess {
            throw UsageCenterError(message: "无法更新统计服务令牌")
        }
    }

    func deleteToken(for sourceID: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: sourceID
        ] as CFDictionary)
    }

    private func token(for sourceID: String) throws -> String {
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: sourceID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw UsageCenterError(message: "请为该 HTTPS 来源配置统计服务令牌")
        }
        return token
    }

    func fetch(source: UsageSource, cursor: UsageCursor, scan: Bool) async throws -> UsageEnvelope {
        if let error = source.validationError {
            throw UsageCenterError(message: error)
        }
        let data: Data = switch source.transport {
        case .https:
            try await fetchHTTPS(source: source, cursor: cursor)
        case .local, .ssh:
            try await fetchProcess(source: source, cursor: cursor, scan: scan)
        case .probe:
            throw UsageCenterError(message: "探针节点由汇聚中枢统一同步")
        }
        try Task.checkCancellation()
        guard let result = try? JSONDecoder().decode(UsageEnvelope.self, from: data), result.isValid else {
            throw UsageCenterError(message: "统计端返回了不支持的协议或无效数据")
        }
        return result
    }

    private func fetchProcess(source: UsageSource, cursor: UsageCursor, scan: Bool) async throws -> Data {
        var arguments = ["collect", "--cursor", String(cursor.revision), "--epoch", cursor.epoch, "--limit", "1500", "--budget", "10"]
        if !scan || source.collectorCacheDirectory?.isEmpty == false {
            arguments.append("--skip-scan")
        }
        if let directory = source.collectorCacheDirectory, !directory.isEmpty {
            arguments += ["--state-dir", directory]
        }
        let providers = source.enabledProviderNames.joined(separator: ",")
        guard !providers.isEmpty else {
            throw UsageCenterError(message: "至少启用一个监控渠道")
        }
        arguments += ["--providers", providers]
        if source.includesCodex {
            arguments.append("--include-auth-type")
        }
        for (flag, path) in [
            ("--codex-home", source.codexHome),
            ("--claude-home", source.claudeHome),
            ("--gemini-home", source.geminiHome)
        ] where !path.isEmpty {
            arguments += [flag, path]
        }
        return try await runCollector(source: source, arguments: arguments)
    }

    func fetchValuationHistory(source: UsageSource) async throws -> UsageValueEvidence {
        guard source.transport == .local else { throw UsageCenterError(message: "价值统计仅补充本机周期记录") }
        var arguments = ["valuation", "--budget", "10"]
        if !source.codexHome.isEmpty {
            arguments += ["--codex-home", source.codexHome]
        }
        if let directory = source.collectorCacheDirectory, !directory.isEmpty {
            arguments += ["--state-dir", directory]
        }
        let data = try await runCollector(source: source, arguments: arguments)
        let result = try JSONDecoder().decode(UsageValueEvidence.self, from: data)
        guard result.schema == 1, result.windows.count <= 1000,
              result.windows.allSatisfy({ $0.resetsAt.isFinite && $0.resetsAt > 0 && $0.observations.count < 20000 }) else {
            throw UsageCenterError(message: "本机周期证据格式无效")
        }
        return result
    }

    func fetchQuotaHistory(source: UsageSource, account: String, scan: Bool) async throws -> UsageSourceQuotaEvidence {
        guard source.transport != .https, source.includesCodex, source.validationError == nil,
              account.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw UsageCenterError(message: "额度历史需要已确认同账号的本机或 SSH 来源")
        }
        var arguments = ["quota-history", "--budget", "10", "--account-key", account]
        if !scan {
            arguments.append("--skip-scan")
        }
        for (flag, path) in [
            ("--codex-home", source.codexHome),
            ("--claude-home", source.claudeHome),
            ("--state-dir", source.collectorCacheDirectory ?? "")
        ] where !path.isEmpty {
            arguments += [flag, path]
        }
        let data = try await runCollector(source: source, arguments: arguments)
        guard let value = try? JSONDecoder().decode(UsageSourceQuotaEvidence.self, from: data), value.isValid else {
            throw UsageCenterError(message: "设备额度历史格式无效")
        }
        guard value.matches(account) else { throw UsageCenterError(message: "当前 OAuth 账号与 Mac 不同, 未合并该来源") }
        return value
    }

    func configureClaude(source: UsageSource, install: Bool, includeHooks: Bool = false) async throws {
        guard source.transport == .local || source.transport == .ssh, source.validationError == nil else {
            throw UsageCenterError(message: "请通过本机或 SSH 在 Claude 所在机器接入")
        }
        var arguments = [install ? "install-claude" : "uninstall-claude"]
        if !includeHooks {
            arguments.append("--no-hooks")
        }
        if !source.claudeHome.isEmpty {
            arguments += ["--claude-home", source.claudeHome]
        }
        _ = try await runCollector(source: source, arguments: arguments)
    }

    func configureGemini(source: UsageSource, install: Bool) async throws {
        guard source.transport == .local || source.transport == .ssh, source.validationError == nil else {
            throw UsageCenterError(message: "请通过本机或 SSH 在 Gemini 所在机器接入")
        }
        var arguments = [install ? "install-gemini" : "uninstall-gemini"]
        if !source.geminiHome.isEmpty {
            arguments += ["--gemini-home", source.geminiHome]
        }
        _ = try await runCollector(source: source, arguments: arguments)
    }

    func fetchLocalGeminiValuation(source: UsageSource, scan: Bool) async throws -> GeminiValuationEvidence {
        guard source.transport == .local else {
            throw UsageCenterError(message: "仅用于读取本机 Gemini 价值缓存")
        }
        var arguments = ["gemini-valuation", "--budget", "8", "--providers", "gemini"]
        if !scan {
            arguments.append("--skip-scan")
        }
        if !source.geminiHome.isEmpty {
            arguments += ["--gemini-home", source.geminiHome]
        }
        if let directory = source.collectorCacheDirectory, !directory.isEmpty {
            arguments += ["--state-dir", directory]
        }
        let data = try await runCollector(source: source, arguments: arguments)
        return try JSONDecoder().decode(GeminiValuationEvidence.self, from: data)
    }

    func fetchLocalClaudeValuation(source: UsageSource) async throws -> GeminiValuationEvidence {
        guard source.transport == .local else {
            throw UsageCenterError(message: "仅用于读取本机 Claude 价值窗口")
        }
        var arguments = ["claude-valuation", "--budget", "6", "--providers", "claude"]
        if !source.claudeHome.isEmpty {
            arguments += ["--claude-home", source.claudeHome]
        }
        let data = try await runCollector(source: source, arguments: arguments)
        return try JSONDecoder().decode(GeminiValuationEvidence.self, from: data)
    }

    nonisolated struct LocalZeroHookSnapshot: Decodable {
        let tasks: [RemoteActivityTask]
        let quotas: [UsageQuotaObservation]
        var geminiAccountKey: String?
        var claudeClockMemo: String?
    }

    func fetchLocalZeroHookSnapshot(source: UsageSource, probeURL: URL? = Bundle.main.url(forResource: "CodexBarProbe", withExtension: "py")) async throws -> LocalZeroHookSnapshot {
        guard source.transport == .local, let probeURL else {
            return LocalZeroHookSnapshot(tasks: [], quotas: [])
        }
        let candidates = (CodexCLIResolver.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
            + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return LocalZeroHookSnapshot(tasks: [], quotas: [])
        }
        let snippet = """
        import importlib.util, json, pathlib, sys, time
        p = pathlib.Path(sys.argv[1])
        spec = importlib.util.spec_from_file_location("probe", p)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        col = mod.load_collector_module()
        homes = mod.default_homes()
        if sys.argv[2]: homes["claude"] = pathlib.Path(sys.argv[2]).expanduser()
        if sys.argv[3]: homes["gemini"] = pathlib.Path(sys.argv[3]).expanduser()
        enabled = set(sys.argv[4].split(",")) if sys.argv[4] else set()
        now = time.time()
        tasks = []
        quotas = []
        account = None
        clocks = {}
        if "claude" in enabled:
            clocks = json.loads(sys.stdin.buffer.read() or b"{}")
            tasks.extend(mod.read_claude_live_tasks(homes["claude"], col, now, clocks))
            q = mod.read_live_quota(homes["claude"], "claude")
            if q: quotas.append(q)
        if "gemini" in enabled:
            tasks.extend(mod.read_gemini_live_tasks(homes["gemini"], col, now))
            state = mod.read_live_state(homes["gemini"])
            account = state.get("activeAccount")
            q = mod.read_live_quota(homes["gemini"], "gemini", state)
            if q: quotas.append(q)
        memo = json.dumps(clocks, separators=(",", ":"))
        print(json.dumps({"tasks": tasks, "quotas": quotas, "geminiAccountKey": account,
                          "claudeClockMemo": memo if len(memo) <= 262144 else "{}"}))
        """
        let wanted = [source.includesClaude ? "claude" : nil, source.includesGemini ? "gemini" : nil].compactMap(\.self).joined(separator: ",")
        guard !wanted.isEmpty else { return LocalZeroHookSnapshot(tasks: [], quotas: []) }
        let data = try await UsageCommandRunner.run(
            executable: python,
            arguments: ["-B", "-c", snippet, probeURL.path, source.claudeHome, source.geminiHome, wanted],
            input: source.includesClaude && source.claudeHome == claudeClockHome ? claudeClockMemo : Data(),
            timeout: 8
        )
        try Task.checkCancellation()
        var snapshot = try JSONDecoder().decode(LocalZeroHookSnapshot.self, from: data)
        // 本机每次采集使用短进程, 游标只在内存中交接
        claudeClockHome = source.claudeHome
        claudeClockMemo = Data((snapshot.claudeClockMemo ?? "").utf8)
        snapshot.claudeClockMemo = nil
        return snapshot
    }

    func fetchTokenHistory(source: UsageSource, account: String, scan: Bool) async throws -> UsageSourceTokenEvidence {
        guard source.transport != .https, source.includesCodex, source.validationError == nil,
              account.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw UsageCenterError(message: "日志估算需要已确认同账号的本机或 SSH 来源")
        }
        var arguments = ["token-history", "--budget", "10", "--account-key", account]
        if !scan {
            arguments.append("--skip-scan")
        }
        for (flag, path) in [
            ("--codex-home", source.codexHome), ("--claude-home", source.claudeHome),
            ("--state-dir", source.collectorCacheDirectory ?? "")
        ] where !path.isEmpty {
            arguments += [flag, path]
        }
        let data = try await runCollector(source: source, arguments: arguments)
        guard let value = try? JSONDecoder().decode(UsageSourceTokenEvidence.self, from: data), value.isValid else {
            throw UsageCenterError(message: "设备 Token 历史格式无效")
        }
        guard value.matches(account) else { throw UsageCenterError(message: "当前 OAuth 账号与 Mac 不同, 未合并该来源") }
        return value
    }

    private func runCollector(source: UsageSource, arguments: [String]) async throws -> Data {
        guard let script = Bundle.main.url(forResource: "UsageCollector", withExtension: "py") else {
            throw UsageCenterError(message: "App 包内缺少统计采集器")
        }
        if source.transport == .local {
            let candidates = (CodexCLIResolver.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
                + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                throw UsageCenterError(message: "本机统计需要 Python 3.9 或以上")
            }
            return try await UsageCommandRunner.run(executable: python, arguments: [script.path] + arguments)
        }
        let bootstrap = "import sys; CODEXBAR_SCRIPT_SOURCE=sys.stdin.buffer.read(1048576); exec(compile(CODEXBAR_SCRIPT_SOURCE, '<codexbar>', 'exec'))"
        let command = (["python3", "-c", bootstrap] + arguments).map(Self.shellQuote).joined(separator: " ")
        let ssh = [
            "-T",
            "-oBatchMode=yes",
            "-oStrictHostKeyChecking=yes",
            "-oConnectTimeout=8",
            "-oServerAliveInterval=10",
            "-oServerAliveCountMax=2",
            "-oForwardAgent=no",
            "-oClearAllForwardings=yes",
            "-oPermitLocalCommand=no",
            "-oRemoteCommand=none",
            "--",
            source.address,
            command
        ]
        return try await UsageCommandRunner.run(executable: "/usr/bin/ssh", arguments: ssh, input: Data(contentsOf: script))
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func fetchHTTPS(source: UsageSource, cursor: UsageCursor) async throws -> Data {
        guard var components = URLComponents(string: source.address) else { throw UsageCenterError(message: "HTTPS 地址无效") }
        components.path = "/v1/changes"
        components.queryItems = [
            URLQueryItem(name: "epoch", value: cursor.epoch),
            URLQueryItem(name: "cursor", value: String(cursor.revision)),
            URLQueryItem(name: "limit", value: "1500")
        ]
        guard let url = components.url else { throw UsageCenterError(message: "HTTPS 地址无效") }
        var request = URLRequest(url: url)
        try request.setValue("Bearer " + token(for: source.id), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: UsageHTTPDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UsageCenterError(message: "统计服务拒绝请求, 请检查地址和服务令牌")
        }
        guard response.expectedContentLength <= 8 * 1024 * 1024 else { throw UsageCenterError(message: "统计服务响应过大") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8 * 1024 * 1024 else { throw UsageCenterError(message: "统计服务响应过大") }
            data.append(byte)
        }
        return data
    }
}
