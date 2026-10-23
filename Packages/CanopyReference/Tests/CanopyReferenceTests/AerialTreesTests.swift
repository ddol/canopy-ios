import CanopyModel
import Foundation
import Testing

@testable import CanopyReference

@Suite struct AerialTreesTests {
    @Test func idsAreStableAndDistinct() {
        let a = GeoPoint(latitude: 37.769652, longitude: -122.475737)
        let nearby = GeoPoint(latitude: 37.7696521, longitude: -122.4757371)  // within the rounding
        let other = GeoPoint(latitude: 37.769752, longitude: -122.475737)  // 11 m north
        #expect(AerialTrees.stableID(a) == AerialTrees.stableID(nearby))
        #expect(AerialTrees.stableID(a) != AerialTrees.stableID(other))
        #expect(AerialTrees.stableID(a).uuidString.dropFirst(14).first == "8")
    }

    @Test func treesBecomeRealCandidatesOnTheMap() throws {
        let origin = GeoPoint(latitude: 37.769652, longitude: -122.475737)
        let frame = LocalFrame(origin: origin)
        let samples = [(0.0, 0.0), (100, 0), (0, 100)].map { e, n in
            (geo: frame.geoPoint(of: ENU(east: e, north: n, up: 0)).point, site: SIMD2(e + 1.57, n - 0.16))
        }
        let georef = try SiteGeoreference(origin: origin, samples: samples)
        let tree = TreeDetector.Tree(
            x: 11.57, y: 19.84, ground: 88, height: 23.46, crownRadius: 4.04, pointCount: 400, confidence: 0.83)
        let candidate = try #require(AerialTrees.candidates([tree], georeference: georef, source: "USGS 3DEP").first)
        let enu = frame.enu(of: candidate.location)
        #expect(abs(enu.east - 10) < 0.001)
        #expect(abs(enu.north - 20) < 0.001)
        #expect(candidate.height == 23.5)
        #expect(candidate.crownRadius == 4.0)
        #expect(!candidate.isSynthetic)
        #expect(candidate.source == "USGS 3DEP")
        #expect(candidate.makeTree().countStatus == .detected)
    }

    @Test func groundModelFromReturnsFillsSmallGaps() throws {
        // Ground returns on a 10 m × 10 m patch every 0.5 m, sloping 1 in 10 to the east, with a hole in the middle.
        var block = PointBlock()
        for i in stride(from: 0.0, through: 10, by: 0.5) {
            for j in stride(from: 0.0, through: 10, by: 0.5) where !(4...6).contains(i) || !(4...6).contains(j) {
                block.x.append(Float(i))
                block.y.append(Float(j))
                block.z.append(Float(80 + i / 10))
            }
        }
        let field = try #require(Heightfield(groundPoints: [block], cellSize: 1))
        #expect(field.nx == 11)
        #expect(field.z.allSatisfy { $0.isFinite })
        #expect(abs((field.height(x: 2.5, y: 2.5) ?? 0) - 80.2) < 0.06)
        #expect(abs((field.height(x: 5, y: 5) ?? 0) - 80.5) < 0.15)
    }
}

@Suite(.enabled(if: Live.enabled), .serialized) struct LiveAerialTreesTests {
    @Test func loadsRealCandidatesForStowLake() async throws {
        let stages = Stages()
        let result = try await AerialTrees.load(
            tile: try #require(S2CellID(token: Live.stowLake)), label: "ggp-stow-lake", client: Live.client
        ) { stages.append($0) }
        print("AERIAL \(result.candidates.count) candidates from \(result.pointCount) points; \(result.attribution)")
        #expect(result.candidates.count > 1000)
        #expect(result.tiles.count == 9)
        #expect(result.attribution.contains { $0.contains("3D Elevation Program") })
        #expect(result.candidates.allSatisfy { !$0.isSynthetic && $0.source?.contains("3DEP") == true })
        #expect(Set(result.candidates.map(\.id)).count == result.candidates.count)
        // A site answers for its own tiles only.
        #expect(result.candidates.allSatisfy { result.tiles.contains($0.location.tile) })
        #expect(stages.values.contains(.detecting))
    }

    final class Stages: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [AerialTrees.Stage] = []
        func append(_ stage: AerialTrees.Stage) { lock.withLock { stored.append(stage) } }
        var values: [AerialTrees.Stage] { lock.withLock { stored } }
    }
}
