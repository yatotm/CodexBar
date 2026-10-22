import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodexSharedStartupTests {
    @Test nonisolated func malformedExistingEndpointNeverLaunchesAnotherDaemon() throws {
        let home = try FixtureHome()
        defer { home.remove() }
        let command = try home.command("printf started > \"$STARTED_FILE\"")
        let server = try SharedServerFixture(url: home.socketURL, performsHandshake: false) { peer in
            try peer.handshake(validAccept: false)
        }
        defer { server.close() }
        #expect(throws: CodexStatusError.self) {
            _ = try AppServerSession.launch(command: command, environment: home.environment, timeout: 1)
        }
        #expect(!FileManager.default.fileExists(atPath: home.marker.path))
        try server.finish()
    }

    @Test nonisolated func failedLauncherDoesNotExposeOutput() throws {
        let home = try FixtureHome()
        defer { home.remove() }
        let command = try home.command("printf secret-stdout; printf secret-stderr >&2; exit 7")
        do {
            try CodexSharedStartup.start(command: command, environment: home.environment)
            Issue.record("启动器失败必须报告失败")
        } catch {
            #expect(!error.localizedDescription.contains("secret-stdout"))
            #expect(!error.localizedDescription.contains("secret-stderr"))
        }
    }

    @Test nonisolated func startupUsesFixedArgumentsAndOnlyProbesReadiness() throws {
        let home = try FixtureHome()
        defer { home.remove() }
        let command = try home.command("printf '%s' \"$*\" > \"$STARTED_FILE\"")
        let server = try SharedServerFixture(url: home.socketURL) { peer in
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        try CodexSharedStartup.start(command: command, environment: home.environment)
        #expect(try String(contentsOf: home.marker, encoding: .utf8) == "app-server daemon start")
        try server.finish()
    }

    @Test func cancelledRequestCannotLaunchDaemon() async throws {
        let home = try FixtureHome()
        defer { home.remove() }
        let command = try home.command("printf started > \"$STARTED_FILE\"")
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try AppServerSession.launch(command: command, environment: home.environment, timeout: 1)
                return false
            } catch is CancellationError { return true }
        }
        #expect(try await task.value)
        #expect(!FileManager.default.fileExists(atPath: home.marker.path))
    }
}

private nonisolated struct FixtureHome: Sendable {
    let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)")
    var socketURL: URL {
        CodexSharedSocket.url(environment: environment)
    }

    var marker: URL {
        url.appendingPathComponent("started")
    }

    var environment: [String: String] {
        ["CODEX_HOME": url.path, "STARTED_FILE": marker.path]
    }

    init() throws {
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func command(_ body: String) throws -> AppServerCommand {
        let executable = url.appendingPathComponent("fake-codex")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return AppServerCommand(source: .global, executablePath: executable.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
