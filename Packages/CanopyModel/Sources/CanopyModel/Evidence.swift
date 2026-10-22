import Foundation

/// An immutable piece of evidence: a cropped, colourless mesh stored as a GLB blob.
public struct Evidence: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case trunkScan
        case limbScan
    }

    public static let glbMediaType = "model/gltf-binary"

    public var meta: RecordMeta
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
