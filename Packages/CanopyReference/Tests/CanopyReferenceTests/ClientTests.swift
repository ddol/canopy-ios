import Foundation
import Testing

@testable import CanopyReference

/// Answers calls with canned messages and records what was sent.
final class MockTransport: GRPCTransport, @unchecked Sendable {
    var responses: [String: Result<[Data], any Error>] = [:]
    private(set) var sent: [(path: String, requests: [Data])] = []
    private let lock = NSLock()

    func call(_ path: String, requests: [Data]) -> AsyncThrowingStream<Data, any Error> {
        lock.withLock { sent.append((path, requests)) }
        let response = lock.withLock { responses[path] } ?? .success([])
        return AsyncThrowingStream { continuation in
            switch response {
            case .success(let messages):
                for m in messages { continuation.yield(m) }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

/// A server that never answers.
struct SilentTransport: GRPCTransport {
    func call(_ path: String, requests: [Data]) -> AsyncThrowingStream<Data, any Error> {
        AsyncThrowingStream { _ in }
    }
}

@Suite struct ClientTests {
    @Test func framesSplitAcrossChunksAreReassembled() async throws {
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        let call = URLSessionGRPCTransport.Call(continuation: continuation)
        let messages = [Data("first".utf8), Data(), Data(repeating: 7, count: 300)]
        var wire = Data()
        for m in messages {
            wire.append(0)
            withUnsafeBytes(of: UInt32(m.count).bigEndian) { wire.append(contentsOf: $0) }
            wire.append(m)
        }
        var offset = 0
        for size in [3, 4, 1, 50, 1000] where offset < wire.count {
            try call.receive(wire[offset..<min(wire.count, offset + size)])
            offset += size
        }
        continuation.finish()
        var received: [Data] = []
        for try await m in stream { received.append(m) }
        #expect(received == messages)

        let other = URLSessionGRPCTransport.Call(
            continuation: AsyncThrowingStream<Data, any Error>.makeStream().continuation)
        #expect(throws: GRPCTransportError.compressedMessage) {
            try other.receive(Data([1, 0, 0, 0, 1, 42]))
        }
    }

    @Test func unpreparedSiteIsNil() async throws {
        let mock = MockTransport()
        mock.responses[AlignClient.site + "GetSite"] = .failure(GRPCStatusError(code: 5, message: "not prepared"))
        #expect(try await AlignClient(transport: mock).site("808587b97") == nil)
        let sent = try #require(mock.sent.first)
        #expect(try ProtoReader.fields(ArraySlice([UInt8](sent.requests[0]))).first?.string == "808587b97")
    }

    @Test func referenceChunksDecode() async throws {
        var points = ProtoWriter()
        points.message(2, PointBlock(x: [1, 2], y: [3, 4], z: [90, 91], classification: [1, 2]))
        points.enumValue(1, ReferenceLayer.aerialPoints.rawValue)  // layer after the payload, as allowed
        var mesh = ProtoWriter()
        mesh.enumValue(1, ReferenceLayer.groundMesh.rawValue)
        mesh.message(7) { h in
            h.message(1, Vector3(x: -10, y: -10, z: 0))
            h.float(2, 1)
            h.uint(3, 2)
            h.uint(4, 1)
            h.packedFloats(5, [87, 88])
        }
        mesh.bool(5, true)
        var done = ProtoWriter()
        done.enumValue(1, ReferenceLayer.aerialPoints.rawValue)
        done.bool(5, true)
        let mock = MockTransport()
        mock.responses[AlignClient.site + "StreamReference"] = .success([points.data, mesh.data, done.data])

        var chunks: [ReferenceChunk] = []
        let request = StreamReferenceRequest(l16Token: "8085876c1", layers: [.aerialPoints, .groundMesh], radius: 25)
        for try await chunk in AlignClient(transport: mock).reference(request) { chunks.append(chunk) }
        #expect(chunks.count == 3)
        guard case .points(let layer, let block) = chunks[0] else {
            Issue.record("not points")
            return
        }
        #expect(layer == .aerialPoints)
        #expect(block.classification == [1, 2])
        guard case .groundMesh(let field) = chunks[1] else {
            Issue.record("not a mesh")
            return
        }
        #expect(field.nx == 2)
        #expect(field.height(x: -9.5, y: -10) == 87.5)
        guard case .layerComplete(.aerialPoints) = chunks[2] else {
            Issue.record("not complete")
            return
        }

        let fields = try ProtoReader.fields(ArraySlice([UInt8](mock.sent[0].requests[0])))
        #expect(fields.first { $0.number == 2 }.map { try! $0.varints() } == [1, 7])
        #expect(fields.first { $0.number == 4 }?.float == 25)
    }

    @Test func uploadSplitsPointsIntoBlocks() async throws {
        let mock = MockTransport()
        var reply = ProtoWriter()
        reply.message(1) { s in
            s.string(1, "sha256:abc")
            s.uint(3, 5)
        }
        mock.responses[AlignClient.registration + "UploadScan"] = .success([reply.data])
        let header = ScanHeader(
            l16Token: "8085876c1", sensorID: "canopy-a1b2", sensorModel: "apple-lidar", kind: .accumulated,
            captureRef: "canopy:test", capturedAt: Date(timeIntervalSince1970: 1_792_540_800.5))
        let points = PointBlock(x: [1, 2, 3, 4, 5], y: [0, 0, 0, 0, 0], z: [1, 1, 1, 1, 1])
        let (scan, already) = try await AlignClient(transport: mock).uploadScan(header, points: points, blockSize: 2)
        #expect(scan.scanID == "sha256:abc")
        #expect(scan.pointCount == 5)
        #expect(!already)
        let requests = try #require(mock.sent.first?.requests)
        #expect(requests.count == 4)  // header + 3 blocks
        let first = try ProtoReader.fields(ArraySlice([UInt8](requests[0])))
        #expect(first.map(\.number) == [1])
        let headerFields = try ProtoReader.fields(first[0].bytes)
        #expect(headerFields.first { $0.number == 1 }?.string == "8085876c1")
        #expect(headerFields.first { $0.number == 4 }?.int == ScanKind.accumulated.rawValue)
        let timestamp = try ProtoReader.fields(try #require(headerFields.first { $0.number == 6 }).bytes)
        #expect(timestamp.first { $0.number == 1 }?.uint == 1_792_540_800)
        #expect(timestamp.first { $0.number == 2 }?.uint == 500_000_000)
        let lastBlock = try PointBlock(try #require(try ProtoReader.fields(ArraySlice([UInt8](requests[3]))).first))
        #expect(lastBlock.x == [5])
    }

    @Test func registerEventsDecode() async throws {
        var progress = ProtoWriter()
        progress.message(1) { p in
            p.string(1, "icp")
            p.float(2, 0.5)
        }
        var finished = ProtoWriter()
        finished.message(3) { r in
            r.string(1, "gms:01")
            r.enumValue(5, RegistrationState.candidate.rawValue)
            r.message(6) { h in
                h.string(1, "h1")
                h.message(2, SensorPose(translation: Vector3(x: 1, y: 2, z: 3), rotation: .identity))
            }
            r.message(7) { g in
                g.string(1, "ground_p95_m")
                g.double(2, 0.1)
                g.double(3, 0.2)
                g.bool(4, true)
            }
        }
        let mock = MockTransport()
        mock.responses[AlignClient.registration + "Register"] = .success([progress.data, finished.data])
        var events: [RegisterEvent] = []
        for try await e in AlignClient(transport: mock).register(scanID: "sha256:abc", hint: nil) { events.append(e) }
        #expect(events.count == 2)
        guard case .finished(let registration) = events[1] else {
            Issue.record("no result")
            return
        }
        #expect(registration.state == .candidate)
        #expect(registration.best?.pose?.translation == Vector3(x: 1, y: 2, z: 3))
        #expect(registration.gates.first?.passed == true)
    }

    @Test func callsGiveUpAtTheirTimeLimit() async throws {
        let timeouts = AlignClient.Timeouts(unary: .milliseconds(50), prepare: .seconds(1))
        let client = AlignClient(transport: SilentTransport(), timeouts: timeouts)
        let start = ContinuousClock.now
        await #expect(throws: GRPCTransportError.timedOut(seconds: 0)) {
            _ = try await client.site("8085876c1")
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        await #expect(throws: GRPCTransportError.timedOut(seconds: 1)) {
            _ = try await client.preparedSite("8085876c1", label: "test")
        }
    }
}
