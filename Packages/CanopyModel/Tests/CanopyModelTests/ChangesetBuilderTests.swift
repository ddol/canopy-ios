import Foundation
import Testing

@testable import CanopyModel

@Suite struct ChangesetBuilderTests {
    @Test func confirmingADetectedTreeIsAStatusUpdateAgainstItsVersion() throws {
        let tree = Sample.detectedTree()
        let state = CensusState(trees: [tree])
        let observation = Sample.observation(.treeConfirmed(treeID: tree.id))

        let changeset = try ChangesetBuilder.changeset(for: observation, in: state, author: Sample.player)

        #expect(changeset.id == observation.changesetID)
        #expect(changeset.state == .pending)
        #expect(changeset.approvals.isEmpty)
        #expect(changeset.meta.playerID == Sample.player)
        #expect(changeset.meta.chunk == tree.position.chunk)
        #expect(changeset.tiles == [tree.position.tile])
        #expect(
            changeset.ops == [
                ChangeOp(op: .update, entity: .tree, id: tree.id, baseVersion: 1, fields: ["countStatus": "confirmed"])
            ])
    }

    @Test func notATreeProposesRemoval() throws {
        let tree = Sample.detectedTree()
        let changeset = try ChangesetBuilder.changeset(
            for: Sample.observation(.treeRejected(treeID: tree.id)),
            in: CensusState(trees: [tree]),
            author: Sample.player
        )
        #expect(changeset.ops.map(\.fields) == [["countStatus": "removed"]])
    }

    @Test func newTreeIsACreateWithSharedFieldsOnly() throws {
        let tree = Sample.newTree()
        let changeset = try ChangesetBuilder.changeset(
            for: Sample.observation(.treeAdded(tree), at: Sample.windmill),
            in: CensusState(),
            author: Sample.player
        )
        let op = try #require(changeset.ops.first)
        #expect(op.op == .create)
        #expect(op.entity == .tree)
        #expect(op.id == tree.id)
        #expect(op.baseVersion == 0)
        #expect(op.fields["countStatus"] == "confirmed")
        #expect(op.fields["species"] == "Monterey cypress")
        #expect(op.fields["s2_l19_token"] == .string(tree.position.chunk.token))
        #expect(op.fields["position"]?.objectValue?["geo"] != nil)
        #expect(op.fields["meta"] == nil)
        #expect(op.fields["proposedStatus"] == nil)
        #expect(changeset.tiles == [Sample.windmill.tile])
    }

    @Test func measurementUpdatesDBHLeanEvidenceAndVerifies() throws {
        let tree = Sample.detectedTree()
        let lean = Lean(angle: Quantity(4.5, uncertainty: 0.5))
        let changeset = try ChangesetBuilder.changeset(
            for: Sample.observation(
                .trunkMeasured(treeID: tree.id, dbh: Sample.dbh, lean: lean, evidence: Sample.evidence)),
            in: CensusState(trees: [tree]),
            author: Sample.player
        )
        let op = try #require(changeset.ops.first)
        #expect(op.op == .update)
        #expect(Set(op.fields.keys) == ["dbh", "lean", "evidenceRefs", "countStatus"])
        #expect(try op.fields["dbh"]?.decode(DBH.self) == Sample.dbh)
        #expect(try op.fields["lean"]?.decode(Lean.self) == lean)
        #expect(op.fields["evidenceRefs"] == .array([.string(Sample.evidence.rawValue)]))
        #expect(op.fields["countStatus"] == "verified")
    }

    @Test func severalObservationsAboutOneTreeChainTheirBaseVersions() throws {
        let tree = Sample.detectedTree()
        var builder = ChangesetBuilder(author: Sample.player, createdAt: Sample.date, state: CensusState(trees: [tree]))
        try builder.add(Sample.observation(.treeConfirmed(treeID: tree.id)))
        try builder.add(
            Sample.observation(.trunkMeasured(treeID: tree.id, dbh: Sample.dbh, lean: nil, evidence: Sample.evidence))
        )
        let changeset = try builder.build()
        #expect(changeset.ops.map(\.baseVersion) == [1, 2])
        #expect(changeset.ops.map(\.op) == [.update, .update])
        // The second op does not repeat the confirmation, and lean stays absent.
        #expect(Set(changeset.ops[1].fields.keys) == ["dbh", "evidenceRefs", "countStatus"])
    }

    @Test func tilesAreTheSortedDistinctL16TilesTouched() throws {
        let a = Sample.detectedTree(at: Sample.stowLake)
        let b = Sample.detectedTree(at: Sample.windmill)
        let c = Sample.detectedTree(at: GeoPoint(latitude: 37.76991, longitude: -122.47571))
        var builder = ChangesetBuilder(author: Sample.player, state: CensusState(trees: [a, b, c]))
        for tree in [b, a, c] {
            try builder.add(Sample.observation(.treeConfirmed(treeID: tree.id), at: tree.position.geo))
        }
        let changeset = try builder.build()
        #expect(changeset.tiles == [Sample.stowLake.tile, Sample.windmill.tile].sorted())
        #expect(changeset.meta.chunk == Sample.windmill.chunk)
    }

    @Test func placingATagCreatesIt() throws {
        let tree = Sample.detectedTree()
        let tag = Sample.tag(on: tree)
        let changeset = try ChangesetBuilder.changeset(
            for: Sample.observation(.tagPlaced(tag)),
            in: CensusState(trees: [tree]),
            author: Sample.player
        )
        let op = try #require(changeset.ops.first)
        #expect(op.op == .create)
        #expect(op.entity == .tag)
        #expect(op.fields["treeID"] == .string(tree.id.uuidString))
        #expect(op.fields["issue"] == "deadwood")
        #expect(op.fields["couldHit"] == "path")
        #expect(op.fields["sizeClass"] == "medium")
        #expect(op.fields["urgency"] == "high")
        #expect(op.fields["status"] == "confirmed")
    }

    @Test func errors() throws {
        let tree = Sample.detectedTree()
        let state = CensusState(trees: [tree])
        #expect(throws: ChangesetBuilderError.empty) {
            try ChangesetBuilder(author: Sample.player, state: state).build()
        }
        let unknown = UUID()
        #expect(throws: ChangesetBuilderError.unknownSubject(unknown)) {
            try ChangesetBuilder.changeset(
                for: Sample.observation(.treeConfirmed(treeID: unknown)),
                in: state,
                author: Sample.player
            )
        }
        let confirmed = state.applying(Sample.observation(.treeConfirmed(treeID: tree.id)))
        #expect(throws: ChangesetBuilderError.noChange(tree.id)) {
            try ChangesetBuilder.changeset(
                for: Sample.observation(.treeConfirmed(treeID: tree.id)),
                in: confirmed,
                author: Sample.player
            )
        }
    }

    @Test func encodesWithTheGerardusFieldNames() throws {
        let tree = Sample.detectedTree()
        let changeset = try ChangesetBuilder.changeset(
            for: Sample.observation(.treeConfirmed(treeID: tree.id)),
            in: CensusState(trees: [tree]),
            author: Sample.player
        )
        let json = try #require(try JSONValue(encoding: changeset).objectValue)
        #expect(Set(json.keys) == ["meta", "ops", "s2_l16_tokens", "state", "approvals"])
        let op = try #require(
            json["ops"].flatMap { value -> JSONValue? in
                if case .array(let ops) = value { ops.first } else { nil }
            }?.objectValue)
        #expect(Set(op.keys) == ["op", "entity", "id", "baseVersion", "fields"])
        #expect(try CanopyJSON.decoder.decode(Changeset.self, from: CanopyJSON.encoder.encode(changeset)) == changeset)
    }

    @Test func policyNeedsTwoPlayersAndOneTrusted() {
        let author = Player(id: Sample.player, alias: "One", isTrusted: false, source: .gameCenter)
        let trustedAuthor = Player(id: Sample.player, alias: "One", isTrusted: true, source: .gameCenter)
        let byOther = Changeset.Approval(playerID: Sample.other, isTrusted: false, at: Sample.date)
        let byTrustedOther = Changeset.Approval(playerID: Sample.other, isTrusted: true, at: Sample.date)
        let bySelf = Changeset.Approval(playerID: Sample.player, isTrusted: true, at: Sample.date)

        #expect(!Changeset.meetsPolicy(author: author, approvals: []))
        #expect(!Changeset.meetsPolicy(author: trustedAuthor, approvals: []))
        #expect(!Changeset.meetsPolicy(author: author, approvals: [byOther]))
        #expect(!Changeset.meetsPolicy(author: author, approvals: [bySelf]))
        #expect(Changeset.meetsPolicy(author: author, approvals: [byTrustedOther]))
        #expect(Changeset.meetsPolicy(author: trustedAuthor, approvals: [byOther]))
    }
}
