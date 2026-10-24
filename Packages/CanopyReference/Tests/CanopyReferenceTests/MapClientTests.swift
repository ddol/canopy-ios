import CanopyModel
import CanopySync
import Foundation
import Testing

@testable import CanopyReference

@Suite struct MapClientTests {
    let player = Player(id: PlayerID(rawValue: "T:_tester"), alias: "Ana Lucía", source: .gameCenter)
    let tile = GeoPoint(latitude: 37.7705, longitude: -122.4760).tile

    func fields(_ data: Data) throws -> [ProtoField] { try ProtoReader.fields(ArraySlice([UInt8](data))) }

    func changeset() -> Changeset {
        let tree = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        let chunk = GeoPoint(latitude: 37.7705, longitude: -122.4760).chunk
        return Changeset(
            meta: RecordMeta(
                id: UUID(uuidString: "A1B2C3D4-0000-4000-8000-000000000001")!,
                createdAt: Date(timeIntervalSince1970: 1_761_200_000.123), playerID: player.id, chunk: chunk),
            ops: [ChangeOp(op: .update, entity: .tree, id: tree, baseVersion: 1, fields: ["countStatus": "confirmed"])],
            tiles: [tile])
    }

    @Test func playersAreNamedInEveryCall() {
        let headers = GerardusIdentity.headers(for: player)
        #expect(headers["x-gerardus-player-id"] == "T:_tester")
        #expect(headers["x-gerardus-player-alias"] == "Ana%20Luc%C3%ADa")
    }

    @Test func aChangesetGoesOutInTheMapServiceShapeAndComesBackWithItsState() async throws {
        var approval = ProtoWriter()
        approval.string(1, "T:_ranger")
        approval.bool(2, true)
        approval.message(3) { $0.uint(1, 1_761_200_100) }
        var view = ProtoWriter()
        view.message(1) { MapMessages.encode(changeset(), to: &$0) }
        // The server's view: applied, with a trusted approval.
        var answer = ProtoWriter()
        answer.message(1) { w in
            MapMessages.encode(changeset(), to: &w)
            w.enumValue(7, 3)
            w.message(8) { $0 = approval }
        }
        let mock = MockTransport()
        mock.responses[GerardusMapClient.service + "SubmitChangeset"] = .success([answer.data])
        let result = try await GerardusMapClient(transport: mock).submit(changeset(), author: player)

        let sent = try #require(mock.sent.first)
        #expect(sent.path == "/gerardus.map.v1alpha1.MapService/SubmitChangeset")
        let message = try fields(Data(try #require(try fields(sent.requests[0]).first).bytes))
        #expect(message.first { $0.number == 1 }?.string == "a1b2c3d4-0000-4000-8000-000000000001")
        #expect(message.first { $0.number == 2 }?.string == "T:_tester")
        let created = try ProtoReader.fields(try #require(message.first { $0.number == 3 }).bytes)
        #expect(created.first { $0.number == 1 }?.uint == 1_761_200_000)
        #expect(created.first { $0.number == 2 }?.uint == 123_000_000)
        #expect(message.first { $0.number == 5 }?.string == tile.token)
        #expect(message.first { $0.number == 9 }?.string == "trees")
        let op = try ProtoReader.fields(try #require(message.first { $0.number == 6 }).bytes)
        #expect(op.first { $0.number == 1 }?.int == 2)  // UPDATE
        #expect(op.first { $0.number == 2 }?.int == 1)  // TREE
        #expect(op.first { $0.number == 3 }?.string == "6f9619ff-8b86-d011-b42d-00c04fc964ff")
        #expect(op.first { $0.number == 4 }?.int == 1)
        #expect(op.first { $0.number == 5 }?.string == #"{"countStatus":"confirmed"}"#)

        #expect(result.state == .applied)
        #expect(
            result.approvals == [
                Changeset.Approval(
                    playerID: PlayerID(rawValue: "T:_ranger"), isTrusted: true,
                    at: Date(timeIntervalSince1970: 1_761_200_100))
            ])
        #expect(result.ops == changeset().ops)
        #expect(result.meta.createdAt == changeset().meta.createdAt)
        #expect(result.tiles == [tile])
    }

    @Test func missingBlobsAreReportedNotStored() async throws {
        let ref = String(repeating: "ab", count: 32)
        var answer = ProtoWriter()
        answer.string(2, ref)
        let mock = MockTransport()
        mock.responses[GerardusMapClient.service + "SubmitChangeset"] = .success([answer.data])
        await #expect(throws: GerardusError.missingBlobs([BlobRef(rawValue: ref)!])) {
            _ = try await GerardusMapClient(transport: mock).submit(changeset(), author: player)
        }
    }

    @Test func pullingFollowsPagesToTheEnd() async throws {
        func page(_ sequences: [Int64], latest: Int64, more: Bool) -> Data {
            var w = ProtoWriter()
            for sequence in sequences {
                w.message(1) { change in
                    change.uint(1, UInt64(sequence))
                    change.string(2, "a1b2c3d4-0000-4000-8000-000000000001")
                    change.string(3, tile.token)
                    change.message(4) { MapMessages.encode(changeset().ops[0], to: &$0) }
                }
            }
            w.uint(2, UInt64(latest))
            w.bool(3, more)
            return w.data
        }
        // The mock answers every call the same, so answer by request instead.
        final class Pages: GRPCTransport, @unchecked Sendable {
            let pages: [Int64: Data]
            init(_ pages: [Int64: Data]) { self.pages = pages }
            func call(_ path: String, requests: [Data]) -> AsyncThrowingStream<Data, any Error> {
                let since =
                    (try? ProtoReader.fields(ArraySlice([UInt8](requests[0]))))?.first { $0.number == 2 }?.uint ?? 0
                let page = pages[Int64(since)]
                return AsyncThrowingStream { continuation in
                    if let page { continuation.yield(page) }
                    continuation.finish()
                }
            }
        }
        let client = GerardusMapClient(
            transport: Pages([0: page([1, 2], latest: 2, more: true), 2: page([3], latest: 3, more: false)]))
        let result = try await client.pullChanges(in: tile, since: 0)
        #expect(result.changes.map(\.sequence) == [1, 2, 3])
        #expect(result.latestSequence == 3)
        #expect(result.changes[0].tile == tile)
        #expect(result.changes[0].op == changeset().ops[0])
    }

    @Test func detectedTreesGoOutWithTheirIdsAndSource() async throws {
        let location = GeoPoint(latitude: 37.770512, longitude: -122.476031)
        let candidates = [
            TreeCandidate(
                id: AerialTrees.stableID(location), location: location, height: 21.5, crownRadius: 4,
                confidence: 0.8, isSynthetic: false, source: "USGS 3DEP"),
            TreeCandidate(
                id: AerialTrees.stableID(location), location: location, confidence: 0.4, isSynthetic: false,
                source: "USGS 3DEP"),
        ]
        var answer = ProtoWriter()
        answer.uint(2, 1)
        answer.uint(4, 1)
        let mock = MockTransport()
        mock.responses[GerardusMapClient.service + "ImportDetectedTrees"] = .success([answer.data])
        let result = try await GerardusMapClient(transport: mock).importDetectedTrees(
            candidates, source: "USGS 3DEP", tiles: [tile], detector: "test")
        #expect(result == GerardusMapClient.ImportResult(created: 1, alreadyPresent: 0, occupied: 1, refused: []))

        let request = try fields(try #require(mock.sent.first).requests[0])
        let trees = try request.filter { $0.number == 1 }.map { try ProtoReader.fields($0.bytes) }
        #expect(trees.count == 2)
        #expect(trees[0].first { $0.number == 1 }?.string == candidates[0].id.uuidString.lowercased())
        #expect(trees[0].first { $0.number == 2 }?.double == location.latitude)
        #expect(trees[0].first { $0.number == 4 }?.double == 21.5)
        #expect(!trees[1].contains { $0.number == 4 })  // no height: not sent
        #expect(request.first { $0.number == 2 }?.string == "USGS 3DEP")
        #expect(request.first { $0.number == 3 }?.string == tile.token)
    }

    @Test func theReviewQueueAndSnapshotsCarryWhoAndWhere() async throws {
        var open = ProtoWriter()
        open.message(1) { w in
            MapMessages.encode(changeset(), to: &w)
            w.enumValue(7, 1)
            w.string(10, "Walker")
            w.bool(11, true)
        }
        var snapshot = ProtoWriter()
        snapshot.message(1) { entity in
            entity.enumValue(1, 1)
            entity.string(2, "6f9619ff-8b86-d011-b42d-00c04fc964ff")
            entity.uint(3, 4)
            entity.string(4, #"{"countStatus":"confirmed","s2_l19_token":"8085876c3c"}"#)
            entity.string(5, tile.token)
            entity.string(6, "gerardus:aerial")
            entity.message(7) { $0.uint(1, 1_761_200_000) }
        }
        snapshot.uint(2, 42)
        let mock = MockTransport()
        mock.responses[GerardusMapClient.service + "ListOpenChangesets"] = .success([open.data])
        mock.responses[GerardusMapClient.service + "GetTile"] = .success([snapshot.data])
        let client = GerardusMapClient(transport: mock)

        let queue = try await client.openChangesets(in: tile)
        #expect(queue.map(\.changeset.id) == [changeset().id])
        #expect(queue.first?.authorAlias == "Walker")
        #expect(queue.first?.authorTrusted == true)

        let tileSnapshot = try await client.tile(tile)
        #expect(tileSnapshot.latestSequence == 42)
        let record = try #require(tileSnapshot.entities.first?.record)
        #expect(record.kind == .tree)
        #expect(record.version == 4)
        #expect(record.tile == tile)
        #expect(record.createdBy == .aerialSurvey)
        #expect(record.createdAt == Date(timeIntervalSince1970: 1_761_200_000))
        #expect(record.fields["countStatus"] == "confirmed")
    }
}
