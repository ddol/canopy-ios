import CanopyModel
import Foundation

/// A client for a Gerardus align server (gerardus.align.v1alpha1): sites and their reference layers, and
/// registering scans against them.
public struct AlignClient: Sendable {
    public static let site = "/gerardus.align.v1alpha1.SiteService/"
    public static let registration = "/gerardus.align.v1alpha1.RegistrationService/"

    /// How long each kind of call may take before it fails with `GRPCTransportError.timedOut`. The server keeps
    /// preparing a site after the call that asked for it gives up, so asking again later finds it ready.
    public struct Timeouts: Sendable {
        /// Calls with one answer: server info, sites, poses.
        public var unary: Duration
        /// Preparing a site; a new site takes about 15 s on a server with its 3DEP data on hand.
        public var prepare: Duration
        /// Streaming reference layers.
        public var reference: Duration
        /// Uploading a scan, and registering it.
        public var registration: Duration

        public init(
            unary: Duration = .seconds(10), prepare: Duration = .seconds(30), reference: Duration = .seconds(45),
            registration: Duration = .seconds(180)
        ) {
            self.unary = unary
            self.prepare = prepare
            self.reference = reference
            self.registration = registration
        }
    }

    public let transport: any GRPCTransport
    public var timeouts: Timeouts

    public init(transport: any GRPCTransport, timeouts: Timeouts = Timeouts()) {
        self.transport = transport
        self.timeouts = timeouts
    }

    /// A client for the server at `baseURL`, calling as `player` when given (`GerardusIdentity`): the server sends
    /// OpenStreetMap only to its admins.
    public init(baseURL: URL, player: Player? = nil) {
        self.init(
            transport: URLSessionGRPCTransport(
                baseURL: baseURL, headers: player.map(GerardusIdentity.headers(for:)) ?? [:]))
    }

    // MARK: Sites

    public func serverInfo() async throws -> ServerInfo {
        try await unary(Self.site + "GetServerInfo", Data())
    }

    public func listSites() async throws -> [Site] {
        let fields = try await unaryFields(Self.site + "ListSites", Data())
        return try fields.filter { $0.number == 1 }.map { try Site($0) }
    }

    /// A prepared site, or nil when the server has not prepared it.
    public func site(_ l16Token: String) async throws -> Site? {
        var request = ProtoWriter()
        request.string(1, l16Token)
        do {
            let fields = try await unaryFields(Self.site + "GetSite", request.data)
            return try fields.first { $0.number == 1 }.map { try Site($0) }
        } catch let error as GRPCStatusError where error.code == GRPCStatusError.notFound {
            return nil
        }
    }

    /// Builds (or returns the cached) bundle for a site. The last event is `.ready`.
    public func prepareSite(
        _ l16Token: String, label: String, refresh: Bool = false
    )
        -> AsyncThrowingStream<PrepareEvent, any Error>
    {
        var request = ProtoWriter()
        request.string(1, l16Token)
        request.string(2, label)
        request.bool(3, refresh)
        return map(call(Self.site + "PrepareSite", [request.data], limit: timeouts.prepare)) { fields in
            for f in fields {
                if f.number == 1 { return .progress(Progress(fields: try ProtoReader.fields(f.bytes))) }
                if f.number == 2 { return .ready(try Site(f)) }
            }
            return nil
        }
    }

    /// Prepares a site and returns it, reporting progress as it goes.
    public func preparedSite(
        _ l16Token: String, label: String, progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Site {
        for try await event in prepareSite(l16Token, label: label) {
            switch event {
            case .progress(let p): progress(p)
            case .ready(let site): return site
            }
        }
        throw GRPCTransportError.noResponse
    }

    /// Streams reference geometry for a prepared site, in the site frame.
    public func reference(_ request: StreamReferenceRequest) -> AsyncThrowingStream<ReferenceChunk, any Error> {
        map(call(Self.site + "StreamReference", [request.serialized], limit: timeouts.reference)) {
            try ReferenceMessage(fields: $0).chunk
        }
    }

    /// Includes completion flags and model identity, needed to reject partial or mixed vector scenes.
    public func referenceMessages(_ request: StreamReferenceRequest) -> AsyncThrowingStream<ReferenceMessage, any Error>
    {
        map(call(Self.site + "StreamReference", [request.serialized], limit: timeouts.reference)) {
            try ReferenceMessage(fields: $0)
        }
    }

    // MARK: Registration

    /// Converts an approximate position and heading into a site-frame pose.
    public func poseFromHint(
        l16Token: String, sensorID: String, hint: PoseHint
    ) async throws -> (
        pose: SensorPose, summary: PoseSummary?
    ) {
        var request = ProtoWriter()
        request.string(1, l16Token)
        request.string(2, sensorID)
        request.message(3, hint)
        let fields = try await unaryFields(Self.registration + "PoseFromHint", request.data)
        guard let pose = try fields.first(where: { $0.number == 1 }).map({ try SensorPose($0) }) else {
            throw GRPCTransportError.noResponse
        }
        return (pose, try fields.first { $0.number == 2 }.map { try PoseSummary($0) })
    }

    /// Uploads a scan in its sensor frame. Points are split into blocks of at most `blockSize`, below the
    /// server's 4 MiB message limit.
    public func uploadScan(
        _ header: ScanHeader, points: PointBlock, blockSize: Int = 150_000
    ) async throws -> (
        scan: Scan, alreadyStored: Bool
    ) {
        var messages: [Data] = []
        var first = ProtoWriter()
        first.message(1, header)
        messages.append(first.data)
        var start = 0
        while start < points.count {
            let end = min(points.count, start + blockSize)
            var block = PointBlock(
                x: Array(points.x[start..<end]), y: Array(points.y[start..<end]), z: Array(points.z[start..<end]))
            if points.confidence.count == points.count { block.confidence = Array(points.confidence[start..<end]) }
            if points.intensity.count == points.count { block.intensity = Array(points.intensity[start..<end]) }
            var message = ProtoWriter()
            message.message(2, block)
            messages.append(message.data)
            start = end
        }
        var scan: Scan?
        var already = false
        for try await data in call(Self.registration + "UploadScan", messages, limit: timeouts.registration) {
            for f in try ProtoReader.fields(ArraySlice([UInt8](data))) {
                if f.number == 1 { scan = Scan(fields: try ProtoReader.fields(f.bytes)) }
                if f.number == 2 { already = f.bool }
            }
        }
        guard let scan else { throw GRPCTransportError.noResponse }
        return (scan, already)
    }

    /// Registers an uploaded scan against its site. The last event is `.finished`.
    public func register(
        scanID: String, hint: PoseHint?, initialPose: SensorPose? = nil, options: RegistrationOptions? = nil
    ) -> AsyncThrowingStream<RegisterEvent, any Error> {
        var request = ProtoWriter()
        request.string(1, scanID)
        if let initialPose { request.message(2, initialPose) }
        if let hint { request.message(3, hint) }
        if let options { request.message(4, options) }
        return map(call(Self.registration + "Register", [request.data], limit: timeouts.registration)) { fields in
            for f in fields {
                switch f.number {
                case 1: return .progress(Progress(fields: try ProtoReader.fields(f.bytes)))
                case 2: return .hypothesis(try Hypothesis(f))
                case 3: return .finished(try Registration(f))
                default: break
                }
            }
            return nil
        }
    }

    // MARK: Plumbing

    func call(_ path: String, _ requests: [Data], limit: Duration) -> AsyncThrowingStream<Data, any Error> {
        transport.call(path, requests, limit: limit)
    }

    func unaryFields(_ path: String, _ request: Data) async throws -> [ProtoField] {
        for try await data in call(path, [request], limit: timeouts.unary) {
            return try ProtoReader.fields(ArraySlice([UInt8](data)))
        }
        throw GRPCTransportError.noResponse
    }

    func unary<Response: ProtoDecodable>(_ path: String, _ request: Data) async throws -> Response {
        try Response(fields: try await unaryFields(path, request))
    }

    /// Decodes each message of a stream; messages the transform returns nil for are skipped.
    func map<Event: Sendable>(
        _ messages: AsyncThrowingStream<Data, any Error>,
        _ transform: @escaping @Sendable ([ProtoField]) throws -> Event?
    ) -> AsyncThrowingStream<Event, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await data in messages {
                        if let event = try transform(try ProtoReader.fields(ArraySlice([UInt8](data)))) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension GRPCTransport {
    /// The messages of a call. Once `limit` has passed the stream fails with `timedOut` and the call is cancelled.
    func call(_ path: String, _ requests: [Data], limit: Duration) -> AsyncThrowingStream<Data, any Error> {
        let messages = call(path, requests: requests)
        return AsyncThrowingStream { continuation in
            let reader = Task {
                do {
                    for try await message in messages { continuation.yield(message) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let timer = Task {
                try await Task.sleep(for: limit)
                continuation.finish(throwing: GRPCTransportError.timedOut(seconds: Int(limit.components.seconds)))
            }
            continuation.onTermination = { _ in
                reader.cancel()
                timer.cancel()
            }
        }
    }

    /// The one message of a unary call, as fields.
    func unaryFields(_ path: String, _ request: Data, limit: Duration) async throws -> [ProtoField] {
        for try await data in call(path, [request], limit: limit) {
            return try ProtoReader.fields(ArraySlice([UInt8](data)))
        }
        throw GRPCTransportError.noResponse
    }
}
