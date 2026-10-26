import CanopyModel
import CanopyReference
import CanopyStore
import Foundation

/// Measures loading real trees from the stand-in server under each network profile, and the work on the phone
/// around it (decoding, detection, the local store), and writes it all down so a later run can be compared.
public enum Bench {
    /// One load of an area, as the app does it: `AerialTrees.load`.
    public struct Load: Codable, Equatable, Sendable {
        public var scenario: String
        public var profile: String
        public var seconds: Double
        /// Seconds from the start until each stage began.
        public var stages: [String: Double]
        public var calls: [String: Int]
        public var bytes: Int
        public var connections: Int
        public var points: Int
        public var candidates: Int
        public var score: DetectionScore
    }

    /// Time for one piece of work on the phone.
    public struct Work: Codable, Equatable, Sendable {
        public var name: String
        /// Median of the runs.
        public var seconds: Double
        public var detail: String
    }

    public struct Report: Codable, Sendable {
        public var date: Date
        public var machine: String
        public var commit: String
        public var site: String
        public var loads: [Load]
        public var work: [Work]

        public init(date: Date, machine: String, commit: String, site: String, loads: [Load], work: [Work]) {
            self.date = date
            self.machine = machine
            self.commit = commit
            self.site = site
            self.loads = loads
            self.work = work
        }
    }

    /// Where each load in a sequence happens and whether the client is new (as after a relaunch).
    public struct Step: Sendable {
        public var name: String
        /// Site-frame centre, and radius; nil radius loads the whole site.
        public var centre: SIMD2<Double>
        public var radius: Double?
        public var newClient: Bool
    }

    /// Load the map in view, again, a little further on, then again after a relaunch, then the whole site.
    public static let steps: [Step] = [
        Step(name: "first", centre: SIMD2(60, -40), radius: 150, newClient: true),
        Step(name: "again", centre: SIMD2(60, -40), radius: 150, newClient: false),
        Step(name: "nudged 8 m", centre: SIMD2(66, -35), radius: 150, newClient: false),
        Step(name: "panned 40 m", centre: SIMD2(100, -40), radius: 150, newClient: false),
        Step(name: "panned 80 m more", centre: SIMD2(180, -40), radius: 150, newClient: false),
        Step(name: "zoomed in", centre: SIMD2(70, -30), radius: 80, newClient: false),
        Step(name: "relaunch", centre: SIMD2(60, -40), radius: 150, newClient: true),
        Step(name: "whole site", centre: .zero, radius: nil, newClient: false),
    ]

    /// Runs the steps under one profile against a fresh server, with a fresh cache folder (none when `cached` is
    /// false). A step with a new client also gets a new cache object on the same folder, as after a relaunch.
    public static func loads(
        site: SyntheticSite, profile: NetworkProfile, steps: [Step] = Bench.steps, cached: Bool = true,
        log: (String) -> Void = { _ in }
    ) async throws -> [Load] {
        let server = StandInServer(align: StandInAlign(site: site), profile: profile)
        try await server.start()
        defer { server.stop() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "canopy-bench-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let tile = S2CellID(token: site.token)!
        var client = AlignClient(baseURL: server.url)
        var cache = cached ? ReferenceCache(directory: folder) : nil
        var out: [Load] = []
        for step in steps {
            if step.newClient {
                client = AlignClient(baseURL: server.url)
                cache = cached ? ReferenceCache(directory: folder) : nil
            }
            server.resetStats()
            let area = step.radius.map { AerialTrees.Area(centre: site.geo(step.centre), radius: $0) }
            let stages = StageClock()
            let result = try await AerialTrees.load(
                tile: tile, area: area, label: "canopy-harness", client: client, cache: cache
            ) { stages.mark($0) }
            let seconds = stages.elapsed
            let stats = server.stats
            let load = Load(
                scenario: step.name, profile: profile.name, seconds: seconds, stages: stages.marks, calls: stats.calls,
                bytes: stats.totalBytes, connections: stats.connections, points: result.pointCount,
                candidates: result.candidates.count,
                score: DetectionScore(candidates: result.candidates, site: site, covers: result.covers))
            log(
                String(
                    format: "  %-12@ %6.2f s  %6.2f MB  %2d calls  %@", step.name as NSString, seconds,
                    Double(load.bytes) / 1e6, stats.totalCalls, load.score.description as NSString))
            out.append(load)
        }
        return out
    }

    // MARK: Work on the phone

    /// Decoding a whole site's stream, detection and the canopy model, and the store with a park's worth of trees.
    public static func work(site: SyntheticSite, runs: Int = 5, log: (String) -> Void = { _ in }) async throws -> [Work]
    {
        var out: [Work] = []
        func measure(_ name: String, detail: String = "", _ body: () throws -> Void) rethrows {
            var times: [Double] = []
            for _ in 0..<runs {
                let start = ContinuousClock.now
                try body()
                times.append((ContinuousClock.now - start).timeInterval)
            }
            let median = times.sorted()[times.count / 2]
            log(String(format: "  %-40@ %8.1f ms  %@", name as NSString, median * 1000, detail as NSString))
            out.append(Work(name: name, seconds: median, detail: detail))
        }
        func measureAsync(_ name: String, detail: String = "", _ body: () async throws -> Void) async rethrows {
            var times: [Double] = []
            for _ in 0..<runs {
                let start = ContinuousClock.now
                try await body()
                times.append((ContinuousClock.now - start).timeInterval)
            }
            let median = times.sorted()[times.count / 2]
            log(String(format: "  %-40@ %8.1f ms  %@", name as NSString, median * 1000, detail as NSString))
            out.append(Work(name: name, seconds: median, detail: detail))
        }

        // The whole site's canopy stream, as it comes off the wire.
        let align = StandInAlign(site: site)
        var request = ProtoWriter()
        request.string(1, site.token)
        request.packedVarints(2, [ReferenceLayer.aerialPoints, .footprints, .groundMesh].map { UInt64($0.rawValue) })
        request.float(5, 1)
        request.packedVarints(6, AerialTrees.canopyClasses.map(UInt64.init))
        let messages = align.answer(AlignClient.site + "StreamReference", [UInt8](request.data)).events.map(\.data)
        let wireBytes = messages.reduce(0) { $0 + $1.count }
        var blocks: [PointBlock] = []
        var ground: Heightfield?
        var buildings: [[SIMD2<Double>]] = []
        try measure("decode whole-site stream", detail: String(format: "%.1f MB", Double(wireBytes) / 1e6)) {
            blocks = []
            for data in messages {
                switch try ReferenceMessage(serialized: data).chunk {
                case .points(_, let block): blocks.append(block)
                case .groundMesh(let field): ground = field
                case .lines(_, let lines):
                    buildings = lines.filter { $0.kind == .building }.map(\.points)
                default: break
                }
            }
        }
        let points = blocks.reduce(0) { $0 + $1.count }
        guard let ground else { return out }
        let detector = TreeDetector()
        var trees: [TreeDetector.Tree] = []
        measure("detect trees, whole site", detail: "\(points) points") {
            trees = detector.detect(points: blocks, ground: ground, buildings: buildings)
        }
        measure("canopy height model, whole site") {
            _ = detector.canopyHeightModel(points: blocks, ground: ground)
        }
        measure("detect and model together, whole site", detail: "as a load does") {
            _ = detector.detectWithCanopy(points: blocks, ground: ground, buildings: buildings)
        }

        // The local store with a park's worth of candidates: loading an area, and a player's tap.
        let candidates = parkCandidates(count: 30_000, seed: 7)
        let fresh = AerialTrees.candidates(
            trees,
            georeference: try SiteGeoreference(
                origin: site.origin,
                samples: [SIMD2(0.0, 0), SIMD2(100, 0), SIMD2(0, 100)].map { (geo: site.geo($0), site: $0) }),
            source: "synthetic")
        for count in [2_000, 30_000] {
            let base = Array(candidates.prefix(count))
            let store = try LocalStore.inMemory()
            try await store.importCandidates(base)
            let tile = S2CellID(token: site.token)!
            let tiles = Set(site.covering.compactMap(S2CellID.init(token:)))
            try await measureAsync("store: replace an area's candidates", detail: "\(count) in the store") {
                _ = try await store.replaceCandidates(where: { tiles.contains($0.tile) }, with: fresh)
            }
            let tree = try require(await store.state().trees.values.first { $0.position.tile == tile })
            let player = PlayerID(rawValue: "bench")
            try await measureAsync("store: confirm one tree", detail: "\(count) in the store") {
                _ = try await store.record(.treeConfirmed(treeID: tree.id), by: player)
            }
            try await measureAsync("store: read candidates", detail: "\(count) in the store") {
                _ = try await store.candidates()
            }
        }
        return out
    }

    /// Candidates spread over Golden Gate Park, as many as the whole park might have.
    public static func parkCandidates(count: Int, seed: UInt64) -> [TreeCandidate] {
        var random = SplitMix64(seed: seed)
        var seen = Set<UUID>()
        var out: [TreeCandidate] = []
        while out.count < count {
            let location = GeoPoint(
                latitude: 37.7650 + random.unit() * 0.009, longitude: -122.5100 + random.unit() * 0.055)
            // Ids come from the position to about a metre; two trees never share one.
            guard seen.insert(AerialTrees.stableID(location)).inserted else { continue }
            out.append(
                TreeCandidate(
                    id: AerialTrees.stableID(location), location: location, height: 10 + random.unit() * 25,
                    crownRadius: 2 + random.unit() * 5, confidence: 0.5 + random.unit() * 0.45, isSynthetic: false,
                    source: "USGS 3DEP aerial LiDAR (synthetic)"))
        }
        return out
    }

    struct Missing: Error {}

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Missing() }
        return value
    }
}

/// Times stages as they are reported, from creation.
final class StageClock: @unchecked Sendable {
    private let start = ContinuousClock.now
    private let lock = NSLock()
    private var stored: [String: Double] = [:]

    func mark(_ stage: AerialTrees.Stage) {
        let name: String
        switch stage {
        case .preparing: name = "preparing"
        case .downloading: name = "downloading"
        case .readingSaved: name = "reading saved"
        case .detecting: name = "detecting"
        case .placing: name = "placing"
        }
        let now = (ContinuousClock.now - start).timeInterval
        lock.withLock {
            if stored[name] == nil { stored[name] = now }
        }
    }

    var marks: [String: Double] { lock.withLock { stored } }
    var elapsed: Double { (ContinuousClock.now - start).timeInterval }
}

extension Bench {
    /// A table of what changed between two reports: time, bytes and calls per load, and time per piece of work.
    public static func compare(_ before: Report, _ after: Report) -> String {
        var lines = ["Compared with \(before.commit) (\(before.date.formatted(date: .abbreviated, time: .shortened)))"]
        lines.append("| Profile | Load | Seconds | MB | Calls |")
        lines.append("|---|---|---|---|---|")
        for load in after.loads {
            let old = before.loads.first { $0.profile == load.profile && $0.scenario == load.scenario }
            func pair(_ new: Double, _ old: Double?, _ format: String) -> String {
                guard let old else { return String(format: format, new) }
                return String(format: "\(format) → \(format)", old, new)
            }
            lines.append(
                "| \(load.profile) | \(load.scenario) | \(pair(load.seconds, old?.seconds, "%.2f")) | "
                    + "\(pair(Double(load.bytes) / 1e6, old.map { Double($0.bytes) / 1e6 }, "%.2f")) | "
                    + "\(pair(Double(load.calls.values.reduce(0, +)), old.map { Double($0.calls.values.reduce(0, +)) }, "%.0f")) |"
            )
        }
        lines.append("")
        lines.append("| Work | Detail | ms |")
        lines.append("|---|---|---|")
        for item in after.work {
            let old = before.work.first { $0.name == item.name && $0.detail == item.detail }
            let ms =
                old.map { String(format: "%.1f → %.1f", $0.seconds * 1000, item.seconds * 1000) }
                ?? String(format: "%.1f", item.seconds * 1000)
            lines.append("| \(item.name) | \(item.detail) | \(ms) |")
        }
        return lines.joined(separator: "\n")
    }
}
