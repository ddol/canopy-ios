import CanopyModel
import CanopyReference
import Foundation
import Testing
import simd

@testable import CanopyCapture

extension StemMesh {
    /// A clump of three stems from the ground, 0.4, 0.3 and 0.24 m across, their bark 0.4 to 0.9 m apart.
    static func clump() -> Mesh {
        var mesh = cylinder(centre: .zero, radius: 0.2, from: -0.1, to: 4.5)
        mesh.append(cylinder(centre: SIMD2(0.8, 0.2), radius: 0.15, from: -0.1, to: 4.5))
        mesh.append(cylinder(centre: SIMD2(-0.3, 1.0), radius: 0.12, from: -0.1, to: 4.5))
        mesh.append(slopedGround())
        return mesh
    }

    /// A trunk 0.6 m across that forks 1.8 m up into two stems 0.3 m across, the eastern of which forks again 3.2 m
    /// up into two 0.2 m across.
    static func forkedTwice() -> Mesh {
        var mesh = cylinder(centre: .zero, radius: 0.3, from: -0.1, to: 1.8)
        mesh.append(cylinder(centre: SIMD2(-0.3, 0), radius: 0.15, from: 1.8, to: 5.5))
        mesh.append(cylinder(centre: SIMD2(0.3, 0), radius: 0.15, from: 1.8, to: 3.2))
        mesh.append(cylinder(centre: SIMD2(0.2, 0.25), radius: 0.1, from: 3.2, to: 5.5))
        mesh.append(cylinder(centre: SIMD2(0.45, -0.2), radius: 0.1, from: 3.2, to: 5.5))
        mesh.append(slopedGround())
        return mesh
    }
}

/// A tree as a main trunk and stems that start from the ground or fork off another stem, forking again
/// (`TreeStem`), and the stems measured at breast height.
@Suite struct StemGraphTests {
    let form = TreeForm(trunkDiameter: 0.4, height: 12, crownHeight: 6, crownWidth: 6)

    @Test func aProfileSavedBeforeTheGraphReadsTheSameAndOneWithItRoundTrips() throws {
        let trunk = [0.0, 1].map { TreeSection(part: .trunk, height: $0, radius: 0.3) }
        let stem = TreeSection(part: .trunk, height: 2, radius: 0.15, offset: SIMD2(0.25, 0), stem: 0)
        let old = TreeProfile(sections: trunk + [stem])
        let json = try JSONEncoder().encode(old)
        // Written as before: no graph at all.
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object.keys.sorted() == ["sections"])
        let read = try JSONDecoder().decode(TreeProfile.self, from: json)
        #expect(read == old)
        #expect(read.stem(0).origin == .fork(parent: nil))

        var clump = old
        let ground = TreeSection(part: .trunk, height: 1.37, radius: 0.1, offset: SIMD2(-1, 0.5))
        let id = clump.addStem([ground], origin: .ground(base: SIMD2(-1, 0.5)))
        #expect(id == 1)
        let again = try JSONDecoder().decode(TreeProfile.self, from: JSONEncoder().encode(clump))
        #expect(again == clump)
        #expect(again.stem(1).origin == .ground(base: SIMD2(-1, 0.5)))
        #expect(again.groundStems == [1])
    }

    @Test func aClumpScannedFromOneStemBecomesAStemFromTheGroundForEachOther() throws {
        let scan = SavedScan(mesh: StemMesh.clump())
        let (snapped, _, stems) = scan.snappingTrunk(TreeProfile(form: form), groundHeight: 0)
        #expect(stems == 2)
        #expect(snapped.groundStems.count == 2)
        // The main trunk goes on up the stem it stood on.
        #expect(snapped.mainTrunk.allSatisfy { abs($0.radius - 0.2) < 0.01 && simd_length($0.offset ?? .zero) < 0.02 })
        let breast = snapped.breastHeightStems()
        #expect(breast.count == 3)
        #expect(Set(breast.map { ($0.diameter * 100).rounded() }) == [40, 30, 24])
        let equivalent = try #require(snapped.equivalentDiameter())
        #expect(abs(equivalent - (0.4 * 0.4 + 0.3 * 0.3 + 0.24 * 0.24).squareRoot()) < 0.01)
        // Each stem from the ground stands on its own base, joined to the ground, not to another stem.
        let joins = WireframeTree.joins(snapped.trunk, in: snapped)
        for stem in snapped.groundStems {
            let start = try #require(snapped.start(ofStem: stem))
            #expect(start.height == 0)
            #expect(joins.contains { $0.0.id == start.id && $0.1.stem == stem })
            #expect(!joins.contains { $0.0.stem != stem && $0.1.stem == stem })
        }
        // Snapping again finds no new stem.
        let (again, _, count) = scan.snappingTrunk(snapped, groundHeight: 0)
        #expect(count == 2)
        #expect(again.groundStems == snapped.groundStems)
    }

    @Test func aStemThatForksAgainForksOffItsOwnStem() throws {
        let scan = SavedScan(mesh: StemMesh.forkedTwice())
        let (snapped, _, _) = scan.snappingTrunk(TreeProfile(form: form), groundHeight: 0)
        let first = snapped.forks(of: nil)
        #expect(first.count == 2)
        // The eastern stem ends in a fork of its own, the western goes on.
        let east = try #require(first.first { (snapped.rings(onStem: $0).first?.offset?.x ?? 0) > 0 })
        let west = try #require(first.first { $0 != east })
        #expect(snapped.endsInFork(east))
        #expect(!snapped.endsInFork(west))
        let second = snapped.forks(of: east)
        #expect(second.count == 2)
        for stem in second {
            #expect(snapped.stem(stem).origin == .fork(parent: east))
            #expect(snapped.rings(onStem: stem).allSatisfy { $0.height > 3.2 && abs($0.radius - 0.1) < 0.01 })
            // Joined to the eastern stem's ring below the fork.
            let start = try #require(snapped.start(ofStem: stem))
            #expect(start.stem == east && start.height < 3.2)
        }
        #expect(snapped.rings(onStem: east).allSatisfy { $0.height < 3.2 })
        #expect(snapped.descendants(of: nil).count == 4)
        // At breast height it is one trunk.
        #expect(snapped.breastHeightStems().count == 1)
    }

    @Test func aForkBelowBreastHeightIsMeasuredAsItsStems() {
        let trunk = TreeSection(part: .trunk, height: 0, radius: 0.35)
        let left = [1.1, 2].map { TreeSection(part: .trunk, height: $0, radius: 0.2, offset: SIMD2(-0.2, 0), stem: 0) }
        let right = [1.1, 2].map { TreeSection(part: .trunk, height: $0, radius: 0.15, offset: SIMD2(0.2, 0), stem: 1) }
        let profile = TreeProfile(sections: [trunk] + left + right)
        let breast = profile.breastHeightStems()
        #expect(breast.map(\.stem) == [0, 1])
        #expect(abs((profile.equivalentDiameter() ?? 0) - 0.5) < 1e-9)
    }

    @Test func theShapeSlidersLeaveTheOtherStemsWhereTheyStart() {
        var profile = TreeProfile(form: form)
        let ground = profile.addStem(
            [1.37, 2].map { TreeSection(part: .trunk, height: $0, radius: 0.12, offset: SIMD2(1, 0)) },
            origin: .ground(base: SIMD2(1, 0)))
        var reshaped = form
        reshaped.crownWidth = 9
        let followed = profile.following(reshaped)
        #expect(followed.stem(ground).origin == .ground(base: SIMD2(1, 0)))
        #expect(followed.rings(onStem: ground).map(\.height) == [1.37, 2])
        // The main trunk keeps its ring at 2 m beside the stem's.
        #expect(followed.mainTrunk.contains { $0.height == 2 })
        #expect(followed.breastHeightStems().count == 2)
    }

    @Test func takingAStemOutTakesWhatGrowsOffItAndMovingOneMovesThemToo() {
        let trunk = [0.0, 1].map { TreeSection(part: .trunk, height: $0, radius: 0.3) }
        var profile = TreeProfile(sections: trunk)
        let a = profile.addStem(
            [TreeSection(part: .trunk, height: 2, radius: 0.15, offset: SIMD2(0.2, 0))], origin: .fork(parent: nil))
        let b = profile.addStem(
            [TreeSection(part: .trunk, height: 3, radius: 0.1, offset: SIMD2(0.3, 0))], origin: .fork(parent: a))
        let c = profile.addStem(
            [TreeSection(part: .trunk, height: 1.37, radius: 0.1, offset: SIMD2(-1, 0))],
            origin: .ground(base: SIMD2(-1, 0)))
        var moved = profile
        moved.moveStem(a, by: SIMD2(0.05, -0.05))
        #expect(moved.rings(onStem: b).first?.offset == SIMD2(0.35, -0.05))
        #expect(moved.rings(onStem: c) == profile.rings(onStem: c))
        moved.moveStem(c, by: SIMD2(0.1, 0))
        #expect(moved.stem(c).origin == .ground(base: SIMD2(-0.9, 0)))

        profile.removeStem(a)
        #expect(profile.stemIDs == [c])
        #expect(profile.mainTrunk.count == 2)
        #expect(profile.stemGraph.map(\.id) == [c])
    }

    @Test func stemsSplitOffAreATreeOfTheirOwnStandingOnTheLargest() throws {
        var profile = TreeProfile(sections: [
            TreeSection(part: .trunk, height: 0, radius: 0.3), TreeSection(part: .trunk, height: 2, radius: 0.3),
            TreeSection(part: .crown, height: 5, radius: 3),
        ])
        let big = profile.addStem(
            [0.5, 1.37, 2].map { TreeSection(part: .trunk, height: $0, radius: 0.25, offset: SIMD2(2, 1)) },
            origin: .ground(base: SIMD2(2, 1)))
        let small = profile.addStem(
            [1.37].map { TreeSection(part: .trunk, height: $0, radius: 0.1, offset: SIMD2(2.5, 1)) },
            origin: .ground(base: SIMD2(2.5, 1)))
        let branch = profile.addStem(
            [3].map { TreeSection(part: .trunk, height: $0, radius: 0.1, offset: SIMD2(2.1, 1)) },
            origin: .fork(parent: big))
        let stay = profile.addStem(
            [1.37].map { TreeSection(part: .trunk, height: $0, radius: 0.1, offset: SIMD2(-0.6, 0)) },
            origin: .ground(base: SIMD2(-0.6, 0)))
        #expect(profile.root(of: branch) == big)
        #expect(profile.root(of: nil) == nil)

        let (kept, off, base) = try #require(profile.splittingOff([big, small]))
        #expect(base == SIMD2(2, 1))
        #expect(kept.stemIDs == [stay])
        #expect(kept.breastHeightStems().count == 2)
        // The largest is the new tree's main trunk, standing on its own base, on the ground.
        #expect(off.mainTrunk.map(\.height) == [0, 0.5, 1.37, 2])
        #expect(off.mainTrunk.allSatisfy { $0.offset == .zero })
        #expect(off.stem(small).origin == .ground(base: SIMD2(0.5, 0)))
        #expect(off.stem(branch).origin == .fork(parent: nil))
        #expect(off.breastHeightStems().map(\.stem) == [nil, small])
        #expect(off.crown == profile.crown)
        // The main trunk cannot be split off.
        #expect(profile.splittingOff([]) == nil)
    }
}

/// Every stem at breast height kept from a scan, and what is reported for them.
@Suite struct ClumpScanTests {
    @Test func theScanKeepsEveryStemOfTheClumpAndReportsTheirEquivalentDBH() throws {
        // Scanned from the bark of the largest stem's south side, 1.37 m up a clump standing on ground at -1.37.
        var world = StemMesh.clump()
        world.positions = world.positions.map { $0 + SIMD3(0, -1.37, -0.2) }
        let capture = try TrunkScan.analyse(
            world: world, floorHeights: [], center: .zero, camera: SIMD3(0, 0, 2), northAligned: true)
        let analysis = capture.analysis
        #expect(abs(analysis.dbh.diameter.value - 0.4) < 0.01)
        #expect(analysis.stems.count == 3)
        #expect(abs(analysis.equivalentDBH.diameter.value - (0.16 + 0.09 + 0.0576).squareRoot()) < 0.01)
        // The evidence takes in every stem.
        #expect(capture.cropRadius > 1.0)

        let form = TreeForm(trunkDiameter: 0.4, height: 12, crownHeight: 6, crownWidth: 6)
        let fitted = TrunkSteps.fitted(TreeProfile(form: form), to: capture, below: form.crownBase)
        let profile = capture.addingStems(to: fitted, below: form.crownBase)
        #expect(profile.groundStems.count == 2)
        #expect(profile.breastHeightStems().count == 3)
        for stem in profile.groundStems {
            let rings = profile.rings(onStem: stem)
            // Fitted up the stem as far as the scan goes, then on to the crown's base.
            #expect(rings.contains { $0.source == .scan && $0.height > 2 })
            #expect(rings.last?.height == form.crownBase)
        }
        // Adding them again adds nothing.
        #expect(capture.addingStems(to: profile, below: form.crownBase).stemIDs == profile.stemIDs)
    }

    @Test func aStemTooFarFromTheClumpIsNotTheTrees() throws {
        var world = StemMesh.cylinder(centre: .zero, radius: 0.25, from: -1.5, to: 3)
        // Another tree, its bark 1.6 m from this one's.
        world.append(StemMesh.cylinder(centre: SIMD2(0, -2.05), radius: 0.2, from: -1.5, to: 3))
        world.append(StemMesh.slopedGround(at: -1.37))
        world.positions = world.positions.map { $0 + SIMD3(0, 0, -0.25) }
        let capture = try TrunkScan.analyse(
            world: world, floorHeights: [], center: .zero, camera: SIMD3(0, 0, 2), northAligned: true,
            regionRadius: 3)
        #expect(capture.analysis.stems.count == 1)
        #expect(capture.analysis.equivalentDBH == capture.analysis.dbh)
    }
}

/// A clump Gerardus sends as several TREES segments sharing a `tree_id` tag, read as one tree of several stems.
@Suite struct GerardusClumpTests {
    func line(_ id: String, base: SIMD3<Float>, tags: [String: String]) -> LineFeature {
        var line = try! LineFeature(fields: [])
        line.featureID = id
        line.kind = .tree
        line.xyz = [base.x, base.y, base.z, base.x, base.y, base.z + 4]
        line.tags = tags
        return line
    }

    @Test func segmentsSharingATreeIDAreOneTreeOfSeveralStems() throws {
        let lines = [
            line("ggp/1", base: SIMD3(10, 20, 30), tags: ["tree_id": "c7", "dbh_m": "0.3", "height_m": "12"]),
            line("ggp/2", base: SIMD3(11, 20.5, 30), tags: ["tree_id": "c7", "dbh_m": "0.4", "height_m": "14"]),
            line("ggp/3", base: SIMD3(40, 40, 30), tags: ["dbh_m": "0.5"]),
            line("ggp/4", base: SIMD3(10.2, 21, 30), tags: ["tree_id": "c7", "dbh_m": "0.24"]),
        ]
        let trees = GerardusTree.trees(lines)
        #expect(trees.map(\.id) == ["ggp/2", "ggp/3"])
        let clump = trees[0]
        // On the largest stem, with the tallest crown, every stem east and north of it.
        #expect(clump.base == SIMD3(11, 20.5, 30))
        #expect(clump.form.height == 14)
        #expect(clump.stems.count == 3)
        let west = try #require(clump.stems.first { $0.diameter.value == 0.3 })
        #expect(abs(west.east + 1) < 1e-6 && abs(west.north + 0.5) < 1e-6)
        #expect(abs(clump.equivalentDiameter - (0.09 + 0.16 + 0.0576).squareRoot()) < 1e-6)
        #expect(trees[1].stems.isEmpty)
        // And it is drawn with a trunk for each stem.
        let item = SiteWireframes.treeItem(id: clump.id, form: clump.form, at: .zero, stems: clump.stems)
        let single = SiteWireframes.treeItem(id: clump.id, form: clump.form, at: .zero)
        #expect(item.segments.count > single.segments.count)
    }
}
