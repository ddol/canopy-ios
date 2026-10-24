import CanopyModel
import Foundation

/// The boundary between Canopy and a Gerardus server.
///
/// Milestone 0 has only `FakeGerardusClient`. The real client (HTTP to the Gerardus Rust server) will implement
/// the same protocol, so the app does not change when it lands.
public protocol GerardusClient: Sendable {
    /// Uploads an immutable blob. Uploading the same bytes again is a no-op.
    func uploadBlob(_ data: Data, ref: BlobRef) async throws

    /// Submits a changeset. Every blob its ops reference must already be uploaded. The author's submission
    /// counts as their agreement. Returns the server's view of the changeset (state and approvals).
    func submit(_ changeset: Changeset, author: Player) async throws -> Changeset

    /// The server's view of the given changesets. Ids the server has never seen are left out.
    func changesets(_ ids: [UUID]) async throws -> [Changeset]

    /// Changes applied to the shared map in an L16 tile after `sequence`, oldest first.
    func pullChanges(in tile: S2CellID, since sequence: Int64) async throws -> ChangePage
}

/// One op applied to the shared map.
public struct AppliedChange: Hashable, Codable, Sendable {
    /// Position in the server's log; increases by one per applied op.
    public var sequence: Int64
    public var changesetID: UUID
    public var tile: S2CellID
    public var op: ChangeOp
    public var appliedAt: Date
    /// The changeset's author, when the server says.
    public var author: PlayerID?

    public init(
        sequence: Int64, changesetID: UUID, tile: S2CellID, op: ChangeOp, appliedAt: Date, author: PlayerID? = nil
    ) {
        self.sequence = sequence
        self.changesetID = changesetID
        self.tile = tile
        self.op = op
        self.appliedAt = appliedAt
        self.author = author
    }
}

public struct ChangePage: Hashable, Sendable {
    public var changes: [AppliedChange]
    /// The highest sequence the server has for the tile; pass it as `since` next time.
    public var latestSequence: Int64

    public init(changes: [AppliedChange], latestSequence: Int64) {
        self.changes = changes
        self.latestSequence = latestSequence
    }
}

public enum GerardusError: Error, Equatable {
    case blobHashMismatch(BlobRef)
    case missingBlobs([BlobRef])
    case unknownChangeset(UUID)
    case alreadySubmitted(UUID)
}

extension Changeset {
    /// The evidence blobs the changeset's ops reference, sorted.
    public var referencedBlobs: [BlobRef] {
        var refs: Set<BlobRef> = []
        for op in ops {
            if case .array(let values)? = op.fields["evidenceRefs"] {
                refs.formUnion(values.compactMap { $0.stringValue.flatMap(BlobRef.init(rawValue:)) })
            }
            if let ref = op.fields["evidenceRef"]?.stringValue.flatMap(BlobRef.init(rawValue:)) {
                refs.insert(ref)
            }
        }
        return refs.sorted { $0.rawValue < $1.rawValue }
    }
}
