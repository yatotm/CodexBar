import Foundation
import Testing

struct NotificationSoundOptionTests {
    @Test func customSoundsKeepSavedIDsWithoutAppearingInSystemGroup() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        for name in ["custom/Example.wav", "custom/local.aif", "custom/invalid.mp3", "system/example.aiff", "system/Glass.aiff"] {
            _ = try directory.write(Data(), to: name)
        }
        let categories = NotificationSoundOption.loadCategories(
            customDirectories: [directory.url.appendingPathComponent("custom")],
            systemDirectory: directory.url.appendingPathComponent("system")
        )
        let custom = try #require(categories.first { $0.title == "Custom" })
        let system = try #require(categories.first { $0.title == "System" })
        #expect(custom.sounds.map(\.id) == ["example", "local"])
        #expect(system.sounds.map(\.id) == ["glass"])
        #expect(custom.sounds.first?.title == "Example")
        let ids = categories.flatMap(\.sounds).map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func sameNamedCustomAndBundledSoundsKeepPriorSelectionPriority() throws {
        let directory = try TestDirectory()
        defer { try? directory.remove() }
        for name in ["user/Ping.wav", "global/ping.aiff", "user/antic.wav"] {
            _ = try directory.write(Data(), to: name)
        }
        let categories = NotificationSoundOption.loadCategories(
            customDirectories: [directory.url.appendingPathComponent("user"), directory.url.appendingPathComponent("global")],
            systemDirectory: directory.url.appendingPathComponent("missing")
        )
        let custom = try #require(categories.first { $0.title == "Custom" })
        #expect(custom.sounds.map(\.title) == ["Ping"])
        #expect(categories.first { $0.title == "Modern" }?.sounds.filter { $0.id == "antic" }.count == 1)
        #expect(!categories.contains { $0.title == "System" })
    }
}
