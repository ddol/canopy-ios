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

    /// The Proposals tab's badge: other players' changes near this player waiting for them to agree (or reject). The
    /// player's own proposals wait on other players, not on them, so they are not counted. Zero with no server set,
    /// since only a server has other players.
    var proposalsAwaitingPlayer: Int {
        gerardusURL == nil ? 0 : reviewQueue.count
    }
}
