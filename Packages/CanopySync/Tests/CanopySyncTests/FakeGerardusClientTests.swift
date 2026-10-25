import CanopyModel
import CryptoKit
import Foundation
import Testing

@testable import CanopySync

@Suite struct FakeGerardusClientTests {
    let author = Player(id: PlayerID(rawValue: "T:_author"), alias: "Author", isTrusted: false, source: .gameCenter)
    let peer = Player(id: PlayerID(rawValue: "T:_peer"), alias: "Peer", isTrusted: false, source: .gameCenter)
    let ranger = Player(id: PlayerID(rawValue: "T:_ranger"), alias: "Ranger", isTrusted: true, source: .gameCenter)
    let tree = TreeCandidate(
        id: UUID(), location: GeoPoint(latitude: 37.7699, longitude: -122.4757), confidence: 0.9, isSynthetic: true
    ).makeTree()

    func changeset(_ kind: FieldObservation.Kind, state: CensusState? = nil) throws -> Changeset {
        let observation = FieldObservation(
            meta: RecordMeta(playerID: author.id, chunk: tree.position.chunk), changesetID: UUID(), kind: kind)
        return try ChangesetBuilder.changeset(
            for: observation, in: state ?? CensusState(trees: [tree]), author: author.id)
    }

    func makeServer() -> FakeGerardusClient {
        FakeGerardusClient(baseEntities: [tree.id: tree.meta.version])
    }

    @Test func authorAloneIsNotEnough() async throws {
        let server = makeServer()
        let submitted = try await server.submit(try changeset(.treeConfirmed(treeID: tree.id)), author: author)
        #expect(submitted.state == .pending)
        #expect(await server.version(of: tree.id) == 1)
    }

    @Test func aTrustedSecondPlayerAppliesIt() async throws {
        let server = makeServer()
        let confirm = try changeset(.treeConfirmed(treeID: tree.id))
        _ = try await server.submit(confirm, author: author)

        let afterPeer = try await server.approve(confirm.id, by: peer)
        #expect(afterPeer.state == .pending, "two untrusted players are not enough")

        let afterRanger = try await server.approve(confirm.id, by: ranger)
        #expect(afterRanger.state == .applied)
        #expect(afterRanger.approvals.map(\.playerID) == [peer.id, ranger.id])
        #expect(await server.version(of: tree.id) == 2)

        let page = await server.pullChanges(in: tree.position.tile, since: 0)
        #expect(page.changes.map(\.op) == confirm.ops)
        #expect(page.latestSequence == 1)
        #expect(await server.pullChanges(in: tree.position.tile, since: 1).changes.isEmpty)
        #expect(await server.openChangesetIDs().isEmpty)
    }

    @Test func staleBaseVersionConflicts() async throws {
        let server = makeServer()
        let first = try changeset(.treeConfirmed(treeID: tree.id))
        let second = try changeset(.treeRejected(treeID: tree.id))  // also against version 1
        _ = try await server.submit(first, author: author)
        _ = try await server.submit(second, author: author)
        #expect(try await server.approve(first.id, by: ranger).state == .applied)
        #expect(try await server.approve(second.id, by: ranger).state == .conflicted)
        #expect(await server.version(of: tree.id) == 2)
    }

    @Test func chainedOpsInOneChangesetApply() async throws {
        let server = makeServer()
        let dbh = DBH(diameter: Quantity(0.5, uncertainty: 0.01), method: .lidarCircleFit)
        let mesh = Data("mesh".utf8)
        let ref = BlobRef(rawValue: SHA256.hash(data: mesh).map { String(format: "%02x", $0) }.joined())!
        var builder = ChangesetBuilder(author: author.id, state: CensusState(trees: [tree]))
        try builder.add(
            FieldObservation(
                meta: RecordMeta(playerID: author.id, chunk: tree.position.chunk), changesetID: nil,
                kind: .treeConfirmed(treeID: tree.id)))
        try builder.add(
            FieldObservation(
                meta: RecordMeta(playerID: author.id, chunk: tree.position.chunk), changesetID: nil,
                kind: .trunkMeasured(treeID: tree.id, dbh: dbh, lean: nil, evidence: ref)))
        let both = try builder.build()

        await #expect(throws: GerardusError.missingBlobs([ref])) {
            try await server.submit(both, author: ranger)
        }
        await #expect(throws: GerardusError.blobHashMismatch(ref)) {
            try await server.uploadBlob(Data("not the mesh".utf8), ref: ref)
        }
        try await server.uploadBlob(mesh, ref: ref)
        _ = try await server.submit(both, author: ranger)
        #expect(try await server.approve(both.id, by: peer).state == .applied)
        #expect(await server.version(of: tree.id) == 3)
    }

    @Test func creatingAnExistingEntityConflicts() async throws {
        let server = makeServer()
        var duplicate = tree
        duplicate.meta.playerID = author.id
        let create = try changeset(.treeAdded(duplicate), state: CensusState())
        _ = try await server.submit(create, author: ranger)
        #expect(try await server.approve(create.id, by: peer).state == .conflicted)
    }

    @Test func rejectAndResubmit() async throws {
        let server = makeServer()
        let confirm = try changeset(.treeConfirmed(treeID: tree.id))
        _ = try await server.submit(confirm, author: author)
        #expect(try await server.reject(confirm.id).state == .rejected)
        #expect(try await server.approve(confirm.id, by: ranger).state == .rejected)
        await #expect(throws: GerardusError.alreadySubmitted(confirm.id)) {
            try await server.submit(confirm, author: author)
        }
        await #expect(throws: GerardusError.unknownChangeset(tree.id)) {
            try await server.approve(tree.id, by: ranger)
        }
    }
}

@Suite struct SyncCoordinatorTests {
    let author = Player(id: PlayerID(rawValue: "T:_author"), alias: "Author", isTrusted: false, source: .gameCenter)
    let ranger = Player(id: PlayerID(rawValue: "T:_ranger"), alias: "Ranger", isTrusted: true, source: .gameCenter)

    @Test func submitsUploadsAndBringsBackState() async throws {
        let tree = TreeCandidate(
            id: UUID(), location: GeoPoint(latitude: 37.7720, longitude: -122.4602), confidence: 0.8,
            isSynthetic: true
        ).makeTree()
        let mesh = Data("trunk mesh".utf8)
        let ref = BlobRef(rawValue: SHA256.hash(data: mesh).map { String(format: "%02x", $0) }.joined())!
        let measure = try ChangesetBuilder.changeset(
            for: FieldObservation(
                meta: RecordMeta(playerID: author.id, chunk: tree.position.chunk), changesetID: UUID(),
                kind: .trunkMeasured(
                    treeID: tree.id, dbh: DBH(diameter: Quantity(0.3, uncertainty: 0.01), method: .lidarCircleFit),
                    lean: nil, evidence: ref)),
            in: CensusState(trees: [tree]),
            author: author.id
        )
        #expect(measure.referencedBlobs == [ref])

        let server = FakeGerardusClient(baseEntities: [tree.id: 1])
        let sync = SyncCoordinator(client: server)
        let blobs = ["\(ref.rawValue)": mesh]

        let first = try await sync.sync([measure], author: author) { blobs[$0.rawValue]! }
        #expect(first.submitted == 1)
        #expect(first.blobsUploaded == 1)
        #expect(first.updated.isEmpty, "still pending, nothing changed")
        #expect(first.known == [measure.id])

        try await server.approve(measure.id, by: ranger)
        let second = try await sync.sync([measure], author: author) { blobs[$0.rawValue]! }
        #expect(second.submitted == 0)
        #expect(second.known == [measure.id])
        #expect(second.updated.map(\.state) == [.applied])
        #expect(second.updated.first?.approvals.map(\.playerID) == [ranger.id])

        let third = try await sync.sync(second.updated, author: author) { blobs[$0.rawValue]! }
        #expect(third == SyncCoordinator.Report.empty(at: third.finishedAt))
    }
}

extension SyncCoordinator.Report {
    static func empty(at date: Date) -> Self {
        var report = Self()
        report.finishedAt = date
        return report
    }
}
