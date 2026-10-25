import Foundation
import Testing

@testable import CanopyModel

@Suite struct ChangesetNeedTests {
    let author = PlayerID(rawValue: "T:_author")

    func changeset(_ approvals: [(String, Bool)]) -> Changeset {
        let chunk = GeoPoint(latitude: 37.7699, longitude: -122.4757).chunk
        return Changeset(
            meta: RecordMeta(playerID: author, chunk: chunk),
            ops: [
                ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 1, fields: ["countStatus": "confirmed"])
            ],
            tiles: [chunk.parent(level: S2CellID.tileLevel)],
            approvals: approvals.map {
                Changeset.Approval(playerID: PlayerID(rawValue: $0.0), isTrusted: $0.1, at: .now)
            })
    }

    @Test func aRegularPlayerAloneNeedsATrustedPlayer() {
        #expect(changeset([]).need(authorTrusted: false) == .trustedPlayer)
        #expect(changeset([("T:_friend", false)]).need(authorTrusted: false) == .trustedPlayer)
        #expect(changeset([("T:_ranger", true)]).need(authorTrusted: false) == .nothing)
    }

    @Test func aTrustedAuthorNeedsAnyOneElse() {
        #expect(changeset([]).need(authorTrusted: true) == .anotherPlayer)
        #expect(changeset([("T:_friend", false)]).need(authorTrusted: true) == .nothing)
        // Agreeing with your own change counts once.
        #expect(changeset([("T:_author", true)]).need(authorTrusted: false) == .anotherPlayer)
    }

    @Test func theRejectionReasonIsKeptAndOldPayloadsStillRead() throws {
        var rejected = changeset([])
        rejected.state = .rejected
        rejected.stateReason = "No tree here, only a shrub"
        let data = try CanopyJSON.encoder.encode(rejected)
        #expect(try CanopyJSON.decoder.decode(Changeset.self, from: data).stateReason == "No tree here, only a shrub")

        // Saved before the field existed.
        var old = try #require(try JSONValue(encoding: changeset([])).objectValue)
        old["stateReason"] = nil
        let decoded = try CanopyJSON.decoder.decode(
            Changeset.self, from: try CanopyJSON.encoder.encode(JSONValue.object(old)))
        #expect(decoded.stateReason == nil)
    }
}
