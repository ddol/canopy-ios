import CanopyCapture
import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import Canopy

/// A proposal shows the scans it brings, and the Review list can show only the changes with a scan, or without.
@MainActor
struct ProposalScansTests {
    let tile = GeoPoint(latitude: 37.7699, longitude: -122.4757).tile
    let me = PlayerID(rawValue: "T:_me")

    func ref(_ n: Int) -> BlobRef { BlobRef(rawValue: String(repeating: String(n), count: 64))! }

    func changeset(_ ops: [ChangeOp]) -> Changeset {
        Changeset(meta: RecordMeta(playerID: me, chunk: tile), ops: ops, tiles: [tile])
    }

    @Test func aProposalsScansAreThoseItsOpsName() {
        let tree = ChangeOp(
            op: .update, entity: .tree, id: UUID(), baseVersion: 2,
            fields: ["evidenceRefs": .array([.string(ref(1).rawValue), .string(ref(2).rawValue)])])
        let tag = ChangeOp(
            op: .create, entity: .tag, id: UUID(), baseVersion: 0, fields: ["evidenceRef": .string(ref(2).rawValue)])
        let confirm = ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 1, fields: [:])
        let withScans = changeset([tree, tag, confirm])
        #expect(withScans.scans == [ref(1), ref(2)])
        let without = changeset([confirm])
        #expect(without.scans.isEmpty)

        #expect(ProposalsScreen.ScanFilter.all.keeps(withScans) && ProposalsScreen.ScanFilter.all.keeps(without))
        #expect(
            ProposalsScreen.ScanFilter.withScan.keeps(withScans) && !ProposalsScreen.ScanFilter.withScan.keeps(without))
        #expect(
            !ProposalsScreen.ScanFilter.withoutScan.keeps(withScans)
                && ProposalsScreen.ScanFilter.withoutScan.keeps(without))
    }

    /// The 3D map's points keep every point and its class up to the limit, and an even share of them past it.
    @Test func aerialPointsAreThinnedEvenlyPastTheLimit() throws {
        let origin = GeoPoint(latitude: 37.7705, longitude: -122.4760)
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100, 0), (0, 100)].map { e, n in
            (geo: frame.geoPoint(of: ENU(east: e, north: n, up: 0)).point, site: SIMD2(e, n))
        }
        let georeference = try SiteGeoreference(origin: origin, samples: samples)
        let block = PointBlock(
            x: (0..<100).map(Float.init), y: Array(repeating: 0, count: 100), z: Array(repeating: 10, count: 100),
            classification: (0..<100).map { $0 % 2 == 0 ? 2 : 5 })
        let all = AppModel.cloud([block], token: "t", georeference: georeference, limit: 1000)
        #expect(all.points.count == 100 && all.classes.count == 100 && all.classes[1] == 5)
        let thinned = AppModel.cloud([block, block], token: "t", georeference: georeference, limit: 50)
        #expect(thinned.points.count == 50 && thinned.classes.count == 50)
    }
}
