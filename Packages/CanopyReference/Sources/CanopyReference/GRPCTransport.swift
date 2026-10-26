import CanopyModel
import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A gRPC call that failed with a status from the server.
public struct GRPCStatusError: Error, Equatable, LocalizedError {
    public static let notFound = 5
    public static let permissionDenied = 7
    public static let unimplemented = 12
    public static let unavailable = 14

    public var code: Int
    public var message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { "gRPC status \(code): \(message)" }
}

public enum GRPCTransportError: Error, Equatable, LocalizedError {
    case http(Int)
    case notGRPC(String)
    case compressedMessage
    case noResponse
    /// The call ran past its time limit and was cancelled.
    case timedOut(seconds: Int)
    /// A reference stream ended before every layer had finished.
    case incomplete

    public var errorDescription: String? {
        switch self {
        case .http(let code): "The server answered with HTTP \(code)."
        case .notGRPC(let type): "The server did not answer with gRPC (\(type))."
        case .compressedMessage: "The server sent a message compressed in a way Canopy cannot read."
        case .noResponse: "The server closed the call without an answer."
        case .timedOut(let seconds): "The server did not finish within \(seconds)\u{202F}s."
        case .incomplete: "The server stopped before sending all of the area. Try again."
        }
    }
}

/// Moves gRPC messages to and from a server. Requests are sent whole (client streaming sends all its messages
/// in one body); responses stream as they arrive.
public protocol GRPCTransport: Sendable {
    func call(_ path: String, requests: [Data]) -> AsyncThrowingStream<Data, any Error>
}

/// Who is calling, as a Gerardus server reads it from every request's metadata: the Game Center team-scoped player
/// id (or `local:<uuid>` before sign-in) and the alias. The server keys accounts, roles and OpenStreetMap access on
/// the id, which it does not verify yet.
public enum GerardusIdentity {
    public static func headers(for player: Player) -> [String: String] {
        // RFC 3986 unreserved characters stay as they are; everything else in the alias is percent-encoded.
        var unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        unreserved.insert(charactersIn: "-._~")
        return [
            "x-gerardus-player-id": player.id.rawValue,
            "x-gerardus-player-alias": player.alias.addingPercentEncoding(withAllowedCharacters: unreserved)
                ?? "",
        ]
    }
}

/// gRPC over HTTP/1.1 with URLSession, which cannot speak cleartext HTTP/2. The Gerardus align server accepts
/// HTTP/1.1. HTTP/1.1 trailers are not visible to URLSession, so a status the server sends after messages is
/// lost; a failure before any message arrives in the headers ("trailers-only") and is reported.
///
/// Calls accept gzip: a server that compresses its answers (`grpc-encoding: gzip`) sends a third or so less.
public final class URLSessionGRPCTransport: GRPCTransport {
    public let baseURL: URL
    /// Request metadata sent with every call, such as the player's identity (`GerardusIdentity`).
    public let headers: [String: String]
    private let session: URLSession
    private let router: Router

    /// - Parameter idleTimeout: how long a call may go without receiving data. Site preparation and
    ///   registration stream progress, so this is the gap between messages, not the length of the call;
    ///   `AlignClient.Timeouts` limits the length.
    public init(baseURL: URL, idleTimeout: TimeInterval = 30, headers: [String: String] = [:]) {
        self.baseURL = baseURL
        self.headers = headers
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = idleTimeout
        configuration.timeoutIntervalForResource = 3600
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = ["User-Agent": "Canopy/0.1 grpc-swift-minimal"]
        let router = Router()
        self.router = router
        self.session = URLSession(configuration: configuration, delegate: router, delegateQueue: router.queue)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func call(_ path: String, requests: [Data]) -> AsyncThrowingStream<Data, any Error> {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("gzip, identity", forHTTPHeaderField: "grpc-accept-encoding")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        var body = Data()
        for message in requests {
            body.append(0)
            withUnsafeBytes(of: UInt32(message.count).bigEndian) { body.append(contentsOf: $0) }
            body.append(message)
        }
        request.httpBody = body

        return AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            router.register(task.taskIdentifier, Call(continuation: continuation))
            // The stream keeps the transport (and so its session) alive until the call ends.
            continuation.onTermination = { [self] _ in
                task.cancel()
                withExtendedLifetime(self) {}
            }
            task.resume()
        }
    }

    /// Per-call state: the frame buffer and where to send messages.
    final class Call {
        let continuation: AsyncThrowingStream<Data, any Error>.Continuation
        var buffer = Data()
        /// The server's `grpc-encoding`, which compressed messages are in.
        var encoding = "identity"

        init(continuation: AsyncThrowingStream<Data, any Error>.Continuation) {
            self.continuation = continuation
        }

        func receive(_ data: Data) throws {
            buffer.append(data)
            while buffer.count >= 5 {
                let start = buffer.startIndex
                let compressed = buffer[start]
                let length = buffer[(start + 1)..<(start + 5)].reduce(0) { $0 << 8 | Int($1) }
                guard buffer.count >= 5 + length else { return }
                let message = Data(buffer[(start + 5)..<(start + 5 + length)])
                switch (compressed, encoding) {
                case (0, _): continuation.yield(message)
                case (1, "gzip"):
                    guard let plain = try? Gzip.decompress(message) else {
                        throw GRPCTransportError.compressedMessage
                    }
                    continuation.yield(plain)
                default: throw GRPCTransportError.compressedMessage
                }
                buffer.removeSubrange(start..<(start + 5 + length))
            }
        }
    }

    /// Routes URLSession callbacks to calls. All callbacks run on `queue`, a serial queue, which is the only
    /// place `calls` is touched; `register` hops onto it too.
    final class Router: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let queue: OperationQueue = {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.name = "canopy.grpc"
            return queue
        }()
        private var calls: [Int: Call] = [:]
        private let lock = NSLock()

        func register(_ id: Int, _ call: Call) {
            lock.withLock { calls[id] = call }
        }

        private func call(_ id: Int) -> Call? {
            lock.withLock { calls[id] }
        }

        private func finish(_ id: Int, error: (any Error)?) {
            let call = lock.withLock { calls.removeValue(forKey: id) }
            if let error {
                call?.continuation.finish(throwing: error)
            } else {
                call?.continuation.finish()
            }
        }

        func urlSession(
            _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
        ) {
            let id = dataTask.taskIdentifier
            guard let http = response as? HTTPURLResponse else {
                finish(id, error: GRPCTransportError.noResponse)
                completionHandler(.cancel)
                return
            }
            if let status = http.value(forHTTPHeaderField: "grpc-status"), let code = Int(status), code != 0 {
                let message = http.value(forHTTPHeaderField: "grpc-message")?.removingPercentEncoding ?? ""
                finish(id, error: GRPCStatusError(code: code, message: message))
                completionHandler(.cancel)
                return
            }
            guard http.statusCode == 200 else {
                finish(id, error: GRPCTransportError.http(http.statusCode))
                completionHandler(.cancel)
                return
            }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            guard type.hasPrefix("application/grpc") else {
                finish(id, error: GRPCTransportError.notGRPC(type))
                completionHandler(.cancel)
                return
            }
            if let encoding = http.value(forHTTPHeaderField: "grpc-encoding") {
                call(id)?.encoding = encoding
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try call(dataTask.taskIdentifier)?.receive(data)
            } catch {
                finish(dataTask.taskIdentifier, error: error)
                dataTask.cancel()
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error = error as? URLError, error.code == .cancelled {
                finish(task.taskIdentifier, error: nil)
            } else {
                finish(task.taskIdentifier, error: error)
            }
        }
    }
}
