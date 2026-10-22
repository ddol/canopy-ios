import CanopyModel
import Foundation
import GameKit
import Observation
import UIKit

/// Signs the player in to Game Center and says who is playing.
///
/// The player id is Game Center's `teamPlayerID`, which stays the same across games from one developer team, so
/// trust earned in one Gerardus app can carry to another. Until sign-in succeeds, and whenever Game Center is
/// unavailable, the app keeps working with a pseudonymous local id.
@MainActor
@Observable
public final class PlayerService {
    public enum State: Equatable, Sendable {
        case signedOut
        case signingIn
        case signedIn
        /// Game Center is not available here (no account, restrictions, not registered); the local id is in use.
        case unavailable(String)
    }

    public private(set) var state: State = .signedOut
    public private(set) var player: Player
    /// Game Center's sign-in screen, when it wants to show one. Present it, then set this to nil.
    public var signInViewController: UIViewController?

    private let localPlayer: Player

    /// - Parameter local: the player to use until (or instead of) Game Center.
    public init(local: Player) {
        self.localPlayer = local
        self.player = local
    }

    /// Starts Game Center authentication. Safe to call more than once; Game Center calls back whenever the
    /// sign-in state changes.
    public func authenticate() {
        state = .signingIn
        GKLocalPlayer.local.authenticateHandler = { @Sendable viewController, error in
            let message = error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handle(viewController: viewController, errorMessage: message)
            }
        }
    }

    private func handle(viewController: UIViewController?, errorMessage: String?) {
        let local = GKLocalPlayer.local
        let identity: (id: String, alias: String)? =
            local.isAuthenticated ? (local.teamPlayerID, local.alias) : nil
        apply(Self.resolve(identity: identity, needsUI: viewController != nil, errorMessage: errorMessage))
        signInViewController = viewController
    }

    func apply(_ resolution: (State, Player?)) {
        state = resolution.0
        player = resolution.1 ?? localPlayer
    }

    /// Maps what Game Center reported to a state and a player. Pure, for tests.
    nonisolated static func resolve(
        identity: (id: String, alias: String)?,
        needsUI: Bool,
        errorMessage: String?
    ) -> (State, Player?) {
        if let identity, !identity.id.isEmpty {
            return (.signedIn, Player(id: PlayerID(rawValue: identity.id), alias: identity.alias, source: .gameCenter))
        }
        if needsUI {
            return (.signingIn, nil)
        }
        if let errorMessage {
            return (.unavailable(errorMessage), nil)
        }
        return (.signedOut, nil)
    }
}
