import CryptoKit
import Darwin
import Foundation
import Security

nonisolated struct HubNodeRemoteDTO: Codable {
    let id: String
    let name: String
    let enabled: Bool
    let enabledProviders: [String]
    let bridgeStatusLine: Bool
    let detectedProviders: [String]
    let probeVersion: String
    let platform: String
    let lastSeenAt: Double?
    let online: Bool
    let warnings: [String]
    let quotas: [UsageQuotaObservation]
    let geminiPlan: String?
    let currentCodexAuthentication: UsageAuthentication?
}

nonisolated struct HubPullResponse: Decodable {
    let `protocol`: Int
    let epoch: String
    let cursor: Int64
    let liveRevision: Int64
    let reset: Bool
    let hasMore: Bool
    let generatedAt: Double
    let retentionDays: Int
    let nodes: [HubNodeRemoteDTO]
    let records: [UsageRecord]
    let liveTasks: [String: [RemoteActivityTask]]
    let geminiValuation: GeminiValuationEvidence?
    let claudeValuation: GeminiValuationEvidence?

    var isValid: Bool {
        `protocol` == 2 && UUID(uuidString: epoch) != nil && cursor >= 0 && liveRevision >= 0
            && records.count <= 3000 && records.allSatisfy(\.isValid)
            && nodes.allSatisfy { $0.quotas.allSatisfy(\.isValid) }
    }
}

nonisolated struct HubEventsResponse: Decodable {
    let `protocol`: Int
    let liveRevision: Int64
    let sentAt: Double
    let geminiAccountKey: String?
    let nodes: [HubNodeRemoteDTO]
    let liveTasks: [String: [RemoteActivityTask]]
}

private final nonisolated class HubNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
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

nonisolated enum HubCrypto {
    static func randomToken(prefix: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return prefix + bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func deriveSigningKey(rawWriteToken: String) -> String {
        sha256Hex(Data(("codexbar-probe-v1:" + rawWriteToken.trimmingCharacters(in: .whitespacesAndNewlines)).utf8))
    }

    static func hashReadToken(rawReadToken: String) -> String {
        let data = Data(("codexbar-hub-read-v1:" + rawReadToken.trimmingCharacters(in: .whitespacesAndNewlines)).utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func probeInstallCommand(hubURL: String, nodeID: String, rawWriteToken: String, providers: [String], bridgeStatusLine: Bool) -> String {
        let trimmedHub = hubURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let provList = providers.joined(separator: ",")
        let extra = bridgeStatusLine ? "" : " --pure-readonly"
        let fetchInstall = "(curl --noproxy '*' -fsSL \"\(trimmedHub)/install.sh\" 2>/dev/null || curl -fsSL \"\(trimmedHub)/install.sh\")"
        return "env CODEXBAR_TOKEN='\(shellEscape(rawWriteToken))' sh -c '\(fetchInstall) | sh -s -- --hub \"\(trimmedHub)\" --node \"\(shellEscape(nodeID))\" --providers \"\(provList)\"\(extra)'"
    }

    static func localIPv4Addresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = pointer {
            let flags = Int32(current.pointee.ifa_flags)
            if (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
               let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let nulIndex = hostname.firstIndex(of: 0) ?? hostname.endIndex
                    let ip = String(bytes: hostname[..<nulIndex].map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
                    if !ip.hasPrefix("169.254."), !addresses.contains(ip) {
                        addresses.append(ip)
                    }
                }
            }
            pointer = current.pointee.ifa_next
        }
        return addresses.sorted { lhs, _ in lhs.hasPrefix("192.168.") || lhs.hasPrefix("100.") }
    }

    private static func shellEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "'\\''")
    }
}

actor HubSyncClient {
    private static let hubKeychainService = "io.github.yatotm.codexbar.hub-viewer"
    private static let nodeKeychainService = "io.github.yatotm.codexbar.probe-node"
    private let secretsDirectory: URL
    private var lanProcess: Process?
    private var activeLanPort: Int?

    init(directory: URL? = nil) {
        secretsDirectory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar-yatotm/UsageCenter", isDirectory: true)
    }

    private var vaultURL: URL {
        secretsDirectory.appendingPathComponent("hub-secrets.json")
    }

    private func vaultKey(account: String, isNodeToken: Bool) -> String {
        (isNodeToken ? "node:" : "hub:") + account
    }

    private func readVault() -> [String: String] {
        guard let data = try? Data(contentsOf: vaultURL),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func writeVault(_ dict: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: secretsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let data = try JSONEncoder().encode(dict)
        var dest = vaultURL
        try data.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dest.setResourceValues(values)
    }

    func saveSecret(_ value: String, account: String, isNodeToken: Bool) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed.utf8.count >= 24, trimmed.utf8.count <= 512,
              trimmed.utf8.allSatisfy({ (33 ... 126).contains($0) }) else {
            throw UsageCenterError(message: "密钥需要 24 到 512 个非空白 ASCII 字符")
        }
        var vault = readVault()
        vault[vaultKey(account: account, isNodeToken: isNodeToken)] = trimmed
        try writeVault(vault)
    }

    func loadSecret(account: String, isNodeToken: Bool) -> String? {
        if let stored = readVault()[vaultKey(account: account, isNodeToken: isNodeToken)], !stored.isEmpty {
            return stored
        }
        let service = isNodeToken ? Self.nodeKeychainService : Self.hubKeychainService
        var result: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8), !str.isEmpty else {
            return nil
        }
        return str
    }

    func deleteSecret(account: String, isNodeToken: Bool) {
        var vault = readVault()
        if vault.removeValue(forKey: vaultKey(account: account, isNodeToken: isNodeToken)) != nil {
            try? writeVault(vault)
        }
        let service = isNodeToken ? Self.nodeKeychainService : Self.hubKeychainService
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }

    func ensureLanReadToken() throws -> String {
        if let existing = loadSecret(account: "lan-hub", isNodeToken: false), !existing.isEmpty {
            return existing
        }
        let created = HubCrypto.randomToken(prefix: "cbr_")
        try saveSecret(created, account: "lan-hub", isNodeToken: false)
        return created
    }

    func startLanHubIfNeeded(port: Int) throws -> String {
        let token = try ensureLanReadToken()
        if let proc = lanProcess, proc.isRunning, activeLanPort == port {
            return token
        }
        stopLanHub()
        guard let scriptURL = Bundle.main.url(forResource: "CodexBarHub", withExtension: "py") else {
            throw UsageCenterError(message: "App 包内缺少内置中枢服务资源")
        }
        let pythonCandidates = (CodexCLIResolver.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/python3" }
            + ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw UsageCenterError(message: "局域网直连服务需要本机安装 Python 3.9+")
        }
        let stateDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexBar-yatotm/LanHub", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [
            "-B", scriptURL.path, "serve",
            "--state-dir", stateDir.path,
            "--listen", "0.0.0.0",
            "--port", String(port),
            "--read-token-hash", HubCrypto.hashReadToken(rawReadToken: token)
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        lanProcess = proc
        activeLanPort = port
        return token
    }

    func stopLanHub() {
        if let proc = lanProcess, proc.isRunning {
            _ = ProcessTermination.terminate(proc, gracefulTimeout: 0.3, killTimeout: 0.5)
        }
        lanProcess = nil
        activeLanPort = nil
    }

    func checkHealth(hubURL: String) async throws -> Bool {
        let url = try endpointURL(hubURL: hubURL, path: "/healthz", query: [], allowLoopbackHTTP: true)
        let data = try await sendRequest(url: url, method: "GET", bearer: nil, body: nil, timeout: 8)
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (obj?["protocol"] as? Int) == 2
    }

    func pull(hubURL: String, readToken: String, epoch: String, cursor: Int64, allowHTTP: Bool, geminiAccount: String? = nil) async throws -> HubPullResponse {
        var query = [
            URLQueryItem(name: "epoch", value: epoch),
            URLQueryItem(name: "cursor", value: String(cursor)),
            URLQueryItem(name: "limit", value: "1500")
        ]
        if let geminiAccount {
            query.append(URLQueryItem(name: "geminiAccount", value: geminiAccount))
        }
        let url = try endpointURL(hubURL: hubURL, path: "/v1/pull", query: query, allowLoopbackHTTP: allowHTTP)
        let data = try await sendRequest(url: url, method: "GET", bearer: readToken, body: nil, timeout: 25)
        guard let decoded = try? JSONDecoder().decode(HubPullResponse.self, from: data), decoded.isValid else {
            throw UsageCenterError(message: "中枢返回了不支持的协议或无效数据")
        }
        return decoded
    }

    func waitEvents(hubURL: String, readToken: String, revision: Int64, allowHTTP: Bool) async throws -> HubEventsResponse {
        let query = [
            URLQueryItem(name: "revision", value: String(revision)),
            URLQueryItem(name: "timeout", value: "25")
        ]
        let url = try endpointURL(hubURL: hubURL, path: "/v1/events", query: query, allowLoopbackHTTP: allowHTTP)
        let data = try await sendRequest(url: url, method: "GET", bearer: readToken, body: nil, timeout: 32)
        guard let decoded = try? JSONDecoder().decode(HubEventsResponse.self, from: data), decoded.protocol == 2 else {
            throw UsageCenterError(message: "中枢事件流格式无效")
        }
        return decoded
    }

    func upsertNode(
        hubURL: String,
        readToken: String,
        source: UsageSource,
        signingKey: String?,
        allowHTTP: Bool
    ) async throws {
        let url = try endpointURL(hubURL: hubURL, path: "/v1/nodes/upsert", query: [], allowLoopbackHTTP: allowHTTP)
        var payload: [String: Any] = [
            "id": source.id,
            "name": source.name,
            "enabled": source.isEnabled,
            "enabledProviders": source.enabledProviderNames,
            "bridgeStatusLine": source.bridgeStatusLine
        ]
        if let signingKey, !signingKey.isEmpty {
            payload["signingKey"] = signingKey
        }
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await sendRequest(url: url, method: "POST", bearer: readToken, body: body, timeout: 15)
    }

    func deleteNode(hubURL: String, readToken: String, nodeID: String, allowHTTP: Bool) async throws {
        let url = try endpointURL(hubURL: hubURL, path: "/v1/nodes/delete", query: [], allowLoopbackHTTP: allowHTTP)
        let body = try JSONSerialization.data(withJSONObject: ["id": nodeID])
        _ = try await sendRequest(url: url, method: "POST", bearer: readToken, body: body, timeout: 15)
    }

    private func endpointURL(hubURL: String, path: String, query: [URLQueryItem], allowLoopbackHTTP: Bool) throws -> URL {
        let trimmed = hubURL.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            throw UsageCenterError(message: "请填写有效的中枢地址")
        }
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        guard scheme == "https" || (allowLoopbackHTTP && scheme == "http" && isLoopback) else {
            throw UsageCenterError(message: "公网常驻中枢必须使用 HTTPS 地址")
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw UsageCenterError(message: "中枢地址格式无效")
        }
        return url
    }

    private func sendRequest(url: URL, method: String, bearer: String?, body: Data?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let bearer, !bearer.isEmpty {
            request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let host = url.host?.lowercased() ?? ""
        let isLoopback = host == "127.0.0.1" || host == "localhost"
        do {
            return try await performRequest(request: request, timeout: timeout, bypassProxy: true)
        } catch let error as URLError where !isLoopback {
            _ = error
            return try await performRequest(request: request, timeout: timeout, bypassProxy: false)
        }
    }

    private func performRequest(request: URLRequest, timeout: TimeInterval, bypassProxy: Bool) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 10
        if bypassProxy {
            config.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: config, delegate: HubNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageCenterError(message: "中枢连接无响应")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw UsageCenterError(message: "中枢管理密钥校验未通过 (401), 请核对控制中心密钥")
            }
            throw UsageCenterError(message: "中枢返回 HTTP \(http.statusCode)")
        }
        var result = Data()
        for try await byte in bytes {
            guard result.count < 8 * 1024 * 1024 else {
                throw UsageCenterError(message: "中枢响应超过大小限制")
            }
            result.append(byte)
        }
        return result
    }
}
