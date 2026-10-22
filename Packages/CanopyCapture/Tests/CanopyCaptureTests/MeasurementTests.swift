import CanopyModel
import Foundation
import ModelIO
import Testing
import simd

@testable import CanopyCapture

@Suite struct CircleFitTests {
    @Test(arguments: [
        (span: 360.0, count: 120, noise: 0.003),
        (span: 180.0, count: 60, noise: 0.003),
        (span: 120.0, count: 50, noise: 0.002),
        (span: 90.0, count: 40, noise: 0.001),
    ])
    func diameterWithinOneCentimetre(span: Double, count: Int, noise: Double) throws {
        for (seed, radius) in [(UInt64(1), 0.08), (2, 0.21), (3, 0.6)] {
            let points = Synthetic.arc(
                center: SIMD2(1.3, -0.4), radius: radius, from: 0.7, through: span * .pi / 180, count: count,
                noise: noise, seed: seed)
            let circle = try CircleFit.fit(points)
            #expect(abs(2 * circle.radius - 2 * radius) < 0.01, "r \(radius) over \(span)°: \(circle.radius)")
            #expect(abs(circle.arc * 180 / .pi - span) < 5)
            #expect(circle.radiusUncertainty < 0.01)
            // The reported uncertainty is honest: the error is within four standard uncertainties.
            #expect(abs(circle.radius - radius) < 4 * circle.radiusUncertainty + 1e-4)
        }
    }

    @Test func exactPointsGiveTheExactCircle() throws {
        let points = Synthetic.arc(
            center: SIMD2(-2, 5), radius: 0.35, from: 0, through: .pi, count: 20, noise: 0, seed: 1)
        let circle = try CircleFit.fit(points)
        #expect(abs(circle.radius - 0.35) < 1e-9)
        #expect(abs(circle.center.x + 2) < 1e-9)
        #expect(abs(circle.center.y - 5) < 1e-9)
        #expect(circle.rmsResidual < 1e-9)
    }

    @Test func robustFitIgnoresOutliers() throws {
        var points = Synthetic.arc(
            center: .zero, radius: 0.25, from: 0, through: .pi, count: 80, noise: 0.002, seed: 7)
        var random = SeededRandom(state: 99)
        for _ in 0..<8 {
            points.append(SIMD2(random.unit() * 0.8 - 0.4, random.unit() * 0.8 - 0.4))
        }
        let plain = try CircleFit.fit(points)
        let robust = try CircleFit.robustFit(points)
        #expect(abs(2 * robust.radius - 0.5) < 0.01)
        #expect(robust.pointCount < points.count)
        #expect(abs(robust.radius - 0.25) <= abs(plain.radius - 0.25))
    }

    @Test func refusesTooFewOrDegeneratePoints() {
        #expect(throws: CircleFitError.tooFewPoints(3)) {
            try CircleFit.fit([.zero, SIMD2(1, 0), SIMD2(0, 1)])
        }
        let line = (0..<10).map { SIMD2(Double($0), 2 * Double($0)) }
        #expect(throws: CircleFitError.self) { try CircleFit.fit(line) }
    }
}

@Suite struct TrunkAnalysisTests {
    @Test(arguments: [0.12, 0.25, 0.45])
    func dbhWithinOneCentimetreFromAOneSidedScan(radius: Double) throws {
        let mesh = Synthetic.scannedTrunk(radius: radius, leanDegrees: 0, seed: UInt64(radius * 1000))
        let result = try TrunkAnalysis().measure(mesh, groundHeight: 0)
        #expect(abs(result.dbh.diameter.value - 2 * radius) < 0.01, "\(result.dbh.diameter.value)")
        #expect(result.dbh.diameter.uncertainty >= 0.005)
        #expect(result.dbh.diameter.uncertainty < 0.02)
        #expect(result.dbh.method == .lidarCircleFit)
        #expect(result.dbh.height == 1.37)
        #expect(abs(result.lean?.angle.value ?? 99) < 1.5)
    }

    @Test func respectsTheGroundHeight() throws {
        let mesh = Synthetic.scannedTrunk(radius: 0.2, leanDegrees: 0, ground: -1.4)
        let result = try TrunkAnalysis().measure(mesh, groundHeight: -1.4)
        #expect(abs(result.dbh.diameter.value - 0.4) < 0.01)
    }

    @Test func measuresLeanAndItsDirection() throws {
        let mesh = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 6, visibleDegrees: 200, seed: 3)
        let result = try TrunkAnalysis().measure(mesh, groundHeight: 0, northAligned: true)
        let lean = try #require(result.lean)
        #expect(abs(lean.angle.value - 6) < 1, "\(lean.angle.value)")
        // Leaning towards +x, which is east when the frame is north-aligned.
        let azimuth = try #require(lean.azimuth)
        #expect(abs(azimuth.value - 90) < 10, "\(azimuth.value)")
        // The horizontal section of a leaning trunk is slightly wider; still within a centimetre at 6°.
        #expect(abs(result.dbh.diameter.value - 0.6) < 0.01)
        #expect(result.stemCenters.count >= 5)
    }

    @Test func noAzimuthWithoutNorthAlignment() throws {
        let mesh = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 6, visibleDegrees: 200, seed: 3)
        #expect(try TrunkAnalysis().measure(mesh, groundHeight: 0).lean?.azimuth == nil)
    }

    @Test func refusesScansThatCannotSupportAFit() {
        let sliver = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, visibleDegrees: 40)
        #expect(throws: TrunkAnalysisError.self) { try TrunkAnalysis().measure(sliver, groundHeight: 0) }
        let short = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, height: 1.0)
        #expect(throws: TrunkAnalysisError.notEnoughPoints(0)) {
            try TrunkAnalysis().measure(short, groundHeight: 0)
        }
    }
}

@Suite struct MeshTests {
    @Test func cropKeepsTrianglesInsideTheCylinderAndRecentres() {
        let mesh = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0)
        let center = SIMD3<Float>(0, 1.37, 0)
        let cropped = mesh.cropped(around: center, radius: 0.5, below: 1.0, above: 1.0)
        #expect(!cropped.isEmpty)
        #expect(cropped.triangleCount < mesh.triangleCount)
        for p in cropped.positions {
            #expect((p.x * p.x + p.z * p.z).squareRoot() <= 0.5 + 1e-5)
            #expect(p.y >= -1.0 - 1e-5 && p.y <= 1.0 + 1e-5)
        }
        #expect(cropped.indices.allSatisfy { Int($0) < cropped.vertexCount })
    }

    @Test func sliceFindsEdgeCrossings() {
        let triangle = Mesh(positions: [SIMD3(0, 0, 0), SIMD3(2, 2, 0), SIMD3(0, 2, 2)], indices: [0, 1, 2])
        let points = triangle.slice(atHeight: 1).sorted { $0.x < $1.x }
        #expect(points == [SIMD2(0, 1), SIMD2(1, 0)])
        #expect(triangle.slice(atHeight: 3).isEmpty)
    }
}

@Suite struct PreviewAndGroundTests {
    @Test func groundHeightIsALowPercentileNearby() {
        let mesh = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, ground: -1.2, noise: 0.002)
        let ground = mesh.groundHeight(near: .zero, radius: 1.0)
        #expect(abs((ground ?? 0) + 1.2) < 0.02)
        #expect(mesh.groundHeight(near: SIMD2(50, 50)) == nil)
    }

    @Test func writesAUSDZPreview() throws {
        let mesh = Synthetic.scannedTrunk(radius: 0.3, leanDegrees: 0, height: 0.5)
        let url = try QuickLookPreview.usdz(for: mesh)
        defer { try? FileManager.default.removeItem(at: url) }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(url.pathExtension == "usdz")
        #expect(size > 1000)
        // ModelIO reads it back as one mesh (USD may split vertices per face for the preview normals).
        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        #expect(meshes.count == 1)
        #expect((meshes.first?.vertexCount ?? 0) >= mesh.vertexCount)
    }
}

@Suite struct USDZTests {
    @Test func archiveAlignsTheLayerAndChecksumsIt() {
        let payload = Data("#usda 1.0\n".utf8)
        let archive = [UInt8](USDZ.archive(fileName: "scan.usdc", contents: payload))
        #expect(Array(archive[0..<4]) == [0x50, 0x4B, 0x03, 0x04])
        let nameLength = Int(archive[26]) | Int(archive[27]) << 8
        let extraLength = Int(archive[28]) | Int(archive[29]) << 8
        let dataStart = 30 + nameLength + extraLength
        #expect(dataStart % 64 == 0)
        #expect(Array(archive[dataStart..<(dataStart + payload.count)]) == [UInt8](payload))
        #expect(archive.readUInt32(at: 14) == CRC32.checksum(payload))
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
