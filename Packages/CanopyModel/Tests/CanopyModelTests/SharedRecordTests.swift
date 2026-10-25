import Foundation
import Testing

@testable import CanopyModel

@Suite struct SharedRecordTests {
    let tree = Sample.detectedTree()

    /// The tree as the shared map has it: its shared fields, as a changeset op carries them.
    func record(_ tree: Tree, version: Int = 1) throws -> SharedRecord {
        SharedRecord(
            kind: .tree, id: tree.id, version: version, tile: tree.position.tile, createdBy: .aerialSurvey,
            createdAt: Date(timeIntervalSince1970: 1_761_200_000), fields: try tree.sharedFields())
    }

    @Test func aRecordBecomesTheTreeItDescribes() throws {
        let shared = try record(tree, version: 3)
        let decoded = try #require(shared.tree())
        #expect(decoded.id == tree.id)
        #expect(decoded.position == tree.position)
        #expect(decoded.countStatus == tree.countStatus)
        #expect(decoded.meta.version == 3)
        #expect(decoded.meta.playerID == .aerialSurvey)
        #expect(decoded.meta.chunk == tree.position.chunk)
        #expect(shared.tag() == nil)
    }

    @Test func anUpdateChangesOnlyTheFieldsItNames() throws {
        let op = ChangeOp(
            op: .update, entity: .tree, id: tree.id, baseVersion: 1,
            fields: ["countStatus": "confirmed", "species": .null])
        var withSpecies = tree
        withSpecies.species = "Monterey cypress"
        let updated = try record(withSpecies).applying(op, tile: tree.position.tile)
        #expect(updated.version == 2)
        let decoded = try #require(updated.tree())
        #expect(decoded.countStatus == .confirmed)
        #expect(decoded.species == nil)
        #expect(decoded.position == tree.position)
    }

    @Test func theSharedMapWinsAndOwnAppliedWorkIsNotCountedTwice() throws {
        var confirmed = tree
        confirmed.countStatus = .confirmed
        // This device confirmed the tree; the server applied it and the pull brought it back at version 2.
        let mine = Sample.observation(.treeConfirmed(treeID: tree.id))
        let state = CensusState.derive(
            base: [tree], shared: [try record(confirmed, version: 2)], observations: [mine],
            changesetStates: [mine.changesetID!: .applied])
        let derived = try #require(state.trees[tree.id])
        #expect(derived.countStatus == .confirmed)
        #expect(derived.proposedStatus == nil)
        #expect(derived.meta.version == 2)
    }

    @Test func ownOpenProposalsShowOnTopOfTheSharedMap() throws {
        let mine = Sample.observation(.treeRejected(treeID: tree.id))
        let state = CensusState.derive(
            base: [tree], shared: [try record(tree, version: 1)], observations: [mine],
            changesetStates: [mine.changesetID!: .pending])
        let derived = try #require(state.trees[tree.id])
        #expect(derived.countStatus == .detected)
        #expect(derived.proposedStatus == .removed)
    }

    @Test func otherPlayersTreesAppear() throws {
        // Not among this device's candidates: another player added it, and the pull brought it.
        let elsewhere = Position(
            geo: GeoPoint(latitude: 37.7712, longitude: -122.4801), covariance: .isotropic(horizontal: 1, vertical: 1))
        var theirs = Tree(
            meta: RecordMeta(playerID: PlayerID(rawValue: "T:_other"), chunk: elsewhere.chunk), position: elsewhere,
            countStatus: .confirmed)
        theirs.species = "Coast live oak"
        let state = CensusState.derive(
            base: [tree], shared: [try record(theirs, version: 1)], observations: [], changesetStates: [:])
        #expect(state.trees.count == 2)
        #expect(state.trees[theirs.id]?.species == "Coast live oak")
        #expect(state.trees[theirs.id]?.countStatus == .confirmed)
    }
}
