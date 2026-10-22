import CryptoKit
import Darwin
import Foundation

nonisolated struct CodexSharedConnectionError: Error {
    let code: Int32
    var isAbsent: Bool {
        code == ENOENT || code == ECONNREFUSED
    }
}

/// 仅拥有客户端连接, 关闭或超时不会终止其他 Codex 客户端共用的后台
final nonisolated class CodexSharedSocket {
    private var descriptor: Int32 = -1
    private let maximumMessageBytes: Int
    var isOpen: Bool {
        descriptor >= 0
    }

    static func url(environment: [String: String]) -> URL {
        let home = environment["CODEX_HOME"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("app-server-control/app-server-control.sock")
    }

    init(url: URL, maximumMessageBytes: Int = 8 * 1024 * 1024) throws {
        guard maximumMessageBytes > 0 else { throw CodexStatusError.invalidServerResponse }
        self.maximumMessageBytes = maximumMessageBytes
        do {
            try AppServerRequestBudget.checkCurrent()
            descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw CodexSharedConnectionError(code: errno) }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
                  fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw CodexSharedConnectionError(code: errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let path = Array(url.path.utf8CString)
            guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw CodexStatusError.serverConnectionClosed }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                path.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                let code = errno
                guard code == EINPROGRESS else { throw CodexSharedConnectionError(code: code) }
                guard try ready(Int16(POLLOUT), deadline: .now.advanced(by: .seconds(2))) else { throw CodexStatusError.serverTimeout }
                var error: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &size) == 0 else { throw CodexSharedConnectionError(code: errno) }
                guard error == 0 else { throw CodexSharedConnectionError(code: error) }
            }
            var enabled: Int32 = 1
            guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw CodexSharedConnectionError(code: errno)
            }
            var peerUser: uid_t = 0
            var peerGroup: gid_t = 0
            guard getpeereid(descriptor, &peerUser, &peerGroup) == 0, peerUser == geteuid() else {
                throw CodexSharedConnectionError(code: EACCES)
            }
            try handshake()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func send(_ payload: Data, deadline: ContinuousClock.Instant) throws {
        do {
            try sendFrame(payload, opcode: 1, deadline: deadline)
        } catch {
            close()
            throw error
        }
    }

    func receive(deadline: ContinuousClock.Instant) throws -> Data? {
        do {
            guard try ready(Int16(POLLIN), deadline: deadline) else { return nil }
            var message = Data()
            var fragmented = false
            while true {
                let header = try [UInt8](read(2, deadline: deadline))
                let opcode = header[0] & 15
                let encodedLength = header[1] & 127
                var length = UInt64(encodedLength)
                if encodedLength == 126 || encodedLength == 127 {
                    length = try read(encodedLength == 126 ? 2 : 8, deadline: deadline).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                    guard encodedLength == 126 ? length >= 126 : length > UInt16.max else {
                        throw CodexStatusError.invalidServerResponse
                    }
                }
                guard header[1] & 128 == 0, header[0] & 0x70 == 0, length <= UInt64(Int64.max),
                      opcode >= 8 ? ([8, 9, 10].contains(opcode) && header[0] & 128 != 0 && length <= 125)
                      : opcode == (fragmented ? 0 : 1) else { throw CodexStatusError.invalidServerResponse }
                guard opcode >= 8 || UInt64(message.count) + length <= maximumMessageBytes else { throw CodexStatusError.invalidServerResponse }
                let payload = try read(Int(length), deadline: deadline)
                if opcode == 8 {
                    throw CodexStatusError.serverConnectionClosed
                }
                if opcode == 9 {
                    try sendFrame(payload, opcode: 10, deadline: deadline)
                }
                if opcode == 9 || opcode == 10 {
                    if !fragmented, try !ready(Int16(POLLIN), deadline: deadline) {
                        return nil
                    }
                    continue
                }
                message.append(payload)
                if header[0] & 128 != 0 {
                    guard String(data: message, encoding: .utf8) != nil else { throw CodexStatusError.invalidServerResponse }
                    return message
                }
                fragmented = true
            }
        } catch {
            // 半帧失败后不能复用流位置, 只关闭自己的 socket
            close()
            throw error
        }
    }

    private func handshake() throws {
        let key = Data((0 ..< 16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let request = "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        try write(Data(request.utf8), deadline: deadline)
        var header = Data()
        while !header.suffix(4).elementsEqual([13, 10, 13, 10]), header.count < 16384 {
            try header.append(read(1, deadline: deadline))
        }
        guard header.suffix(4).elementsEqual([13, 10, 13, 10]),
              let text = String(data: header, encoding: .utf8), text.hasPrefix("HTTP/1.1 101 ") else {
            throw CodexStatusError.invalidServerResponse
        }
        let headers = text.components(separatedBy: "\r\n").dropFirst().compactMap { line -> (String, String)? in
            guard let separator = line.firstIndex(of: ":") else { return nil }
            return (line[..<separator].lowercased(), line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))
        }
        let expected = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        guard headers.filter({ $0.0 == "sec-websocket-accept" }).map(\.1) == [expected],
              headers.contains(where: { $0.0 == "upgrade" && $0.1.lowercased() == "websocket" }),
              headers.contains(where: { $0.0 == "connection" && $0.1.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" } }) else {
            throw CodexStatusError.invalidServerResponse
        }
    }

    private func sendFrame(_ payload: Data, opcode: UInt8, deadline: ContinuousClock.Instant) throws {
        try AppServerRequestBudget.checkCurrent()
        guard payload.count <= (opcode >= 8 ? 125 : maximumMessageBytes) else { throw CodexStatusError.invalidServerResponse }
        let mask = (0 ..< 4).map { _ in UInt8.random(in: .min ... .max) }
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(0xFE)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 255)])
        } else {
            frame.append(0xFF)
            frame.append(contentsOf: (0 ..< 8).reversed().map { UInt8((UInt64(payload.count) >> ($0 * 8)) & 255) })
        }
        frame.append(contentsOf: mask)
        frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        try write(frame, deadline: deadline)
    }

    private func ready(_ events: Int16, deadline: ContinuousClock.Instant) throws -> Bool {
        let deadline = min(deadline, AppServerRequestBudget.current?.deadline ?? deadline)
        while true {
            try AppServerRequestBudget.checkCurrent()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            guard descriptor >= 0 else { throw CodexStatusError.serverConnectionClosed }
            var value = pollfd(fd: descriptor, events: events, revents: 0)
            let milliseconds = Int32(max(1, min(100, ceil(TimeInterval(remaining) * 1000))))
            let result = Darwin.poll(&value, 1, milliseconds)
            if result < 0 {
                if errno == EINTR {
                    continue
                }
                throw CodexStatusError.serverConnectionClosed
            }
            try AppServerRequestBudget.checkCurrent()
            guard ContinuousClock.now < deadline else { return false }
            if value.revents & events != 0 {
                return true
            }
            if value.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                throw CodexStatusError.serverConnectionClosed
            }
        }
    }

    private func read(_ count: Int, deadline: ContinuousClock.Instant) throws -> Data {
        var result = Data()
        while result.count < count {
            guard try ready(Int16(POLLIN), deadline: deadline) else { throw CodexStatusError.serverTimeout }
            var buffer = [UInt8](repeating: 0, count: min(65536, count - result.count))
            let length = Darwin.read(descriptor, &buffer, buffer.count)
            if length < 0, errno == EAGAIN || errno == EINTR {
                continue
            }
            guard length > 0 else { throw CodexStatusError.serverConnectionClosed }
            result.append(contentsOf: buffer.prefix(length))
        }
        return result
    }

    private func write(_ data: Data, deadline: ContinuousClock.Instant) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard try ready(Int16(POLLOUT), deadline: deadline) else { throw CodexStatusError.serverTimeout }
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EAGAIN || errno == EINTR {
                    continue
                }
                guard count > 0 else { throw CodexStatusError.serverConnectionClosed }
                offset += count
            }
        }
    }
}

/// 只在监听端点明确不存在时调用, 不停止或重启已经运行的共享后台
nonisolated enum CodexSharedStartup {
    static func start(command: AppServerCommand, environment: [String: String]) throws {
        try AppServerRequestBudget.checkCurrent()
        let expiration = Date().addingTimeInterval(15)
        let budget = AppServerRequestBudget.current?.constrained(to: expiration) ?? AppServerRequestBudget(deadline: expiration)
        try AppServerRequestBudget.$current.withValue(budget) {
            let deadline = budget.deadline
            let result = BoundedProcess.run(
                executable: URL(fileURLWithPath: command.executablePath),
                arguments: ["app-server", "daemon", "start"], environment: environment,
                configuration: .init(deadline: deadline)
            )
            try AppServerRequestBudget.checkCurrent()
            if result.completion == .cancelled {
                throw CancellationError()
            }
            guard result.completion == .exited, result.exitCode == 0 else {
                if result.timedOut {
                    throw CodexStatusError.serverTimeout
                }
                // 启动器输出可能包含用户环境, 只给出固定提示, 不展示 stdout 或 stderr
                throw CodexStatusError.serverError("Codex 共享后台未就绪, 请确认 CLI 已升级并启动后台服务")
            }
            let url = CodexSharedSocket.url(environment: environment)
            for _ in 0 ..< 10 {
                try AppServerRequestBudget.checkCurrent()
                guard ContinuousClock.now < deadline else { throw CodexStatusError.serverTimeout }
                do {
                    let probe = try CodexSharedSocket(url: url)
                    probe.close()
                    return
                } catch let error as CodexSharedConnectionError where error.isAbsent {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            throw CodexStatusError.serverTimeout
        }
    }
}
