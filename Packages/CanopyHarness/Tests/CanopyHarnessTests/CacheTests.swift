import CanopyModel
import CanopyReference
import Foundation
import Testing

@testable import CanopyHarness

/// Loading through `ReferenceCache` against the stand-in: what goes over the wire, and that kept data gives exactly
/// what the server would have sent.
@Suite struct CacheTests {
    let site = Shared.site
    var tile: S2CellID { S2CellID(token: site.token)! }

    func temporaryCache() -> ReferenceCache {
        ReferenceCache(directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
    }

    func area(_ x: Double, _ y: Double, _ radius: Double) -> AerialTrees.Area {
        AerialTrees.Area(centre: site.geo(SIMD2(x, y)), radius: radius)
    }

    @Test func aLoadFromTheCacheFindsTheSameTreesAsADownload() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }

        let first = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        #expect(!first.fromCache)
        #expect(server.stats.calls("StreamReference") == 1)

        // Smaller and off-centre, but inside: from the cache, cut as the server would cut it.
        let inner = area(80, -20, 90)
        server.resetStats()
        let kept = try await AerialTrees.load(tile: tile, area: inner, label: "test", client: client, cache: cache)
        #expect(kept.fromCache)
        #expect(onlyChecked(server.stats))
        let fresh = try await AerialTrees.load(tile: tile, area: inner, label: "test", client: client)
        #expect(!fresh.fromCache)
        #expect(kept.pointCount == fresh.pointCount)
        #expect(kept.candidates == fresh.candidates)
        #expect(kept.canopy?.heights == fresh.canopy?.heights)
        #expect(kept.lines == fresh.lines)
    }

    @Test func eachLoadAsksOnlyForWhatItHasNot() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let cache = temporaryCache()
        defer { cache.removeAll() }
        var client = AlignClient(baseURL: server.url)

        _ = try await AerialTrees.load(tile: tile, area: area(0, 0, 150), label: "test", client: client, cache: cache)
        let first = server.stats
        #expect(first.calls("GetSite") == 1)
        #expect(first.calls("PoseFromHint") >= 6)
        #expect(first.calls("StreamReference") == 1)

        // The same area again: the site is checked, nothing else.
        server.resetStats()
        _ = try await AerialTrees.load(tile: tile, area: area(0, 0, 150), label: "test", client: client, cache: cache)
        #expect(onlyChecked(server.stats))
        #expect(server.stats.totalBytes < 2_000)

        // After a relaunch: a new client and a new cache object on the same folder.
        client = AlignClient(baseURL: server.url)
        let relaunched = ReferenceCache(directory: cache.directory)
        server.resetStats()
        let again = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 100), label: "test", client: client, cache: relaunched)
        #expect(again.fromCache)
        #expect(onlyChecked(server.stats))

        // Somewhere it has not been: points again, but not the georeference.
        server.resetStats()
        let moved = try await AerialTrees.load(
            tile: tile, area: area(-100, 80, 120), label: "test", client: client, cache: relaunched)
        #expect(!moved.fromCache)
        #expect(server.stats.calls("GetSite") == 1 && server.stats.calls("PoseFromHint") == 0)
        #expect(server.stats.bytes("StreamReference") > 100_000)

        // The whole site answers for every area after it.
        _ = try await AerialTrees.load(tile: tile, label: "test", client: client, cache: relaunched)
        server.resetStats()
        let anywhere = try await AerialTrees.load(
            tile: tile, area: area(150, 150, 60), label: "test", client: client, cache: relaunched)
        #expect(anywhere.fromCache)
        #expect(onlyChecked(server.stats))
    }

    @Test func aLoadAFewMetresAwayUsesTheKeptPoints() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }
        _ = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        // The first load asked for a little more than its area and margin, and kept it.
        #expect(server.stats.calls("StreamReference") == 1)

        // The map settled 8 m away: still inside, and the same trees as a download there would find.
        let nudged = area(66, -35, 150)
        server.resetStats()
        let kept = try await AerialTrees.load(tile: tile, area: nudged, label: "test", client: client, cache: cache)
        #expect(kept.fromCache)
        #expect(onlyChecked(server.stats))
        let fresh = try await AerialTrees.load(tile: tile, area: nudged, label: "test", client: client)
        #expect(kept.candidates == fresh.candidates)
        #expect(kept.pointCount == fresh.pointCount)

        // 40 m away is not.
        server.resetStats()
        let moved = try await AerialTrees.load(
            tile: tile, area: area(100, -40, 150), label: "test", client: client, cache: cache)
        #expect(!moved.fromCache)
    }

    @Test func aNewBundleIsDownloadedAgain() async throws {
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        _ = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 100), label: "test", client: AlignClient(baseURL: server.url), cache: cache)
        server.stop()

        // The server prepared the site again from new inputs: same tile, new bundle.
        let rebuilt = SyntheticSite(seed: 2)
        let next = StandInServer(align: StandInAlign(site: rebuilt))
        try await next.start()
        defer { next.stop() }
        let result = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 100), label: "test", client: AlignClient(baseURL: next.url), cache: cache)
        #expect(!result.fromCache)
        #expect(next.stats.calls("StreamReference") == 1)
        #expect(result.site.bundleID == rebuilt.bundleID)
    }

    @Test func keptAreasLoadWithoutTheServer() async throws {
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        let url = server.url
        let online = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 150), label: "test", client: AlignClient(baseURL: url), cache: cache)
        server.stop()

        let offline = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 150), label: "test", client: AlignClient(baseURL: url), cache: cache)
        #expect(offline.fromCache)
        #expect(offline.candidates == online.candidates)

        // Somewhere not kept still fails, with the connection error.
        await #expect(throws: (any Error).self) {
            _ = try await AerialTrees.load(
                tile: tile, area: area(-150, 150, 60), label: "test", client: AlignClient(baseURL: url), cache: cache)
        }
    }

    @Test func oldStreamsAreEvicted() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let areas = [area(-120, 0, 60), area(0, 0, 60), area(120, 0, 60)]
        // How big each area's stream is.
        var sizes: [Int] = []
        for a in areas {
            let measure = temporaryCache()
            _ = try await AerialTrees.load(tile: tile, area: a, label: "test", client: client, cache: measure)
            sizes.append(measure.streamBytes)
            measure.removeAll()
        }
        // Room for the last two, not all three: the first, least recently used, goes.
        let limit = sizes[1] + sizes[2] + 1
        let cache = ReferenceCache(
            directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"),
            byteLimit: limit)
        defer { cache.removeAll() }
        for a in areas {
            _ = try await AerialTrees.load(tile: tile, area: a, label: "test", client: client, cache: cache)
        }
        #expect(cache.streamBytes == sizes[1] + sizes[2])
        server.resetStats()
        _ = try await AerialTrees.load(tile: tile, area: areas[2], label: "test", client: client, cache: cache)
        #expect(onlyChecked(server.stats))
        server.resetStats()
        _ = try await AerialTrees.load(tile: tile, area: areas[0], label: "test", client: client, cache: cache)
        #expect(server.stats.bytes("StreamReference") > 100_000)
    }
}

/// A load that found everything kept: the site checked, and at most a probe of the site model a few hundred bytes long.
func onlyChecked(_ stats: StandInServer.Stats) -> Bool {
    stats.calls("GetSite") == 1 && stats.calls("StreamReference") <= 1 && stats.bytes("StreamReference") < 2_000
        && stats.totalCalls <= 2
}

/// Loads that kept circles hold only part of: the rest is asked for in small circles, and the trees are the same.
@Suite struct ComposedLoadTests {
    let site = Shared.site
    var tile: S2CellID { S2CellID(token: site.token)! }

    func area(_ x: Double, _ y: Double, _ radius: Double) -> AerialTrees.Area {
        AerialTrees.Area(centre: site.geo(SIMD2(x, y)), radius: radius)
    }

    @Test func aPannedLoadAsksOnlyForWhatIsNew() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = ReferenceCache(
            directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
        defer { cache.removeAll() }
        _ = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        server.resetStats()
        _ = try await AerialTrees.load(tile: tile, area: area(100, -40, 150), label: "test", client: client)
        let whole = server.stats.bytes("StreamReference")

        // Panned 40 m east: the kept circle holds most of it.
        server.resetStats()
        let panned = try await AerialTrees.load(
            tile: tile, area: area(100, -40, 150), label: "test", client: client, cache: cache)
        let composed = server.stats
        print("PANNED \(composed.bytes("StreamReference")) of \(whole) bytes in \(composed.calls) calls")
        #expect(composed.bytes("StreamReference") * 2 < whole)
        #expect(composed.calls("StreamReference") >= 2)  // patches and the ground

        // The same trees as one request for it all.
        let fresh = try await AerialTrees.load(tile: tile, area: area(100, -40, 150), label: "test", client: client)
        #expect(panned.pointCount == fresh.pointCount)
        #expect(panned.candidates == fresh.candidates)
        #expect(panned.canopy?.heights == fresh.canopy?.heights)
        #expect(Set(panned.lines.map(\.featureID)) == Set(fresh.lines.map(\.featureID)))

        // And now that area is all kept.
        server.resetStats()
        let again = try await AerialTrees.load(
            tile: tile, area: area(100, -40, 150), label: "test", client: client, cache: cache)
        #expect(onlyChecked(server.stats))
        #expect(again.candidates == fresh.candidates)
    }

    @Test func farAwayIsOneRequest() async throws {
        let server = StandInServer(align: StandInAlign(site: site))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = ReferenceCache(
            directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
        defer { cache.removeAll() }
        _ = try await AerialTrees.load(
            tile: tile, area: area(-100, 0, 100), label: "test", client: client, cache: cache)
        server.resetStats()
        // Overlapping a little: not worth piecing together.
        _ = try await AerialTrees.load(tile: tile, area: area(80, 0, 100), label: "test", client: client, cache: cache)
        #expect(server.stats.calls("StreamReference") == 1)
    }
}

/// What the cache must never keep or reuse.
@Suite struct CacheSafetyTests {
    let site = Shared.site
    var tile: S2CellID { S2CellID(token: site.token)! }

    func area(_ x: Double, _ y: Double, _ radius: Double) -> AerialTrees.Area {
        AerialTrees.Area(centre: site.geo(SIMD2(x, y)), radius: radius)
    }

    func temporaryCache() -> ReferenceCache {
        ReferenceCache(directory: FileManager.default.temporaryDirectory.appending(path: "cache-\(UUID().uuidString)"))
    }

    @Test func aStreamCutShortIsNeitherUsedNorKept() async throws {
        let align = StandInAlign(site: site)
        let server = StandInServer(align: align)
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }
        // The server fails after two blocks; over HTTP/1.1 the client only sees the stream end.
        align.cutAfter = 2
        await #expect(throws: GRPCTransportError.incomplete) {
            _ = try await AerialTrees.load(
                tile: tile, area: area(0, 0, 150), label: "test", client: client, cache: cache)
        }
        #expect(cache.streamBytes == 0)
        await #expect(throws: GRPCTransportError.incomplete) {
            _ = try await AerialTrees.load(tile: tile, area: area(0, 0, 150), label: "test", client: client)
        }
        align.cutAfter = nil
        let whole = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 150), label: "test", client: client, cache: cache)
        #expect(!whole.fromCache)
        #expect(whole.candidates.count > 100)
    }

    @Test func aCancelledLoadKeepsNothing() async throws {
        let server = StandInServer(
            align: StandInAlign(site: site),
            profile: NetworkProfile(name: "slow", rtt: .zero, bytesPerSecond: 2_000_000))
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let tile = tile
        let area = area(0, 0, 150)
        let load = Task {
            try await AerialTrees.load(tile: tile, area: area, label: "test", client: client, cache: cache)
        }
        try await Task.sleep(for: .milliseconds(600))
        load.cancel()
        _ = await load.result
        #expect(cache.streamBytes == 0)
    }

    @Test func keptGroundFollowsTheSiteModel() async throws {
        let align = StandInAlign(site: site)
        let server = StandInServer(align: align)
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let before = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)

        // An operator accepts a scan: the ground model changes; the bundle, and so the points, do not.
        align.acceptScan(raise: 0.5)
        server.resetStats()
        let after = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        let fresh = try await AerialTrees.load(tile: tile, area: area(60, -40, 150), label: "test", client: client)
        #expect(after.candidates == fresh.candidates)
        #expect(after.canopy?.heights == fresh.canopy?.heights)
        #expect(after.candidates.map(\.height) != before.candidates.map(\.height))

        // Only the ground came down again, and now it is kept for the new model, a little wider, like any load.
        server.resetStats()
        let again = try await AerialTrees.load(
            tile: tile, area: area(60, -40, 150), label: "test", client: client, cache: cache)
        #expect(onlyChecked(server.stats))
        #expect(again.candidates == fresh.candidates)
        server.resetStats()
        _ = try await AerialTrees.load(
            tile: tile, area: area(64, -37, 150), label: "test", client: client, cache: cache)
        #expect(onlyChecked(server.stats))
    }

    @Test func aSlowServerSaysToTryAgain() async throws {
        let align = StandInAlign(site: site)
        align.slowStart = .seconds(2)
        let server = StandInServer(align: align)
        try await server.start()
        defer { server.stop() }
        // A one-second idle limit stands in for URLSession's thirty.
        let client = AlignClient(transport: URLSessionGRPCTransport(baseURL: server.url, idleTimeout: 1))
        await #expect(throws: AerialTrees.Failure.slowServer) {
            _ = try await AerialTrees.load(tile: tile, area: area(0, 0, 100), label: "test", client: client)
        }
    }

    @Test func aBusyServerDoesNotHoldUpAKeptLoad() async throws {
        let align = StandInAlign(site: site)
        let server = StandInServer(align: align)
        try await server.start()
        defer { server.stop() }
        let client = AlignClient(baseURL: server.url)
        let cache = temporaryCache()
        defer { cache.removeAll() }
        let first = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 120), label: "test", client: client, cache: cache)

        // The server is deriving its model: the probe gives up after a few seconds and the kept ground is used.
        align.slowStart = .seconds(20)
        let start = ContinuousClock.now
        let kept = try await AerialTrees.load(
            tile: tile, area: area(0, 0, 120), label: "test", client: client, cache: cache)
        #expect(ContinuousClock.now - start < .seconds(8))
        #expect(kept.fromCache)
        #expect(kept.candidates == first.candidates)
    }
}
