import Foundation

/// A client for a Gerardus align server (gerardus.align.v1alpha1): sites and their reference layers, and
/// registering scans against them.
public struct AlignClient: Sendable {
    public static let site = "/gerardus.align.v1alpha1.SiteService/"
    public static let registration = "/gerardus.align.v1alpha1.RegistrationService/"

    public let transport: any GRPCTransport

    public init(transport: any GRPCTransport) {
        self.transport = transport
    }

    public init(baseURL: URL) {
        self.init(transport: URLSessionGRPCTransport(baseURL: baseURL))
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
        return map(transport.call(Self.site + "PrepareSite", requests: [request.data])) { fields in
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
        map(transport.call(Self.site + "StreamReference", requests: [request.serialized])) { fields in
            var layer = ReferenceLayer.unspecified
            var chunk: ReferenceChunk?
            var complete = false
            for f in fields {
                switch f.number {
                case 1: layer = ReferenceLayer(rawValue: f.int) ?? .unspecified
                case 2: chunk = .points(layer, try PointBlock(f))
                case 3:
                    let lines = try ProtoReader.fields(f.bytes).filter { $0.number == 1 }.map { try LineFeature($0) }
                    chunk = .lines(layer, lines)
                case 7: chunk = .groundMesh(try Heightfield(f))
                case 5: complete = f.bool
                case 4, 6: chunk = .other(layer)
                default: break
                }
            }
            // The layer field may follow the payload on the wire; fix the layer up once everything is read.
            switch chunk {
            case .points(_, let block): chunk = .points(layer, block)
            case .lines(_, let lines): chunk = .lines(layer, lines)
            case .other: chunk = .other(layer)
            default: break
            }
            if chunk == nil, complete { return .layerComplete(layer) }
            return chunk
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
        for try await data in transport.call(Self.registration + "UploadScan", requests: messages) {
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
        return map(transport.call(Self.registration + "Register", requests: [request.data])) { fields in
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

    func unaryFields(_ path: String, _ request: Data) async throws -> [ProtoField] {
        for try await data in transport.call(path, requests: [request]) {
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
