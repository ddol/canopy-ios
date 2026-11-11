import CanopyModel
import Foundation
import Testing
import simd

@testable import CanopyCapture

/// Meshes for fitting rings: upright trunks walked all the way round, on uneven ground.
enum StemMesh {
    /// A trunk of `radius` round `centre` (x, z) from `bottom` to `top`, triangles about 3 cm across.
    static func cylinder(
        centre: SIMD2<Double>, radius: Double, from bottom: Double, to top: Double, arcDegrees: Double = 360
    ) -> Mesh {
        var mesh = Mesh.empty
        let rows = max(1, Int((top - bottom) / 0.03))
        let columns = max(4, Int(arcDegrees * .pi / 180 * radius / 0.03))
        for row in 0...rows {
            let y = bottom + (top - bottom) * Double(row) / Double(rows)
            for column in 0...columns {
                let angle = arcDegrees * .pi / 180 * Double(column) / Double(columns)
                mesh.positions.append(
                    SIMD3(Float(centre.x + cos(angle) * radius), Float(y), Float(centre.y + sin(angle) * radius)))
            }
        }
        let width = UInt32(columns + 1)
        for row in 0..<UInt32(rows) {
            for column in 0..<UInt32(columns) {
                let a = row * width + column
                mesh.indices += [a, a + width, a + 1, a + 1, a + width, a + width + 1]
            }
        }
        return mesh
    }

    /// Ground 3 m across that rises about 10 cm from west to east, so a slice near the ground crosses it all over.
    static func slopedGround(at height: Double = 0) -> Mesh {
        var mesh = Mesh.empty
        let cells = 30
        for i in 0...cells {
            for j in 0...cells {
                let x = -1.5 + 3 * Double(i) / Double(cells)
                let z = -1.5 + 3 * Double(j) / Double(cells)
                mesh.positions.append(SIMD3(Float(x), Float(height - 0.047 + (x + 1.5) / 31), Float(z)))
            }
        }
        let side = UInt32(cells + 1)
        for i in 0..<UInt32(cells) {
            for j in 0..<UInt32(cells) {
                let a = i * side + j
                mesh.indices += [a, a + 1, a + side, a + 1, a + side + 1, a + side]
            }
        }
        return mesh
    }

    /// A trunk 0.6 m across that forks 1.8 m up into two stems 0.3 m across, 0.5 m apart.
    static func forked() -> Mesh {
        var mesh = cylinder(centre: .zero, radius: 0.3, from: -0.1, to: 1.8)
        mesh.append(cylinder(centre: SIMD2(-0.25, 0), radius: 0.15, from: 1.8, to: 4.5))
        mesh.append(cylinder(centre: SIMD2(0.25, 0), radius: 0.15, from: 1.8, to: 4.5))
        mesh.append(slopedGround())
        return mesh
    }
}

@Suite struct TrunkStemsTests {
    @Test func aRingAtTheGroundLeavesTheGroundOut() throws {
        var mesh = StemMesh.cylinder(centre: SIMD2(0.1, -0.05), radius: 0.4, from: -0.2, to: 2)
        mesh.append(StemMesh.slopedGround())
        let scan = SavedScan(mesh: mesh)
        // Every triangle the plane crosses, ground and all, is not a trunk.
        let everything = mesh.sectionSlices(atHeight: 0)
        #expect(everything.count > mesh.trunkSlices(atHeight: 0).count + 50)
        let ring = try scan.snapping(TreeSection(part: .trunk, height: 0, radius: 0.2), groundHeight: 0)
        #expect(abs(ring.radius - 0.4) < 0.01, "\(ring.radius)")
        #expect(simd_distance(try #require(ring.offset), SIMD2(0.1, -0.05)) < 0.01)
    }

    @Test func aRingSnapsToTheTrunkNearestIt() throws {
        var mesh = StemMesh.cylinder(centre: .zero, radius: 0.3, from: 0, to: 3)
        // A post a metre and a half away.
        mesh.append(StemMesh.cylinder(centre: SIMD2(1.5, 0), radius: 0.06, from: 0, to: 3))
        let scan = SavedScan(mesh: mesh)
        let trunk = try scan.snapping(TreeSection(part: .trunk, height: 1, radius: 0.2), groundHeight: 0)
        #expect(abs(trunk.radius - 0.3) < 0.01)
        let post = try scan.snapping(
            TreeSection(part: .trunk, height: 1, radius: 0.2, offset: SIMD2(1.4, 0)), groundHeight: 0)
        #expect(abs(post.radius - 0.06) < 0.01)
    }

    @Test func aTrunkScannedInTwoPiecesIsOneTrunk() {
        // Two arcs of one trunk with a gap between them wider than a piece's gap.
        var mesh = StemMesh.cylinder(centre: .zero, radius: 0.35, from: 0, to: 2, arcDegrees: 120)
        var other = StemMesh.cylinder(centre: .zero, radius: 0.35, from: 0, to: 2, arcDegrees: 120)
        other.positions = other.positions.map { p in
            // Turned 180° round the axis.
            SIMD3(-p.x, p.y, -p.z)
        }
        mesh.append(other)
        let rings = TrunkStems.rings(through: mesh.trunkSlices(atHeight: 1))
        #expect(rings.count == 1)
        #expect(abs((rings.first?.radius ?? 0) - 0.35) < 0.01)
    }

    @Test func aForkedTrunkSplitsIntoAStemPerRingAboveTheFork() throws {
        let scan = SavedScan(mesh: StemMesh.forked())
        let profile = TreeProfile(form: TreeForm(trunkDiameter: 0.5, height: 12, crownHeight: 8, crownWidth: 6))
        let (snapped, count, stems) = scan.snappingTrunk(profile, groundHeight: 0)
        #expect(stems == 2)
        // Below the fork, one ring at 0 and 1 m; above it, two at each of 2, 3 and 4 m.
        #expect(snapped.mainTrunk.map(\.height) == [0, 1])
        #expect(count == 2 + 3 * 2)
        for (stem, rings) in snapped.stems {
            #expect(rings.map(\.height) == [2, 3, 4])
            #expect(rings.allSatisfy { abs($0.radius - 0.15) < 0.01 && $0.source == .scan })
            // Each stem keeps its number up the tree.
            let side = rings.map { $0.offset!.x.sign }
            #expect(Set(side).count == 1, "stem \(stem)")
        }
        #expect(snapped.mainTrunk.allSatisfy { abs($0.radius - 0.3) < 0.01 })
        // Snapping again changes nothing.
        let (again, _, _) = scan.snappingTrunk(snapped, groundHeight: 0)
        #expect(again.stems.mapValues { $0.map(\.id) } == snapped.stems.mapValues { $0.map(\.id) })
    }

    @Test func oneRingSplitsWhereThePlayerAsks() throws {
        let scan = SavedScan(mesh: StemMesh.forked())
        let ring = TreeSection(part: .trunk, height: 2.5, radius: 0.3)
        let profile = TreeProfile(sections: [TreeSection(part: .trunk, height: 1, radius: 0.3), ring])
        let (split, ids) = try #require(scan.splitting(profile, at: ring.id, groundHeight: 0))
        #expect(ids.count == 2)
        #expect(split.section(ring.id) == nil)
        #expect(Set(ids.compactMap { split.section($0)?.stem }) == [0, 1])
        // The ring below the fork shows one trunk, so it does not split.
        let below = try #require(profile.trunk.first)
        #expect(scan.splitting(profile, at: below.id, groundHeight: 0) == nil)
    }

    @Test func theStemsFunnelIntoTheTrunkBelowTheFork() {
        let trunk = [0.0, 1].map { TreeSection(part: .trunk, height: $0, radius: 0.3) }
        let left = [2.0, 3].map {
            TreeSection(part: .trunk, height: $0, radius: 0.15, offset: SIMD2(-0.25, 0), stem: 0)
        }
        let right = [2.0, 3].map {
            TreeSection(part: .trunk, height: $0, radius: 0.15, offset: SIMD2(0.25, 0), stem: 1)
        }
        // A ring on no stem above the fork, as left from before it was split.
        let high = TreeSection(part: .trunk, height: 4, radius: 0.3)
        let profile = TreeProfile(sections: trunk + left + right + [high])
        let joins = WireframeTree.joins(profile.trunk).map { [$0.0.id, $0.1.id] }
        #expect(joins.contains([trunk[0].id, trunk[1].id]))
        #expect(joins.contains([trunk[1].id, left[0].id]))
        #expect(joins.contains([trunk[1].id, right[0].id]))
        #expect(joins.contains([left[0].id, left[1].id]))
        #expect(joins.contains([right[0].id, right[1].id]))
        // Not across the fork from the trunk to the ring above it, nor from one stem to the other.
        #expect(!joins.contains([trunk[1].id, high.id]))
        #expect(!joins.contains { $0.contains(left[1].id) && $0.contains(right[0].id) })
        #expect(joins.count == 5)
    }

    @Test func aRingOnAStemIsAddedUpThatStem() throws {
        let stem = TreeSection(part: .trunk, height: 2, radius: 0.15, offset: SIMD2(0.25, 0), stem: 1)
        var profile = TreeProfile(sections: [TreeSection(part: .trunk, height: 0, radius: 0.3), stem])
        let addedID = profile.addSection(above: stem.id)
        let added = try #require(addedID)
        let ring = try #require(profile.section(added))
        #expect(ring.stem == 1)
        #expect(ring.height == 3)
        #expect(ring.offset == SIMD2(0.25, 0))
    }
}

@Suite struct ReachingTheCrownTests {
    @Test func aForkedTrunksStemsGoOnUpToTheCrown() throws {
        // The forked scan only reaches 4.5 m; the crown starts at 7 m.
        let scan = SavedScan(mesh: StemMesh.forked())
        let profile = TreeProfile(form: TreeForm(trunkDiameter: 0.5, height: 15, crownHeight: 8, crownWidth: 6))
        let (snapped, _, stems) = scan.snappingTrunk(profile, groundHeight: 0)
        #expect(stems == 2)
        // No ring on no stem above the fork.
        #expect(snapped.mainTrunk.allSatisfy { $0.height < 1.8 })
        for (_, rings) in snapped.stems {
            #expect(rings.map(\.height) == [2, 3, 4, 5, 6, 7])
            // Each carries on up its own side.
            let side = rings.map { $0.offset!.x.sign }
            #expect(Set(side).count == 1)
            let added = rings.filter { $0.height > 4.5 }
            #expect(added.allSatisfy { $0.source == .eye && abs($0.radius - 0.15) < 0.01 })
            #expect(abs(added.last!.offset!.x) - 0.25 < 0.05)
        }
    }

    @Test func aTrunkWithNoForkGoesUpToTheCrownsBase() {
        let profile = TreeProfile(sections: [
            TreeSection(part: .trunk, height: 0, radius: 0.3, source: .scan, offset: .zero),
            TreeSection(part: .trunk, height: 1, radius: 0.29, source: .scan, offset: SIMD2(0.02, 0)),
            TreeSection(part: .trunk, height: 2, radius: 0.28, source: .scan, offset: SIMD2(0.04, 0)),
            TreeSection(part: .trunk, height: 9, radius: 0.5),
            TreeSection(part: .crown, height: 6.5, radius: 3),
            TreeSection(part: .crown, height: 12, radius: 3),
        ])
        let reached = profile.reachingCrown()
        // The ring set by eye above the crown's base goes; the steps and the crown's base are added on the line.
        #expect(reached.trunk.map(\.height) == [0, 1, 2, 3, 4, 5, 6, 6.5])
        let top = reached.trunk.last!
        #expect(abs(top.offset!.x - 0.13) < 0.005)
        #expect(abs(top.radius - 0.235) < 0.005)
    }
}

@Suite struct AerialRegistrationTests {
    /// Aerial returns off the forked trunk's bark and the crown, as the census position misplaces them.
    func aerial(shift: SIMD2<Double>) -> [SIMD3<Float>] {
        var random = SeededRandom(state: 5)
        var points: [SIMD3<Float>] = []
        func bark(centre: SIMD2<Double>, radius: Double, from bottom: Double, to top: Double, count: Int) {
            for _ in 0..<count {
                let angle = random.unit() * 2 * .pi
                let h = bottom + (top - bottom) * random.unit()
                points.append(
                    SIMD3(
                        Float(centre.x + cos(angle) * radius + shift.x), Float(h),
                        Float(centre.y + sin(angle) * radius + shift.y)))
            }
        }
        bark(centre: .zero, radius: 0.3, from: 0.6, to: 1.8, count: 15)
        bark(centre: SIMD2(-0.25, 0), radius: 0.15, from: 1.8, to: 4.4, count: 15)
        bark(centre: SIMD2(0.25, 0), radius: 0.15, from: 1.8, to: 4.4, count: 15)
        // Leaves and branches all round, mostly above the scan.
        for _ in 0..<800 {
            points.append(
                SIMD3(Float(random.unit() * 12 - 6), Float(2 + random.unit() * 10), Float(random.unit() * 12 - 6)))
        }
        return points
    }

    @Test func theAerialPointsMoveOntoTheScannedStems() throws {
        let mesh = StemMesh.forked()
        let registration = try #require(
            AerialRegistration.register(aerial(shift: SIMD2(1.3, -0.8)), to: mesh, groundHeight: 0))
        #expect(simd_distance(registration.shift, SIMD2(-1.3, 0.8)) < 0.1, "\(registration)")
        #expect(registration.matched >= 35)
        #expect(registration.matched > registration.matchedBefore)
    }

    @Test func pointsAlreadyOnTheTrunkStay() throws {
        let registration = try #require(
            AerialRegistration.register(aerial(shift: .zero), to: StemMesh.forked(), groundHeight: 0))
        #expect(simd_length(registration.shift) < 0.1)
    }

    @Test func noTrunkReturnsNoRegistration() {
        var random = SeededRandom(state: 9)
        let leaves = (0..<300).map { _ in
            SIMD3(Float(random.unit() * 12 - 6), Float(6 + random.unit() * 6), Float(random.unit() * 12 - 6))
        }
        #expect(AerialRegistration.register(leaves, to: StemMesh.forked(), groundHeight: 0) == nil)
    }
}
