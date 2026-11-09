import CanopyModel
import CanopyStore
import CanopySync
import Foundation
import Testing

@testable import Canopy
@testable import CanopyReference

/// What the Proposals tab lists, and its badge.
@MainActor
@Suite struct ProposalsTests {
    func makeModel() throws -> AppModel {
        AppModel(
            store: try LocalStore.inMemory(),
            player: Player(id: PlayerID(rawValue: "T:_test"), alias: "Test", source: .gameCenter)
        )
    }

    /// Another player's open change to one tree, as the server lists it for review.
    func othersChange() -> GerardusMapClient.OpenChangeset {
        let chunk = GeoPoint(latitude: 37.7699, longitude: -122.4757).chunk
        let changeset = Changeset(
            meta: RecordMeta(playerID: PlayerID(rawValue: "T:_friend"), chunk: chunk),
            ops: [
                ChangeOp(op: .update, entity: .tree, id: UUID(), baseVersion: 1, fields: ["countStatus": "confirmed"])
            ],
            tiles: [chunk.parent(level: S2CellID.tileLevel)])
        return GerardusMapClient.OpenChangeset(changeset: changeset, authorAlias: "Friend", authorTrusted: false)
    }

    @Test func openProposalsAndHistoryAreNewestFirst() async throws {
        let model = try makeModel()
        await model.load()
        let trees = Array(model.census.trees.values.prefix(2))
        await model.confirm(trees[0])
        await model.confirm(trees[1])
        let made = model.changesets.map(\.id)
        #expect(model.openProposals.map(\.id) == made.reversed())
        #expect(model.closedProposals.isEmpty)

        await model.sync()
        await model.simulateTrustedApproval()
        #expect(model.openProposals.isEmpty)
        #expect(model.closedProposals.map(\.id) == made.reversed())
        #expect(model.closedProposals.allSatisfy { $0.state == .applied })
    }

    @Test func theBadgeCountsOtherPlayersChangesOnlyWithAServer() throws {
        let model = try makeModel()
        model.reviewQueue = [othersChange(), othersChange()]
        // With no server there are no other players; a queue left from a server forgotten in Settings is not counted.
        #expect(model.proposalsAwaitingPlayer == 0)
        model.serverSettings.save(GerardusEndpoint("gerardus.local"))
        #expect(model.proposalsAwaitingPlayer == 2)
        model.reviewQueue.removeFirst()
        #expect(model.proposalsAwaitingPlayer == 1)
    }

    @Test func thePlayersOwnProposalsDoNotBadgeTheTab() async throws {
        let model = try makeModel()
        await model.load()
        await model.confirm(try #require(model.census.trees.values.first))
        model.serverSettings.save(GerardusEndpoint("gerardus.local"))
        #expect(model.openProposals.count == 1)
        #expect(model.proposalsAwaitingPlayer == 0)
    }

    @Test func theTabOpensOnReviewOnlyWhenSomethingWaitsThere() {
        #expect(ProposalsScreen.firstPart(awaiting: 0) == .yours)
        #expect(ProposalsScreen.firstPart(awaiting: 3) == .review)
    }
}
