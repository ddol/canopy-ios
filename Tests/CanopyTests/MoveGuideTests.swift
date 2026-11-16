import CanopyMap
import CanopyModel
import Foundation
import Testing

@testable import Canopy

/// Moving a tree on the map shows the crowns aerial lidar found round it, and snaps to the nearest; the Proposals tab
/// lists the player's proposals sent from their other devices.
struct MoveGuideTests {
    let here = GeoPoint(latitude: 37.7699, longitude: -122.4757)

    /// `metres` east and `north` metres north of `here`.
    func offset(east: Double, north: Double = 0) -> GeoPoint {
        LocalFrame(origin: here).geoPoint(of: ENU(east: east, north: north, up: 0)).point
    }

    func detected(_ id: UUID = UUID(), at point: GeoPoint, height: Double? = nil) -> Tree {
        TreeCandidate(id: id, location: point, height: height, confidence: 0.9, isSynthetic: false).makeTree()
    }

    /// The tree's own detection is marked as its own; a neighbour's candidate and a detected tree pulled from the
    /// shared map (no candidate here) are both crowns; anything beyond reach, or a tree someone has looked at, is not.
    @Test func theCrownsRoundATreeComeFromCandidatesAndDetectedTrees() {
        let ownID = UUID()
        let tree = detected(ownID, at: offset(east: 1.5))
        let candidates = [
            TreeCandidate(
                id: ownID, location: offset(east: 0), height: 20, crownRadius: 5, confidence: 0.9, isSynthetic: false),
            TreeCandidate(id: UUID(), location: offset(east: 12), height: 16, confidence: 0.8, isSynthetic: false),
            TreeCandidate(id: UUID(), location: offset(east: 90), confidence: 0.8, isSynthetic: false),
        ]
        let pulled = detected(at: offset(east: -10, north: 5), height: 40)
        var confirmed = detected(at: offset(east: -5))
        confirmed.countStatus = .confirmed
        let crowns = AppModel.crowns(
            around: tree, candidates: candidates, trees: [tree, pulled, confirmed, detected(at: offset(east: 300))])
        #expect(crowns.count == 3)
        let own = crowns.first(where: \.isOwn)
        #expect(own?.id == ownID && own?.radius == 5)
        // No width from the survey: a quarter of the height, within 2 to 8 m.
        #expect(crowns.first { $0.id == candidates[1].id }?.radius == 4)
        #expect(crowns.first { $0.id == pulled.id }?.radius == 8)
        #expect(!crowns.contains { $0.id == confirmed.id })
    }

    /// Snapping goes to the nearest crown top in reach, the tree's own when it is about as near, and nowhere when
    /// none is close.
    @Test func snappingGoesToTheNearestCrown() {
        let own = AppModel.Crown(id: UUID(), centre: offset(east: 2), radius: 3, isOwn: true)
        let neighbour = AppModel.Crown(id: UUID(), centre: offset(east: -1.5), radius: 3)
        #expect(AppModel.snapTarget(for: here, among: [own, neighbour])?.id == own.id)
        #expect(AppModel.snapTarget(for: offset(east: -3), among: [own, neighbour])?.id == neighbour.id)
        #expect(AppModel.snapTarget(for: offset(east: 40), among: [own, neighbour]) == nil)
        // Inside a wide crown counts, however far from its top.
        let wide = AppModel.Crown(id: UUID(), centre: offset(east: 40), radius: 10)
        #expect(AppModel.snapTarget(for: offset(east: 31), among: [wide])?.id == wide.id)
    }

    /// The player's open changesets on the server that this device never held are the ones from their other devices,
    /// newest first.
    @Test func proposalsFromOtherDevicesAreThoseNotMadeHere() {
        let me = PlayerID(rawValue: "T:_me")
        func changeset(_ at: Double) -> Changeset {
            Changeset(
                meta: RecordMeta(createdAt: Date(timeIntervalSince1970: at), playerID: me, chunk: here.tile),
                ops: [ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 1, fields: [:])],
                tiles: [here.tile])
        }
        let madeHere = changeset(1)
        let older = changeset(2)
        let newer = changeset(3)
        let listed = AppModel.otherDeviceProposals([older, madeHere, newer], local: [madeHere])
        #expect(listed.map(\.id) == [newer.id, older.id])
    }
}
