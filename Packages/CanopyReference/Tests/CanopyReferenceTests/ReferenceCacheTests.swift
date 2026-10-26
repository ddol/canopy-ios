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

    @Test func theSameServerGetsTheSameCache() throws {
        let a = try #require(ReferenceCache.caches(for: URL(string: "http://gerardus.local:50061")!))
        let b = try #require(ReferenceCache.caches(for: URL(string: "http://gerardus.local:50061")!))
        let other = try #require(ReferenceCache.caches(for: URL(string: "http://gerardus.local:50062")!))
        #expect(a === b)
        #expect(a !== other)
        #expect(a.directory != other.directory)
    }

    @Test func filesTheIndexDoesNotNameAreTidiedAway() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "tidy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let streams = folder.appending(path: "streams")
        try FileManager.default.createDirectory(at: streams, withIntermediateDirectories: true)
        // A stream written but never indexed, and an index entry whose stream is gone.
        try Data([1, 2, 3]).write(to: streams.appending(path: "orphan.grpc"))
        let missing = entry(request(0, 0, 100))
        try JSONEncoder().encode([missing]).write(to: streams.appending(path: "index.json"))
        let cache = ReferenceCache(directory: folder)
        #expect(cache.streamBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: streams.appending(path: "orphan.grpc").path))
    }

    /// Every point of the wanted circle is in a kept circle or a patch, whatever the radii (the samples once stopped
    /// up to a spacing short of the far edge).
    @Test func patchesLeaveNoGaps() throws {
        // The case that found it: 2r is not a multiple of the spacing.
        let wanted = Circle(centre: .zero, radius: 22.45)
        let kept = Circle(centre: SIMD2(-30, 0), radius: 52)
        let patches = try #require(ReferencePatches.plan(wanted, kept: [kept], maxShare: 1))
        #expect(kept.holds(22.4, 0) || patches.contains { $0.holds(22.4, 0) })

        var random = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let r = Float.random(in: 8...200, using: &random)
            let wanted = Circle(
                centre: SIMD2(Double.random(in: -50...50, using: &random), Double.random(in: -50...50, using: &random)),
                radius: r)
            let offset = Double.random(in: 0...Double(r), using: &random)
            let angle = Double.random(in: 0..<(2 * .pi), using: &random)
            let kept = Circle(
                centre: wanted.centre + SIMD2(cos(angle), sin(angle)) * offset,
                radius: r + Float.random(in: -5...10, using: &random))
            guard let patches = ReferencePatches.plan(wanted, kept: [kept], maxShare: 1) else { continue }
            for ring in stride(from: 0.0, through: 1, by: 0.02) {
                for step in 0..<180 {
                    let a = Double(step) * .pi / 90
                    let p = wanted.centre + SIMD2(cos(a), sin(a)) * Double(r) * ring
                    let (x, y) = (Float(p.x), Float(p.y))
                    guard wanted.holds(x, y) else { continue }
                    #expect(kept.holds(x, y) || patches.contains { $0.holds(x, y) }, "gap at \(p) for r \(r)")
                }
            }
        }
    }
}
