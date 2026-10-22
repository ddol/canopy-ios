import Foundation

/// A tree found by aerial LiDAR, before anyone has looked at it.
public struct TreeCandidate: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var location: GeoPoint
    /// Canopy height from the aerial survey, in metres.
    public var height: Double?
    /// Crown radius from the aerial survey, in metres.
    public var crownRadius: Double?
    /// Detection confidence, 0…1.
    public var confidence: Double
    /// True for made-up sample data.
    public var isSynthetic: Bool

    public init(
        id: UUID,
        location: GeoPoint,
        height: Double? = nil,
        crownRadius: Double? = nil,
        confidence: Double,
        isSynthetic: Bool
    ) {
        self.id = id
        self.location = location
        self.height = height
        self.crownRadius = crownRadius
        self.confidence = confidence
        self.isSynthetic = isSynthetic
    }

    /// Typical horizontal error of an aerial crown-centre detection, in metres.
    public static let horizontalSigma = 2.0

    /// The candidate as a `detected` tree in the base layer. The tree keeps the candidate's id.
    public func makeTree(surveyedAt: Date = Date(timeIntervalSince1970: 0)) -> Tree {
        let position = Position(
            geo: location,
            covariance: .isotropic(horizontal: Self.horizontalSigma, vertical: Self.horizontalSigma)
        )
        return Tree(
            meta: RecordMeta(
                id: id,
                createdAt: surveyedAt,
                playerID: .aerialSurvey,
                cell: position.chunk
            ),
            position: position,
            countStatus: .detected,
            height: height.map { TreeHeight(height: Quantity($0, uncertainty: 1), source: .aerialLidar) },
            candidateID: id.uuidString.lowercased()
        )
    }
}
