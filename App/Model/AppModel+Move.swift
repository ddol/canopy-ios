import CanopyMap
import CanopyModel
import Foundation

/// Moving a tree on the map: the crowns aerial lidar (USGS 3DEP) found round it, to set it by.
extension AppModel {
    typealias Crown = MapLayers.MoveGuide.Crown

    /// How far round a tree being moved its neighbours' crowns are drawn, in metres: a little more than the map shows
    /// at first (`MapScreen.moveRadius`).
    nonisolated static let crownReach = 40.0

    /// The crowns aerial lidar found within `crownReach` of `tree`: the aerial candidates on this device (the tree's
    /// own among them when it was detected as one), and the detected trees on the shared map that have no candidate
    /// here (detected on the server and pulled, as on an iPad that never loaded the aerial trees itself), which still
    /// stand where they were found. Worked out off the main actor: a census can hold tens of thousands of trees.
    func crowns(near tree: Tree) async -> [Crown] {
        let candidates = (try? await store.candidates()) ?? []
        let trees = Array(census.trees.values)
        return await Task.detached(priority: .userInitiated) {
            Self.crowns(around: tree, candidates: candidates, trees: trees)
        }.value
    }

    nonisolated static func crowns(
        around tree: Tree, candidates: [TreeCandidate], trees: [Tree], within reach: Double = crownReach
    ) -> [Crown] {
        let frame = LocalFrame(origin: tree.position.geo)
        func near(_ point: GeoPoint) -> Bool {
            // A cheap box first: a degree of latitude is 111 km everywhere, one of longitude no more than that.
            let degrees = reach / 111_000 / max(cos(tree.position.geo.latitude * .pi / 180), 0.01)
            guard abs(point.latitude - tree.position.geo.latitude) < degrees,
                abs(point.longitude - tree.position.geo.longitude) < degrees
            else { return false }
            return frame.enu(of: point).horizontalDistance <= reach
        }
        let own = tree.candidateID.flatMap(UUID.init(uuidString:)) ?? tree.id
        var crowns: [Crown] = []
        var seen: Set<UUID> = []
        for candidate in candidates where near(candidate.location) {
            seen.insert(candidate.id)
            crowns.append(
                Crown(
                    id: candidate.id, centre: candidate.location,
                    radius: candidate.crownRadius ?? Crown.radius(height: candidate.height),
                    height: candidate.height, isOwn: candidate.id == own))
        }
        for other in trees
        where other.id != tree.id && !seen.contains(other.id) && other.countStatus == .detected
            && other.proposedStatus == nil && (other.candidateID != nil || other.meta.playerID == .aerialSurvey)
            && near(other.position.geo)
        {
            let height = other.height?.height.value
            crowns.append(
                Crown(id: other.id, centre: other.position.geo, radius: Crown.radius(height: height), height: height))
        }
        return crowns.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The crown whose top is nearest `point`, within `reach` metres (or its own radius, if wider): where Snap to
    /// crown sets a tree being moved. The tree's own crown wins over a neighbour's that is no nearer than a metre
    /// closer.
    nonisolated static func snapTarget(for point: GeoPoint, among crowns: [Crown], reach: Double = 6) -> Crown? {
        let frame = LocalFrame(origin: point)
        let scored = crowns.map { crown in
            (crown, frame.enu(of: crown.centre).horizontalDistance)
        }
        .filter { $0.1 <= max(reach, $0.0.radius) }
        return scored.min { a, b in
            (a.1 - (a.0.isOwn ? 1 : 0)) < (b.1 - (b.0.isOwn ? 1 : 0))
        }?.0
    }
}
