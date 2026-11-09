import CanopyCapture
import CanopyMap
import CanopyModel
import CanopyPlayers
import CanopyReference
import CanopyStore
import CanopySync
import Foundation
import Observation
import SwiftUI
import os

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
    /// The census's trees by level-16 tile, and their counts by status, for the map to draw only some tiles in full and
    /// shade the rest without looking at every tree each time it is drawn. Made with the census, off the main actor.
    private(set) var censusTiles = CensusTiles(CensusState())
    /// The trees worked on on this phone (added, measured, confirmed, moved, under any player id): the map draws them
    /// at every zoom.
    private(set) var ownTrees: Set<UUID> = []
    private(set) var summary = CensusSummary(confirmed: 0, estimated: 0, coverage: 0)
    private(set) var changesets: [Changeset] = []
    private(set) var boundary: [[GeoPoint]] = []
    private(set) var lastSync: SyncCoordinator.Report?
    private(set) var isSyncing = false
    /// Loading real trees from a Gerardus align server (see AppModel+Aerial).
    var aerial = AerialProgress.idle
    /// The map's visible region, as the Map tab last reported it: sync pulls the shared map's tiles here.
    var mapViewport: MapViewport?
    /// How many scans (evidence meshes) this device has recorded.
    private(set) var scanCount = 0
    /// The scans being saved, by hash, so Save tapped twice saves a scan once (`saveTrunkMeasurement`).
    @ObservationIgnored var scansBeingSaved: Set<BlobRef> = []
    /// The tiles pulled from the shared map so far (see AppModel+SharedMap).
    private(set) var followedTiles: Set<S2CellID> = []
    /// The level-16 cells the player has marked as surveyed (see AppModel+Survey).
    private(set) var surveyedCells: [S2CellID: SurveyedCell] = [:]
    /// Tree shapes the player has adjusted by eye in AR, by wireframe id (`census:<uuid>` or a Gerardus feature id),
    /// drawn the same on the wireframe map. In memory only.
    var treeForms: [String: TreeForm] = [:]
    /// Ring-by-ring profiles fitted over scanned trunks, in AR or against a saved scan, by the same ids. Saved with
    /// their scans and restored at launch (see AppModel+Alignment).
    var treeProfiles: [String: TreeProfile] = [:]
    /// How many refreshes have started, so one overtaken by a later one leaves the census by tile to it.
    @ObservationIgnored private var refreshes = 0
    /// Bookkeeping for syncing on its own (`syncSoon`).
    @ObservationIgnored var pendingSync: Task<Void, Never>?
    /// The server's counts for the tiles round recent map views (GetTileSummaries), so a wide view shades tiles this
    /// phone never pulled. In memory only.
    var serverTiles: [S2CellID: TileSummary] = [:]
    /// When each tile's summary was last asked for, so moving the map back and forth does not ask again at once.
    @ObservationIgnored var summariesAskedAt: [S2CellID: Date] = [:]
    @ObservationIgnored var pendingSummaries: Task<Void, Never>?
    /// The tiles whose trees were detected over the whole tile, by this phone and saved to the server (kept across
    /// launches) or, from its summaries, by anyone the server heard from (see AppModel+Detection).
    var detectedTiles: Set<S2CellID> = AppModel.savedDetectedTiles() {
        didSet { if detectedTiles != oldValue { Self.saveDetectedTiles(detectedTiles) } }
    }
    /// The tiles the map has drawn in full lately, oldest first and at most `visitedTileLimit`, kept across launches: a
    /// sync keeps the ones it pulled up to date (see `followedTiles()`).
    var visitedTiles: [S2CellID] = AppModel.savedVisitedTiles() {
        didSet { if visitedTiles != oldValue { Self.saveVisitedTiles(visitedTiles) } }
    }
    /// The park being detected in full, site by site (`detectPark`).
    var parkDetection: ParkDetection?
    /// When the whole city's summaries were last asked for.
    @ObservationIgnored var cityAskedAt: Date?
    @ObservationIgnored var syncAgain = false
    /// Other players' open changesets near the tiles this device follows, for the player to agree with or reject.
    var reviewQueue: [GerardusMapClient.OpenChangeset] = []
    /// The player as the Gerardus server sees them (trusted, admin), after a sync.
    var serverPlayer: GerardusMapClient.PlayerInfo?
    /// The last loaded area's own data (canopy heights, outlines), for the Gerardus map. In memory only.
    var aerialReference: MapLayers.Reference? {
        didSet { updateMapReference() }
    }
    /// Vectors loaded per site (L16 token), drawn over either map. In memory only.
    var vectorAreas: [String: MapLayers.Reference] = [:] {
        didSet { updateMapReference() }
    }
    /// The loaded sites' vectors as sent, per site, for the AR overlay. In memory only.
    var loadedVectors: [String: LoadedVectors] = [:]
    /// The tiles the loaded vector sites cover.
    var vectorTiles: Set<S2CellID> = []
    /// A level-13 cell being prepared on the server site by site, if any (Map → Layers → Server cells).
    var cellPreparation: CellPreparation?
    /// Credits for the loaded vectors.
    var vectorAttribution: [String] = []
    /// Everything loaded, as the map draws it: kept, not computed, so the map's canopy images are made once.
    private(set) var mapReference: MapLayers.Reference?
    /// Where each base-layer candidate came from, for the tree sheet: nil for the synthetic sample.
    private(set) var candidateSources: [UUID: String] = [:]
    /// The last error to show, if any.
    var error: String?
    /// The selected tab, so screens can send the player elsewhere (for example from a tree to Tag).
    var section: RootView.Section = .map
    /// The tree the Tag screen should start with.
    var tagTarget: UUID?
    /// The tree the Map screen should centre on and select (`showOnMap`).
    var mapTarget: UUID?

    /// The clients for the Gerardus server in Settings, kept so calls share connections and the reference cache
    /// (see `AppModel+Aerial`).
    @ObservationIgnored var gerardusConnection: GerardusConnection?

    let store: LocalStore
    let players: PlayerService
    /// The Gerardus server stand-in. In memory: it forgets everything when the app quits.
    private(set) var server: FakeGerardusClient
    /// The real Gerardus server's address, set in Settings.
    let serverSettings: ServerSettings
    /// Flags for checking the data, for admins only.
    let adminSettings: AdminSettings
    /// Pictures of the evidence meshes for the lists of scans, rendered once each (see AppModel+Scans).
    let scanPreviews: ScanPreviewCache
    /// Where screens keep their `@AppStorage` choices (such as the base map). Forgotten when the app quits under tests,
    /// so every UI test starts from the defaults.
    let preferences: UserDefaults

    /// Who records are attributed to: the Game Center player once signed in, the local id before.
    var player: Player { players.player }

    /// Whether this player sees the admin flags and tools: listed in this build (`AdminSettings`), or an admin on the
    /// Gerardus server, as a sync last found.
    var isAdmin: Bool { adminSettings.isAdmin(player) || serverPlayer?.isAdmin == true }

    /// Whether the map shows the whole city (`AdminSettings.wholeCity`): admins only, for now.
    var showsWholeCity: Bool { isAdmin && adminSettings.wholeCity }

    private func updateMapReference() {
        mapReference = MapLayers.Reference.merged(
            [aerialReference].compactMap { $0 } + vectorAreas.keys.sorted().compactMap { vectorAreas[$0] })
    }

    init(
        store: LocalStore, players: PlayerService, server: FakeGerardusClient = FakeGerardusClient(),
        serverSettings: ServerSettings = .volatile(), adminSettings: AdminSettings = .volatile(),
        preferences: UserDefaults = AppModel.volatilePreferences(), scanPreviews: ScanPreviewCache = .temporary()
    ) {
        self.store = store
        self.players = players
        self.server = server
        self.serverSettings = serverSettings
        self.adminSettings = adminSettings
        self.preferences = preferences
        self.scanPreviews = scanPreviews
    }

    static func volatilePreferences() -> UserDefaults {
        let name = "canopy.testing.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
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
                serverSettings: ServerSettings(), adminSettings: .live(), preferences: .standard,
                scanPreviews: (try? ScanPreviewCache.inCaches()) ?? .temporary())
        } catch {
            // Fall back to memory so the app still opens, and say why.
            let model = AppModel(
                store: try! LocalStore.inMemory(), players: players, serverSettings: ServerSettings(),
                adminSettings: .live(), preferences: .standard)
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

    /// Reads the store, importing the sample candidates on first launch, and loads the current state. The map is up
    /// before this starts: with a city's worth of shared trees, reading and deriving them takes seconds, all of it on the
    /// store's own executor and none on the main actor.
    func load() async {
        let start = ContinuousClock.now
        do {
            boundary = try ParkFixtures.boundary()
            try await store.prepare()
            let prepared = ContinuousClock.now
            if try await store.candidateCount() == 0 {
                try await store.importCandidates(try ParkFixtures.candidates())
            }
            await refresh()
            await loadAlignments()
            #if DEBUG || TESTING_TOOLS
                await seedScanIfAsked()
            #endif
            await seedServer()
            phase = .ready
            Self.loadLog.notice(
                """
                Ready \(Self.seconds(ContinuousClock.now - start), format: .fixed(precision: 2)) s after load began \
                (store \(Self.seconds(prepared - start), format: .fixed(precision: 2)) s), \
                \(self.census.trees.count) trees
                """)
        } catch {
            phase = .failed(error.localizedDescription)
            self.error = "Could not read local data: \(error.localizedDescription)"
        }
    }

    static let loadLog = Logger(subsystem: "io.github.ddol.canopy", category: "load")

    func refresh() async {
        refreshes += 1
        let refresh = refreshes
        let state = await store.state()
        census = state
        // Placing tens of thousands of trees in their tiles takes a while: off the main actor, so the map keeps moving.
        // Until it is done the map draws from the tiles of the census before; a refresh that started later brings its
        // own.
        let tiles = await Task.detached(priority: .userInitiated) { CensusTiles(state) }.value
        if refresh == refreshes { censusTiles = tiles }
        summary = await store.summary()
        changesets = (try? await store.changesets()) ?? []
        ownTrees = Self.trees(touchedBy: changesets)
        followedTiles = Set(((try? await store.sharedTiles()) ?? [:]).keys)
        scanCount = (try? await store.evidenceCount()) ?? 0
        candidateSources = await store.candidateSources()
        surveyedCells = Dictionary(
            ((try? await store.surveyedCells()) ?? []).map { ($0.cell, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// The trees some changesets touch. Every changeset in the store was made on this phone, and all of them count,
    /// whoever was signed in: work recorded under the local id before a Game Center sign-in (or while it is still
    /// signing in at launch, when the census is first read) is the same player's.
    nonisolated static func trees(touchedBy changesets: [Changeset]) -> Set<UUID> {
        Set(changesets.flatMap { $0.ops.filter { $0.entity == .tree }.map(\.id) })
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

    /// "Move": `tree` stands at `position`, placed in AR the way a new tree is; this also says it is a tree.
    func move(_ tree: Tree, to position: Position) async {
        await record(.treeMoved(treeID: tree.id, position: position))
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
            syncSoon()
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
    ///
    /// A scan is identified by its hash, so saving one that is already saved (Save tapped twice) adds nothing: it
    /// returns the tree the scan measured. A save of the same scan while one is still running returns nil at once.
    @discardableResult
    func saveTrunkMeasurement(
        dbh: DBH, lean: Lean?, glb: Data, evidenceMesh: (vertices: Int, triangles: Int), cropRadius: Double,
        tree target: Tree?, position: Position
    ) async -> Tree? {
        let blob = BlobStore.reference(for: glb)
        guard scansBeingSaved.insert(blob).inserted else { return nil }
        defer { scansBeingSaved.remove(blob) }
        var tree = target
        if let saved = try? await store.evidence(hash: blob), let measured = census.trees[saved.subjectID] {
            tree = measured
        }
        if tree == nil {
            let added = Tree(
                meta: RecordMeta(playerID: player.id, chunk: position.chunk), position: position,
                countStatus: .proposed)
            guard await record(.treeAdded(added)) != nil else { return nil }
            tree = census.trees[added.id]
        }
        guard let tree else { return nil }
        do {
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
            // The record already stored for this scan, if there is one, says which tree it measured; recording the
            // measurement again returns the one already recorded.
            let stored = try await store.addEvidence(evidence, data: glb)
            await record(.trunkMeasured(treeID: stored.subjectID, dbh: dbh, lean: lean, evidence: blob))
            return census.trees[stored.subjectID]
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
    /// Where sync sends changesets: the Gerardus server in Settings, or the simulated one when none is set.
    var syncClient: any GerardusClient { mapClient ?? server }

    /// Pushes open changesets to the Gerardus server (or the simulated one) and brings back their state; with a real
    /// server, also pulls the shared map and the review queue. One sync runs at a time: a call during one runs once more
    /// after it.
    func sync() async {
        guard !isSyncing else {
            syncAgain = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }
        repeat {
            syncAgain = false
            await syncOnce()
        } while syncAgain
    }

    private func syncOnce() async {
        let blobs = store.blobs
        do {
            // A server takes changesets only from their author: ones made under another id (before a Game Center
            // sign-in) stay on the phone.
            let report = try await SyncCoordinator(client: syncClient).sync(
                changesets.filter { $0.state.isOpen && $0.meta.playerID == player.id }, author: player
            ) { ref in try blobs.data(for: ref) }
            for changeset in report.updated {
                try await store.updateChangeset(changeset)
            }
            if let client = mapClient {
                // Who the server says the player is decides whether the map shows the whole city, so ask first.
                if serverPlayer == nil { serverPlayer = try? await client.player() }
                try? await summariseCity(client)
                let followed = try await followedTiles()
                try await forgetUnfollowed(followed)
                try await pullSharedMap(client, tiles: followed)
                try await refreshReviewQueue(client, tiles: followed)
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

    /// Has the simulated trusted ranger approve every open changeset on the fake server, then syncs. Only without a
    /// real server: on one, a second player has to agree.
    func simulateTrustedApproval() async {
        guard mapClient == nil else {
            error =
                "The simulated ranger only approves on the simulated server. Forget the server in Settings to use it."
            return
        }
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
            try? await scanPreviews.removeAll()
            // The rings were restored from the store, which no longer has them.
            treeProfiles = [:]
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
