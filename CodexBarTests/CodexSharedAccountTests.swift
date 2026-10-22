import Darwin
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodexSharedAccountTests {
    @Test func expiredSafetyCutoffRejectsBeforeConnecting() async throws {
        let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let service = try Self.makeService(domain: domain, socketURL: URL(fileURLWithPath: "/tmp/unused-\(UUID().uuidString).sock"))
        do {
            _ = try await service.consumeResetCredit(
                id: "credit", idempotencyKey: "key", expectedAccountIdentity: "chatgpt\u{0}test@example.com",
                expirationDate: Date().addingTimeInterval(30),
                budget: AppServerRequestBudget(deadline: Date().addingTimeInterval(60))
            )
            Issue.record("已进入安全截止区间的凭证不能发起消费")
        } catch let error as CodexStatusError {
            guard case .serverTimeout = error else { Issue.record("必须在连接前按预算截止")
                return
            }
        }
    }

    @Test func changedAccountCannotConsumeCreditFromPreviousAccount() async throws {
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            let account = try peer.readMessage()
            #expect(account["method"] as? String == "account/read")
            try peer.reply(to: account, result: Self.accountPayload("other@example.com"))
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let socketURL = server.url
        try await Task.detached {
            let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
            defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
            let service = try Self.makeService(domain: domain, socketURL: socketURL)
            do {
                _ = try await service.consumeResetCredit(
                    id: "credit", idempotencyKey: "key", expectedAccountIdentity: "chatgpt\u{0}test@example.com",
                    expirationDate: Date().addingTimeInterval(900),
                    budget: AppServerRequestBudget(deadline: Date().addingTimeInterval(5))
                )
                Issue.record("更换账号后不能消费旧账号凭证")
            } catch AutoResetServiceError.accountChanged {}
        }.value
        try server.finish()
    }

    @Test func successfulConsumptionUsesFreshAccountAndKeepsIdempotencyKey() async throws {
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            let account = try peer.readMessage()
            try peer.reply(to: account, result: Self.accountPayload())
            let consume = try peer.readMessage()
            #expect(consume["method"] as? String == "account/rateLimitResetCredit/consume")
            let parameters = try #require(consume["params"] as? [String: String])
            #expect(parameters == ["creditId": "credit", "idempotencyKey": "stable-key"])
            try peer.reply(to: consume, result: ["outcome": "reset"])
            let refreshedAccount = try peer.readMessage()
            try peer.reply(to: refreshedAccount, result: Self.accountPayload())
            let limits = try peer.readMessage()
            #expect(limits["method"] as? String == "account/rateLimits/read")
            try peer.reply(to: limits, result: ["rateLimits": [:], "rateLimitResetCredits": ["availableCount": 0, "credits": []]])
        }
        defer { server.close() }
        let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let service = try Self.makeService(domain: domain, socketURL: server.url)
        let result = try await service.consumeResetCredit(
            id: "credit", idempotencyKey: "stable-key", expectedAccountIdentity: "chatgpt\u{0}test@example.com",
            expirationDate: Date().addingTimeInterval(900),
            budget: AppServerRequestBudget(deadline: Date().addingTimeInterval(5))
        )
        #expect(result.outcome == .reset)
        #expect(result.refreshedRead?.availableCount == 0)
        let info = await service.currentConnectionInfo()
        #expect(info?.version == "0.163.0")
        #expect(info?.socketPath == server.url.path)
        #expect(info?.executablePath.isEmpty == true)
        try server.finish()
    }

    private nonisolated static func makeService(domain: String, socketURL: URL) throws -> CodexStatusService {
        try CodexStatusService(defaults: #require(UserDefaults(suiteName: domain)), socketURL: socketURL)
    }

    private nonisolated static func initialize(_ peer: SharedServerFixture.Peer) throws {
        let initialize = try peer.readMessage()
        #expect(initialize["method"] as? String == "initialize")
        try peer.reply(to: initialize, result: ["userAgent": "codex/0.163.0"])
        let initialized = try peer.readMessage()
        #expect(initialized["method"] as? String == "initialized")
        let account = try peer.readMessage()
        #expect(account["method"] as? String == "account/read")
        try peer.reply(to: account, result: Self.accountPayload())
    }

    private nonisolated static func accountPayload(_ email: String = "test@example.com") -> [String: Any] {
        ["account": ["type": "chatgpt", "email": email, "planType": "pro"]]
    }
}
