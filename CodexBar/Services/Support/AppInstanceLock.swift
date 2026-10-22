import Darwin
import Foundation

nonisolated enum AppInstanceLock {
    static func directoryURL(bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "io.github.yatotm.codexbar") -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        // Debug 和 Release 可以共存, 同一版本的不同安装位置共用一把锁
        return support.appendingPathComponent("CodexBar-yatotm/Instances", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    static func acquire(in directory: URL) throws -> Int32? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 不替换锁文件 inode, 也不让执行的 Codex 或 SSH 子进程继承锁
        let descriptor = open(directory.appendingPathComponent("app.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    static func release(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
