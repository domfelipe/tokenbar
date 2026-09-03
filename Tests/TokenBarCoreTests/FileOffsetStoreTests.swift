import Foundation
import Testing
@testable import TokenBarCore

struct FileOffsetStoreTests {
    private func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name + "-" + UUID().uuidString)
    }

    @Test
    func testSetThenReloadRoundtrip() throws {
        let url = tempURL("cursors")
        do {
            let store = JSONFileOffsetStore(url: url)
            try store.set(FileCursor(offset: 1234), for: "/tmp/a.jsonl")
            try store.set(FileCursor(offset: 0), for: "/tmp/b.jsonl")
        }
        let reloaded = JSONFileOffsetStore(url: url)
        #expect(reloaded.cursors()["/tmp/a.jsonl"] == FileCursor(offset: 1234))
        #expect(reloaded.cursors()["/tmp/b.jsonl"] == FileCursor(offset: 0))
    }

    @Test
    func testRemoveWithNil() throws {
        let url = tempURL("cursors")
        let store = JSONFileOffsetStore(url: url)
        try store.set(FileCursor(offset: 10), for: "/tmp/a.jsonl")
        try store.set(nil, for: "/tmp/a.jsonl")
        #expect(store.cursors().isEmpty)
    }

    @Test
    func testCorruptedFileStartsEmpty() throws {
        let url = tempURL("cursors")
        try "{not json".write(to: url, atomically: true, encoding: .utf8)
        let store = JSONFileOffsetStore(url: url)
        #expect(store.cursors().isEmpty)
    }

    @Test
    func testMissingFileStartsEmpty() {
        let store = JSONFileOffsetStore(url: tempURL("never-created"))
        #expect(store.cursors().isEmpty)
    }
}
