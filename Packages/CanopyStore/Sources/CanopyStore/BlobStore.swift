import CanopyModel
import CryptoKit
import Foundation

public enum BlobStoreError: Error, Equatable {
    case hashMismatch(expected: BlobRef, actual: BlobRef)
    case missing(BlobRef)
}

/// A directory of immutable blobs named by their SHA-256: `blobs/ab/cdef…` for digest `abcdef…`.
public struct BlobStore: Sendable {
    public let directory: URL

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileProtection.apply(to: directory)
    }

    public static func reference(for data: Data) -> BlobRef {
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return BlobRef(rawValue: hex)!
    }

    /// Stores `data` and returns its reference. Storing the same bytes twice is a no-op.
    @discardableResult
    public func put(_ data: Data) throws -> BlobRef {
        let ref = Self.reference(for: data)
        let url = url(for: ref)
        guard !FileManager.default.fileExists(atPath: url.path) else { return ref }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try FileProtection.apply(to: url)
        return ref
    }

    /// Stores `data`, checking that it hashes to `expected`.
    public func put(_ data: Data, expecting expected: BlobRef) throws {
        let actual = Self.reference(for: data)
        guard actual == expected else { throw BlobStoreError.hashMismatch(expected: expected, actual: actual) }
        try put(data)
    }

    public func contains(_ ref: BlobRef) -> Bool {
        FileManager.default.fileExists(atPath: url(for: ref).path)
    }

    /// Reads a blob and checks its hash.
    public func data(for ref: BlobRef) throws -> Data {
        guard contains(ref) else { throw BlobStoreError.missing(ref) }
        let data = try Data(contentsOf: url(for: ref))
        let actual = Self.reference(for: data)
        guard actual == ref else { throw BlobStoreError.hashMismatch(expected: ref, actual: actual) }
        return data
    }

    public func url(for ref: BlobRef) -> URL {
        let hex = ref.rawValue
        return directory.appending(path: String(hex.prefix(2)), directoryHint: .isDirectory)
            .appending(path: String(hex.dropFirst(2)), directoryHint: .notDirectory)
    }

    func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileProtection.apply(to: directory)
    }
}

enum FileProtection {
    /// Files stay encrypted until the device is first unlocked after boot.
    static func apply(to url: URL) throws {
        #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        #endif
    }
}
