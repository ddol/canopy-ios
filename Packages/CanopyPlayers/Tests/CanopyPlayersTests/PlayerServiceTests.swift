import CanopyModel
import Foundation
import Testing

@testable import CanopyPlayers

@MainActor
@Suite struct PlayerServiceTests {
    let local = Player(id: .local(UUID()), alias: "You", source: .local)

    @Test func startsWithTheLocalPlayer() {
        let service = PlayerService(local: local)
        #expect(service.state == .signedOut)
        #expect(service.player == local)
    }

    @Test func signedInUsesTheTeamPlayerIDAndAlias() {
        let (state, player) = PlayerService.resolve(
            identity: (id: "T:_abc123", alias: "Treehugger"), needsUI: false, errorMessage: nil)
        #expect(state == .signedIn)
        #expect(player?.id == PlayerID(rawValue: "T:_abc123"))
        #expect(player?.alias == "Treehugger")
        #expect(player?.source == .gameCenter)
        #expect(player?.isTrusted == false)
    }

    @Test func unavailableFallsBackToTheLocalPlayer() {
        let service = PlayerService(local: local)
        service.apply(PlayerService.resolve(identity: nil, needsUI: false, errorMessage: "Not recognised"))
        #expect(service.state == .unavailable("Not recognised"))
        #expect(service.player == local)
    }

    @Test func signInScreenKeepsSigningIn() {
        let (state, player) = PlayerService.resolve(identity: nil, needsUI: true, errorMessage: nil)
        #expect(state == .signingIn)
        #expect(player == nil)
    }
}
