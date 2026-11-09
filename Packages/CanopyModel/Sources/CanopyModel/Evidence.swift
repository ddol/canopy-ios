import Foundation

/// An immutable piece of evidence: a cropped, colourless mesh stored as a GLB blob.
///
/// A scan is identified by its hash, `blob`: the SHA-256 of the GLB bytes, which is also the blob's name on this device
/// and on a Gerardus server. The GLB writer is deterministic and a scan is encoded once, when it is captured, so two
/// records with the same hash are the same scan saved twice. A store keeps one record per hash.
public struct Evidence: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case trunkScan
        case limbScan
    }

    public static let glbMediaType = "model/gltf-binary"

    public var meta: RecordMeta
    /// The scan's hash: the lower-case hex SHA-256 of the GLB bytes.
    public var blob: BlobRef
    public var byteCount: Int
    public var mediaType: String
    public var kind: Kind
    /// The tree or tag the evidence is about.
    public var subjectID: UUID
    /// Radius of the crop around the subject, in metres.
    public var cropRadius: Double
    public var vertexCount: Int
    public var triangleCount: Int

    public init(
        meta: RecordMeta,
        blob: BlobRef,
        byteCount: Int,
        mediaType: String = Evidence.glbMediaType,
        kind: Kind,
        subjectID: UUID,
        cropRadius: Double,
        vertexCount: Int,
        triangleCount: Int
    ) {
        self.meta = meta
        self.blob = blob
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.kind = kind
        self.subjectID = subjectID
        self.cropRadius = cropRadius
        self.vertexCount = vertexCount
        self.triangleCount = triangleCount
    }

    public var id: UUID { meta.id }
}
