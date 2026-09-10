import CryptoKit
import Foundation

private final class AnalyticsRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

actor UsageAnalyticsClient {
    private let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexBar-yatotm/UsageAnalytics", isDirectory: true)

    private func credentials() throws -> AnalyticsCredentials {
        let home = CodexCLIResolver.environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let path = URL(fileURLWithPath: (home as NSString).expandingTildeInPath).appendingPathComponent("auth.json")
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65537) ?? Data()
        guard data.count <= 65536, let value = try? JSONDecoder().decode(AnalyticsCredentials.self, from: data),
              value.authMode == "chatgpt", !value.tokens.accessToken.isEmpty, !value.tokens.accountID.isEmpty else {
            throw UsageCenterError(message: "价值统计需要本机 Codex 的 ChatGPT OAuth 登录")
        }
        return value
    }

    func accountKey() throws -> String {
        try UsageAnalyticsIdentity.hash("codex-account", credentials().tokens.accountID)
    }

    func restore() throws -> UsageAnalyticsSnapshot? {
        let key = try UsageAnalyticsIdentity.hash("codex-account", credentials().tokens.accountID)
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key + ".json")),
              let value = try? JSONDecoder().decode(UsageAnalyticsSnapshot.self, from: data), value.schema == 1,
              value.accountKey == key else { return nil }
        return value
    }

    func save(_ supplied: UsageAnalyticsSnapshot) throws {
        var snapshot = supplied
        let file = directory.appendingPathComponent(snapshot.accountKey + ".json")
        if let data = try? Data(contentsOf: file), let old = try? JSONDecoder().decode(UsageAnalyticsSnapshot.self, from: data),
           old.schema == 1, old.accountKey == snapshot.accountKey {
            let windows = UsageAnalyticsValuation.merge(old.windows + snapshot.windows)
            if old.fetchedAt > snapshot.fetchedAt {
                snapshot = old
            }
            snapshot.windows = windows
            snapshot.importedHistory = snapshot.importedHistory || old.importedHistory
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = directory.appendingPathComponent(snapshot.accountKey + ".json")
        try JSONEncoder().encode(snapshot).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    func prices() throws -> UsagePriceBook {
        guard let path = Bundle.main.url(forResource: "UsagePrices", withExtension: "json") else {
            throw UsageCenterError(message: "缺少官方价格快照")
        }
        return try JSONDecoder().decode(UsagePriceBook.self, from: Data(contentsOf: path))
    }

    func fetch() async throws -> UsageAnalyticsSnapshot {
        let auth = try credentials()
        let formatter = ISO8601DateFormatter()
        let today = Date()
        let start = String(formatter.string(from: today.addingTimeInterval(-70 * 86400)).prefix(10))
        let end = String(formatter.string(from: today.addingTimeInterval(86400)).prefix(10))
        let query = [
            URLQueryItem(name: "start_date", value: start),
            URLQueryItem(name: "end_date", value: end),
            URLQueryItem(name: "group_by", value: "day"),
            URLQueryItem(name: "timezone_offset_min", value: "0")
        ]
        async let usage = get("/backend-api/wham/usage", query: [], auth: auth)
        async let weights = get("/backend-api/wham/usage/daily-token-usage-breakdown", query: query, auth: auth)
        async let totals = get(
            "/backend-api/wham/analytics/daily-workspace-usage-counts",
            query: query + [URLQueryItem(name: "workspace_user", value: "true")],
            auth: auth
        )
        let result = try await UsageAnalyticsParser.parse(
            usage: usage,
            breakdown: weights,
            counts: totals,
            accountID: auth.tokens.accountID,
            start: start,
            end: end
        )
        guard try credentials().tokens.accountID == auth.tokens.accountID else {
            throw UsageCenterError(message: "登录账号在查询中发生变化, 请重新刷新")
        }
        return result
    }

    private func get(_ path: String, query: [URLQueryItem], auth: AnalyticsCredentials, retried: Bool = false) async throws -> Data {
        var url = URLComponents(string: "https://chatgpt.com")!
        url.path = path
        if !query.isEmpty {
            url.queryItems = query
        }
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + auth.tokens.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(auth.tokens.accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: AnalyticsRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageCenterError(message: "官方统计响应无效") }
        if http.statusCode == 401, !retried {
            let refreshed = try credentials()
            guard refreshed.tokens.accountID == auth.tokens.accountID else { throw UsageCenterError(message: "登录账号已变化") }
            return try await get(path, query: query, auth: refreshed, retried: true)
        }
        guard http.statusCode == 200 else {
            throw UsageCenterError(message: "官方统计接口返回 HTTP \(http.statusCode), 已保留缓存")
        }
        var data = Data()
        for try await byte in stream {
            guard data.count < 8 * 1024 * 1024 else { throw UsageCenterError(message: "官方统计响应超过大小上限") }
            data.append(byte)
        }
        return data
    }
}

private nonisolated struct AnalyticsCredentials: Decodable {
    let authMode: String
    let tokens: AnalyticsCredentialTokens
    enum CodingKeys: String, CodingKey { case tokens
        case authMode = "auth_mode"
    }
}

private nonisolated struct AnalyticsCredentialTokens: Decodable {
    let accessToken: String
    let accountID: String
    enum CodingKeys: String, CodingKey { case accessToken = "access_token"
        case accountID = "account_id"
    }
}
