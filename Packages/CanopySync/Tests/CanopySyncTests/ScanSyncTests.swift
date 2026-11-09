import CanopyModel
import CryptoKit
import Foundation
import Testing

@testable import CanopySync

/// A scan is named by its hash on the phone and on the server: a sync sends each scan once, every changeset that names
/// it still does, and sending it again keeps one copy.
@Suite struct ScanSyncTests {
    let author = Player(id: PlayerID(rawValue: "T:_author"), alias: "Author", isTrusted: false, source: .gameCenter)
    let ranger = Player(id: PlayerID(rawValue: "T:_ranger"), alias: "Ranger", isTrusted: true, source: .gameCenter)
    let trees = [
        TreeCandidate(
            id: UUID(), location: GeoPoint(latitude: 37.7720, longitude: -122.4602), confidence: 0.8, isSynthetic: true
        ).makeTree(),
        TreeCandidate(
            id: UUID(), location: GeoPoint(latitude: 37.7721, longitude: -122.4603), confidence: 0.8, isSynthetic: true
        ).makeTree(),
    ]
    let mesh = Data("trunk mesh".utf8)
    var ref: BlobRef { BlobRef(rawValue: SHA256.hash(data: mesh).map { String(format: "%02x", $0) }.joined())! }

    /// Measurements of two trees from one scan, as Save tapped twice on a new tree recorded them before saves were
    /// deduplicated.
    func duplicateMeasurements() throws -> [Changeset] {
        let dbh = DBH(diameter: Quantity(0.3, uncertainty: 0.01), method: .lidarCircleFit)
        return try trees.map { tree in
            try ChangesetBuilder.changeset(
                for: FieldObservation(
                    meta: RecordMeta(playerID: author.id, chunk: tree.position.chunk), changesetID: UUID(),
                    kind: .trunkMeasured(treeID: tree.id, dbh: dbh, lean: nil, evidence: ref)),
                in: CensusState(trees: trees), author: author.id)
        }
    }

    @Test func aScanNamedTwiceIsUploadedOnceAndBothChangesetsKeepIt() async throws {
        let measurements = try duplicateMeasurements()
        #expect(measurements.map(\.referencedBlobs) == [[ref], [ref]])
        let server = FakeGerardusClient(baseEntities: Dictionary(uniqueKeysWithValues: trees.map { ($0.id, 1) }))
        let sync = SyncCoordinator(client: server)
        let mesh = mesh

        let report = try await sync.sync(measurements, author: author) { _ in mesh }
        #expect(report.submitted == 2)
        #expect(report.blobsUploaded == 1)
        #expect(await server.blobRefs() == [ref])

        // The server took both, each naming the one copy it holds, and applies both.
        for measurement in measurements {
            #expect(try await server.approve(measurement.id, by: ranger).state == .applied)
        }
        #expect(await server.changesets(measurements.map(\.id)).map(\.referencedBlobs) == [[ref], [ref]])
    }

    @Test func syncingOrUploadingAgainAddsNothing() async throws {
        let measurements = try duplicateMeasurements()
        let server = FakeGerardusClient(baseEntities: Dictionary(uniqueKeysWithValues: trees.map { ($0.id, 1) }))
        let sync = SyncCoordinator(client: server)
        let mesh = mesh
        _ = try await sync.sync(measurements, author: author) { _ in mesh }

        let again = try await sync.sync(measurements, author: author) { _ in mesh }
        #expect(again.submitted == 0)
        #expect(again.blobsUploaded == 0)
        #expect(again.known == Set(measurements.map(\.id)))

        try await server.uploadBlob(mesh, ref: ref)
        #expect(await server.blobRefs() == [ref])
        #expect(await server.openChangesetIDs().count == 2)
    }
}
