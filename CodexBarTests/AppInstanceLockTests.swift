import Darwin
import Foundation
import Testing

struct AppInstanceLockTests {
    @Test nonisolated func duplicateInstanceDoesNotBlockAndCanStartAfterOwnerExits() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }

        do {
            let descriptor = try #require(try AppInstanceLock.acquire(in: directory.url))
            defer { AppInstanceLock.release(descriptor) }
            let duplicate = try AppInstanceLock.acquire(in: directory.url)
            defer {
                if let duplicate {
                    AppInstanceLock.release(duplicate)
                }
            }
            #expect(duplicate == nil)
            #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
        }

        let replacement = try #require(try AppInstanceLock.acquire(in: directory.url))
        AppInstanceLock.release(replacement)
    }

    @Test nonisolated func debugAndReleaseRemainIndependent() throws {
        #expect(AppInstanceLock.directoryURL(bundleIdentifier: "io.github.yatotm.codexbar")
            != AppInstanceLock.directoryURL(bundleIdentifier: "io.github.yatotm.codexbar.debug"))
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let release = try #require(try AppInstanceLock.acquire(in: directory.url.appendingPathComponent("release")))
        defer { AppInstanceLock.release(release) }
        let debug = try #require(try AppInstanceLock.acquire(in: directory.url.appendingPathComponent("debug")))
        AppInstanceLock.release(debug)
    }

    @Test nonisolated func unreadableStorageIsReportedInsteadOfAssumingAnotherInstance() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        let file = try directory.write(Data(), to: "file")
        #expect(throws: (any Error).self) {
            try AppInstanceLock.acquire(in: file)
        }
    }
}
