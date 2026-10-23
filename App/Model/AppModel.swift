import CanopyModel
import CanopyPlayers
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
    private(set) var lastSync: SyncCoordinator.Report?
    private(set) var isSyncing = false
    /// The last error to show, if any.
    var error: String?
    /// The selected tab, so screens can send the player elsewhere (for example from a tree to Tag).
    var section: RootView.Section = .map
    /// The tree the Tag screen should start with.
    var tagTarget: UUID?

    let store: LocalStore
    let players: PlayerService
    /// The Gerardus server stand-in. In memory: it forgets everything when the app quits.
    private(set) var server: FakeGerardusClient
    /// The real Gerardus server's address, set in Settings.
    let serverSettings: ServerSettings

    /// Who records are attributed to: the Game Center player once signed in, the local id before.
    var player: Player { players.player }

    init(
        store: LocalStore, players: PlayerService, server: FakeGerardusClient = FakeGerardusClient(),
        serverSettings: ServerSettings = .volatile()
    ) {
        self.store = store
        self.players = players
        self.server = server
        self.serverSettings = serverSettings
    }

    convenience init(store: LocalStore, player: Player) {
        self.init(store: store, players: PlayerService(local: player))
    }

    /// The model the app runs with: the store in Application Support, or an in-memory one for UI tests.
    static func live(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppModel {
        let players = PlayerService(
            local: Player(id: LocalPlayerID.current(), alias: "You", isTrusted: false, source: .local))
        do {
            if isTesting(arguments) {
                return AppModel(store: try LocalStore.inMemory(), players: players)
            }
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return AppModel(
                store: try LocalStore(directory: support.appending(path: "Canopy")), players: players,
                serverSettings: ServerSettings())
        } catch {
            // Fall back to memory so the app still opens, and say why.
            let model = AppModel(store: try! LocalStore.inMemory(), players: players, serverSettings: ServerSettings())
            model.error = "Could not open local data: \(error.localizedDescription)"
            return model
        }
    }

    /// True under UI tests (`-ui-testing`) and when the app hosts unit tests: use an in-memory store and leave
    /// Game Center alone.
    static func isTesting(
        _ arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains("-ui-testing") || environment["XCTestConfigurationFilePath"] != nil
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
            await seedServer()
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
            meta: RecordMeta(playerID: player.id, chunk: position.chunk),
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

// MARK: - Measurements

extension AppModel {
    /// Saves a trunk measurement: the GLB blob, its evidence record and the observation. With no target tree,
    /// first adds a new tree at `position`. Returns the measured tree.
    @discardableResult
    func saveTrunkMeasurement(
        dbh: DBH, lean: Lean?, glb: Data, evidenceMesh: (vertices: Int, triangles: Int), cropRadius: Double,
        tree target: Tree?, position: Position
    ) async -> Tree? {
        var tree = target
        if tree == nil {
            let added = Tree(
                meta: RecordMeta(playerID: player.id, chunk: position.chunk), position: position,
                countStatus: .proposed)
            guard await record(.treeAdded(added)) != nil else { return nil }
            tree = census.trees[added.id]
        }
        guard let tree else { return nil }
        do {
            let blob = try store.blobs.put(glb)
            let evidence = Evidence(
                meta: RecordMeta(playerID: player.id, chunk: tree.position.chunk),
                blob: blob,
                byteCount: glb.count,
                kind: .trunkScan,
                subjectID: tree.id,
                cropRadius: cropRadius,
                vertexCount: evidenceMesh.vertices,
                triangleCount: evidenceMesh.triangles
            )
            try await store.addEvidence(evidence, data: glb)
            await record(.trunkMeasured(treeID: tree.id, dbh: dbh, lean: lean, evidence: blob))
            return census.trees[tree.id]
        } catch {
            self.error = "Could not save the measurement: \(error.localizedDescription)"
            return nil
        }
    }

    /// A copy of an evidence blob with a `.glb` name, for sharing.
    func shareableGLB(_ ref: BlobRef) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "canopy-\(ref.rawValue.prefix(12)).glb")
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: store.blobs.url(for: ref), to: url)
        return url
    }
}

// MARK: - Sync

extension AppModel {
    /// Pushes open changesets to the (fake) Gerardus server and brings back their state.
    func sync() async {
        isSyncing = true
        defer { isSyncing = false }
        let blobs = store.blobs
        do {
            let report = try await SyncCoordinator(client: server).sync(
                changesets.filter(\.state.isOpen), author: player
            ) { ref in try blobs.data(for: ref) }
            for changeset in report.updated {
                try await store.updateChangeset(changeset)
            }
            lastSync = report
            await refresh()
        } catch {
            self.error = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// A trusted stand-in player who agrees with everything, for trying the policy before the review flow
    /// exists.
    static let fakeRanger = Player(
        id: PlayerID(rawValue: "gerardus:fake-ranger"), alias: "Ranger (simulated)", isTrusted: true,
        source: .gameCenter)

    /// Has the simulated trusted ranger approve every open changeset on the fake server, then syncs.
    func simulateTrustedApproval() async {
        await sync()
        do {
            for id in await server.openChangesetIDs() {
                try await server.approve(id, by: Self.fakeRanger)
            }
        } catch {
            self.error = "Approval failed: \(error.localizedDescription)"
        }
        await sync()
    }

    /// Deletes all local data and starts again from the fixtures.
    func reset() async {
        do {
            try await store.reset()
            server = FakeGerardusClient()
            lastSync = nil
            try await store.importCandidates(try ParkFixtures.candidates())
            await refresh()
            await seedServer()
        } catch {
            self.error = "Reset failed: \(error.localizedDescription)"
        }
    }

    /// Tells the fake server about the aerial base layer, which the real server will already have.
    private func seedServer() async {
        let base = census.trees.values.filter { $0.meta.playerID == .aerialSurvey }
        await server.seed(Dictionary(uniqueKeysWithValues: base.map { ($0.id, 1) }))
    }
}
