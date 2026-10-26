import CanopyModel
import Foundation

/// Reference data kept on the phone, so loading an area again costs no download.
///
/// A site's reference stream is kept as it arrived, under the site's `bundle_id` (which changes whenever any input
/// changes) and what was asked for: layers, classes, voxel size and the circle. A later request for the same bundle
/// is answered from a kept stream whose layers and classes include the ones asked for and whose circle contains the
/// one asked for, cut to that circle exactly as the server cuts it. The site itself is kept too, so a load can go
/// ahead when the server cannot be reached, and so is the site georeference, which depends only on the site frame.
///
/// Streams are evicted least recently used first once they pass `byteLimit` (250 MB unless given). The folder belongs in Caches: the system
/// may empty it, and everything in it can be downloaded again.
public final class ReferenceCache: @unchecked Sendable {
    public let directory: URL
    public let byteLimit: Int

    /// One kept stream.
    struct Entry: Codable, Equatable {
        var file: String
        var token: String
        var bundleID: String
        var layers: [Int]
        /// Empty: every class but noise, as the server reads it.
        var classes: [UInt32]
        var voxel: Float
        var centre: SIMD2<Double>
        /// 0: the whole site.
        var radius: Float
        var bytes: Int
        var lastUsed: Date
    }

    private let lock = NSLock()
    private var index: [Entry]?

    public init(directory: URL, byteLimit: Int = 250_000_000) {
        self.directory = directory
        self.byteLimit = byteLimit
    }

    /// The default place: the app's Caches folder, one folder per server so sites from two servers never mix. Asking
    /// again for the same server gives the same cache: two on one folder would each keep an index of their own.
    public static func caches(for server: URL) -> ReferenceCache? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let name = [server.host() ?? "server", server.port.map(String.init) ?? ""].filter { !$0.isEmpty }
            .joined(separator: "-")
        let directory = caches.appending(path: "Gerardus/reference/\(name)")
        return opened.withLock { opened in
            if let cache = opened[directory.path] { return cache }
            let cache = ReferenceCache(directory: directory)
            opened[directory.path] = cache
            return cache
        }
    }

    private static let opened = Locked<[String: ReferenceCache]>([:])

    // MARK: Sites

    /// The site as the server last described it, and when that was.
    public func site(_ token: String) -> (site: Site, savedAt: Date)? {
        let url = directory.appending(path: "sites/\(token).pb")
        guard let data = try? Data(contentsOf: url), let site = try? Site(serialized: data),
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return nil }
        return (site, date)
    }

    /// Keeps the site's message (`Site`, serialized as the server sent it).
    public func store(site data: Data, token: String) {
        write(data, to: "sites/\(token).pb")
    }

    // MARK: Georeference

    struct SavedGeoreference: Codable {
        var latitude: Double
        var longitude: Double
        var frame: String
        var samples: [[Double]]
    }

    /// The georeference fitted for this site's frame before, if any.
    public func georeference(for site: Site) -> SiteGeoreference? {
        guard let origin = site.frame?.origin,
            let data = try? Data(contentsOf: directory.appending(path: "georeference/\(site.l16Token).json")),
            let saved = try? JSONDecoder().decode(SavedGeoreference.self, from: data),
            saved.latitude == origin.latitude, saved.longitude == origin.longitude,
            saved.frame == Self.frameKey(site)
        else { return nil }
        let samples = saved.samples.filter { $0.count == 4 }.map {
            (geo: GeoPoint(latitude: $0[0], longitude: $0[1]), site: SIMD2($0[2], $0[3]))
        }
        return try? SiteGeoreference(
            origin: GeoPoint(latitude: origin.latitude, longitude: origin.longitude), samples: samples)
    }

    public func store(_ georeference: SiteGeoreference, for site: Site) {
        guard let origin = site.frame?.origin else { return }
        let saved = SavedGeoreference(
            latitude: origin.latitude, longitude: origin.longitude, frame: Self.frameKey(site),
            samples: georeference.samples.map { [$0.geo.latitude, $0.geo.longitude, $0.site.x, $0.site.y] })
        guard let data = try? JSONEncoder().encode(saved) else { return }
        write(data, to: "georeference/\(site.l16Token).json")
    }

    /// What the frame's map to WGS 84 depends on.
    static func frameKey(_ site: Site) -> String {
        guard let frame = site.frame else { return "" }
        return [frame.frameID, frame.horizontalDatum, frame.verticalDatum, frame.workingCRS].joined(separator: "|")
    }

    // MARK: Reference streams

    /// A kept stream that answers `request` for the bundle, as its messages and the circle it was kept for.
    func messages(for request: StreamReferenceRequest, bundleID: String) -> [Data]? {
        lock.withLock {
            var entries = loadIndex()
            guard let k = entries.firstIndex(where: { Self.entry($0, answers: request, bundleID: bundleID) }) else {
                return nil
            }
            guard let data = try? Data(contentsOf: directory.appending(path: "streams/\(entries[k].file)"))
            else {
                entries.remove(at: k)
                saveIndex(entries)
                return nil
            }
            entries[k].lastUsed = .now
            saveIndex(entries)
            return Self.unframe(data)
        }
    }

    /// Kept streams that hold part of what `request` asks for: the same site, bundle and voxels, the layers (but the
    /// ground model, which is not cut into parts) and classes asked for, and a circle that overlaps the request's. Each
    /// comes with its circle.
    func overlapping(_ request: StreamReferenceRequest, bundleID: String) -> [(circle: Circle, messages: [Data])] {
        guard request.radius > 0 else { return [] }
        let wanted = Circle(request)
        var parts = request
        parts.layers.removeAll { $0 == .groundMesh }
        return lock.withLock {
            var entries = loadIndex()
            var out: [(Circle, [Data])] = []
            for k in entries.indices where entries[k].radius > 0 && Self.compatible(entries[k], parts, bundleID) {
                let circle = Circle(entries[k].request)
                guard circle.overlaps(wanted),
                    let data = try? Data(contentsOf: directory.appending(path: "streams/\(entries[k].file)")),
                    let messages = Self.unframe(data)
                else { continue }
                entries[k].lastUsed = .now
                out.append((circle, messages))
            }
            saveIndex(entries)
            return out
        }
    }

    /// Keeps a complete stream. Streams already kept that this one answers for are dropped.
    func store(_ messages: [Data], for request: StreamReferenceRequest, bundleID: String) {
        let data = Self.frame(messages)
        guard data.count <= byteLimit else { return }
        lock.withLock {
            var entries = loadIndex()
            let entry = Entry(
                file: UUID().uuidString.lowercased() + ".grpc", token: request.l16Token, bundleID: bundleID,
                layers: Set(request.layers.map(\.rawValue)).sorted(), classes: Set(request.aerialClasses).sorted(),
                voxel: Self.voxel(request.voxelSize),
                centre: request.centre.map { SIMD2($0.x, $0.y) } ?? .zero, radius: max(0, request.radius),
                bytes: data.count, lastUsed: .now)
            guard write(data, to: "streams/\(entry.file)") else { return }
            // A kept stream for an older bundle of the site, or one this stream covers, is no use any more.
            let stale = entries.filter { old in
                old.token == entry.token
                    && (old.bundleID != bundleID
                        || Self.entry(entry, answers: old.request, bundleID: old.bundleID))
            }
            for old in stale {
                try? FileManager.default.removeItem(at: directory.appending(path: "streams/\(old.file)"))
            }
            entries.removeAll { stale.contains($0) }
            entries.append(entry)
            // Least recently used first, until the rest fit.
            entries.sort { $0.lastUsed > $1.lastUsed }
            var total = 0
            entries = entries.filter { e in
                total += e.bytes
                if total <= byteLimit { return true }
                try? FileManager.default.removeItem(at: directory.appending(path: "streams/\(e.file)"))
                return false
            }
            saveIndex(entries)
        }
    }

    /// Bytes of kept streams.
    public var streamBytes: Int { lock.withLock { loadIndex().reduce(0) { $0 + $1.bytes } } }

    /// Forgets everything.
    public func removeAll() {
        lock.withLock {
            try? FileManager.default.removeItem(at: directory)
            index = []
        }
    }

    /// The server's default voxel when a request names none.
    static func voxel(_ size: Float) -> Float { size > 0 ? size : 0.5 }

    /// Whether a kept stream holds everything `request` asks for.
    static func entry(_ entry: Entry, answers request: StreamReferenceRequest, bundleID: String) -> Bool {
        guard compatible(entry, request, bundleID) else { return false }
        guard entry.radius > 0 else { return true }
        guard request.radius > 0 else { return false }
        let centre = request.centre.map { SIMD2($0.x, $0.y) } ?? .zero
        let d = centre - entry.centre
        return (d * d).sum().squareRoot() + Double(request.radius) <= Double(entry.radius)
    }

    /// Whether a kept stream holds what `request` asks for wherever their circles overlap.
    static func compatible(_ entry: Entry, _ request: StreamReferenceRequest, _ bundleID: String) -> Bool {
        guard entry.token == request.l16Token, entry.bundleID == bundleID,
            entry.voxel == voxel(request.voxelSize),
            Set(request.layers.map(\.rawValue)).isSubset(of: entry.layers)
        else { return false }
        if !entry.classes.isEmpty {
            guard !request.aerialClasses.isEmpty, Set(request.aerialClasses).isSubset(of: entry.classes) else {
                return false
            }
        } else if request.aerialClasses.contains(where: { $0 == 7 || $0 == 18 }) {
            return false  // noise is never in a stream that asked for no classes
        }
        return true
    }

    // MARK: Files

    /// The index, read once. Files it does not name (left by a crash between writing a stream and the index) are
    /// removed, and entries whose file is missing are dropped, so the folder holds only what the index counts.
    private func loadIndex() -> [Entry] {
        if let index { return index }
        let decoder = JSONDecoder()
        let streams = directory.appending(path: "streams")
        var loaded =
            (try? Data(contentsOf: streams.appending(path: "index.json")))
            .flatMap { try? decoder.decode([Entry].self, from: $0) } ?? []
        let files = Set((try? FileManager.default.contentsOfDirectory(atPath: streams.path)) ?? [])
        let named = Set(loaded.map(\.file))
        for file in files where file != "index.json" && !named.contains(file) {
            try? FileManager.default.removeItem(at: streams.appending(path: file))
        }
        let before = loaded.count
        loaded.removeAll { !files.contains($0.file) }
        index = loaded
        if loaded.count != before { saveIndex(loaded) }
        return loaded
    }

    private func saveIndex(_ entries: [Entry]) {
        index = entries
        if let data = try? JSONEncoder().encode(entries) { write(data, to: "streams/index.json") }
    }

    @discardableResult
    private func write(_ data: Data, to path: String) -> Bool {
        let url = directory.appending(path: path)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Messages, each after its length as four bytes, big-endian.
    static func frame(_ messages: [Data]) -> Data {
        var data = Data(capacity: messages.reduce(0) { $0 + $1.count + 4 })
        for m in messages {
            withUnsafeBytes(of: UInt32(m.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(m)
        }
        return data
    }

    static func unframe(_ data: Data) -> [Data]? {
        var messages: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            guard data.endIndex - offset >= 4 else { return nil }
            let length = data[offset..<(offset + 4)].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard data.endIndex - offset >= length else { return nil }
            messages.append(data.subdata(in: offset..<(offset + length)))
            offset += length
        }
        return messages
    }
}

extension ReferenceCache.Entry {
    /// The request this stream answered.
    var request: StreamReferenceRequest {
        StreamReferenceRequest(
            l16Token: token, layers: layers.compactMap(ReferenceLayer.init(rawValue:)),
            centre: Vector3(x: centre.x, y: centre.y, z: 0), radius: radius, voxelSize: voxel, aerialClasses: classes)
    }
}

extension AlignClient {
    /// Reference layers for a prepared site, from `cache` when it holds them, otherwise from the server, keeping a
    /// stream that finishes whole. Kept data is cut to the request's circle exactly as the server cuts it, so the
    /// chunks are the same either way. `fromCache` is told which it was before the first chunk.
    ///
    /// With `padding`, a stream the cache does not hold is asked for `padding` metres wider than `request` and kept
    /// that wide, then cut to `request`: a later request that has moved a few metres is then inside what is kept.
    public func reference(
        _ request: StreamReferenceRequest, bundleID: String, cache: ReferenceCache?, padding: Float = 0,
        fromCache: @escaping @Sendable (Bool) -> Void = { _ in }
    ) -> AsyncThrowingStream<ReferenceChunk, any Error> {
        let transport = transport
        let limit = timeouts.reference
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let cache, let kept = cache.messages(for: request, bundleID: bundleID) {
                        fromCache(true)
                        let cut = ReferenceCut(request)
                        for data in kept {
                            let message = try ReferenceMessage(serialized: data)
                            guard request.layers.isEmpty || request.layers.contains(message.layer) else { continue }
                            if let chunk = cut.apply(message.chunk) { continuation.yield(chunk) }
                        }
                        continuation.finish()
                        return
                    }
                    fromCache(false)
                    if let cache, try await composed(request, bundleID: bundleID, cache: cache, into: continuation) {
                        continuation.finish()
                        return
                    }
                    var fetch = request
                    if cache != nil, padding > 0, request.radius > 0 { fetch.radius += padding }
                    let cut = fetch.radius == request.radius ? nil : ReferenceCut(request)
                    var received: [Data] = []
                    for try await data in transport.call(
                        Self.site + "StreamReference", [fetch.serialized], limit: limit)
                    {
                        if cache != nil { received.append(data) }
                        let chunk = try ReferenceMessage(serialized: data).chunk
                        if let chunk = cut.map({ $0.apply(chunk) }) ?? chunk { continuation.yield(chunk) }
                    }
                    cache?.store(received, for: fetch, bundleID: bundleID)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AlignClient {
    /// Answers `request` from kept streams that each hold part of it, asking the server only for the rest: a few small
    /// circles round what no kept stream holds, and the ground model for the whole circle. Each point and line is
    /// taken from the first stream whose circle holds it, so nothing comes twice and the result is what one request
    /// would have sent (in another order). False, with nothing sent, when kept streams hold too little to be worth it.
    func composed(
        _ request: StreamReferenceRequest, bundleID: String, cache: ReferenceCache,
        into continuation: AsyncThrowingStream<ReferenceChunk, any Error>.Continuation
    ) async throws -> Bool {
        let kept = cache.overlapping(request, bundleID: bundleID)
        guard !kept.isEmpty, let patches = ReferencePatches.plan(Circle(request), kept: kept.map(\.circle)) else {
            return false
        }
        let transport = transport
        let limit = timeouts.reference
        let wantsGround = request.layers.contains(.groundMesh)
        var fetched: [(circle: Circle, messages: [Data])] = []
        var ground: [Data] = []
        try await withThrowingTaskGroup(of: (Int, [Data]).self) { group in
            for (k, patch) in patches.enumerated() {
                var part = request
                part.layers.removeAll { $0 == .groundMesh }
                part.centre = Vector3(x: patch.centre.x, y: patch.centre.y, z: 0)
                part.radius = patch.radius
                group.addTask {
                    var messages: [Data] = []
                    for try await data in transport.call(Self.site + "StreamReference", [part.serialized], limit: limit)
                    {
                        messages.append(data)
                    }
                    cache.store(messages, for: part, bundleID: bundleID)
                    return (k, messages)
                }
            }
            if wantsGround {
                var only = request
                only.layers = [.groundMesh]
                if let held = cache.messages(for: only, bundleID: bundleID) {
                    ground = held
                } else {
                    group.addTask {
                        var messages: [Data] = []
                        for try await data in transport.call(
                            Self.site + "StreamReference", [only.serialized], limit: limit)
                        {
                            messages.append(data)
                        }
                        cache.store(messages, for: only, bundleID: bundleID)
                        return (-1, messages)
                    }
                }
            }
            var parts: [Int: [Data]] = [:]
            for try await (k, messages) in group {
                if k < 0 { ground = messages } else { parts[k] = messages }
            }
            fetched = patches.indices.map { (patches[$0], parts[$0] ?? []) }
        }

        let sources = kept + fetched
        let cut = ReferenceCut(request)
        var lines: [LineFeature] = []
        var linesLayer = ReferenceLayer.footprints
        for (k, source) in sources.enumerated() {
            let earlier = sources[..<k].map(\.circle)
            for data in source.messages {
                let message = try ReferenceMessage(serialized: data)
                guard request.layers.contains(message.layer), message.layer != .groundMesh else { continue }
                switch cut.apply(message.chunk) {
                case .points(let layer, let block):
                    let keep = (0..<block.count).filter { i in
                        !earlier.contains { $0.holds(block.x[i], block.y[i]) }
                    }
                    if keep.count == block.count {
                        continuation.yield(.points(layer, block))
                    } else if !keep.isEmpty {
                        continuation.yield(.points(layer, block.subset(keep)))
                    }
                case .lines(let layer, let more):
                    linesLayer = layer
                    lines += more.filter { line in
                        !earlier.contains { circle in
                            stride(from: 0, to: line.xyz.count / 3 * 3, by: 3).contains {
                                circle.holds(line.xyz[$0], line.xyz[$0 + 1])
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
        if !lines.isEmpty { continuation.yield(.lines(linesLayer, lines)) }
        for data in ground {
            let message = try ReferenceMessage(serialized: data)
            guard message.layer == .groundMesh else { continue }
            if let chunk = cut.apply(message.chunk) { continuation.yield(chunk) }
        }
        return true
    }
}

/// A circle in a site frame, as a request names it: the radius is the request's float, so holding a point is the
/// same test the server makes.
struct Circle: Equatable, Sendable {
    var centre: SIMD2<Double>
    var radius: Float

    init(centre: SIMD2<Double>, radius: Float) {
        self.centre = centre
        self.radius = radius
    }

    init(_ request: StreamReferenceRequest) {
        centre = request.centre.map { SIMD2($0.x, $0.y) } ?? .zero
        radius = request.radius
    }

    func holds(_ x: Float, _ y: Float) -> Bool {
        let dx = Double(x) - centre.x
        let dy = Double(y) - centre.y
        return dx * dx + dy * dy <= Double(radius) * Double(radius)
    }

    func distance(to p: SIMD2<Double>) -> Double {
        let d = p - centre
        return (d * d).sum().squareRoot()
    }

    func overlaps(_ other: Circle) -> Bool {
        distance(to: other.centre) < Double(radius) + Double(other.radius)
    }

    var area: Double { .pi * Double(radius) * Double(radius) }
}

/// Plans the requests that, with kept circles, cover a wanted one.
enum ReferencePatches {
    /// Circles to ask for so that, with `kept`, every point of `wanted` is in some circle: empty when the kept ones
    /// already cover it between them, nil when the part they leave would cost nearly as much as asking for it all.
    ///
    /// The wanted circle is sampled every `spacing` metres; a sample counts as kept when the square round it lies
    /// inside a kept circle. What is left is grouped on a grid and each group gets the smallest circle round its
    /// squares, the grid growing until there are at most `maxPatches`.
    static func plan(
        _ wanted: Circle, kept: [Circle], spacing: Double = 5, maxPatches: Int = 6, maxShare: Double = 0.6
    ) -> [Circle]? {
        let r = Double(wanted.radius)
        let reach = spacing * 0.5.squareRoot()
        var open: [SIMD2<Double>] = []
        var x = -r
        while x <= r {
            var y = -r
            while y <= r {
                let p = wanted.centre + SIMD2(x, y)
                if wanted.distance(to: p) <= r + reach,
                    !kept.contains(where: { $0.distance(to: p) + reach <= Double($0.radius) })
                {
                    open.append(p)
                }
                y += spacing
            }
            x += spacing
        }
        guard !open.isEmpty else { return [] }
        var cell = 40.0
        while cell <= 2 * r + spacing {
            var groups: [SIMD2<Int>: [SIMD2<Double>]] = [:]
            for p in open {
                let d = (p - wanted.centre) / cell
                groups[SIMD2(Int(d.x.rounded(.down)), Int(d.y.rounded(.down))), default: []].append(p)
            }
            if groups.count <= maxPatches {
                let patches = groups.keys.sorted { ($0.x, $0.y) < ($1.x, $1.y) }.map { key in
                    let points = groups[key]!
                    let low = points.reduce(SIMD2(Double.infinity, .infinity)) { pointwiseMin($0, $1) }
                    let high = points.reduce(SIMD2(-Double.infinity, -.infinity)) { pointwiseMax($0, $1) }
                    let centre = (low + high) / 2
                    let radius = points.map { (($0 - centre) * ($0 - centre)).sum().squareRoot() }.max()! + reach + 0.5
                    return Circle(centre: centre, radius: Float(radius.rounded(.up)))
                }
                return patches.reduce(0) { $0 + $1.area } <= maxShare * wanted.area ? patches : nil
            }
            cell *= 1.5
        }
        return nil
    }
}

extension PointBlock {
    /// The points at `indices`, with whatever per-point fields the block has.
    func subset(_ indices: [Int]) -> PointBlock {
        var out = PointBlock(
            x: indices.map { x[$0] }, y: indices.map { y[$0] }, z: indices.map { z[$0] })
        if classification.count == count { out.classification = indices.map { classification[$0] } }
        if intensity.count == count { out.intensity = indices.map { intensity[$0] } }
        if confidence.count == count { out.confidence = indices.map { confidence[$0] } }
        return out
    }
}

/// Cuts kept reference data to a request's circle and classes, as the server would have.
struct ReferenceCut {
    let centre: SIMD2<Double>
    /// Squared; infinite for the whole site.
    let radius2: Double
    let radius: Double
    let classes: Set<UInt32>

    init(_ request: StreamReferenceRequest) {
        centre = request.centre.map { SIMD2($0.x, $0.y) } ?? .zero
        radius = request.radius > 0 ? Double(request.radius) : .infinity
        radius2 = radius * radius
        classes = Set(request.aerialClasses)
    }

    func near(_ x: Float, _ y: Float) -> Bool {
        let dx = Double(x) - centre.x
        let dy = Double(y) - centre.y
        return dx * dx + dy * dy <= radius2
    }

    func apply(_ chunk: ReferenceChunk?) -> ReferenceChunk? {
        switch chunk {
        case .points(let layer, let block):
            var out = PointBlock()
            let hasClass = block.classification.count == block.count
            let hasIntensity = block.intensity.count == block.count
            let hasConfidence = block.confidence.count == block.count
            for k in 0..<block.count {
                guard near(block.x[k], block.y[k]) else { continue }
                if !classes.isEmpty, hasClass, !classes.contains(block.classification[k]) { continue }
                out.x.append(block.x[k])
                out.y.append(block.y[k])
                out.z.append(block.z[k])
                if hasClass { out.classification.append(block.classification[k]) }
                if hasIntensity { out.intensity.append(block.intensity[k]) }
                if hasConfidence { out.confidence.append(block.confidence[k]) }
            }
            return .points(layer, out)
        case .lines(let layer, let lines):
            return .lines(
                layer,
                lines.filter { line in
                    stride(from: 0, to: line.xyz.count / 3 * 3, by: 3).contains { near(line.xyz[$0], line.xyz[$0 + 1]) }
                })
        case .groundMesh(let field):
            return field.cropped(centre: centre, radius: radius).map { .groundMesh($0) }
        case let other:
            return other
        }
    }
}

extension Heightfield {
    /// The grid cut to the square round a circle, as the server crops its ground model for a request; nil when the
    /// circle misses the grid. An infinite radius keeps it all.
    public func cropped(centre: SIMD2<Double>, radius: Double) -> Heightfield? {
        guard nx > 0, ny > 0 else { return nil }
        func index(_ v: Double, _ o: Double, _ n: Int, _ rule: FloatingPointRoundingRule) -> Int {
            min(max(Int(((v - o) / cellSize).rounded(rule)), 0), n - 1)
        }
        func far(_ v: Double, _ o: Double, _ n: Int) -> Bool {
            radius.isFinite && (v + radius < o || v - radius > o + Double(n - 1) * cellSize)
        }
        guard !far(centre.x, origin.x, nx), !far(centre.y, origin.y, ny) else { return nil }
        guard radius.isFinite else { return self }
        let i0 = index(centre.x - radius, origin.x, nx, .down)
        let i1 = index(centre.x + radius, origin.x, nx, .up)
        let j0 = index(centre.y - radius, origin.y, ny, .down)
        let j1 = index(centre.y + radius, origin.y, ny, .up)
        var cut: [Float] = []
        cut.reserveCapacity((i1 - i0 + 1) * (j1 - j0 + 1))
        for j in j0...j1 { cut += z[(j * nx + i0)...(j * nx + i1)] }
        return Heightfield(
            origin: Vector3(
                x: origin.x + Double(i0) * cellSize, y: origin.y + Double(j0) * cellSize, z: origin.z),
            cellSize: cellSize, nx: i1 - i0 + 1, ny: j1 - j0 + 1, z: cut)
    }
}

/// A value behind a lock.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock { body(&value) }
    }
}
