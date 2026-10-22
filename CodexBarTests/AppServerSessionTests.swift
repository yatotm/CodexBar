import Darwin
import Foundation
import Synchronization
import Testing

@Suite(.timeLimit(.minutes(1)))
struct AppServerSessionTests {
    @Test nonisolated func ignoresNotificationsAndOtherRequestIDs() throws {
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            try peer.send(["method": "account/updated", "params": ["authentication": "chatgpt"]])
            try peer.send(["id": 999, "result": ["value": "other"]])
            try peer.send(["id": "other-client", "result": ["value": "other"]])
            try peer.reply(to: request, result: ["value": "matched"])
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url)
        defer { session.close() }
        let result = try session.request("probe", as: [String: String].self)
        #expect(result == ["value": "matched"])
        try server.finish()
    }

    @Test nonisolated func unsupportedMethodIsCachedWithoutSendingAgain() throws {
        let server = try SharedServerFixture { peer in
            let request = try peer.readMessage()
            try peer.send(["id": #require(request["id"]), "error": ["message": "Invalid request: unknown variant"]])
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url)
        for _ in 0 ..< 2 {
            #expect(throws: CodexStatusError.self) { let _: [String: String] = try session.request("unsupported", as: [String: String].self) }
        }
        session.close()
        try server.finish()
    }

    @Test nonisolated func malformedResultDoesNotDiscardFollowingMessageBoundary() throws {
        let server = try SharedServerFixture { peer in
            let first = try peer.readMessage()
            try peer.reply(to: first, result: ["value": 1])
            let second = try peer.readMessage()
            try peer.reply(to: second, result: ["value": "ok"])
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url)
        defer { session.close() }
        #expect(throws: CodexStatusError.self) { let _: [String: String] = try session.request("probe", as: [String: String].self) }
        #expect(session.isOpen)
        let result = try session.request("probe", as: [String: String].self)
        #expect(result == ["value": "ok"])
        try server.finish()
    }

    @Test nonisolated func businessRetryCannotResetRequestDeadline() throws {
        let server = try SharedServerFixture { peer in
            let first = try peer.readMessage()
            Thread.sleep(forTimeInterval: 0.08)
            try peer.send(["id": #require(first["id"]), "error": ["message": "temporarily unavailable"]])
            _ = try peer.readMessage()
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let session = try AppServerSession(socketURL: server.url, timeout: 0.15)
        let started = ContinuousClock.now
        #expect(throws: CodexStatusError.self) { let _: [String: String] = try session.request("probe", as: [String: String].self) }
        #expect(started.duration(to: .now) < .milliseconds(220))
        #expect(!session.isOpen)
        try server.finish()
    }

    @Test func cancellingBlockedReadClosesOnlyClientAndAllowsNextConnection() async throws {
        let entered = Mutex(0)
        let server = try SharedServerFixture(connections: 2) { peer in
            _ = try peer.readMessage()
            entered.withLock { $0 += 1 }
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let socketURL = server.url
        for index in 0 ..< 2 {
            let task = Task.detached {
                let session = try AppServerSession(socketURL: socketURL, timeout: 10)
                defer { session.close() }
                do {
                    let _: [String: String] = try session.request("probe", as: [String: String].self)
                    return false
                } catch is CancellationError {
                    return !session.isOpen
                }
            }
            let waitingDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while entered.withLock({ $0 }) <= index, ContinuousClock.now < waitingDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(entered.withLock { $0 } > index)
            let started = ContinuousClock.now
            task.cancel()
            #expect(try await task.value)
            #expect(started.duration(to: .now) < .seconds(1))
        }
        try server.finish()
    }

    @Test nonisolated func localSecretsAreRedactedFromNestedJSONAndEscapedProxyURLs() throws {
        let raw = #"{"access_token":"secret-a","tokens":{"refreshToken":"secret-b"},"api_key":"secret-c","proxy":"https:\/\/name:secret-d@example.test","outputTokens":23}"#
        let text = AppServerSession.redactingProxyCredentials(raw)
        for value in ["secret-a", "secret-b", "secret-c", "secret-d"] {
            #expect(!text.contains(value))
        }
        let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(object["outputTokens"] as? Int == 23)
    }

    @Test nonisolated func existingSharedDaemonNeedsNoLauncher() throws {
        let home = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let socketURL = CodexSharedSocket.url(environment: ["CODEX_HOME": home.path])
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = try SharedServerFixture(url: socketURL) { peer in
            let request = try peer.readMessage()
            try peer.reply(to: request, result: ["value": "ok"])
        }
        defer { server.close() }
        let session = try AppServerSession.launch(command: nil, environment: ["CODEX_HOME": home.path], timeout: 2)
        defer { session.close() }
        let result = try session.request("probe", as: [String: String].self)
        #expect(result == ["value": "ok"])
        try server.finish()
    }
}
