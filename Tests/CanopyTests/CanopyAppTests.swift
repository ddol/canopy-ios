import CanopyModel
import CanopyStore
import Foundation
import Testing

@testable import Canopy

@MainActor
@Suite struct FixtureTests {
    @Test func bundlesTwoHundredSyntheticCandidatesInsideThePark() throws {
        let candidates = try ParkFixtures.candidates()
        #expect(candidates.count == 200)
        #expect(candidates.allSatisfy { $0.isSynthetic })
        #expect(Set(candidates.map(\.id)).count == 200)
        let ring = try #require(try ParkFixtures.boundary().first)
        #expect(candidates.allSatisfy { contains(ring, $0.location) })
    }

    @Test func s2CellFixtureMatchesS2CellID() throws {
        let cells = try ParkFixtures.cells()
        #expect(cells.count == 7)
        #expect(Set(cells.map(\.cell.level)) == [16, 19])
        for (cell, corners) in cells {
            for (vertex, expected) in zip(cell.vertices, corners) {
                #expect(abs(vertex.latitude - expected.latitude) < 1e-8)
                #expect(abs(vertex.longitude - expected.longitude) < 1e-8)
            }
        }
    }

    private func contains(_ ring: [GeoPoint], _ point: GeoPoint) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let (a, b) = (ring[i], ring[j])
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
                point.longitude
                    < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude)
                    + a.longitude
            {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

@MainActor
@Suite struct AppModelTests {
    func makeModel() throws -> AppModel {
        AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter)
        )
    }

    @Test func loadImportsTheFixturesOnce() async throws {
        let model = try makeModel()
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.census.trees.count == 200)
        #expect(model.summary == CensusSummary(confirmed: 0, estimated: 200, coverage: 0))
        #expect(!model.boundary.isEmpty)
        await model.load()
        #expect(model.census.trees.count == 200)
    }

    @Test func confirmingATreeProposesItAndCreatesAPendingChangeset() async throws {
        let model = try makeModel()
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        await model.confirm(tree)
        #expect(model.tree(tree.id)?.displayStatus == .proposed)
        #expect(model.changesets.map(\.state) == [.pending])
        #expect(model.summary.coverage == 1.0 / 200.0)
        #expect(model.error == nil)
    }

    @Test func movingATreeProposesItAtItsNewPlace() async throws {
        let model = try makeModel()
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        let moved = LocalFrame(origin: tree.position.geo).geoPoint(of: ENU(east: 2, north: -1.5, up: 0)).point
        await model.move(tree, to: Position(geo: moved, covariance: .isotropic(horizontal: 3, vertical: 3)))
        let after = try #require(model.tree(tree.id))
        #expect(LocalFrame(origin: moved).enu(of: after.position.geo).horizontalDistance < 0.001)
        #expect(after.displayStatus == .proposed)
        let changeset = try #require(model.changesets.last)
        #expect(changeset.state == .pending)
        #expect(changeset.ops.first?.fields["position"] != nil)
        #expect(ChangesetSummary.describe(changeset) == "Move tree")
        #expect(model.error == nil)
    }

    @Test func placingATagMakesAProposedTagAndAPendingChangeset() async throws {
        let model = try makeModel()
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        let tag = try #require(
            await model.placeTag(
                on: tree,
                point: Tag.Point(position: tree.position, heightAboveGround: Quantity(6, uncertainty: 1)),
                issue: .hanger, couldHit: .path, sizeClass: .large, urgency: .high,
                evidence: AppModel.LimbEvidence(glb: Data("limb".utf8), vertexCount: 3, triangleCount: 1, cropRadius: 1)
            ))
        #expect(tag.status == .proposed)
        #expect(tag.evidenceRef != nil)
        #expect(model.tags(on: tree).map(\.id) == [tag.id])
        let changeset = try #require(model.changesets.last)
        #expect(changeset.state == .pending)
        #expect(changeset.ops.map(\.entity) == [.tag])
        #expect(changeset.ops.first?.fields["evidenceRef"] == .string(tag.evidenceRef!.rawValue))
        #expect(try await model.store.evidence(about: tag.id).first?.kind == .limbScan)
    }

    @Test func savingAScanTwiceKeepsOneScanAndOneTree() async throws {
        let model = try makeModel()
        await model.load()
        let other = try #require(model.census.trees.values.first)
        let glb = Data("trunk glb".utf8)
        let dbh = DBH(diameter: Quantity(0.4, uncertainty: 0.01), method: .lidarCircleFit)
        func save(_ target: Tree? = nil) async -> Tree? {
            await model.saveTrunkMeasurement(
                dbh: dbh, lean: nil, glb: glb, evidenceMesh: (3, 1), cropRadius: 1.5, tree: target,
                position: other.position)
        }

        // Save as a new tree tapped twice: the second tap does nothing while the first saves.
        async let first = save()
        async let second = save()
        let saved = Set(await [first, second].compactMap { $0?.id })
        #expect(saved.count == 1)
        let tree = try #require(saved.first)
        #expect(model.census.trees.count == 201)
        #expect(model.scanCount == 1)
        #expect(model.changesets.count == 2, "the new tree and its measurement")

        // Saving it again later, even for another tree, links to the tree it measured.
        #expect(await save()?.id == tree)
        #expect(await save(other)?.id == tree)
        #expect(model.census.trees.count == 201)
        #expect(model.scanCount == 1)
        #expect(model.changesets.count == 2)
        #expect(model.tree(tree)?.evidenceRefs == [BlobStore.reference(for: glb)])
        #expect(model.tree(other.id)?.evidenceRefs == [])
        #expect(model.error == nil)
    }

    @Test func placingATagWithOneLimbScanTwiceKeepsOneScanAndOneTag() async throws {
        let model = try makeModel()
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        let limb = AppModel.LimbEvidence(glb: Data("limb glb".utf8), vertexCount: 3, triangleCount: 1, cropRadius: 1)
        func place() async -> CanopyModel.Tag? {
            await model.placeTag(
                on: tree, point: Tag.Point(position: tree.position, heightAboveGround: Quantity(6, uncertainty: 1)),
                issue: .hanger, couldHit: .path, sizeClass: .large, urgency: .high, evidence: limb)
        }

        // Save tapped twice: the second tap does nothing while the first saves.
        async let first = place()
        async let second = place()
        let placed = Set(await [first, second].compactMap { $0?.id })
        #expect(placed.count == 1)
        let tag = try #require(placed.first)

        // Saving it again later returns the tag the scan is about.
        #expect(await place()?.id == tag)
        #expect(model.tags(on: tree).map(\.id) == [tag])
        #expect(model.scanCount == 1)
        #expect(model.changesets.count == 1)
        #expect(model.error == nil)
    }

    @Test func syncSubmitsAndASimulatedTrustedApprovalAppliesTheChange() async throws {
        let model = try makeModel()
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        await model.confirm(tree)

        await model.sync()
        #expect(model.lastSync?.submitted == 1)
        #expect(model.changesets.map(\.state) == [.pending])

        await model.simulateTrustedApproval()
        #expect(model.changesets.map(\.state) == [.applied])
        #expect(model.tree(tree.id)?.countStatus == .confirmed)
        #expect(model.summary.confirmed == 1)
        #expect(model.error == nil)
    }

    @Test func resetStartsAgainFromTheFixtures() async throws {
        let model = try makeModel()
        await model.load()
        await model.confirm(try #require(model.census.trees.values.first))
        await model.reset()
        #expect(model.changesets.isEmpty)
        #expect(model.census.trees.count == 200)
        #expect(model.summary.coverage == 0)
    }

    @Test func taggingFromATreeSwitchesToTheTagTab() async throws {
        let model = try makeModel()
        await model.load()
        let tree = try #require(model.census.trees.values.first)
        model.tagLimb(on: tree)
        #expect(model.section == .tag)
        #expect(model.tagTarget == tree.id)
    }
}
