import Foundation
import os

/// 对共享 app-server JSON-RPC 的薄封装
/// 负责日志记录, 超时和 unsupported 方法缓存
final nonisolated class AppServerSession {
    var isOpen: Bool {
        socket.isOpen
    }

    private typealias EncodedMessage = (data: Data, text: String)
    private typealias ResponseLine = (text: String, data: Data)

    private static let writeFailureMessage = String(localized: "request-log.error.write-connection-closed")
    private static let responseConnectionClosedMessage = String(localized: "request-log.error.response-connection-closed")
    private static let responseTimeoutMessage = String(localized: "request-log.error.response-timeout")
    private let socket: CodexSharedSocket
    private let timeout: TimeInterval
    private let deadline: Date?
    let socketURL: URL
    private let logStorage: RequestLogStorage?
    private var nextId = 1
    private var unsupportedMethods: Set<String> = []

    init(socketURL: URL, timeout: TimeInterval = 20, deadline: Date? = nil, logStorage: RequestLogStorage? = nil) throws {
        guard timeout.isFinite, timeout > 0 else { throw CodexStatusError.serverTimeout }
        socket = try AppServerRequestBudget.$current.withValue(Self.connectionBudget(deadline: deadline)) {
            try CodexSharedSocket(url: socketURL)
        }
        self.socketURL = socketURL
        self.timeout = timeout
        self.deadline = deadline
        self.logStorage = logStorage
    }

    private init(socket: CodexSharedSocket, socketURL: URL, timeout: TimeInterval, deadline: Date?) {
        self.socket = socket
        self.socketURL = socketURL
        self.timeout = timeout
        self.deadline = deadline
        logStorage = deadline == nil ? .shared : nil
    }

    static func launch(
        command: AppServerCommand?,
        environment: [String: String],
        timeout: TimeInterval,
        deadline: Date? = nil,
        usesCustomProxy: Bool = false
    ) throws -> AppServerSession {
        guard !usesCustomProxy else {
            throw CodexStatusError.serverError("共享后台使用 Codex 自身的代理配置, 请在 Codex 中调整")
        }
        guard timeout.isFinite, timeout > 0 else { throw CodexStatusError.serverTimeout }
        let url = CodexSharedSocket.url(environment: environment)
        let socket = try AppServerRequestBudget.$current.withValue(connectionBudget(deadline: deadline)) {
            do {
                return try CodexSharedSocket(url: url)
            } catch let error as CodexSharedConnectionError where error.isAbsent {
                guard let command else { throw CodexStatusError.executableNotFound }
                try CodexSharedStartup.start(command: command, environment: environment)
                return try CodexSharedSocket(url: url)
            }
        }
        return AppServerSession(
            socket: socket,
            socketURL: url,
            timeout: timeout,
            deadline: deadline
        )
    }

    private static func connectionBudget(deadline: Date?) -> AppServerRequestBudget? {
        guard let deadline else { return AppServerRequestBudget.current }
        return AppServerRequestBudget.current?.constrained(to: deadline) ?? AppServerRequestBudget(deadline: deadline)
    }

    static func redactingProxyCredentials(_ text: String) -> String {
        func redact(_ value: Any) -> Any {
            switch value {
            case let string as String:
                string.replacingOccurrences(
                    of: #"(?i)(https?://)[^\s/"@]+@"#,
                    with: "$1<redacted>@",
                    options: .regularExpression
                )
            case let object as [String: Any]:
                Dictionary(uniqueKeysWithValues: object.map { key, value in
                    let normalized = key.lowercased().filter(\.isLetter)
                    let sensitive = ["accesstoken", "refreshtoken", "idtoken", "apikey", "authorization", "password", "cookie", "setcookie"].contains(normalized)
                    return (key, sensitive ? "<redacted>" : redact(value))
                })
            case let array as [Any]: array.map(redact)
            default: value
            }
        }

        // 先解码 JSON 转义, 避免 URL 中的斜杠或 Unicode 转义绕过脱敏
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed),
           let data = try? JSONSerialization.data(withJSONObject: redact(object), options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
           let result = String(data: data, encoding: .utf8) {
            return result
        }
        return redact(text) as? String ?? text
    }

    func initializeAccount() throws -> (version: String, account: AccountReadResponse) {
        let result = try request(
            "initialize",
            params: ["clientInfo": [
                "name": "codex_bar",
                "title": "Codex Bar",
                "version": Self.clientVersion()
            ]],
            as: InitializeResult.self
        )
        let version = Self.serverVersion(fromUserAgent: result.userAgent)
        let minimum = CodexCLIMinimumVersion.global
        // 只信任已连接后台的握手版本, 磁盘启动器可能刚刚升级
        guard let version, let isSupported = CodexCLIVersionReader.isVersion(version, atLeast: minimum) else {
            throw CodexStatusError.invalidServerResponse
        }
        guard isSupported else {
            let error = CodexStatusError.unsupportedVersion(minimum: minimum)
            if let logStorage {
                let details = LogFields.joined("current=\(version)", "minimum=\(minimum)")
                AppLog.codexCLI.notice("Codex 版本不支持: \(details, privacy: .public)")
                logStorage.recordFailure(message: error.localizedDescription)
            }
            throw error
        }
        try notify("initialized")
        let account = try request("account/read", params: ["refreshToken": false], as: AccountReadResponse.self)
        guard account.account != nil else { throw CodexStatusError.notLoggedIn }
        return (version, account)
    }

    private static func clientVersion() -> String {
        guard let version = Bundle.main.shortVersionString, !version.isEmpty else { return "1.0.0" }
        return version
    }

    /// userAgent 首个 token 中 "/" 之后的部分才是实际运行版本
    private static func serverVersion(fromUserAgent userAgent: String?) -> String? {
        guard let firstToken = userAgent?.split(separator: " ").first,
              let slashIndex = firstToken.firstIndex(of: "/") else { return nil }
        let version = firstToken[firstToken.index(after: slashIndex)...]
        return version.isEmpty ? nil : String(version)
    }

    func close() {
        socket.close()
    }

    func notify(_ method: String, params: [String: Any]? = nil) throws {
        let encoded = try encodeMessage(method: method, id: nil, params: params)
        do {
            try socket.send(encoded.data, deadline: requestDeadline(timeout: min(5, timeout)))
            logStorage?.recordRequestWithEmptyResponse(method: method, payload: Self.redactingProxyCredentials(encoded.text))
        } catch {
            socket.close()
            logStorage?.recordFailure(method: method, message: Self.writeFailureMessage)
            throw error
        }
    }

    func request<Response: Decodable>(
        _ method: String,
        params: [String: Any]? = nil,
        as type: Response.Type
    ) throws -> Response {
        try AppServerRequestBudget.checkCurrent()
        guard !unsupportedMethods.contains(method) else { throw CodexStatusError.unsupportedMethod }
        let ordinaryRead = ["account/rateLimits/read", "account/usage/read"].contains(method)
            || (method == "account/read" && params?["refreshToken"] as? Bool != true)
        let requestDeadline = requestDeadline(timeout: ordinaryRead ? min(timeout, 10) : timeout)
        do {
            return try performRequestRememberingUnsupported(method, params: params, as: type, before: requestDeadline)
        } catch let error as CodexStatusError where deadline == nil && error.isRetriableServerError {
            // 业务重试复用同一个截止时间, 不额外延长一次刷新
            return try performRequestRememberingUnsupported(method, params: params, as: type, before: requestDeadline)
        }
    }

    private func requestDeadline(timeout: TimeInterval) -> ContinuousClock.Instant {
        var value = ContinuousClock.now.advanced(by: .seconds(timeout))
        if let deadline {
            value = min(value, ContinuousClock.now.advanced(by: .seconds(max(0, deadline.timeIntervalSinceNow))))
        }
        return min(value, AppServerRequestBudget.current?.deadline ?? value)
    }

    private func performRequestRememberingUnsupported<Response: Decodable>(
        _ method: String,
        params: [String: Any]?,
        as type: Response.Type,
        before deadline: ContinuousClock.Instant
    ) throws -> Response {
        do {
            return try performRequest(method, params: params, as: type, before: deadline)
        } catch let error as CodexStatusError {
            if error.isUnsupportedMethod {
                unsupportedMethods.insert(method)
            }
            throw error
        }
    }

    private func performRequest<Response: Decodable>(
        _ method: String,
        params: [String: Any]?,
        as type: Response.Type,
        before deadline: ContinuousClock.Instant
    ) throws -> Response {
        try AppServerRequestBudget.checkCurrent()
        guard ContinuousClock.now < deadline else { throw CodexStatusError.serverTimeout }
        let id = nextId
        nextId += 1
        let encoded = try encodeMessage(method: method, id: id, params: params)
        let token = logStorage?.beginRequest(method: method, payload: Self.redactingProxyCredentials(encoded.text)) ?? UUID()
        do {
            try socket.send(encoded.data, deadline: deadline)
            let result: Response = try waitForResponse(id: id, token: token, decode: type, before: deadline)
            return result
        } catch {
            if error is CancellationError || (error as? CodexStatusError)?.isTransportFailure == true {
                // 请求未结束就失去流位置时, 只废弃本客户端连接
                socket.close()
                let message = error is CancellationError ? "请求已取消" : error.localizedDescription
                logStorage?.failRequest(token, message: Self.redactingProxyCredentials(message))
            }
            throw error
        }
    }

    private func encodeMessage(method: String, id: Int?, params: [String: Any]?) throws -> EncodedMessage {
        try encode(message(method: method, id: id, params: params))
    }

    private func message(method: String, id: Int?, params: [String: Any]?) -> [String: Any] {
        var object: [String: Any] = ["method": method]
        if let id {
            object["id"] = id
        }
        if let params {
            object["params"] = params
        }
        return object
    }

    private func encode(_ object: [String: Any]) throws -> EncodedMessage {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                object,
                .init(codingPath: [], debugDescription: "Encoded app-server JSON was not UTF-8")
            )
        }
        return (data, text)
    }

    private func waitForResponse<Response: Decodable>(
        id: Int, token: UUID, decode type: Response.Type, before deadline: ContinuousClock.Instant
    ) throws -> Response {
        let decoder = JSONDecoder()
        while ContinuousClock.now < deadline {
            try AppServerRequestBudget.checkCurrent()
            guard let data = try socket.receive(deadline: deadline) else { break }
            guard let text = String(data: data, encoding: .utf8),
                  let envelope = try? decoder.decode(RPCIDEnvelope.self, from: data) else {
                throw CodexStatusError.invalidServerResponse
            }
            guard envelope.id == id else { continue }
            let line = (text: text, data: data)
            let result = try decodeResponse(line, as: type, token: token, decoder: decoder)
            logStorage?.finishRequest(token, response: Self.redactingProxyCredentials(text))
            return result
        }
        try failRequest(token, message: Self.responseTimeoutMessage, error: .serverTimeout)
    }

    private func decodeResponse<Response: Decodable>(
        _ line: ResponseLine,
        as _: Response.Type,
        token: UUID,
        decoder: JSONDecoder
    ) throws -> Response {
        let envelope: RPCResponseEnvelope<Response>
        do {
            envelope = try decoder.decode(RPCResponseEnvelope<Response>.self, from: line.data)
        } catch is RPCResponsePayloadDecodingError {
            try failRequest(token, message: line.text, error: .invalidResponsePayload)
        } catch {
            try failRequest(token, message: line.text, error: .invalidServerResponse)
        }

        if let error = envelope.error {
            try failRequest(token, message: line.text, error: .serverError(Self.redactingProxyCredentials(error.message)))
        }
        if let result = envelope.result {
            return result
        }

        try failRequest(token, message: line.text, error: .invalidServerResponse)
    }

    private func failRequest(_ token: UUID, message: String, error: CodexStatusError) throws -> Never {
        logStorage?.failRequest(token, message: Self.redactingProxyCredentials(message))
        throw error
    }
}

private nonisolated struct InitializeResult: Decodable {
    let userAgent: String?
}

/// 先轻量读取 id, 避免把其他请求或日志行误当成本次响应
private nonisolated struct RPCIDEnvelope: Decodable {
    let id: Int?

    private enum CodingKeys: String, CodingKey { case id }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try? container.decode(Int.self, forKey: .id)
    }
}

/// error 与 result 合并在同一个信封里一次解码
/// result 形状不匹配时单独分类, 响应行已消费不会破坏会话边界
private nonisolated struct RPCResponseEnvelope<Response: Decodable>: Decodable {
    let error: RPCError?
    let result: Response?

    private enum CodingKeys: String, CodingKey {
        case error
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        error = try container.decodeIfPresent(RPCError.self, forKey: .error)
        guard error == nil else {
            result = nil
            return
        }

        do {
            result = try container.decodeIfPresent(Response.self, forKey: .result)
        } catch {
            throw RPCResponsePayloadDecodingError()
        }
    }
}

private nonisolated struct RPCResponsePayloadDecodingError: Error {}

private nonisolated struct RPCError: Decodable {
    let message: String
}
