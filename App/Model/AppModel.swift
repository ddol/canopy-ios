import CanopyModel
import CanopyStore
import CanopySync
import Foundation
import Observation
import SwiftUI

/// The app's state and actions. Screens read from it and call its methods; it owns the store and the sync
/// client.
@Observable
final class AppModel {
    enum Phase: Equatable {
        case loading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var census = CensusState()
    private(set) var summary = CensusSummary(confirmed: 0, estimated: 0, coverage: 0)
    private(set) var changesets: [Changeset] = []
    private(set) var boundary: [[GeoPoint]] = []
    private(set) var player: Player
    /// The last error to show, if any.
    var error: String?
    /// The selected tab, so screens can send the player elsewhere (for example from a tree to Tag).
    var section: RootView.Section = .map
    /// The tree the Tag screen should start with.
    var tagTarget: UUID?

    let store: LocalStore
    let server: FakeGerardusClient

    init(store: LocalStore, player: Player, server: FakeGerardusClient = FakeGerardusClient()) {
        self.store = store
        self.player = player
        self.server = server
    }

    /// The model the app runs with: the store in Application Support, or an in-memory one for UI tests.
    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        let player = Player(id: LocalPlayerID.current(), alias: "You", isTrusted: false, source: .local)
        do {
            if arguments.contains("-ui-testing") {
                return AppModel(store: try LocalStore.inMemory(), player: player)
            }
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return AppModel(store: try LocalStore(directory: support.appending(path: "Canopy")), player: player)
        } catch {
            // Fall back to memory so the app still opens; the error is shown on the Me screen.
            let model = AppModel(store: try! LocalStore.inMemory(), player: player)
            model.error = "Could not open local data: \(error.localizedDescription)"
            return model
        }
    }

    // MARK: Loading

    /// Imports the sample candidates on first launch and loads the current state.
    func load() async {
        do {
            boundary = try ParkFixtures.boundary()
            if try await store.candidateCount() == 0 {
                try await store.importCandidates(try ParkFixtures.candidates())
            }
            await refresh()
            let base = census.trees.values.filter { $0.meta.playerID == .aerialSurvey }
            await server.seed(Dictionary(uniqueKeysWithValues: base.map { ($0.id, 1) }))
            phase = .ready
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refresh() async {
        census = await store.state()
        summary = await store.summary()
        changesets = (try? await store.changesets()) ?? []
    }

    // MARK: Census actions

    func tree(_ id: UUID?) -> Tree? {
        id.flatMap { census.trees[$0] }
    }

    func confirm(_ tree: Tree) async {
        await record(.treeConfirmed(treeID: tree.id))
    }

    func reject(_ tree: Tree) async {
        await record(.treeRejected(treeID: tree.id))
    }

    /// "New tree here": a tree the aerial survey missed, at `position`.
    func addTree(at position: Position) async {
        let tree = Tree(
            meta: RecordMeta(playerID: player.id, cell: position.chunk),
            position: position,
            countStatus: .proposed
        )
        await record(.treeAdded(tree))
    }

    func tagLimb(on tree: Tree) {
        tagTarget = tree.id
        section = .tag
    }

    @discardableResult
    func record(_ kind: FieldObservation.Kind) async -> Changeset? {
        do {
            let (_, changeset) = try await store.record(kind, by: player.id)
            await refresh()
            return changeset
        } catch {
            self.error = "Could not save: \(error.localizedDescription)"
            return nil
        }
    }
}

/// A device-local pseudonymous player id, used until Game Center sign-in.
enum LocalPlayerID {
    static let key = "canopy.localPlayerID"

    static func current(defaults: UserDefaults = .standard) -> PlayerID {
        if let stored = defaults.string(forKey: key), let id = UUID(uuidString: stored) {
            return .local(id)
        }
        let id = UUID()
        defaults.set(id.uuidString, forKey: key)
        return .local(id)
    }
}
