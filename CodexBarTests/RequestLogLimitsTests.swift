import Foundation
import Testing

struct RequestLogLimitsTests {
    @Test func methodFilteringSupportsMultipleMethodsAndUnattributedFailures() {
        let storage = RequestLogStorage()
        _ = storage.beginRequest(method: "account/read", payload: "{}")
        _ = storage.beginRequest(method: "account/rateLimits/read", payload: "{}")
        _ = storage.beginRequest(method: "account/usage/read", payload: "{}")
        storage.recordFailure(message: "connection closed")
        let store = RequestLogStore(storage: storage)
        #expect(store.filteredEntries.count == 4)
        store.setSelectedMethods(["account/rateLimits/read", "account/usage/read"])
        #expect(Set(store.filteredEntries.compactMap(\.method)) == ["account/rateLimits/read", "account/usage/read"])
        store.setSelectedMethods([""])
        #expect(store.filteredEntries.count == 1)
        #expect(store.filteredEntries.first?.kind == .failure)
        store.setSelectedMethods(["absent"])
        #expect(store.filteredEntries.isEmpty)
        #expect(store.availableMethods.contains("absent"))
        store.setSelectedMethods([])
        #expect(store.filteredEntries.count == 4)
        #expect(storage.entries.count == 4)
    }

    @Test func largeUnicodeResponsesAreBoundedBeforePreviewLayout() throws {
        let store = RequestLogStorage()
        let payload = String(repeating: "测试", count: 100000)
        let id = store.beginRequest(method: "fixture", payload: payload)
        store.finishRequest(id, response: payload)
        let entry = try #require(store.entries.first)
        #expect(try #require(entry.request?.utf8.count) < 129 * 1024)
        #expect(try #require(entry.detail?.utf8.count) < 129 * 1024)
        #expect(entry.kind == .response)
        #expect(try #require(entry.detail?.hasSuffix("[日志内容已截断]")))
    }

    @Test func boundedStorageKeepsLatestEntriesAndCompleteSmallJSON() throws {
        let store = RequestLogStorage()
        for index in 0 ..< 501 {
            let id = store.beginRequest(method: "fixture-\(index)", payload: "{}")
            store.finishRequest(id, response: #"{"ok":true}"#)
        }
        #expect(store.entries.count == 500)
        let newest = try #require(store.entries.first)
        #expect(newest.method == "fixture-500")
        #expect(newest.detail == #"{"ok":true}"#)
    }
}
