import Darwin
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct CodexSharedSocketTests {
    @Test nonisolated func fragmentedTextAllowsInterleavedPingAndMasksPong() throws {
        let server = try SharedServerFixture { peer in
            #expect(try peer.readMessage()["method"] as? String == "probe")
            try peer.sendRaw(Data([0xE4]), final: false)
            try peer.sendRaw(Data("ping".utf8), opcode: 9)
            #expect(try peer.readPayload(opcode: 10) == Data("ping".utf8))
            try peer.sendRaw(Data([0xB8, 0xAD]), opcode: 0)
        }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url)
        defer { socket.close() }
        try socket.send(Data(#"{"method":"probe"}"#.utf8), deadline: .now.advanced(by: .seconds(2)))
        #expect(try socket.receive(deadline: .now.advanced(by: .seconds(2))) == Data("中".utf8))
        try server.finish()
    }

    @Test(arguments: [125, 126, 65535, 65536])
    nonisolated func clientMessagesRemainMaskedAcrossLengthEncodings(_ size: Int) throws {
        let payload = Data(repeating: 120, count: size)
        let server = try SharedServerFixture { peer in
            let received = try peer.readPayload(opcode: 1)
            #expect(received == payload)
        }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url)
        defer { socket.close() }
        try socket.send(payload, deadline: .now.advanced(by: .seconds(2)))
        try server.finish()
    }

    @Test nonisolated func closingOneClientDoesNotStopSharedListener() throws {
        let server = try SharedServerFixture(connections: 2) { peer in
            let request = try peer.readMessage()
            try peer.reply(to: request, result: ["value": "ok"])
        }
        defer { server.close() }
        for _ in 0 ..< 2 {
            let socket = try CodexSharedSocket(url: server.url)
            try socket.send(Data(#"{"id":1,"method":"probe"}"#.utf8), deadline: .now.advanced(by: .seconds(2)))
            #expect(try socket.receive(deadline: .now.advanced(by: .seconds(2))) != nil)
            socket.close()
            #expect(!socket.isOpen)
        }
        try server.finish()
    }

    @Test(arguments: [Data([0xC1, 0]), Data([0x81, 0x80]), Data([0x81, 126, 0, 1]), Data([0x89, 126, 0, 126]), Data([0x82, 0]), Data([0x80, 0])])
    nonisolated func malformedFramesCloseOnlyClient(_ bytes: Data) throws {
        let server = try SharedServerFixture { peer in try peer.sendBytes(bytes) }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url)
        #expect(throws: CodexStatusError.self) { _ = try socket.receive(deadline: .now.advanced(by: .seconds(1))) }
        #expect(!socket.isOpen)
        try server.finish()
    }

    @Test nonisolated func fragmentedPayloadIsBoundedAcrossFrames() throws {
        let server = try SharedServerFixture { peer in
            try peer.sendRaw(Data(repeating: 120, count: 20), final: false)
            try peer.sendHeader(length: 20, opcode: 0)
        }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url, maximumMessageBytes: 32)
        #expect(throws: CodexStatusError.self) { _ = try socket.receive(deadline: .now.advanced(by: .seconds(1))) }
        #expect(!socket.isOpen)
        try server.finish()
    }

    @Test nonisolated func partialFrameTimesOutAndClosesConnection() throws {
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let server = try SharedServerFixture { peer in
            try peer.sendBytes(Data([0x81, 100, 123]))
            #expect(release.wait(timeout: .now() + 3) == .success)
        }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url)
        let started = ContinuousClock.now
        #expect(throws: CodexStatusError.self) { _ = try socket.receive(deadline: .now.advanced(by: .milliseconds(80))) }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(!socket.isOpen)
        release.signal()
        try server.finish()
    }

    @Test nonisolated func expiredBudgetNeverWritesAnotherFrame() throws {
        let server = try SharedServerFixture { peer in
            var byte: UInt8 = 0
            #expect(Darwin.read(peer.descriptor, &byte, 1) == 0)
        }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url)
        let budget = AppServerRequestBudget(deadline: Date().addingTimeInterval(-1))
        AppServerRequestBudget.$current.withValue(budget) {
            #expect(throws: CodexStatusError.self) { try socket.send(Data("test".utf8), deadline: .now.advanced(by: .seconds(2))) }
        }
        #expect(!socket.isOpen)
        try server.finish()
    }

    @Test(arguments: [false, true])
    nonisolated func invalidHandshakeIsRejected(missingConnection: Bool) throws {
        let server = try SharedServerFixture(performsHandshake: false) { peer in
            try peer.handshake(validAccept: missingConnection, connection: missingConnection ? nil : "Upgrade")
        }
        defer { server.close() }
        #expect(throws: CodexStatusError.self) { _ = try CodexSharedSocket(url: server.url) }
        try server.finish()
    }

    @Test nonisolated func invalidTextEncodingIsRejected() throws {
        let server = try SharedServerFixture { peer in try peer.sendRaw(Data([255])) }
        defer { server.close() }
        let socket = try CodexSharedSocket(url: server.url)
        #expect(throws: CodexStatusError.self) { _ = try socket.receive(deadline: .now.advanced(by: .seconds(1))) }
        #expect(!socket.isOpen)
        try server.finish()
    }
}
