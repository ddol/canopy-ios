import Foundation

/// A URLProtocol that answers requests for a host with a canned response, and records what it was sent. Each test
/// uses its own host, so tests can run in parallel.
final class StubServer: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body = Data()
    }

    struct Received: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: @Sendable (Received) -> Reply] = [:]
    nonisolated(unsafe) private static var received: [String: [Received]] = [:]

    /// A session whose requests to `host` are answered by `reply`.
    static func session(host: String, reply: @escaping @Sendable (Received) -> Reply) -> URLSession {
        lock.withLock { replies[host] = reply }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubServer.self]
        return URLSession(configuration: configuration)
    }

    static func requests(to host: String) -> [Received] {
        lock.withLock { received[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host ?? ""
        let incoming = Received(
            method: request.httpMethod ?? "", path: request.url?.path ?? "",
            headers: request.allHTTPHeaderFields ?? [:])
        let reply: Reply? = Self.lock.withLock {
            Self.received[host, default: []].append(incoming)
            return Self.replies[host].map { $0(incoming) }
        }
        guard let reply, let url = request.url,
            let response = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
