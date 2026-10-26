import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import CanopyHarness

/// Detection on the whole synthetic site, pinned: making detection faster must not move a single tree. When detection
/// is changed on purpose, check the score still holds and update the fingerprint.
@Suite struct DetectionRegressionTests {
    /// The whole site's canopy stream, decoded, without a server.
    static func wholeSite() throws -> (points: [PointBlock], ground: Heightfield, buildings: [[SIMD2<Double>]]) {
        let site = Shared.site
        var request = ProtoWriter()
        request.string(1, site.token)
        request.packedVarints(2, [ReferenceLayer.aerialPoints, .footprints, .groundMesh].map { UInt64($0.rawValue) })
        request.float(5, 1)
        request.packedVarints(6, AerialTrees.canopyClasses.map(UInt64.init))
        var points: [PointBlock] = []
        var ground: Heightfield?
        var buildings: [[SIMD2<Double>]] = []
        for event in StandInAlign(site: site).answer(AlignClient.site + "StreamReference", [UInt8](request.data)).events
        {
            switch try ReferenceMessage(serialized: event.data).chunk {
            case .points(_, let block): points.append(block)
            case .groundMesh(let field): ground = field
            case .lines(_, let lines): buildings += lines.filter { $0.kind == .building }.map(\.points)
            default: break
            }
        }
        return (points, try #require(ground), buildings)
    }

    /// Sums that change if any tree moves, grows or shrinks.
    static func fingerprint(_ trees: [TreeDetector.Tree]) -> String {
        let sums = trees.reduce(into: [0.0, 0, 0, 0, 0, 0]) { s, t in
            s[0] += t.x
            s[1] += t.y
            s[2] += t.height
            s[3] += t.crownRadius
            s[4] += t.confidence
            s[5] += Double(t.pointCount)
        }
        return "\(trees.count) " + sums.map { String(format: "%.4f", $0) }.joined(separator: " ")
    }

    static func fingerprint(_ chm: TreeDetector.CanopyHeightModel?) -> String {
        guard let chm else { return "none" }
        let sum = chm.heights.reduce(0.0) { $0 + Double($1) }
        return "\(chm.nx)×\(chm.ny) " + String(format: "%.3f", sum)
    }

    @Test func wholeSiteDetectionIsUnchanged() throws {
        let (points, ground, buildings) = try Self.wholeSite()
        let detector = TreeDetector()
        let trees = detector.detect(points: points, ground: ground, buildings: buildings)
        let chm = detector.canopyHeightModel(points: points, ground: ground)
        print("FINGERPRINT trees \(Self.fingerprint(trees))")
        print("FINGERPRINT canopy \(Self.fingerprint(chm))")
        #expect(Self.fingerprint(trees) == Self.trees)
        #expect(Self.fingerprint(chm) == Self.canopy)
    }

    static let trees = "1865 15336.7500 -9360.2500 46288.1554 7581.6807 1676.3800 573807.0000"
    static let canopy = "899×899 5681594.374"
}
