import CanopyModel
import Foundation

/// Reference data kept on the phone, so loading an area again costs no download.
///
/// A site's reference stream is kept as it arrived, under the site's `bundle_id` (which changes whenever any input
/// changes) and what was asked for: layers, classes, voxel size and the circle. A later request for the same bundle
/// is answered from a kept stream whose layers and classes include the ones asked for and whose circle contains the
/// one asked for, cut to that circle exactly as the server cuts it. Only streams in which every layer finished are
/// kept. The ground model comes from the server's site model, which changes when it accepts a scan while the bundle
/// does not, so kept ground is used only when it is the server's current model (`AlignClient.currentModel`), or when
/// the server cannot be reached. The site itself is kept too, so a load can go ahead when the server cannot be
/// reached, and so is the site georeference, which depends only on the site frame.
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
        /// The site model its ground came from (`ReferenceMessage.modelID`): the ground changes when the server accepts
        /// a scan, while the bundle stays the same. Nil without ground.
        var model: String?
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

    /// A kept stream that answers `request` for the bundle, as its messages. With a `model`, a request for the ground
    /// is answered only by a stream whose ground came from that site model.
    func messages(for request: StreamReferenceRequest, bundleID: String, model: String? = nil) -> [Data]? {
        let needsModel = model != nil && request.layers.contains(.groundMesh)
        return lock.withLock {
            var entries = loadIndex()
            guard
                let k = entries.firstIndex(where: {
                    Self.entry($0, answers: request, bundleID: bundleID) && (!needsModel || $0.model == model)
                })
            else {
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

    /// Whether some kept stream answers `request`, whatever site model its ground came from.
    func holds(_ request: StreamReferenceRequest, bundleID: String) -> Bool {
        lock.withLock { loadIndex().contains { Self.entry($0, answers: request, bundleID: bundleID) } }
    }

    /// Keeps a complete stream (every layer asked for finished), whose ground came from `model`. Streams already kept
    /// that this one answers for are dropped.
    func store(_ messages: [Data], for request: StreamReferenceRequest, bundleID: String, model: String?) {
        let data = Self.frame(messages)
        guard data.count <= byteLimit else { return }
        lock.withLock {
            var entries = loadIndex()
            let entry = Entry(
                file: UUID().uuidString.lowercased() + ".grpc", token: request.l16Token, bundleID: bundleID,
                layers: Set(request.layers.map(\.rawValue)).sorted(), classes: Set(request.aerialClasses).sorted(),
                voxel: Self.voxel(request.voxelSize),
                centre: request.centre.map { SIMD2($0.x, $0.y) } ?? .zero, radius: max(0, request.radius),
                bytes: data.count, lastUsed: .now, model: request.layers.contains(.groundMesh) ? model ?? "" : nil)
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
        guard !request.layers.isEmpty, entry.token == request.l16Token, entry.bundleID == bundleID,
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
    /// stream in which every layer finished. Kept data is cut to the request's circle exactly as the server cuts it, so
    /// the chunks are the same either way. `fromCache` is told which it was before the first chunk. A stream that
    /// ends before every layer has finished (the server stopped part-way; HTTP/1.1 hides why) fails with
    /// `GRPCTransportError.incomplete` rather than giving trees from part of the points.
    ///
    /// With `padding`, a stream the cache does not hold is asked for `padding` metres wider than `request` and kept
    /// that wide, then cut to `request`: a later request that has moved a few metres is then inside what is kept.
    public func reference(
        _ request: StreamReferenceRequest, bundleID: String, cache: ReferenceCache?, padding: Float = 0,
        fromCache: @escaping @Sendable (Bool) -> Void = { _ in }
    ) -> AsyncThrowingStream<ReferenceChunk, any Error> {
        let transport = transport
        let limit = timeouts.reference
        // The server reads no layers as six of its own choosing: not something to keep.
        let cache = request.layers.isEmpty ? nil : cache
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Kept ground is the server's current site model, or the server cannot say (offline, older).
                    var model: String?
                    if let cache, request.layers.contains(.groundMesh) {
                        var ground = request
                        ground.layers = [.groundMesh]
                        if cache.holds(ground, bundleID: bundleID) {
                            do {
                                model = try await currentModel(request)
                            } catch  where Self.isOffline(error) || AlignClient.timedOut(error) {
                                // Offline, or busy deriving its model (after accepting a scan, or after being idle):
                                // the kept ground is the best there is now, and the next load asks again.
                                model = nil
                            }
                        }
                    }
                    if let cache, let kept = cache.messages(for: request, bundleID: bundleID, model: model) {
                        fromCache(true)
                        let cut = ReferenceCut(request)
                        for data in kept {
                            let message = try ReferenceMessage(serialized: data)
                            guard request.layers.contains(message.layer) else { continue }
                            if let chunk = cut.apply(message.chunk) { continuation.yield(chunk) }
                        }
                        continuation.finish()
                        return
                    }
                    fromCache(false)
                    if let cache,
                        try await composed(
                            request, bundleID: bundleID, cache: cache, model: model, padding: padding,
                            into: continuation)
                    {
                        continuation.finish()
                        return
                    }
                    var fetch = request
                    if cache != nil, padding > 0, request.radius > 0 { fetch.radius += padding }
                    let cut = fetch.radius == request.radius ? nil : ReferenceCut(request)
                    var received: [Data] = []
                    var finished = StreamCompletion(fetch.layers)
                    for try await data in transport.call(
                        Self.site + "StreamReference", [fetch.serialized], limit: limit)
                    {
                        let message = try ReferenceMessage(serialized: data)
                        finished.note(message)
                        if cache != nil { received.append(data) }
                        if let chunk = cut.map({ $0.apply(message.chunk) }) ?? message.chunk {
                            continuation.yield(chunk)
                        }
                    }
                    try finished.check()
                    cache?.store(received, for: fetch, bundleID: bundleID, model: finished.model)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The site model the server's ground layer comes from now: a few cells of ground round the request's centre,
    /// which name it (an older server without site models names none, ""). Given a few seconds only: a server that
    /// takes longer is deriving its model, which can take minutes, and a load from kept points should not wait.
    func currentModel(_ request: StreamReferenceRequest, limit: Duration = .seconds(5)) async throws -> String {
        var probe = request
        probe.layers = [.groundMesh]
        probe.radius = 1
        return try await complete(probe, transport: transport, limit: limit).model ?? ""
    }

    /// Whether a call failed because there is no connection to the server at all, as opposed to a slow or failing
    /// server: only then is kept data used as it is.
    static func isOffline(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [
            .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
            .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
        ].contains(error.code)
    }

    /// The messages of one request, checked to have finished every layer.
    func complete(
        _ request: StreamReferenceRequest, transport: any GRPCTransport, limit: Duration
    ) async throws -> (messages: [Data], model: String?) {
        var messages: [Data] = []
        var finished = StreamCompletion(request.layers)
        for try await data in transport.call(Self.site + "StreamReference", [request.serialized], limit: limit) {
            finished.note(try ReferenceMessage(serialized: data))
            messages.append(data)
        }
        try finished.check()
        return (messages, finished.model)
    }
}

/// Which layers of a stream have finished (the server marks each layer's last message), and the site model its
/// ground came from.
struct StreamCompletion {
    var waiting: Set<ReferenceLayer>
    var model: String?

    init(_ layers: [ReferenceLayer]) {
        waiting = Set(layers)
    }

    mutating func note(_ message: ReferenceMessage) {
        if message.complete { waiting.remove(message.layer) }
        if message.layer == .groundMesh { model = message.modelID }
    }

    /// Throws unless every layer finished; a cancelled task's stream simply ends, so that is checked too.
    func check() throws {
        try Task.checkCancellation()
        guard waiting.isEmpty else { throw GRPCTransportError.incomplete }
    }
}

extension AlignClient {
    /// Answers `request` from kept streams that each hold part of it, asking the server only for the rest: a few small
    /// circles round what no kept stream holds, and the ground model for the whole circle unless it is kept for
    /// `model`. Each point and line is taken from the first stream whose circle holds it, so nothing comes twice and
    /// the result is what one request would have sent (in another order). False, with nothing sent, when kept streams
    /// hold too little to be worth it.
    func composed(
        _ request: StreamReferenceRequest, bundleID: String, cache: ReferenceCache, model: String?, padding: Float,
        into continuation: AsyncThrowingStream<ReferenceChunk, any Error>.Continuation
    ) async throws -> Bool {
        let kept = cache.overlapping(request, bundleID: bundleID)
        guard !kept.isEmpty, let patches = ReferencePatches.plan(Circle(request), kept: kept.map(\.circle)) else {
            return false
        }
        let transport = transport
        let limit = timeouts.reference
        var fetched: [(circle: Circle, messages: [Data])] = []
        var ground: [Data] = []
        try await withThrowingTaskGroup(of: (Int, [Data]).self) { group in
            for (k, patch) in patches.enumerated() {
                var part = request
                part.layers.removeAll { $0 == .groundMesh }
                part.centre = Vector3(x: patch.centre.x, y: patch.centre.y, z: 0)
                part.radius = patch.radius
                guard !part.layers.isEmpty else { continue }
                group.addTask {
                    let (messages, _) = try await complete(part, transport: transport, limit: limit)
                    cache.store(messages, for: part, bundleID: bundleID, model: nil)
                    return (k, messages)
                }
            }
            if request.layers.contains(.groundMesh) {
                var only = request
                only.layers = [.groundMesh]
                if let held = cache.messages(for: only, bundleID: bundleID, model: model) {
                    ground = held
                } else {
                    // Padded as a whole load is, so the next nudge finds it.
                    var fetch = only
                    if padding > 0, fetch.radius > 0 { fetch.radius += padding }
                    group.addTask {
                        let (messages, model) = try await complete(fetch, transport: transport, limit: limit)
                        cache.store(messages, for: fetch, bundleID: bundleID, model: model)
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
        // A centimetre to spare, for points stored as floats.
        let spare = 0.01
        var open: [SIMD2<Double>] = []
        // Squares `spacing` wide from -r until they pass +r, so together they cover the whole circle.
        var x = -r
        while x - spacing / 2 < r {
            var y = -r
            while y - spacing / 2 < r {
                let p = wanted.centre + SIMD2(x, y)
                // A point of the wanted circle in this square is within reach of the sample, and within r of the
                // wanted centre: whichever bound is tighter.
                if wanted.distance(to: p) <= r + reach,
                    !kept.contains(where: {
                        min($0.distance(to: p) + reach, $0.distance(to: wanted.centre) + r) + spare <= Double($0.radius)
                    })
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
