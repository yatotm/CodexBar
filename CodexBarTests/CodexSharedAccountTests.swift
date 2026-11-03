import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodexSharedAccountTests {
    @Test(arguments: ["account/rateLimits/read", "account/usage/read"])
    func supplementalTimeoutKeepsSuccessfulDataAndRecoversNextRefresh(method: String) async throws {
        let connections = Mutex(0)
        let server = try SharedServerFixture(connections: 2) { peer in
            let index = connections.withLock { $0 += 1
                return $0
            }
            try Self.initialize(peer)
            try Self.replyQuota(peer, used: index == 1 ? 10 : 30)
            try Self.replyUsage(peer, tokens: index == 1 ? 100 : 300)
            guard index == 1 else { return }
            try peer.reply(to: Self.read(peer, method: "account/read"), result: Self.accountPayload())
            if method == "account/usage/read" {
                try Self.replyQuota(peer, used: 20)
            }
            _ = try Self.read(peer, method: method)
            // 等客户端预算到期关闭连接, 不通过服务端主动断开模拟超时
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let service = try Self.makeService(domain: domain, socketURL: server.url)
        let initial = try await Self.snapshot(service.fetchOutcome())
        #expect(initial.hasTrustedData)
        let degraded = await AppServerRequestBudget.$current.withValue(AppServerRequestBudget(deadline: Date().addingTimeInterval(0.5))) {
            await service.fetchOutcome()
        }
        let cached = try Self.snapshot(degraded)
        let quotaFailed = method == "account/rateLimits/read"
        #expect(cached.account == initial.account)
        #expect(cached.codexLimit?.window(ofKind: .primary)?.usedPercent == (quotaFailed ? 10 : 20))
        #expect(cached.isRateLimitsStale == quotaFailed)
        #expect(cached.isUsageStale)
        #expect(cached.usage == initial.usage)
        #expect(degraded.trace.rateLimits == (quotaFailed ? .cached : .ok))
        #expect(degraded.trace.usage == .cached)
        #expect(await service.currentConnectionInfo() == nil)
        let recovered = try await Self.snapshot(service.fetchOutcome())
        #expect(!recovered.isRateLimitsStale && !recovered.isUsageStale)
        #expect(recovered.codexLimit?.window(ofKind: .primary)?.usedPercent == 30)
        #expect(recovered.usage != initial.usage)
        #expect(connections.withLock { $0 } == 2)
        try server.finish()
    }

    @Test func supplementalFailureWithoutCacheKeepsKnownAccountAndMissingData() async throws {
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            _ = try Self.read(peer, method: "account/rateLimits/read")
        }
        defer { server.close() }
        let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let service = try Self.makeService(domain: domain, socketURL: server.url)
        let result = await service.fetchOutcome()
        let snapshot = try Self.snapshot(result)
        #expect(snapshot.account.email == "test@example.com")
        #expect(snapshot.limits.isEmpty && snapshot.usage == nil)
        #expect(!snapshot.hasTrustedData)
        #expect(result.trace.rateLimits == .failed && result.trace.usage == .failed)
        try server.finish()
    }

    @Test func changedAccountCannotReuseSupplementalCacheAfterTransportFailure() async throws {
        let server = try SharedServerFixture { peer in
            try Self.initialize(peer)
            try Self.replyQuota(peer, used: 10)
            try Self.replyUsage(peer, tokens: 100)
            try peer.reply(to: Self.read(peer, method: "account/read"), result: Self.accountPayload("other@example.com"))
            _ = try Self.read(peer, method: "account/rateLimits/read")
        }
        defer { server.close() }
        let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let service = try Self.makeService(domain: domain, socketURL: server.url)
        #expect(try await Self.snapshot(service.fetchOutcome()).hasTrustedData)
        let snapshot = try await Self.snapshot(service.fetchOutcome())
        #expect(snapshot.account.email == "other@example.com")
        #expect(snapshot.limits.isEmpty && snapshot.usage == nil)
        #expect(snapshot.autoResetCandidates == nil && !snapshot.hasTrustedData)
        try server.finish()
    }

    @Test func authenticationFailureStillClearsSupplementalCache() async throws {
        let connections = Mutex(0)
        let server = try SharedServerFixture(connections: 2) { peer in
            let index = connections.withLock { $0 += 1
                return $0
            }
            try Self.initialize(peer)
            if index == 2 {
                _ = try Self.read(peer, method: "account/rateLimits/read")
                return
            }
            try Self.replyQuota(peer, used: 10)
            try Self.replyUsage(peer, tokens: 100)
            try peer.reply(to: Self.read(peer, method: "account/read"), result: Self.accountPayload())
            let quota = try Self.read(peer, method: "account/rateLimits/read")
            try peer.send(["id": #require(quota["id"]), "error": ["message": "codex account authentication required"]])
            let refreshed = try Self.read(peer, method: "account/read")
            #expect((refreshed["params"] as? [String: Bool])?["refreshToken"] == true)
            try peer.reply(to: refreshed, result: ["account": NSNull()])
        }
        defer { server.close() }
        let domain = "io.github.yatotm.codexbar.shared-test.\(UUID().uuidString)"
        defer { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
        let service = try Self.makeService(domain: domain, socketURL: server.url)
        #expect(try await Self.snapshot(service.fetchOutcome()).hasTrustedData)
        let result = await service.fetchOutcome()
        guard case .notLoggedIn = result.outcome else {
            Issue.record("明确认证失效不能被补充接口降级掩盖")
            return
        }
        let next = try await Self.snapshot(service.fetchOutcome())
        #expect(next.limits.isEmpty && next.usage == nil && !next.hasTrustedData)
        try server.finish()
    }

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

    private nonisolated static func read(_ peer: SharedServerFixture.Peer, method: String) throws -> [String: Any] {
        let request = try peer.readMessage()
        #expect(request["method"] as? String == method)
        return request
    }

    private nonisolated static func replyQuota(_ peer: SharedServerFixture.Peer, used: Int) throws {
        try peer.reply(to: read(peer, method: "account/rateLimits/read"), result: [
            "rateLimits": ["primary": ["usedPercent": used, "windowDurationMins": 300]]
        ])
    }

    private nonisolated static func replyUsage(_ peer: SharedServerFixture.Peer, tokens: Int) throws {
        try peer.reply(to: read(peer, method: "account/usage/read"), result: ["summary": ["lifetimeTokens": tokens]])
    }

    private nonisolated static func snapshot(_ result: CodexFetchResult) throws -> CodexQuotaSnapshot {
        try #require({
            if case let .data(snapshot) = result.outcome {
                snapshot
            } else {
                nil
            }
        }())
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
