import Foundation

@testable import CanopyModel

/// Shared fixtures for the model tests.
enum Sample {
    static let player = PlayerID(rawValue: "T:_player-one")
    static let other = PlayerID(rawValue: "T:_player-two")
    static let date = Date(timeIntervalSince1970: 1_792_540_800)

    static let stowLake = GeoPoint(latitude: 37.7699, longitude: -122.4757)
    static let windmill = GeoPoint(latitude: 37.7704, longitude: -122.5090)

    static func detectedTree(at point: GeoPoint = stowLake, id: UUID = UUID()) -> Tree {
        TreeCandidate(id: id, location: point, height: 18, crownRadius: 4, confidence: 0.9, isSynthetic: true)
            .makeTree()
    }

    static func meta(_ point: GeoPoint = stowLake, player: PlayerID = player) -> RecordMeta {
        RecordMeta(createdAt: date, playerID: player, cell: point.chunk)
    }

    static func observation(
        _ kind: FieldObservation.Kind, changeset: UUID? = UUID(), at point: GeoPoint = stowLake
    )
        -> FieldObservation
    {
        FieldObservation(meta: meta(point), changesetID: changeset, kind: kind)
    }

    static let evidence = BlobRef(rawValue: String(repeating: "ab", count: 32))!

    static let dbh = DBH(diameter: Quantity(0.42, uncertainty: 0.008), method: .lidarCircleFit)

    static func newTree(at point: GeoPoint = windmill) -> Tree {
        Tree(
            meta: meta(point),
            position: Position(geo: point, covariance: .isotropic(horizontal: 5, vertical: 5)),
            countStatus: .proposed,
            species: "Monterey cypress"
        )
    }

    static func tag(on tree: Tree) -> Tag {
        Tag(
            meta: meta(tree.position.geo),
            treeID: tree.id,
            point: Tag.Point(position: tree.position, heightAboveGround: Quantity(6.5, uncertainty: 0.3)),
            issue: .deadwood,
            couldHit: .path,
            sizeClass: .medium,
            urgency: .high
        )
    }
}
