import CanopyReference
import Foundation
import Network

/// What a call answers: messages, each after a delay from the start of the answer, then a status. A failure with no
/// messages goes in the headers ("trailers-only"), as the real server sends it, so a client on HTTP/1.1 sees it.
public struct GRPCReply: Sendable {
    public struct Event: Sendable {
        public var after: Duration
        public var data: Data
    }

    public var events: [Event]
    public var status = 0
    public var message = ""

    public static func messages(_ messages: [Data]) -> GRPCReply {
        GRPCReply(events: messages.map { Event(after: .zero, data: $0) })
    }

    public static func status(_ code: Int, _ message: String) -> GRPCReply {
        GRPCReply(events: [], status: code, message: message)
    }
}

/// How the link between the phone and the server behaves.
public struct NetworkProfile: Sendable, Equatable, CustomStringConvertible {
    public var name: String
    /// Round trip: added once before each answer, and once more for a new connection's handshake.
    public var rtt: Duration
    /// Download bytes per second, shared by every connection; nil for no limit.
    public var bytesPerSecond: Double?

    public init(name: String, rtt: Duration, bytesPerSecond: Double?) {
        self.name = name
        self.rtt = rtt
        self.bytesPerSecond = bytesPerSecond
    }

    /// No shaping: as fast as loopback goes.
    public static let loopback = NetworkProfile(name: "loopback", rtt: .zero, bytesPerSecond: nil)
    /// A server on the same Wi-Fi, as measured in the backlog: 4 MB in about a second.
    public static let lan = NetworkProfile(name: "lan", rtt: .milliseconds(4), bytesPerSecond: 12_000_000)
    /// Tailscale over LTE in the park: about 8 Mbit/s down and 120 ms round trips.
    public static let cellular = NetworkProfile(name: "cellular", rtt: .milliseconds(120), bytesPerSecond: 1_000_000)
    /// One bar under the trees: 2 Mbit/s and 300 ms.
    public static let poor = NetworkProfile(name: "poor", rtt: .milliseconds(300), bytesPerSecond: 250_000)

    public static let all: [NetworkProfile] = [.loopback, .lan, .cellular, .poor]

    public var description: String {
        let rate = bytesPerSecond.map { String(format: "%.1f Mbit/s", $0 * 8 / 1e6) } ?? "unlimited"
        return "\(name) (\(Int(rtt.timeInterval * 1000)) ms, \(rate))"
    }
}

/// A Gerardus server on this machine: gRPC over HTTP/1.1 (what `URLSessionGRPCTransport` speaks), answered by a
/// handler, with the link shaped to a `NetworkProfile` and every call counted. An app in the iOS Simulator reaches it
/// at `127.0.0.1` too.
public final class StandInServer: @unchecked Sendable {
    /// Calls and bytes, per method.
    public struct Stats: Sendable, Equatable, Codable {
        public var calls: [String: Int] = [:]
        public var bytes: [String: Int] = [:]
        public var connections = 0

        public var totalCalls: Int { calls.values.reduce(0, +) }
        public var totalBytes: Int { bytes.values.reduce(0, +) }

        public func calls(_ method: String) -> Int { calls[method] ?? 0 }
        public func bytes(_ method: String) -> Int { bytes[method] ?? 0 }
    }

    public typealias Handler = @Sendable (_ path: String, _ request: [UInt8]) -> GRPCReply

    /// Whether answers are compressed with gzip for clients that accept it, as a server with compression on does.
    public var compresses: Bool {
        get { queue.sync { compressing } }
        set { queue.sync { compressing = newValue } }
    }
    private var compressing = false

    public var profile: NetworkProfile {
        get { queue.sync { link.profile } }
        set { queue.sync { link.profile = newValue } }
    }
    public private(set) var port: UInt16 = 0
    public var url: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private let handler: Handler
    private let started = Date()
    private let queue = DispatchQueue(label: "canopy.harness.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: Connection] = [:]
    private var link: Link
    private var counted = Stats()

    public init(profile: NetworkProfile = .loopback, handler: @escaping Handler) {
        self.link = Link(profile: profile)
        self.handler = handler
    }

    /// A server answering the align service for a synthetic site, and refusing everything else as unimplemented.
    public convenience init(align: StandInAlign, profile: NetworkProfile = .loopback) {
        self.init(profile: profile) { path, request in align.answer(path, request) }
    }

    deinit {
        listener?.cancel()
    }

    /// Starts listening; `port` 0 picks a free one. `anyInterface` also listens beyond loopback, for a phone on the
    /// same network.
    public func start(port: UInt16 = 0, anyInterface: Bool = false) async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if !anyInterface {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        }
        let listener =
            anyInterface
            ? try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
            : try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let ready: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = Once()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.run { continuation.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    resumed.run { continuation.resume(throwing: error) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        queue.sync {
            self.listener = listener
            self.port = ready
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for connection in connections.values { connection.close() }
            connections = [:]
        }
    }

    public var stats: Stats { queue.sync { counted } }

    public func resetStats() {
        queue.sync { counted = Stats() }
    }

    // MARK: Connections

    private func accept(_ nw: NWConnection) {
        let connection = Connection(nw, server: self)
        connections[ObjectIdentifier(connection)] = connection
        counted.connections += 1
        connection.start(queue: queue)
    }

    fileprivate func closed(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    /// Answers a request on `queue`, pacing the reply through the link.
    fileprivate func respond(to request: HTTPRequest, on connection: Connection, firstOnConnection: Bool) {
        let method = request.path.split(separator: "/").last.map(String.init) ?? request.path
        counted.calls[method, default: 0] += 1
        let start = DispatchTime.now() + link.profile.rtt.timeInterval * (firstOnConnection ? 2 : 1)
        if request.method == "GET" {
            let page = Self.statusPage(started: started)
            let head =
                "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: \(page.count)\r\n\r\n"
            connection.send([Data(head.utf8) + page], at: start, count: { _ in })
            return
        }
        // gRPC framing: one flag byte, a big-endian length, the message. Requests carry one message here.
        var message: [UInt8] = []
        if request.body.count >= 5 {
            let length = request.body[1..<5].reduce(0) { $0 << 8 | Int($1) }
            if request.body.count >= 5 + length { message = Array(request.body[5..<(5 + length)]) }
        }
        let reply = handler(request.path, message)

        if reply.events.isEmpty {
            let status = reply.status == 0 ? GRPCStatusError.unimplemented : reply.status
            let head =
                "HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\ngrpc-status: \(status)\r\n"
                + "grpc-message: \(reply.message.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")\r\n"
                + "content-length: 0\r\n\r\n"
            connection.send(
                [Data(head.utf8)], at: start, count: { [weak self] in self?.counted.bytes[method, default: 0] += $0 })
            return
        }
        // Compressed as tonic's send_compressed(Gzip) would, when asked to and the client accepts it.
        let gzip = compressing && (request.headers["grpc-accept-encoding"] ?? "").contains("gzip")
        let head =
            "HTTP/1.1 200 OK\r\ncontent-type: application/grpc\r\ntransfer-encoding: chunked\r\n"
            + (gzip ? "grpc-encoding: gzip\r\n" : "") + "\r\n"
        connection.send([Data(head.utf8)], at: start, count: { _ in })
        for event in reply.events {
            let payload = gzip ? Gzip.compress(event.data) : event.data
            var frame = Data(capacity: payload.count + 16)
            frame.append(contentsOf: Array(String(payload.count + 5, radix: 16).utf8))
            frame.append(contentsOf: [13, 10, gzip ? 1 : 0])
            withUnsafeBytes(of: UInt32(payload.count).bigEndian) { frame.append(contentsOf: $0) }
            frame.append(payload)
            frame.append(contentsOf: [13, 10])
            connection.send(
                Self.slices(frame), at: start + event.after.timeInterval,
                count: { [weak self] in self?.counted.bytes[method, default: 0] += $0 })
        }
        let trailer = "0\r\ngrpc-status: \(reply.status)\r\n\r\n"
        connection.send([Data(trailer.utf8)], at: start, count: { _ in })
    }

    /// Pieces small enough for the pacing to be smooth.
    static func slices(_ data: Data, size: Int = 32 * 1024) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { data.subdata(in: $0..<min(data.count, $0 + size)) }
    }
}

/// One HTTP/1.1 request.
struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data
}

/// The download link: every byte any connection sends queues behind the bytes before it.
struct Link {
    var profile: NetworkProfile
    /// When the link is next free.
    var free = DispatchTime.now()

    /// When `bytes` will have arrived if sent no earlier than `notBefore`; reserves the link until then.
    mutating func reserve(_ bytes: Int, notBefore: DispatchTime) -> DispatchTime {
        let begin = max(notBefore, free, DispatchTime.now())
        guard let rate = profile.bytesPerSecond else { return begin }
        free = begin + Double(bytes) / rate
        return free
    }
}

/// Bytes waiting to go out, and what to count them as once sent.
private struct Piece: Sendable {
    var data: Data
    var notBefore: DispatchTime
    var count: @Sendable (Int) -> Void
}

/// One TCP connection: reads requests one after another (HTTP/1.1 keep-alive) and writes paced replies in order.
private final class Connection: @unchecked Sendable {
    private let nw: NWConnection
    private weak var server: StandInServer?
    private var buffer = Data()
    private var answered = 0
    private var isClosed = false
    /// Sends waiting their turn: a connection's bytes go out in order.
    private var pending: [Piece] = []
    private var sending = false
    private var queue: DispatchQueue!

    init(_ nw: NWConnection, server: StandInServer) {
        self.nw = nw
        self.server = server
    }

    func start(queue: DispatchQueue) {
        self.queue = queue
        nw.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        nw.start(queue: queue)
        receive()
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        pending = []
        nw.cancel()
        server?.closed(self)
    }

    private func receive() {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { buffer.append(data) }
            while let request = parse() {
                server?.respond(to: request, on: self, firstOnConnection: answered == 0)
                answered += 1
            }
            if complete || error != nil {
                close()
            } else {
                receive()
            }
        }
    }

    /// The next whole request in the buffer, removed from it.
    private func parse() -> HTTPRequest? {
        guard let end = buffer.range(of: Data([13, 10, 13, 10])) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(
                in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return nil }
        let bodyStart = end.upperBound
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])
        buffer = Data(buffer[buffer.index(bodyStart, offsetBy: length)...])
        return HTTPRequest(
            method: requestLine.first.map(String.init) ?? "",
            path: requestLine.count > 1 ? String(requestLine[1]) : "/", headers: headers, body: body)
    }

    /// Queues pieces to go out no earlier than `notBefore`, each when the link has room for it.
    func send(_ pieces: [Data], at notBefore: DispatchTime, count: @escaping @Sendable (Int) -> Void) {
        for piece in pieces { pending.append(Piece(data: piece, notBefore: notBefore, count: count)) }
        pump()
    }

    private func pump() {
        guard !sending, !isClosed, !pending.isEmpty, let server else { return }
        sending = true
        let next = pending.removeFirst()
        let arrival = server.reserveLink(next.data.count, notBefore: next.notBefore)
        queue.asyncAfter(deadline: arrival) { [weak self] in
            guard let self, !isClosed else { return }
            nw.send(
                content: next.data,
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    sending = false
                    if error != nil {
                        close()
                        return
                    }
                    next.count(next.data.count)
                    pump()
                })
        }
    }
}

extension StandInServer {
    fileprivate func reserveLink(_ bytes: Int, notBefore: DispatchTime) -> DispatchTime {
        link.reserve(bytes, notBefore: notBefore)
    }
}

/// Runs a closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
