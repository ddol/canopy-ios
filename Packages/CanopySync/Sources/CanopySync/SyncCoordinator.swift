import CanopyModel
import Foundation

/// Pushes local changesets to a Gerardus server and brings back their state.
///
/// For each open local changeset: if the server has not seen it, upload the blobs it references and submit
/// it; otherwise take the server's state and approvals. The result is the changesets that changed, for the
/// caller to save.
public struct SyncCoordinator: Sendable {
    public let client: any GerardusClient

    public init(client: any GerardusClient) {
        self.client = client
    }

    public struct Report: Hashable, Sendable {
        public var submitted: Int = 0
        public var updated: [Changeset] = []
        public var blobsUploaded: Int = 0
        public var finishedAt: Date = .now

        public init() {}
    }

    public func sync(
        _ local: [Changeset],
        author: Player,
        blob: @Sendable (BlobRef) async throws -> Data
    ) async throws -> Report {
        var report = Report()
        let open = local.filter(\.state.isOpen)
        let known = Dictionary(
            try await client.changesets(open.map(\.id)).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for changeset in open {
            let remote: Changeset
            if let existing = known[changeset.id] {
                remote = existing
            } else {
                for ref in changeset.referencedBlobs {
                    try await client.uploadBlob(try await blob(ref), ref: ref)
                    report.blobsUploaded += 1
                }
                remote = try await client.submit(changeset, author: author)
                report.submitted += 1
            }
            if remote.state != changeset.state || remote.approvals != changeset.approvals {
                var merged = changeset
                merged.state = remote.state
                merged.approvals = remote.approvals
                report.updated.append(merged)
            }
        }
        report.finishedAt = .now
        return report
    }
}
