import Foundation
import Testing

struct MainPanelSourceSettingsTests {
    @Test func existingSectionOrderAndVisibilitySurviveNewServiceStatusSection() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let order = ["usage", "account", "quota", "status", "activity"]
        preferences.defaults.set(order, forKey: "MainPanel.sectionOrder")
        preferences.defaults.set(["activity"], forKey: "MainPanel.hiddenSections")
        let settings = MainPanelSettings(defaults: preferences.defaults)
        settings.updateActivitySources(local: true)
        #expect(settings.layout.orderedSections == [.usage, .account, .quota, .status, .activity, .serviceStatus])
        #expect(!settings.layout.isVisible(.activity))
        #expect(settings.layout.isVisible(.serviceStatus))
        #expect(preferences.defaults.stringArray(forKey: "MainPanel.sectionOrder") == order)
        #expect(preferences.defaults.stringArray(forKey: "MainPanel.hiddenSections") == ["activity"])
    }

    @Test func configuredRemoteSourcesKeepTasksAvailableWithoutLocalHook() throws {
        let preferences = try TestPreferences()
        defer { preferences.remove() }
        let settings = MainPanelSettings(defaults: preferences.defaults)
        settings.updateActivitySources(local: false, hasRemote: true)
        #expect(settings.hasActivitySource && settings.hasRemoteActivitySource)
        settings.setSection(.activity, isVisible: false, undoManager: UndoManager())
        settings.updateActivitySources(local: false, hasRemote: true)
        settings.refresh()
        #expect(!settings.layout.isVisible(.activity))
        settings.setSection(.activity, isVisible: true, undoManager: UndoManager())
        #expect(settings.layout.isVisible(.activity))
    }
}
