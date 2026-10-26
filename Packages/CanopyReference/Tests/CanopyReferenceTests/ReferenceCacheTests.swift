import Foundation
import Testing

@testable import CanopyReference

@Suite struct ReferenceCacheTests {
    func request(
        _ x: Double, _ y: Double, _ radius: Float, layers: [ReferenceLayer] = [.aerialPoints, .groundMesh],
        classes: [UInt32] = [1, 3, 4, 5], voxel: Float = 1
    ) -> StreamReferenceRequest {
        StreamReferenceRequest(
            l16Token: "8085876c1", layers: layers, centre: Vector3(x: x, y: y, z: 0), radius: radius, voxelSize: voxel,
            aerialClasses: classes)
    }

    func entry(_ request: StreamReferenceRequest, bundle: String = "sha256:a") -> ReferenceCache.Entry {
        ReferenceCache.Entry(
            file: "x", token: request.l16Token, bundleID: bundle, layers: request.layers.map(\.rawValue).sorted(),
            classes: request.aerialClasses.sorted(), voxel: ReferenceCache.voxel(request.voxelSize),
            centre: SIMD2(request.centre!.x, request.centre!.y), radius: request.radius, bytes: 1, lastUsed: .now)
    }

    @Test func aKeptStreamAnswersWhatItHolds() {
        let kept = entry(request(0, 0, 180))
        #expect(ReferenceCache.entry(kept, answers: request(5, 5, 170), bundleID: "sha256:a"))
        #expect(ReferenceCache.entry(kept, answers: request(0, 0, 100, layers: [.groundMesh]), bundleID: "sha256:a"))
        #expect(ReferenceCache.entry(kept, answers: request(0, 0, 100, classes: [1]), bundleID: "sha256:a"))
        // Too far, another bundle, more layers or classes, other voxels, the whole site.
        #expect(!ReferenceCache.entry(kept, answers: request(20, 0, 170), bundleID: "sha256:a"))
        #expect(!ReferenceCache.entry(kept, answers: request(0, 0, 100), bundleID: "sha256:b"))
        #expect(!ReferenceCache.entry(kept, answers: request(0, 0, 100, layers: [.footprints]), bundleID: "sha256:a"))
        #expect(!ReferenceCache.entry(kept, answers: request(0, 0, 100, classes: [2]), bundleID: "sha256:a"))
        #expect(!ReferenceCache.entry(kept, answers: request(0, 0, 100, voxel: 0.5), bundleID: "sha256:a"))
        #expect(!ReferenceCache.entry(kept, answers: request(0, 0, 0), bundleID: "sha256:a"))
        // A stream that asked for every class answers any but noise.
        let all = entry(request(0, 0, 0, classes: []))
        #expect(ReferenceCache.entry(all, answers: request(90, 90, 50, classes: [1, 2]), bundleID: "sha256:a"))
        #expect(!ReferenceCache.entry(all, answers: request(90, 90, 50, classes: [7]), bundleID: "sha256:a"))
    }

    @Test func framesRoundTrip() {
        let messages = [Data("one".utf8), Data(), Data(repeating: 9, count: 70_000)]
        #expect(ReferenceCache.unframe(ReferenceCache.frame(messages)) == messages)
        #expect(ReferenceCache.unframe(Data([0, 0, 0, 9, 1])) == nil)
    }

    @Test func patchesCoverWhatKeptCirclesLeave() throws {
        let wanted = Circle(centre: SIMD2(40, 0), radius: 170)
        // Nothing kept: asking for it all is cheaper.
        #expect(ReferencePatches.plan(wanted, kept: []) == nil)
        // A bigger kept circle round it: nothing to ask for.
        #expect(ReferencePatches.plan(wanted, kept: [Circle(centre: SIMD2(30, 0), radius: 190)]) == [])
        // 40 m off: a few small circles that, with the kept one, hold every point of the wanted circle.
        let kept = Circle(centre: .zero, radius: 180)
        let patches = try #require(ReferencePatches.plan(wanted, kept: [kept]))
        #expect((1...6).contains(patches.count))
        #expect(patches.reduce(0) { $0 + $1.area } < 0.6 * wanted.area)
        var missed = 0
        for angle in stride(from: 0.0, to: 2 * .pi, by: .pi / 360) {
            for distance in stride(from: 0.0, through: 170, by: 1) {
                let p = wanted.centre + SIMD2(cos(angle), sin(angle)) * distance
                if !kept.holds(Float(p.x), Float(p.y)) && !patches.contains(where: { $0.holds(Float(p.x), Float(p.y)) })
                {
                    missed += 1
                }
            }
        }
        #expect(missed == 0)
    }
}
