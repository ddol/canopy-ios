import CanopyModel
import Foundation
import Testing

@testable import CanopyStore

@Suite struct BlobStoreTests {
    let store: BlobStore

    init() throws {
        store = try BlobStore(
            directory: FileManager.default.temporaryDirectory.appending(path: "canopy-blobs-\(UUID().uuidString)"))
    }

    @Test func namesBlobsBySHA256() throws {
        let ref = try store.put(Data("hello".utf8))
        #expect(ref.rawValue == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
        let url = store.url(for: ref)
        #expect(url.deletingLastPathComponent().lastPathComponent == "2c")
        #expect(url.lastPathComponent == String(ref.rawValue.dropFirst(2)))
        #expect(store.contains(ref))
        #expect(try store.data(for: ref) == Data("hello".utf8))
    }

    @Test func putIsIdempotent() throws {
        let first = try store.put(Data("same".utf8))
        let second = try store.put(Data("same".utf8))
        #expect(first == second)
    }

    @Test func detectsCorruption() throws {
        let ref = try store.put(Data("original".utf8))
        try Data("tampered".utf8).write(to: store.url(for: ref))
        #expect(throws: BlobStoreError.self) {
            try store.data(for: ref)
        }
    }

    @Test func missingBlob() {
        let ref = BlobStore.reference(for: Data("never stored".utf8))
        #expect(!store.contains(ref))
        #expect(throws: BlobStoreError.missing(ref)) {
            try store.data(for: ref)
        }
    }
}
