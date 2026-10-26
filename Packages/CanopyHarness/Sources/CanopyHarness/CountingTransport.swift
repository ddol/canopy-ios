import CanopyReference
import Foundation

/// A transport that counts what another one receives, per method: for measuring a real server from the client's side.
public final class CountingTransport: GRPCTransport, @unchecked Sendable {
    public let base: any GRPCTransport
    private let lock = NSLock()
    private var counted = StandInServer.Stats()

    public init(_ base: any GRPCTransport) {
        self.base = base
    }

    public var stats: StandInServer.Stats { lock.withLock { counted } }

    public func reset() {
        lock.withLock { counted = StandInServer.Stats() }
    }

    public func call(_ path: String, requests: [Data]) -> AsyncThrowingStream<Data, any Error> {
        let method = path.split(separator: "/").last.map(String.init) ?? path
        lock.withLock { counted.calls[method, default: 0] += 1 }
        let messages = base.call(path, requests: requests)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await message in messages {
                        // The message and its five-byte gRPC frame, as it came (after any decompression).
                        self.lock.withLock { self.counted.bytes[method, default: 0] += message.count + 5 }
                        continuation.yield(message)
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
