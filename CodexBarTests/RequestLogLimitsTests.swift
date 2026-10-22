import Foundation
import Testing

struct RequestLogLimitsTests {
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
