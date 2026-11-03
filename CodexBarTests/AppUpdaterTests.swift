import Foundation
import Sparkle
import Testing

struct AppUpdaterTests {
    @Test func downloadedUpdateUsesSameInstallHandlerUntilCycleFinishes() throws {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let appUpdater = AppUpdater(bundle: Bundle(for: SUAppcastItem.self))
        let item = try updateItem()
        appUpdater.updater(controller.updater, didFindValidUpdate: item)
        #expect(appUpdater.availableUpdateMessage?.contains("v1.2.3 (Build 10)") == true)
        var installs = 0
        #expect(appUpdater.updater(controller.updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { installs += 1 }))
        #expect(appUpdater.isUpdateReadyToInstall)
        #expect(appUpdater.settingsStatusMessage?.contains("v1.2.3 (Build 10)") == true)

        appUpdater.checkForUpdates()
        appUpdater.startUpdate()
        appUpdater.startUpdate()
        #expect(installs == 2)
        #expect(appUpdater.isUpdateReadyToInstall)

        appUpdater.updater(controller.updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        #expect(!appUpdater.isUpdateReadyToInstall)
        #expect(appUpdater.settingsStatusMessage == nil)
        appUpdater.startUpdate()
        #expect(installs == 2)
    }

    @Test func failedCycleReleasesOldInstallHandlerAndNoUpdateClearsNotice() throws {
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let appUpdater = AppUpdater(bundle: Bundle(for: SUAppcastItem.self))
        let item = try updateItem()
        appUpdater.updater(controller.updater, didFindValidUpdate: item)
        var installs = 0
        _ = appUpdater.updater(controller.updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { installs += 1 })
        appUpdater.updater(controller.updater, didFinishUpdateCycleFor: .updates, error: URLError(.cannotConnectToHost))
        #expect(!appUpdater.isUpdateReadyToInstall)
        appUpdater.startUpdate()
        #expect(installs == 0)

        appUpdater.updaterDidNotFindUpdate(controller.updater, error: NSError(domain: "SUSparkleErrorDomain", code: Int(SUError.noUpdateError.rawValue)))
        #expect(appUpdater.availableUpdateMessage == nil)
    }

    @Test func releaseNotesStayOnForkAndUseActualVersionTag() {
        #expect(AppUpdater.releaseNotesURL(for: "1.2.3").absoluteString == "https://github.com/yatotm/CodexBar/releases/tag/fork-v1.2.3")
        #expect(AppUpdater.releaseNotesURL(for: nil).absoluteString == "https://github.com/yatotm/CodexBar/releases")
    }

    @Test func buildLabelsDistinguishSameVersionAndHandleMissingFields() {
        #expect(Bundle.displayVersionLabel(version: "1.2.3", build: "10") == "v1.2.3 (Build 10)")
        #expect(Bundle.displayVersionLabel(version: "1.2.3", build: "11") == "v1.2.3 (Build 11)")
        #expect(Bundle.displayVersionLabel(version: "1.2.3", build: nil) == "v1.2.3")
        #expect(Bundle.displayVersionLabel(version: nil, build: "11") == "--")
    }

    private func updateItem() throws -> SUAppcastItem {
        try #require(SUAppcastItem(dictionary: [
            "sparkle:version": "10",
            "sparkle:shortVersionString": "1.2.3",
            "enclosure": ["url": "https://example.invalid/CodexBar.zip", "length": "1", "type": "application/octet-stream"]
        ]))
    }
}
