import CanopyModel

/// What the Proposals tab lists: the player's own changesets, open and closed, and how many of other players'
/// changes wait on them.
extension AppModel {
    /// The player's open changesets (pending or approved), newest first.
    var openProposals: [Changeset] {
        changesets.filter(\.state.isOpen).reversed()
    }

    /// The player's closed changesets (on the shared map, rejected or conflicted), newest first.
    var closedProposals: [Changeset] {
        changesets.filter { !$0.state.isOpen }.reversed()
    }

    /// The player's open proposals sent from their other devices (a phone's, on the iPad): theirs among the open
    /// changesets the server holds in the tiles this device follows, from the last sync, newest first.
    var otherDeviceProposals: [Changeset] {
        Self.otherDeviceProposals(ownOpenChangesets, local: changesets)
    }

    /// Those of `server` (the player's open changesets on the server) this device's store does not hold, newest first.
    nonisolated static func otherDeviceProposals(_ server: [Changeset], local: [Changeset]) -> [Changeset] {
        let here = Set(local.map(\.id))
        return server.filter { !here.contains($0.id) }.sorted { $0.meta.createdAt > $1.meta.createdAt }
    }

    /// Whether this device made `changeset`: every changeset in its store was made on it.
    func madeHere(_ changeset: Changeset) -> Bool {
        changesets.contains { $0.id == changeset.id }
    }

    /// The Proposals tab's badge: other players' changes near this player waiting for them to agree (or reject). The
    /// player's own proposals wait on other players, not on them, so they are not counted. Zero with no server set,
    /// since only a server has other players.
    var proposalsAwaitingPlayer: Int {
        gerardusURL == nil ? 0 : reviewQueue.count
    }
}
