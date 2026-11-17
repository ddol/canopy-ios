import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import CanopyStore
import SwiftUI
import simd

/// Census with LiDAR: the AR view with the reconstructed mesh, Gerardus's site drawn as wireframes round the player
/// (trees, buildings, streets) with the census's own trees, the selected tree with a compass to find it, and the
/// census actions: once the selected tree is in view, Not a tree and Move; Scan trunk at any time.
struct LiDARCensusView: View {
    @Environment(AppModel.self) private var model
    @State private var capture = CaptureSession()
    @State private var location = LocationProvider()
    @State private var targetID: UUID?
    @State private var isMeasuring = false
    @State private var measurement: Measurement?
    @State private var notice: String?
    /// The session registered against 3DEP: positions come from it instead of GPS while it lasts.
    @State private var registered: RegisteredScan?
    @State private var isRegistering = false
    @State private var confirmingRegistration = false
    /// The measured trunk with the wireframe tree being fitted over it, between finishing a scan and the sheet.
    @State private var fit: TreeFit?

    // The site overlay.
    @State private var overlayLayers: Set<SiteWireframes.Layer> = [.trees, .buildings, .cells]
    @State private var showsCensusTrees = true
    /// The AR session origin's map position, from the best GPS fix so far and the camera's offset then.
    @State private var sessionOrigin: GeoPoint?
    @State private var sessionOriginAccuracy = Double.infinity
    /// How far the overlay is turned by hand about the vertical, radians (`GPSPlacement`).
    @State private var sessionYaw = 0.0
    /// Where GPS last put the session origin, before any moving by hand.
    @State private var gpsOrigin: GeoPoint?
    /// Whether the player has moved or turned the overlay by hand: GPS then leaves it alone until From GPS.
    @State private var placedByHand = false
    /// Whether the placement radar and pad are up.
    @State private var showsPlacement = false
    /// The trees near by as they were when the list was opened, while it is.
    @State private var treeChoices: [NearbyTreeList.Choice]?
    /// The tile whose site was last asked for on arrival, so a slow server is asked once.
    @State private var autoLoadTile: S2CellID?
    /// When a load of the site under the player last failed on its own: it is not tried again for a while, and
    /// not at all while the phone is offline, so a walk in the woods is not a stream of failed connections.
    @State private var autoLoadFailedAt: Date?
    /// Why the scan could not measure, shown with the scan until it changes: kept apart from the notice, which other
    /// news would replace before it is read.
    @State private var scanIssue: String?
    /// Moves the dashes round the rings of a tree being moved, so they read as moving ("marching ants").
    @State private var antsPhase: Float = 0
    @State private var loadingVectors = false
    /// The tree picked by tapping; the shapes the player adjusts live on the model, shared with the map.
    @State private var selection: ARTreeSelection?
    /// Census trees near the player that are not removed, nearest first, kept between fixes.
    @State private var nearby: [(Tree, Double)] = []
    /// Where each pickable tree is drawn in AR: census trees, and Gerardus's.
    @State private var drawnCensus: [String: DrawnTree] = [:]
    @State private var drawnSite: [String: DrawnTree] = [:]
    /// Follows the selected tree from the camera for its card, the compass and whether it is in view.
    @State private var tracker = TreeTracker()
    /// The selected tree while it is being moved to its true spot.
    @State private var move: TreeMove?
    /// The stems from the ground to split off into a tree of their own, while the player confirms it.
    @State private var pendingSplit: [Int]?
    /// Whether the site load running was asked for on its own (`autoLoadVectors`), so says nothing.
    @State private var loadingQuietly = false
    private let format = QuantityFormat()

    var body: some View {
        following(watching(scene))
            .onAppear {
                capture.start()
                location.start(heading: true)
                refreshNearby()
            }
            .onDisappear {
                endMove()
                capture.stopAligning()
                capture.pause()
                location.stop()
            }
            .task {
                while !Task.isCancelled {
                    tracker.sample(capture: capture, location: location)
                    try? await Task.sleep(for: .seconds(TreeTracker.interval))
                }
            }
            .confirmationDialog(
                "Register with aerial LiDAR?", isPresented: $confirmingRegistration, titleVisibility: .visible
            ) {
                Button("Upload and register") { Task { await register() } }
            } message: {
                Text(
                    "Uploads the colourless 3D mesh around you (up to 60 m, geometry only, no photos) to "
                        + "\(model.gerardusURL?.host() ?? "the Gerardus server set in Me → Settings") and matches it "
                        + "to USGS 3DEP aerial LiDAR, so trees you add or measure land within a few centimetres "
                        + "instead of GPS metres.")
            }
            // The AR session pauses under the result sheet (Quick Look's AR mode needs the camera) and resumes, with
            // the mesh and the scan, when the sheet closes.
            .sheet(item: $measurement, onDismiss: resumeCapture) { measurement in
                MeasurementSheet(measurement: measurement) {
                    capture.stopAligning()
                    capture.cancelScan()
                    capture.hideTree()
                    fit = nil
                }
                .presentationDetents([.medium, .large])
            }
            .confirmationDialog(
                splitTitle, isPresented: Binding(get: { pendingSplit != nil }, set: { if !$0 { pendingSplit = nil } }),
                titleVisibility: .visible
            ) {
                Button("Split them off") {
                    let roots = pendingSplit ?? []
                    pendingSplit = nil
                    Task { await splitOff(roots) }
                }
                Button("Cancel", role: .cancel) { pendingSplit = nil }
            } message: {
                Text(
                    "The stems beyond the cut become a new tree, proposed where the largest of them stands, with "
                        + "their DBH and this scan as evidence. \(fit?.savedTree?.name ?? "This tree") keeps the rest.")
            }
            .sheet(
                isPresented: Binding(get: { treeChoices != nil }, set: { if !$0 { treeChoices = nil } })
            ) {
                NearbyTreeList(choices: treeChoices ?? [], selected: target?.id, onChoose: choose)
                    .presentationDetents([.medium, .large])
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { overlayMenu }
            }
    }

    /// The AR view with the reticle, the target card, the notice and the bottom panel.
    private var scene: some View {
        ZStack {
            ARViewContainer(session: capture)
                .ignoresSafeArea()
            Reticle()
            VStack(spacing: Spacing.s) {
                // While a scanned trunk is fitted, the screen is the tree's: the card and the overlay's lines go.
                if fit == nil {
                    SelectedTreeCard(
                        focus: focus, tracker: tracker,
                        placeholder: placeholder,
                        canChoose: !nearby.isEmpty, onChooseAnother: openTreeChoices)
                    overlayStatusRow
                }
                if let notice {
                    HStack(alignment: .top, spacing: Spacing.xs) {
                        if loadingVectors, !loadingQuietly { ProgressView().controlSize(.small) }
                        Text(notice)
                            .lineLimit(fit == nil ? nil : 3)
                        Spacer(minLength: 0)
                        Button("Dismiss", systemImage: "xmark") { self.notice = nil }
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(Color.canopyInkMuted)
                    }
                    .font(.footnote)
                    .padding(Spacing.xs)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
                    .accessibilityIdentifier("census-notice")
                }
                Spacer()
                if let focus, showsCompass {
                    HStack {
                        Spacer()
                        TreeCompassView(tracker: tracker, title: focus.title)
                    }
                }
                if let scan = capture.scan, fit == nil {
                    if scan.trackingJumped {
                        TrackingJumpCard(
                            onRestart: {
                                capture.restartScanAfterJump()
                                scanIssue = nil
                            },
                            onKeep: { capture.keepScanAfterJump() })
                    }
                    ScanProgressCard(progress: scan.progress, regionRadius: scan.regionRadius)
                    if let scanIssue {
                        Label(scanIssue, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .padding(Spacing.xs)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
                            .accessibilityIdentifier("scan-issue")
                    }
                }
                bottomPanel
            }
            .padding(Spacing.m)
        }
    }

    /// The fit sliders while a scanned trunk is being fitted, the scan's buttons while one runs, moving the selected
    /// tree, the tapped tree's panel, else the census actions.
    @ViewBuilder
    private var bottomPanel: some View {
        if fit != nil {
            TreeFitPanel(
                fitting: fitFittingBinding, selectedSection: fitSectionBinding, onSnap: snapSelectedSection,
                isAligning: capture.isAligning, alignStatus: alignStatus, onAlign: toggleAlignment,
                onMoveHere: moveTreeHere, onBack: stopFitting, onMeasurement: showMeasurement, stems: stemActions)
        } else if capture.scan != nil {
            scanControls
        } else if let move {
            MovePanel(
                name: move.name, offset: moveOffset(move), onReticle: moveToReticle, onCancel: endMove,
                onPlace: { Task { await placeMovedTree() } })
        } else if showsPlacement {
            PlacementPanel(
                tracker: tracker, trees: radarTrees, status: placementStatus,
                canMove: registered == nil && sessionOrigin != nil, focusName: focus?.title,
                isMovedByHand: placedByHand, onMove: walk, onTurn: turn, onLineUp: lineUpFocus,
                onReset: placeFromGPS, onDone: { showsPlacement = false })
        } else if let selection {
            SelectedTreePanel(
                selection: selection, form: selectedFormBinding, isAdjusted: model.treeForms[selection.id] != nil,
                canEdit: canEditFocus, onReset: resetSelectedForm, onScan: startScan, onDone: deselect,
                onNotATree: rejectFocus, onMove: startMove)
        } else {
            controls
        }
    }

    /// The compass shows while there is a selected tree out of view and nothing else is going on.
    private var showsCompass: Bool {
        !tracker.inView && capture.scan == nil && fit == nil && move == nil && !showsPlacement
    }

    /// Whether Not a tree and Move apply: the selected tree is a census tree, and it is in view.
    private var canEditFocus: Bool {
        focus?.tree != nil && tracker.inView
    }

    /// What the whole overlay is drawn from: the loaded sites, the placement and the layers. The adjusted shapes are
    /// watched apart, since a slider moves them many times a second and only the trees need drawing again.
    private var overlayInputs: OverlayInputs {
        OverlayInputs(
            sites: model.loadedVectors.count, registration: registered?.registrationID, origin: sessionOrigin,
            yaw: sessionYaw, layers: overlayLayers, fitting: fit != nil)
    }

    /// What the census trees and cells are drawn from.
    private var censusInputs: [Int] {
        [showsCensusTrees ? 1 : 0, model.census.trees.count, model.surveyedCells.count, model.treeProfiles.count]
    }

    /// What the overlay follows: the fix, taps, loaded sites, the registration, the placement and the layer choices.
    private func watching(_ view: some View) -> some View {
        view
            .onChange(of: location.geoPoint) {
                placeSession()
                autoLoadVectors()
                refreshNearby()
            }
            .onChange(of: capture.lastTap) {
                if let tap = capture.lastTap { handleTap(at: tap.point) }
            }
            .onChange(of: overlayInputs) { rebuildOverlay() }
            .onChange(of: censusInputs) { rebuildOverlay([.census, .cells]) }
            .onChange(of: model.treeForms) { old, new in rebuildOverlay(OverlayParts(reshaping: old, new)) }
            .onChange(of: capture.ringFits) { applyRingFits() }
            .onChange(of: model.aerial) {
                guard loadingVectors, !loadingQuietly, case .working(let message) = model.aerial else { return }
                notice = message
            }
            .onChange(of: model.isOnline) {
                // Back online: the site under the player can be asked for again.
                if model.isOnline {
                    autoLoadFailedAt = nil
                    autoLoadVectors()
                }
            }
    }

    /// What follows the selected tree: the tracker's targets, its highlight, the trees near by and dragging it.
    private func following(_ view: some View) -> some View {
        view
            .onChange(of: trackerTargets, initial: true) {
                tracker.follow(trackerTargets.focus, nearby: trackerTargets.nearby)
            }
            .onChange(of: focus?.id, initial: true) { capture.highlightWireframe(id: focus?.id) }
            .onChange(of: model.censusTarget, initial: true) { takeCensusTarget() }
            .onChange(of: nearbyInputs) { refreshNearby() }
            .onChange(of: capture.lastDrag) {
                if let drag = capture.lastDrag { dragTree(drag) }
            }
            .task(id: move?.treeID) { await marchAnts() }
    }

    // MARK: The selected tree

    /// The census tree being moved, else the one chosen from the list, else the nearest one. A move holds on to its
    /// tree, so walking to its true spot does not make another tree the nearest under it.
    private var target: Tree? {
        model.tree(move?.treeID ?? targetID).flatMap { $0.effectiveStatus == .removed ? nil : $0 } ?? nearby.first?.0
    }

    /// The tree the census actions are about: the tapped one, else the target.
    private var focus: FocusTree? {
        if let selection {
            let tree = selection.censusID.flatMap { model.tree($0) }
            return FocusTree(
                id: selection.id, title: tree?.name ?? selection.title, status: tree?.displayStatus ?? selection.status,
                tree: tree, geo: tree?.position.geo ?? selection.geo, source: .tapped, dbh: tree?.dbh)
        }
        guard let target else { return nil }
        return FocusTree(
            id: ARTreeSelection.censusPrefix + target.id.uuidString, title: target.name, status: target.displayStatus,
            tree: target, geo: target.position.geo, source: targetID == target.id ? .chosen : .nearest,
            dbh: target.dbh)
    }

    /// The selected tree and the trees near by, as drawn in AR or on the map, for the tracker.
    private var trackerTargets: TrackerTargets {
        func target(_ id: String, geo: GeoPoint?) -> TreeTracker.Target {
            let drawn = drawnCensus[id] ?? drawnSite[id]
            return TreeTracker.Target(id: id, world: drawn?.base, geo: geo, height: drawn?.height ?? 8)
        }
        return TrackerTargets(
            focus: focus.map { target($0.id, geo: $0.geo) },
            nearby: nearby.map { target(ARTreeSelection.censusPrefix + $0.0.id.uuidString, geo: $0.0.position.geo) })
    }

    /// What the tree card says with no tree to show. Until the store has been read at launch the census is empty, which
    /// is not the same as no tree near by: saying so keeps a player from adding trees that are there.
    private var placeholder: String {
        if model.phase == .loading { return "Reading the trees on this phone…" }
        return location.geoPoint == nil ? "Waiting for GPS…" : "No tree within 60 m"
    }

    /// What changes the trees near by besides the fix: trees arriving, and every change the player records.
    private var nearbyInputs: [Int] {
        [model.census.trees.count, model.changesets.count]
    }

    private func refreshNearby() {
        guard let here = location.geoPoint else {
            nearby = []
            return
        }
        nearby = model.census.trees(near: here, within: 60, limit: 20, tiles: model.censusTiles)
    }

    /// A tree chosen from the card's list becomes the target, leaving any move of another where it was.
    private func choose(_ tree: Tree) {
        if move?.treeID != tree.id { endMove() }
        deselect()
        targetID = tree.id
    }

    /// A tree sent from the map to scan: it becomes the selected tree, wherever it is.
    private func takeCensusTarget() {
        guard let id = model.censusTarget else { return }
        model.censusTarget = nil
        guard let tree = model.tree(id) else { return }
        choose(tree)
        showsPlacement = false
        notice =
            "Scanning " + tree.name + ": point the middle of the screen at its trunk and tap Scan " + tree.name
            + ". The scan measures this tree even if another is nearer."
    }

    /// Opens the list of trees near by, as they are now.
    private func openTreeChoices() {
        refreshNearby()
        treeChoices = nearby.map { NearbyTreeList.Choice(tree: $0.0, distance: $0.1) }
    }

    /// Which wireframes are drawn, and loading the site here.
    private var overlayMenu: some View {
        Menu {
            Section("Wireframes") {
                ForEach(SiteWireframes.Layer.allCases, id: \.self) { layer in
                    Toggle(
                        layer.label,
                        isOn: Binding(
                            get: { overlayLayers.contains(layer) },
                            set: { if $0 { overlayLayers.insert(layer) } else { overlayLayers.remove(layer) } }))
                }
                Toggle("Census trees", isOn: $showsCensusTrees)
            }
            if let cell = currentCell {
                Section("This cell") {
                    Text(cellSummary(cell))
                    if model.isSurveyed(cell) {
                        Button("Unmark surveyed", systemImage: "xmark.square") {
                            Task { await model.unmarkSurveyed(cell) }
                        }
                    } else {
                        Button("Mark this cell surveyed", systemImage: "checkmark.square") {
                            Task { await model.markSurveyed(cell) }
                        }
                    }
                }
            }
            Section("Gerardus") {
                Button("Load vectors here", systemImage: "arrow.down.circle") {
                    if let here = location.geoPoint { loadVectors(around: here) }
                }
                .disabled(model.alignClient == nil || model.aerial.isWorking || location.geoPoint == nil)
                Button("Line up the overlay by hand", systemImage: "dot.circle.and.hand.point.up.left.fill") {
                    showsPlacement = true
                }
                .disabled(registered != nil || sessionOrigin == nil)
                .accessibilityIdentifier("placement-open")
                Button("Re-place overlay from GPS", systemImage: "scope") { placeFromGPS() }
                    .disabled(registered != nil || location.geoPoint == nil)
                registrationControl
                Text(overlayStatus)
            }
        } label: {
            Label("Wireframes", systemImage: "square.3.layers.3d")
                .labelStyle(.iconOnly)
        }
        .accessibilityIdentifier("overlay-menu")
    }

    /// A line under the target card: how many sites are drawn and how the overlay is placed, with a way to ask
    /// again when a load failed.
    @ViewBuilder
    private var overlayStatusRow: some View {
        if model.loadedVectors.isEmpty, !loadingVectors, model.alignClient != nil, location.geoPoint != nil {
            Button {
                if let here = location.geoPoint { loadVectors(around: here) }
            } label: {
                Label(
                    model.aerial.isFailed ? "Load the site here again" : "Load the site here",
                    systemImage: "square.3.layers.3d.down.right"
                )
                .font(.footnote)
            }
            .buttonStyle(.canopySecondary)
            .accessibilityIdentifier("load-site-here")
        } else if !model.loadedVectors.isEmpty {
            // Tapped, it opens the radar to line the overlay up by hand.
            Button {
                if registered == nil, sessionOrigin != nil { showsPlacement.toggle() }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "square.3.layers.3d")
                    Text(overlayStatus)
                    if registered == nil, sessionOrigin != nil {
                        Image(systemName: "dot.circle.and.hand.point.up.left.fill")
                    }
                }
                .font(CanopyFont.mono(.caption))
                .foregroundStyle(Color.canopyInkMuted)
                .padding(.horizontal, Spacing.xs)
                .padding(.vertical, Spacing.xxs)
                .background(.thinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("overlay-status")
        }
        if let cell = currentCell {
            HStack(spacing: Spacing.xs) {
                Image(systemName: model.isSurveyed(cell) ? "checkmark.square" : "square.grid.3x3")
                Text(cellSummary(cell))
            }
            .font(CanopyFont.mono(.caption))
            .foregroundStyle(model.isSurveyed(cell) ? Color.canopyBrand : Color.canopyInkMuted)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(.thinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cell-status")
        }
    }

    /// The level-16 cell the player stands in.
    private var currentCell: S2CellID? { (location.geoPoint ?? sessionOrigin)?.tile }

    /// "L16 80858-7b53 · 12 of 40 looked at", or "· surveyed" once it is marked.
    private func cellSummary(_ cell: S2CellID) -> String {
        let counts = model.cellCensus(cell)
        let state =
            model.isSurveyed(cell)
            ? "surveyed, \(counts.detected) left as detected" : "\(counts.reviewed) of \(counts.total) looked at"
        return "L16 " + cell.familyDisplay + " · " + state
    }

    private var overlayStatus: String {
        let sites = model.loadedVectors.count
        let placed: String
        if let registered {
            placed = "placed by 3DEP ±" + format.length(registered.sigma, fractionDigits: 2)
        } else if sessionOrigin != nil, sessionOriginAccuracy.isFinite {
            placed =
                placedByHand
                ? "lined up by hand" : "placed by GPS ±" + format.length(sessionOriginAccuracy, fractionDigits: 0)
        } else {
            placed = "waiting for GPS"
        }
        return (sites == 0 ? "No site loaded" : sites == 1 ? "1 site loaded" : "\(sites) sites loaded") + ", " + placed
    }

    // MARK: Actions

    /// Not a tree and Move once the selected tree is in view, New tree here, and Scan trunk.
    private var controls: some View {
        VStack(spacing: Spacing.s) {
            TreeActionsRow(
                canEdit: canEditFocus, onNotATree: rejectFocus, onMove: startMove,
                onNewTree: { Task { await addTreeAtReticle() } })
            ScanHeroButton(treeName: focus?.source == .chosen ? focus?.title : nil, action: startScan)
        }
    }

    private var scanControls: some View {
        HStack(spacing: Spacing.s) {
            Button("Cancel", systemImage: "xmark") {
                capture.cancelScan()
                notice = nil
                scanIssue = nil
            }
            .buttonStyle(.canopySecondary)
            Button("Aim here", systemImage: "scope") { reaimScan() }
                .buttonStyle(.canopySecondary)
                .accessibilityIdentifier("scan-reaim")

            Button {
                Task { await finishScan() }
            } label: {
                Label(isMeasuring ? "Measuring…" : "Finish scan", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.canopySurvey)
            .disabled(isMeasuring)
        }
    }

    /// Register with 3DEP, in the overlay menu: matching the mesh to aerial LiDAR, or how well it matched.
    @ViewBuilder
    private var registrationControl: some View {
        if let registered {
            Label(
                "Registered to 3DEP ±" + QuantityFormat.thinSpace + format.length(registered.sigma, fractionDigits: 2),
                systemImage: "checkmark.seal")
        } else {
            Button(isRegistering ? "Registering…" : "Register with 3DEP", systemImage: "scope") {
                confirmingRegistration = true
            }
            .disabled(isRegistering)
        }
    }

    /// Where an AR world point is on the map as the overlay draws it: through the 3DEP registration when there is
    /// one, else through the session origin; nil before the session is placed.
    private func placedPosition(ofARKit point: SIMD3<Float>) -> Position? {
        if let registered {
            return registered.position(ofARKit: point)
        }
        guard let placement, sessionOriginAccuracy.isFinite else { return nil }
        // Lined up by hand on the trees, it is as good as the trees it was lined up on, not the GPS fix.
        let accuracy = placedByHand ? min(sessionOriginAccuracy, Self.placedByHandAccuracy) : sessionOriginAccuracy
        return GeoReference.position(ofARKit: point, placement: placement, accuracy: accuracy)
    }

    /// How well the overlay is placed once it has been lined up on the trees by hand, in metres.
    static let placedByHandAccuracy = 1.0

    /// The session's placement on the map by GPS, with what the player moved and turned by hand.
    private var placement: GPSPlacement? {
        sessionOrigin.map { GPSPlacement(origin: $0, yaw: sessionYaw) }
    }

    /// Where an AR world point is on the map: as the overlay draws it once the session is placed, so a tree added or
    /// moved stays where it was put, else from the GPS fix and the point's offset from the camera.
    private func position(of point: SIMD3<Float>, camera: SIMD3<Float>, device: GeoPoint) -> Position {
        placedPosition(ofARKit: point)
            ?? GeoReference.position(
                of: point, camera: camera, device: device, horizontalAccuracy: location.accuracy ?? 10,
                northAligned: capture.isNorthAligned)
    }

    private func register() async {
        guard let gps = location.geoPoint, let camera = capture.cameraPosition else {
            notice = "Waiting for GPS and AR tracking."
            return
        }
        isRegistering = true
        defer { isRegistering = false }
        do {
            let outcome = try await model.registerScan(
                arkitPoints: capture.worldPoints(range: 60), gps: gps, camera: camera,
                groundBelowOrigin: capture.groundHeight(under: .zero), northAligned: capture.isNorthAligned
            ) { notice = $0 }
            if let placed = outcome.placed, placed.passedGates {
                registered = placed
                notice =
                    "Registered to 3DEP. New positions are good to "
                    + format.length(placed.sigma, fractionDigits: 2) + "."
            } else {
                let failed = outcome.registration.gates.filter { !$0.passed }.map(\.name)
                let reason = outcome.registration.failureReason
                notice =
                    "No reliable match in 3DEP"
                    + (failed.isEmpty ? "" : " (failed: \(failed.joined(separator: ", ")))")
                    + (reason.isEmpty ? "" : ": \(reason)") + ". Still using GPS; look around more and try again."
            }
        } catch {
            notice = "Could not register: \(error.localizedDescription)"
        }
    }

    private func addTreeAtReticle() async {
        guard let device = location.geoPoint else {
            notice = "Waiting for a GPS fix."
            return
        }
        let position: Position
        if let hit = capture.raycastCenter(maxDistance: 15) {
            position = self.position(of: hit.position, camera: hit.cameraPosition, device: device)
        } else {
            let sigma = location.accuracy ?? 10
            position = Position(geo: device, covariance: .isotropic(horizontal: sigma, vertical: sigma))
        }
        await model.addTree(at: position)
        notice = "Added a new tree."
    }

    private func resumeCapture() {
        capture.start()
    }

    private func startScan() {
        scanIssue = nil
        do {
            try capture.startScan()
            notice =
                "Walk slowly round the trunk, keeping it in view. If the lime takes in something else, point at the "
                + "trunk and tap Aim here."
        } catch {
            notice = Self.describe(error)
        }
    }

    /// Aims the scan at the trunk under the reticle instead, keeping what it kept there.
    private func reaimScan() {
        do {
            try capture.reaimScan()
            scanIssue = nil
            notice = "Aimed at the trunk in the middle of the screen. Keep walking round it."
        } catch {
            scanIssue = Self.describe(error)
        }
    }

    private func finishScan() async {
        isMeasuring = true
        defer { isMeasuring = false }
        scanIssue = nil
        do {
            let result = try await capture.finishScan()
            // The tree the scan measures, read before the selection is cleared below.
            let measuring = target
            let position: Position
            if let registered {
                position = registered.position(ofARKit: result.trunkBase)
            } else if let device = location.geoPoint {
                position = self.position(of: result.trunkBase, camera: result.cameraPosition, device: device)
            } else if let target {
                position = target.position
            } else {
                notice = "Waiting for a GPS fix."
                return
            }
            // The fitted tree starts from the selected tree's shape when one is selected, else from the DBH.
            var form = selection.map { model.treeForms[$0.id] ?? $0.baseForm } ?? TreeForm(dbh: result.analysis.dbh)
            form.trunkDiameter = result.analysis.dbh.diameter.value
            form = form.clamped
            deselect()
            // Breast height and the steps a metre apart start fitted to the scan as far up as its points reach, as
            // the DBH was, with every other stem of the tree the scan crosses there.
            let lean = result.analysis.lean
            let profile = result.addingStems(
                to: TrunkSteps.fitted(TreeProfile(form: form), to: result, below: form.crownBase),
                below: form.crownBase, lean: lean)
            // A tree with stems measured by another scan keeps those this one did not measure again.
            let anchor = measuring?.position.geo ?? position.geo
            let measured = StemRecord.measures(
                profile, lean: lean, base: result.trunkBase, mainDBH: result.analysis.dbh, anchor: anchor,
                place: mapPosition(ofARKit:))
            let others = (measuring?.stems ?? []).filter { old in
                StemMeasure.merging([old], with: measured).count == measured.count + 1
            }
            let stems = others + measured
            let dbh = stems.count > 1 ? StemRecord.dbh(stems) ?? result.analysis.dbh : result.analysis.dbh
            // Saved on the phone straight away, mesh and all: nothing more to tap for the scan to be kept, and its rings
            // can be aligned from Me → Your scans even if nothing else is done here.
            let saved = await model.saveTrunkMeasurement(
                dbh: dbh, lean: lean, glb: result.glb,
                evidenceMesh: (result.evidence.vertexCount, result.evidence.triangleCount),
                cropRadius: result.cropRadius, tree: measuring, position: position,
                stems: StemRecord.recorded(stems))
            if let saved {
                await model.saveAlignment(
                    ScanAlignment(
                        scan: BlobStore.reference(for: result.glb), treeID: saved.id, profile: profile,
                        groundHeight: result.groundHeight))
                // Measuring again in this scan measures the same tree, not another new one.
                targetID = saved.id
            }
            var fit = TreeFit(
                capture: result, position: position, fitting: TreeFitting(shape: form, profile: profile),
                base: result.trunkBase)
            fit.savedTree = saved
            fit.otherStems = others
            self.fit = fit
            showFit(fit)
            let steps = profile.trunk.filter { $0.source == .scan }.map(\.height).max()
            let found = profile.breastHeightStems(lean: lean).count
            notice =
                (saved.map { "Saved the scan of \($0.name) on this phone. " } ?? "")
                + (found > 1
                    ? "Found \(found) stems: equivalent DBH "
                        + format.length(dbh.diameter.value, fractionDigits: 2) + ". Check them under Stems. "
                    : "")
                + (steps.map { "Rings are fitted to the scan up to " + format.length($0, fractionDigits: 1) + ". " }
                    ?? "")
                + "Set the shape with the sliders, or align the rings later from Me → Your scans."
        } catch {
            // Kept with the scan, so it is there to read and the scan can go on.
            scanIssue = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.noSurface: "Point the centre of the screen at the trunk, within 6 m."
        case CaptureError.notEnoughMesh: "Walk slowly round the trunk so the mesh fills in, then try again."
        case CaptureError.noGround: "Include some ground at the foot of the trunk in the scan."
        case CaptureError.notScanning: "Start a scan on the trunk first."
        case TrunkAnalysisError.notEnoughPoints:
            "Not enough of the trunk 1.37 m above the ground yet. Scan it from closer."
        case TrunkAnalysisError.arcTooShort(let degrees):
            "The scan covers \(Int(degrees.rounded()))° of the trunk 1.37 m up, and needs 75°. Keep walking round it."
        case TrunkAnalysisError.implausibleDiameter(let diameter):
            "The scan 1.37 m up fits a circle " + QuantityFormat().length(diameter, fractionDigits: 1)
                + " across, which is no trunk. Point at the trunk, tap Aim here, then walk round it."
        default: "Could not measure: \(error.localizedDescription)"
        }
    }

    // MARK: Fitting the wireframe tree

    /// Draws the fitted tree as it stands, with the ring being edited picked out.
    private func showFit(_ fit: TreeFit) {
        capture.showTree(fit.profile, lean: fit.capture.analysis.lean, at: fit.base, highlight: fit.selectedSection)
    }

    /// The panel's binding into the fitted shape and rings: every change redraws the tree.
    private var fitFittingBinding: Binding<TreeFitting> {
        Binding(
            get: {
                fit?.fitting
                    ?? TreeFitting(shape: TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5))
            },
            set: { fitting in
                guard var fit else { return }
                stopAligningEdited(from: fit.profile, to: fitting.profile)
                fit.fitting = fitting
                if let selected = fit.selectedSection, fitting.profile.section(selected) == nil {
                    fit.selectedSection = nil
                }
                self.fit = fit
                showFit(fit)
            })
    }

    /// The ring being edited.
    private var fitSectionBinding: Binding<TreeSection.ID?> {
        Binding(
            get: { fit?.selectedSection },
            set: { id in
                guard var fit else { return }
                fit.selectedSection = id
                self.fit = fit
                showFit(fit)
            })
    }

    /// Fits the ring being edited to the scan at its height.
    private func snapSelectedSection() {
        guard var fit, let id = fit.selectedSection, let section = fit.profile.section(id) else { return }
        do {
            fit.profile[id] = try fit.capture.snapping(section)
            // Fitted to the scan now: the camera no longer sets it.
            capture.stopAligning(ring: id)
            self.fit = fit
            showFit(fit)
            notice =
                "Ring fitted to the scan " + format.length(section.height, fractionDigits: 2)
                + " up. Tap \"Looks right\" if it matches the tree."
        } catch TrunkAnalysisError.notEnoughPoints {
            notice =
                "The scan has too little of the tree " + format.length(section.height, fractionDigits: 2)
                + " up to fit a ring there."
        } catch TrunkAnalysisError.arcTooShort {
            notice = "The scan covers too little of the trunk at that height. Walk round it and scan again."
        } catch {
            notice = Self.describe(error)
        }
    }

    // MARK: Aligning rings to the camera

    /// Starts or stops aligning the trunk's rings above the scan to its edges in the camera image. Starting puts a
    /// ring at every step a metre apart up to the crown's base, on the axis and at the taper of the rings fitted
    /// below, then moves each to the trunk's edges as the player walks round.
    private func toggleAlignment() {
        guard var fit else { return }
        if capture.isAligning {
            capture.stopAligning()
            notice = "Stopped. The blue rings are set from the camera: tap Looks right on each that matches the tree."
            return
        }
        let lean = fit.capture.analysis.lean
        let top = fit.profile.crown.first?.height ?? fit.fitting.shape.crownBase
        fit.profile = TrunkSteps.predicted(fit.profile, below: top, lean: lean)
        guard let aligner = TrunkSteps.aligner(for: fit.profile, base: fit.base, lean: lean) else {
            notice = "Every trunk ring is fitted to the scan or confirmed already."
            return
        }
        self.fit = fit
        showFit(fit)
        capture.startAligning(aligner)
        notice = "Point the phone up the trunk and walk slowly round it: the rings above the scan move to its edges."
    }

    /// The camera's latest fits, applied to the rings still being aligned.
    private func applyRingFits() {
        guard var fit, !capture.ringFits.isEmpty else { return }
        let aligned = TrunkSteps.applying(capture.ringFits, to: fit.profile, base: fit.base)
        guard aligned != fit.profile else { return }
        fit.profile = aligned
        self.fit = fit
        showFit(fit)
    }

    /// Stops aligning the rings the player moved by hand, confirmed or took out. (Snapping one to the scan stops it in
    /// `snapSelectedSection`.)
    private func stopAligningEdited(from old: TreeProfile, to new: TreeProfile) {
        for id in capture.aligningRings {
            guard let ring = new.section(id) else {
                capture.stopAligning(ring: id)
                continue
            }
            if ring.source == .confirmed || (ring.source == .eye && ring != old.section(id)) {
                capture.stopAligning(ring: id)
            }
        }
    }

    /// How the alignment is going, for the rings panel.
    private var alignStatus: String? {
        guard capture.isAligning else { return nil }
        let found = capture.ringFits.count
        guard found > 0 else { return "Looking for the trunk's edges: point the phone up it." }
        let views = capture.ringFits.values.map(\.views).max() ?? 0
        return "\(found) of \(capture.aligningRings.count) rings on its edges, from \(views) "
            + (views == 1 ? "viewpoint" : "viewpoints")
    }

    /// Stands the tree on the ground under the centre of the view instead.
    private func moveTreeHere() {
        guard var fit else { return }
        capture.stopAligning()
        guard let hit = capture.raycastCenter(maxDistance: 20) else {
            notice = "Point the centre of the screen at the foot of the tree."
            return
        }
        let ground = capture.groundHeight(under: hit.position) ?? hit.position.y
        fit.base = SIMD3(hit.position.x, ground, hit.position.z)
        if let registered {
            fit.position = registered.position(ofARKit: fit.base)
        } else if let device = location.geoPoint {
            fit.position = position(of: fit.base, camera: hit.cameraPosition, device: device)
        }
        self.fit = fit
        showFit(fit)
        notice = nil
    }

    /// Back to scanning: the scan keeps running, the wireframe comes down.
    private func stopFitting() {
        capture.stopAligning()
        capture.hideTree()
        fit = nil
        notice = nil
    }

    private func showMeasurement() {
        guard let fit else { return }
        // Stems sorted and not yet recorded are recorded on the way.
        if fit.stemsChanged { Task { await saveStems() } }
        notice = nil
        capture.stopAligning()
        capture.pause()
        measurement = Measurement(
            capture: fit.capture, position: fit.position, target: fit.savedTree ?? target, form: fit.form,
            profile: fit.profile, saved: fit.savedTree)
    }

    // MARK: The tree's stems

    /// Where an AR world point is on the map, by the 3DEP registration, the placement, or the GPS fix and the camera.
    private func mapPosition(ofARKit point: SIMD3<Float>) -> GeoPoint? {
        if let placed = placedPosition(ofARKit: point) { return placed.geo }
        guard let device = location.geoPoint, let camera = capture.cameraPosition else { return nil }
        return position(of: point, camera: camera, device: device).geo
    }

    /// The fitted tree's stems as it records them: this scan's, with those other scans measured, and their DBH.
    private func stemRecord(_ fit: TreeFit) -> (dbh: DBH, stems: [StemMeasure]) {
        let measured = StemRecord.measures(
            fit.profile, lean: fit.capture.analysis.lean, base: fit.base, mainDBH: fit.capture.analysis.dbh,
            anchor: fit.savedTree?.position.geo ?? fit.position.geo, place: mapPosition(ofARKit:))
        let stems = fit.otherStems + measured
        let dbh = stems.count > 1 ? StemRecord.dbh(stems) : nil
        return (dbh ?? fit.capture.analysis.dbh, stems)
    }

    /// What the Stems mode shows and does.
    private var stemActions: TreeStemsEditor.Actions {
        guard let fit else { return TreeStemsEditor.Actions() }
        let record = stemRecord(fit)
        return TreeStemsEditor.Actions(
            count: record.stems.count, others: fit.otherStems.count, dbh: record.dbh, isChanged: fit.stemsChanged,
            onRemove: removeStem, onAdd: addStemAtReticle, onSplit: prepareSplit,
            onSave: { Task { await saveStems() } })
    }

    /// Takes out a stem that is not one: a post, a shrub or another tree's.
    private func removeStem(_ stem: Int) {
        guard var fit else { return }
        fit.profile.removeStem(stem)
        fit.selectedSection = TreeStemsEditor.ring(of: nil, in: fit.profile)?.id
        fit.stemsChanged = true
        self.fit = fit
        showFit(fit)
        notice = "Took the stem out. Save records the tree's stems."
    }

    /// Adds the stem under the middle of the screen, fitted to the scan at breast height.
    private func addStemAtReticle() {
        guard var fit else { return }
        guard let hit = capture.raycastCenter(maxDistance: 15) else {
            notice = "Point the middle of the screen at the stem 1.37 m up."
            return
        }
        let near = SIMD2(Double(hit.position.x - fit.base.x), Double(hit.position.z - fit.base.z))
        do {
            let top = fit.profile.crown.first?.height ?? fit.fitting.shape.crownBase
            guard
                let (profile, stem) = try fit.capture.addingStem(
                    near: near, to: fit.profile, below: top, lean: fit.capture.analysis.lean)
            else {
                notice = "That stem is the tree's already."
                return
            }
            fit.profile = profile
            fit.selectedSection = TreeStemsEditor.ring(of: stem, in: profile)?.id
            fit.stemsChanged = true
            self.fit = fit
            showFit(fit)
            notice = "Added the stem, fitted to the scan. Save records the tree's stems."
        } catch {
            notice =
                "The scan has too little of that stem 1.37 m up. Finish this one, then scan it and save it on the "
                + "same tree."
        }
    }

    /// The question asked before splitting.
    private var splitTitle: String {
        let count = pendingSplit?.count ?? 0
        return count == 1 ? "Split this stem off as its own tree?" : "Split these \(count) stems off as a tree?"
    }

    /// Cuts the clump along a line on the ground through the middle of the screen, the way the camera faces: the
    /// stems from the ground beyond it, from the main trunk, are asked to be split off.
    private func prepareSplit() {
        guard let fit else { return }
        guard let hit = capture.raycastCenter(maxDistance: 15) else {
            notice = "Point the middle of the screen at the ground between the stems to cut there."
            return
        }
        let at = SIMD2(Double(hit.position.x - fit.base.x), Double(hit.position.z - fit.base.z))
        let camera = SIMD2(Double(hit.cameraPosition.x - fit.base.x), Double(hit.cameraPosition.z - fit.base.z))
        let along = at - camera
        guard simd_length(along) > 0.1 else { return }
        func side(_ point: SIMD2<Double>) -> Double {
            along.x * (point.y - at.y) - along.y * (point.x - at.x)
        }
        let mainSide = side(.zero)
        let beyond = fit.profile.groundStems.filter { side(fit.profile.base(of: $0)) * mainSide < 0 }
        guard !beyond.isEmpty, fit.savedTree != nil else {
            notice =
                "Every stem is on the main trunk's side of that cut. Aim the middle of the screen at the ground "
                + "between the stems to split off, facing along the gap."
            return
        }
        pendingSplit = beyond
    }

    /// Splits stems off the fitted tree into a tree of their own.
    private func splitOff(_ roots: [Int]) async {
        guard var fit, let tree = fit.savedTree else { return }
        let lean = fit.capture.analysis.lean
        guard let split = fit.profile.splittingOff(roots, lean: lean) else { return }
        let base = fit.base + SIMD3(Float(split.base.x), 0, Float(split.base.y))
        guard let geo = mapPosition(ofARKit: base) else {
            notice = "Waiting for GPS to place the new tree."
            return
        }
        let position =
            placedPosition(ofARKit: base)
            ?? Position(geo: geo, covariance: .isotropic(horizontal: location.accuracy ?? 10, vertical: 10))
        if let refusal = model.splitRefusal(at: geo) {
            notice = refusal
            return
        }
        let offStems = StemRecord.measures(
            split.off, lean: lean, base: base, mainDBH: nil, anchor: geo, place: mapPosition(ofARKit:))
        let offDBH = StemRecord.dbh(offStems) ?? DBH(diameter: Quantity(0.3, uncertainty: 0.1), method: .estimate)
        fit.profile = split.kept
        fit.selectedSection = TreeStemsEditor.ring(of: nil, in: fit.profile)?.id
        let kept = stemRecord(fit)
        guard
            let new = await model.splitOff(
                from: tree, keeping: (kept.dbh, kept.stems), at: position, dbh: offDBH, stems: offStems,
                evidence: BlobStore.reference(for: fit.capture.glb), profile: split.off)
        else { return }
        fit.stemsChanged = false
        fit.savedTree = model.tree(tree.id) ?? tree
        self.fit = fit
        showFit(fit)
        await model.saveAlignment(
            ScanAlignment(
                scan: BlobStore.reference(for: fit.capture.glb), treeID: tree.id, profile: fit.profile,
                groundHeight: fit.capture.groundHeight))
        notice =
            "Split \(offStems.count == 1 ? "a stem" : "\(offStems.count) stems") off as \(new.name), proposed. "
            + "\(tree.name) keeps \(kept.stems.count == 1 ? "one stem" : "\(kept.stems.count)")."
    }

    /// Records the fitted tree's stems as sorted, and keeps its rings with the scan.
    private func saveStems() async {
        guard var fit, let tree = fit.savedTree else { return }
        let record = stemRecord(fit)
        guard await model.saveStems(of: tree.id, dbh: record.dbh, stems: record.stems) else { return }
        await model.saveAlignment(
            ScanAlignment(
                scan: BlobStore.reference(for: fit.capture.glb), treeID: tree.id, profile: fit.profile,
                groundHeight: fit.capture.groundHeight))
        fit.stemsChanged = false
        fit.savedTree = model.tree(tree.id) ?? tree
        self.fit = fit
        notice =
            record.stems.count > 1
            ? "Recorded \(record.stems.count) stems, equivalent DBH "
                + format.length(record.dbh.diameter.value, fractionDigits: 2) + "."
            : "Recorded one stem."
    }

    // MARK: Placing the session

    /// Fixes where the AR session's origin is on the map: the GPS fix, less the camera's offset from the origin.
    /// Done again whenever a clearly better fix arrives, until a 3DEP registration takes over.
    /// Once lined up by hand, it stays where the player put it: a new fix would undo that.
    private func placeSession() {
        guard registered == nil, !placedByHand, let fix = location.geoPoint, let accuracy = location.accuracy,
            let camera = capture.cameraPosition, capture.isNorthAligned
        else { return }
        guard sessionOrigin == nil || accuracy < sessionOriginAccuracy - 2 else { return }
        sessionOrigin =
            LocalFrame(origin: fix).geoPoint(of: ENU(east: Double(-camera.x), north: Double(camera.z), up: 0)).point
        gpsOrigin = sessionOrigin
        sessionYaw = 0
        sessionOriginAccuracy = accuracy
    }

    /// Back to placing the overlay by GPS: what was moved by hand is forgotten.
    private func placeFromGPS() {
        placedByHand = false
        sessionYaw = 0
        sessionOrigin = gpsOrigin ?? sessionOrigin
        sessionOriginAccuracy = .infinity
        placeSession()
        rebuildOverlay()
    }

    // MARK: Lining the overlay up by hand

    /// Moves or turns the overlay by hand, about the camera.
    private func adjustPlacement(_ change: (GPSPlacement, SIMD3<Float>) -> GPSPlacement) {
        guard registered == nil, let placement, let camera = capture.cameraPosition else { return }
        let next = change(placement, camera)
        placedByHand = true
        sessionOrigin = next.origin
        sessionYaw = next.yaw
    }

    /// The way the camera faces on the map, degrees clockwise from north.
    private var facing: Double {
        tracker.heading ?? capture.cameraTransform.flatMap(Compass.heading(ofCamera:)) ?? 0
    }

    /// Moves the player `forward` and `right` metres through the drawing, as the camera faces: the drawing moves the
    /// other way.
    private func walk(forward: Double, right: Double) {
        let h = facing * .pi / 180
        let ahead = SIMD3<Float>(Float(sin(h)), 0, Float(-cos(h)))
        let side = SIMD3<Float>(Float(cos(h)), 0, Float(sin(h)))
        let step = ahead * Float(forward) + side * Float(right)
        adjustPlacement { placement, camera in placement.moving(drawnAt: camera, to: camera - step) }
    }

    /// Turns the player `degrees` clockwise against the drawing: the drawing turns the other way about them.
    private func turn(clockwise degrees: Double) {
        adjustPlacement { placement, camera in
            placement.turning(clockwise: -degrees * .pi / 180, about: camera)
        }
    }

    /// Moves the overlay so the selected tree, as drawn, stands on the trunk under the reticle.
    private func lineUpFocus() {
        guard let focus, let drawn = drawnCensus[focus.id] ?? drawnSite[focus.id] else {
            notice = "Wait until the tree is drawn in AR, then try again."
            return
        }
        let radius = Float((focus.dbh?.diameter.value ?? 0.3) / 2)
        guard let base = reticleTrunkBase(radius: radius) else {
            notice = "Point the centre of the screen at the foot of the trunk, within 25 m."
            return
        }
        let distance = simd_length(Compass.offset(from: drawn.base, to: base))
        adjustPlacement { placement, _ in placement.moving(drawnAt: drawn.base, to: base) }
        notice =
            "Moved the overlay " + format.length(distance, fractionDigits: 1) + " to put " + focus.title
            + " on the trunk. Turn it with the pad if the trees round it are still off."
    }

    /// The trees the overlay draws within reach of the radar.
    private var radarTrees: [RadarTree] {
        guard let camera = tracker.camera else { return [] }
        func near(_ drawn: DrawnTree) -> Bool { simd_length(Compass.offset(from: camera, to: drawn.base)) < 45 }
        var trees: [RadarTree] = []
        for (id, drawn) in drawnSite where near(drawn) && id != focus?.id {
            trees.append(RadarTree(id: id, base: drawn.base, kind: .site))
        }
        for (id, drawn) in drawnCensus where near(drawn) && id != focus?.id {
            trees.append(RadarTree(id: id, base: drawn.base, kind: .census))
        }
        if let focus, let drawn = drawnCensus[focus.id] ?? drawnSite[focus.id] {
            trees.append(RadarTree(id: focus.id, base: drawn.base, kind: .focus))
        }
        return trees
    }

    /// "Placed by GPS ±6 m", or how far it was moved and turned by hand.
    private var placementStatus: String {
        if registered != nil { return "Placed by 3DEP: nothing to line up by hand." }
        guard let sessionOrigin, sessionOriginAccuracy.isFinite else { return "Waiting for GPS to place the overlay." }
        guard placedByHand, let gpsOrigin else {
            return "Placed by GPS ±" + format.length(sessionOriginAccuracy, fractionDigits: 0)
                + ". Move until the drawn trees stand on the real ones."
        }
        let moved = simd_length(Compass.offset(from: gpsOrigin, to: sessionOrigin))
        return "Moved " + format.length(moved, fractionDigits: 1) + " and turned "
            + format.angle(abs(sessionYaw * 180 / .pi), fractionDigits: 0) + " from GPS. GPS leaves it alone now."
    }

    /// Asks for the site under the player once per tile arrived at, when a server is set and it is not loaded yet.
    /// Asked for on its own, a site load is quiet: it is not tried while the phone is offline, a failure says
    /// nothing and waits `autoLoadPatience` before the next try, and nothing it says covers what the player is doing.
    private func autoLoadVectors() {
        guard let fix = location.geoPoint, model.alignClient != nil, model.isOnline else { return }
        if let failed = autoLoadFailedAt, Date.now.timeIntervalSince(failed) < Self.autoLoadPatience { return }
        let tile = fix.tile
        guard tile != autoLoadTile, !model.hasVectors(at: fix), !model.aerial.isWorking else { return }
        autoLoadTile = tile
        loadVectors(around: fix, quietly: true)
    }

    /// How long a failed load of the site under the player waits before it is tried again, in seconds.
    static let autoLoadPatience: TimeInterval = 180

    private func loadVectors(around point: GeoPoint, quietly: Bool = false) {
        guard !loadingVectors else { return }
        loadingVectors = true
        loadingQuietly = quietly
        Task {
            await model.loadVectors(around: point)
            loadingVectors = false
            loadingQuietly = false
            switch model.aerial {
            case .done(let message):
                autoLoadFailedAt = nil
                if !quietly || (capture.scan == nil && move == nil) { notice = message }
            case .failed(let message):
                if quietly {
                    autoLoadFailedAt = .now
                    autoLoadTile = nil
                } else {
                    notice = message
                }
            default: break
            }
            rebuildOverlay()
        }
    }

    // MARK: The site overlay

    /// A loaded site placed in the AR world.
    private struct PlacedSite {
        var token: String
        var loaded: LoadedVectors
        var frame: ARSiteFrame
    }

    /// The ARKit height of the ground under the session origin: the mesh's floor there, else a camera height
    /// below the camera.
    private var arGroundAtOrigin: Float {
        capture.groundHeight(under: .zero) ?? ((capture.cameraPosition?.y ?? 0) - 1.5)
    }

    /// Every loaded site, placed by the registration when there is one, else by GPS; none until the session is
    /// placed.
    private func placedSites() -> [PlacedSite] {
        let arGround = arGroundAtOrigin
        return model.loadedVectors.keys.sorted().compactMap { token in
            guard let loaded = model.loadedVectors[token] else { return nil }
            if let registered {
                return PlacedSite(
                    token: token, loaded: loaded,
                    frame: ARSiteFrame(registered: registered, georeference: loaded.georeference))
            }
            guard let placement else { return nil }
            let originSite = loaded.georeference.site(of: placement.origin)
            let siteGround =
                ARSiteFrame.groundHeight(loaded.vectors.ground, at: originSite) ?? Self.typicalGround(loaded.vectors)
            return PlacedSite(
                token: token, loaded: loaded,
                frame: ARSiteFrame(
                    placement: placement, georeference: loaded.georeference, arGroundAtOrigin: arGround,
                    siteGroundAtOrigin: siteGround))
        }
    }

    /// The median height of a site's features' first vertices: the ground, near enough, for a site without a
    /// ground grid.
    static func typicalGround(_ vectors: VectorReference) -> Double {
        let heights = vectors.features.compactMap { $0.line.vertices.first?.z }.sorted()
        return heights.isEmpty ? 0 : Double(heights[heights.count / 2])
    }

    /// Draws parts of the overlay again from what is loaded and where the session is placed: by default all of it.
    private func rebuildOverlay(_ parts: OverlayParts = .all) {
        guard !parts.isEmpty else { return }
        // A trunk being fitted is drawn alone: the site's lines and the census's trees round it would bury its rings.
        let sites = fit == nil ? placedSites() : []
        let camera = capture.cameraPosition ?? .zero
        if !parts.isDisjoint(with: [.siteTrees, .siteOther]) {
            for layer in SiteWireframes.Layer.allCases where layer.isSiteLayer {
                guard parts.contains(layer == .trees ? .siteTrees : .siteOther) else { continue }
                let name = "site-" + layer.rawValue
                guard overlayLayers.contains(layer), !sites.isEmpty else {
                    capture.hideWireframes(named: name)
                    if layer == .trees { drawnSite = [:] }
                    continue
                }
                // Neighbouring sites overlap; a feature is drawn once, from the first site that has it.
                var seen: Set<String> = []
                var items: [WireframeItem] = []
                for site in sites {
                    let centre = site.frame.site(ofARKit: camera)
                    for item in SiteWireframes.items(
                        site.loaded.vectors.features, layer: layer, frame: site.frame,
                        centre: SIMD2(Float(centre.x), Float(centre.y)), forms: model.treeForms)
                    where seen.insert(item.id).inserted {
                        items.append(item)
                    }
                }
                capture.showWireframes(
                    WireframeLayer(
                        name: name, items: items, color: Self.color(of: layer),
                        lineWidth: layer == .trees ? 0.015 : 0.02))
                if layer == .trees { drawnSite = DrawnTree.byID(items) }
            }
        }
        if parts.contains(.census) { rebuildCensusTrees(sites: sites) }
        if parts.contains(.cells) { rebuildCells(sites: sites) }
    }

    /// Where a map point is on the ground in the AR world: on a loaded site's ground grid when one has it, else on
    /// the ground under the session origin. Nil until the session is placed.
    private func arGroundPoint(_ geo: GeoPoint, sites: [PlacedSite], arGround: Float) -> SIMD3<Float>? {
        if let site = sites.first(where: {
            ARSiteFrame.groundHeight($0.loaded.vectors.ground, at: $0.frame.site(of: geo)) != nil
        }) ?? sites.first {
            let xy = site.frame.site(of: geo)
            let z =
                ARSiteFrame.groundHeight(site.loaded.vectors.ground, at: xy)
                ?? Self.typicalGround(site.loaded.vectors)
            return site.frame.arkit(SIMD3<Double>(xy.x, xy.y, z))
        }
        guard let placement else { return nil }
        let xz = placement.arkitXZ(of: geo)
        return SIMD3(xz.x, arGround, xz.y)
    }

    /// The S2 cells round the player on the ground: level-16 tiles (surveyed ones in green) and their level-13
    /// parents, each with posts at its corners.
    private func rebuildCells(sites: [PlacedSite]) {
        let names = ["cells-l16", "cells-l16-surveyed", "cells-l13"]
        guard overlayLayers.contains(.cells), fit == nil, let here = location.geoPoint ?? sessionOrigin else {
            for name in names { capture.hideWireframes(named: name) }
            return
        }
        let arGround = arGroundAtOrigin
        let cells = SiteWireframes.cells(around: here)
        func item(_ cell: S2CellID) -> WireframeItem {
            SiteWireframes.cellItem(cell) { geo in arGroundPoint(geo, sites: sites, arGround: arGround) ?? .zero }
        }
        let surveyed = cells.level16.filter(model.isSurveyed)
        let open = cells.level16.filter { !model.isSurveyed($0) }
        capture.showWireframes(
            WireframeLayer(name: names[0], items: open.map(item), color: Self.cellColor, lineWidth: 0.02))
        capture.showWireframes(
            WireframeLayer(
                name: names[1], items: surveyed.map(item), color: Self.surveyedCellColor, lineWidth: 0.03))
        capture.showWireframes(
            WireframeLayer(name: names[2], items: cells.level13.map(item), color: Self.cell13Color, lineWidth: 0.05))
    }

    static let cellColor = SIMD4<Float>(0.62, 0.68, 0.60, 1)
    static let surveyedCellColor = SIMD4<Float>(0.35, 0.78, 0.45, 1)
    static let cell13Color = SIMD4<Float>(0.45, 0.62, 0.90, 1)

    /// The census's trees within 120 m, as wireframes of what is known about them.
    private func rebuildCensusTrees(sites: [PlacedSite]) {
        let name = "census-trees"
        guard showsCensusTrees, fit == nil, let here = location.geoPoint ?? sessionOrigin else {
            capture.hideWireframes(named: name)
            capture.hideWireframes(named: name + "-surveyed")
            drawnCensus = [:]
            return
        }
        let arGround = arGroundAtOrigin
        var items: [WireframeItem] = []
        // Detections in a surveyed cell were looked over and left: drawn faint and thin.
        var surveyed: [WireframeItem] = []
        for (tree, _) in model.census.trees(near: here, within: 120, limit: 400, tiles: model.censusTiles)
        where tree.id != move?.treeID {
            guard let base = arGroundPoint(tree.position.geo, sites: sites, arGround: arGround) else { continue }
            let id = ARTreeSelection.censusPrefix + tree.id.uuidString
            var item = SiteWireframes.treeItem(
                id: id, form: model.treeProfiles[id]?.form ?? model.treeForms[id] ?? Self.censusForm(tree),
                lean: tree.lean, at: base)
            // Fitted rings, else every stem of a tree of several.
            if let profile = model.treeProfiles[id]
                ?? tree.stems.map({ TreeProfile(form: model.treeForms[id] ?? Self.censusForm(tree), stems: $0) })
            {
                item.segments =
                    WireframeTree.figure(
                        profile, lean: tree.lean, at: base, detail: SiteWireframes.treeDetail
                    ).all
            }
            if tree.effectiveStatus == .detected, model.isSurveyed(tree.position.tile) {
                surveyed.append(item)
            } else {
                items.append(item)
            }
        }
        capture.showWireframes(
            WireframeLayer(name: name, items: items, color: Self.censusColor, lineWidth: 0.015))
        capture.showWireframes(
            WireframeLayer(
                name: name + "-surveyed", items: surveyed, color: Self.censusColor * SIMD4(1, 1, 1, 0.35),
                lineWidth: 0.008))
        drawnCensus = DrawnTree.byID(items + surveyed)
    }

    /// What the census knows of a tree's shape: its DBH and height when measured, a middling tree otherwise.
    static func censusForm(_ tree: Tree) -> TreeForm {
        var form =
            tree.dbh.map(TreeForm.init(dbh:)) ?? TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5)
        if let height = tree.height?.height.value {
            form.height = height
            form.crownHeight = height * 2 / 3
        }
        return form.clamped
    }

    static let censusColor = SIMD4<Float>(0.44, 0.75, 0.50, 1)

    static func color(of layer: SiteWireframes.Layer) -> SIMD4<Float> {
        switch layer {
        case .trees: CaptureSession.crownColor
        case .buildings: SIMD4(0.75, 0.69, 0.55, 1)
        case .streets: SIMD4(0.55, 0.55, 0.45, 1)
        case .cells: cellColor
        }
    }

    // MARK: Selecting trees

    private func handleTap(at point: CGPoint) {
        guard fit == nil, move == nil, let id = capture.pickWireframe(at: point) else { return }
        select(id)
    }

    private func select(_ id: String) {
        if let uuid = ARTreeSelection(id: id).censusID, let tree = model.tree(uuid) {
            targetID = uuid
            var parts: [String] = []
            if let dbh = tree.dbh {
                parts.append("DBH " + format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty))
            }
            if let height = tree.height {
                parts.append("height " + format.length(height.height.value, fractionDigits: 1))
            }
            let measured =
                parts.isEmpty ? "No measurements yet; the shape is a guess." : parts.joined(separator: " · ")
            selection = ARTreeSelection(
                id: id, title: tree.name, detail: tree.species.map { $0 + " · " + measured } ?? measured,
                status: tree.displayStatus, baseForm: Self.censusForm(tree), geo: tree.position.geo)
        } else if let found = gerardusTree(id) {
            let (tree, georeference) = found
            var parts: [String] = []
            parts.append(
                tree.measured.contains("dbh_m")
                    ? "DBH " + format.length(tree.form.trunkDiameter, fractionDigits: 2) : "DBH unknown")
            parts.append(
                tree.measured.contains("height_m")
                    ? "height " + format.length(tree.form.height, fractionDigits: 1) : "height a default")
            parts.append(id.hasPrefix("datasf:") ? "Street Tree List" : "seen in 3DEP and scans")
            selection = ARTreeSelection(
                id: id, title: tree.commonName ?? tree.species ?? "Gerardus tree",
                detail: parts.joined(separator: " · "),
                status: nil, baseForm: tree.form,
                geo: georeference.geo(x: Double(tree.base.x), y: Double(tree.base.y)))
        }
    }

    /// Back to the target; its wireframe is highlighted instead (`following`).
    private func deselect() {
        selection = nil
    }

    /// The selected tree's shape: the player's adjustment, else what is known.
    private var selectedFormBinding: Binding<TreeForm> {
        Binding(
            get: {
                selection.map { model.treeForms[$0.id] ?? $0.baseForm }
                    ?? TreeForm(dbh: DBH(diameter: Quantity(0.3, uncertainty: 0.1), method: .estimate))
            },
            set: { form in
                guard let selection else { return }
                model.treeForms[selection.id] = form.clamped
            })
    }

    private func resetSelectedForm() {
        guard let selection else { return }
        model.treeForms[selection.id] = nil
    }

    /// One of Gerardus's trees by its feature id, with the georeference of the site it came from.
    private func gerardusTree(_ id: String) -> (GerardusTree, SiteGeoreference)? {
        for loaded in model.loadedVectors.values {
            if let tree = SiteWireframes.trees(in: loaded.vectors.features).first(where: { $0.id == id }) {
                return (tree, loaded.georeference)
            }
        }
        return nil
    }

    // MARK: Not a tree and Move

    /// Not a tree: the selected census tree is proposed removed, and the next nearest becomes the target.
    private func rejectFocus() {
        guard let tree = focus?.tree else { return }
        Task {
            await model.reject(tree)
            if selection?.censusID == tree.id { deselect() }
            if targetID == tree.id { targetID = nil }
            notice = "Marked \(tree.name) as not a tree. Shared when you sync."
            rebuildOverlay([.census])
        }
    }

    /// Starts moving the selected census tree: it stands at the trunk under the reticle, if there is one, else where
    /// it is drawn, until Place here.
    private func startMove() {
        guard let focus, let tree = focus.tree, let drawn = drawnCensus[focus.id] else {
            notice = "Wait until the tree is drawn in AR, then try again."
            return
        }
        let profile = model.treeProfiles[focus.id]
        let form = profile?.form ?? model.treeForms[focus.id] ?? Self.censusForm(tree)
        var move = TreeMove(
            treeID: tree.id, name: tree.name, from: drawn.base, base: drawn.base, form: form, profile: profile,
            lean: tree.lean)
        if let base = reticleTrunkBase(radius: move.radius) { move.base = base }
        self.move = move
        capture.acceptsDrags = true
        // Only the tree being moved is drawn for it, not its old copy too.
        rebuildOverlay([.census])
        showMove(move)
        notice = nil
    }

    /// Stands the tree being moved at the trunk under the reticle.
    private func moveToReticle() {
        guard var move else { return }
        guard let base = reticleTrunkBase(radius: move.radius) else {
            notice = "Point the centre of the screen at the foot of the tree, within 25 m."
            return
        }
        move.base = base
        self.move = move
        showMove(move)
        notice = nil
    }

    /// The trunk's base under the reticle: on the ground, behind the near side of the trunk the ray met.
    private func reticleTrunkBase(radius: Float) -> SIMD3<Float>? {
        guard let hit = capture.raycastCenter(maxDistance: 25) else { return nil }
        let ground = capture.groundHeight(under: hit.position) ?? hit.position.y
        return Compass.trunkBase(hit: hit.position, camera: hit.cameraPosition, ground: ground, radius: radius)
    }

    /// Moves the tree being moved to the ground under a finger: the mesh where the finger points (behind a trunk's
    /// near side), else the level of the tree's base. The ground is looked up again when the finger lifts.
    private func dragTree(_ drag: CaptureSession.Drag) {
        guard var move else { return }
        var base: SIMD3<Float>?
        if let hit = capture.raycast(at: drag.point, maxDistance: 40) {
            base = Compass.trunkBase(
                hit: hit.position, camera: hit.cameraPosition, ground: move.base.y, radius: move.radius)
        } else if let ray = capture.ray(through: drag.point) {
            base = Compass.ground(rayFrom: ray.origin, direction: ray.direction, height: move.base.y)
        }
        guard var base else { return }
        if drag.ended, let ground = capture.groundHeight(under: base + SIMD3(0, 1, 0)) {
            base.y = ground
        }
        move.base = base
        self.move = move
        showMove(move)
    }

    /// Draws the tree being moved where it stands now, with marching ants round its foot and a dashed line back to a
    /// grey ring where it was: the orange tree is where Place here puts it, the grey ring where it is now.
    private func showMove(_ move: TreeMove) {
        if let profile = move.profile {
            capture.showTree(profile, lean: move.lean, at: move.base)
        } else {
            capture.showTree(move.form, lean: move.lean, at: move.base)
        }
        drawAnts(move)
    }

    /// The moving parts of a move: dashes that march round the new foot and along the line back, a little further
    /// each time (`antsPhase`).
    private func drawAnts(_ move: TreeMove) {
        let lift = SIMD3<Float>(0, 0.05, 0)
        let footRadius = max(move.radius + 0.35, 0.6)
        capture.showWireframes(
            WireframeLayer(
                name: Self.moveLineLayer,
                items: [
                    WireframeItem(
                        id: Self.moveLineLayer,
                        segments: Wireframe.dashedRing(
                            centre: move.base + lift, radius: footRadius, dashes: 18, phase: antsPhase)
                            + Wireframe.dashedLine(
                                from: move.base + lift, to: move.from + lift, dash: 0.25, phase: antsPhase))
                ],
                color: CaptureSession.highlightColor, lineWidth: 0.025, throughWalls: true))
        capture.showWireframes(
            WireframeLayer(
                name: Self.moveLineLayer + "-from",
                items: [
                    WireframeItem(
                        id: Self.moveLineLayer + "-from",
                        segments: Wireframe.ring(centre: move.from + lift, radius: footRadius, count: 32))
                ],
                color: SIMD4(0.8, 0.8, 0.8, 0.7), lineWidth: 0.015, throughWalls: true))
    }

    static let moveLineLayer = "move-line"

    /// Marches the ants round a tree being moved, a few times a second, while it is.
    private func marchAnts() async {
        while !Task.isCancelled, let move {
            antsPhase += 0.12
            drawAnts(move)
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    /// Stops moving the tree, leaving it where it was.
    private func endMove() {
        capture.acceptsDrags = false
        guard move != nil else { return }
        capture.hideTree()
        capture.hideWireframes(named: Self.moveLineLayer)
        capture.hideWireframes(named: Self.moveLineLayer + "-from")
        move = nil
        rebuildOverlay([.census])
    }

    /// "1.8 m NE of where it was drawn".
    private func moveOffset(_ move: TreeMove) -> String {
        let offset = Compass.offset(from: move.from, to: move.base)
        let distance = simd_length(offset)
        guard distance >= 0.05, let bearing = Compass.bearing(of: offset) else { return "Where it was drawn" }
        return format.length(distance, fractionDigits: 1) + " " + Compass.point(of: bearing) + " of where it was drawn"
    }

    /// Records the tree at its new spot, placed on the map as a new tree is, and draws it there.
    private func placeMovedTree() async {
        guard let move, let tree = model.tree(move.treeID) else { return endMove() }
        let placed =
            placedPosition(ofARKit: move.base)
            ?? location.geoPoint.flatMap { device in
                capture.cameraPosition.map { position(of: move.base, camera: $0, device: device) }
            }
        guard let position = placed else {
            notice = "Waiting for GPS and AR tracking."
            return
        }
        // The shared map keeps one tree to each L22 cell, about 2 m across: a move into one another tree holds would
        // conflict when it is applied, and the tree would jump back.
        if let other = model.census.tree(standingAt: position.geo, except: tree.id) {
            notice =
                other.name + " already stands there, and the map keeps one tree to every 2 m square. If they are the "
                + "same tree, cancel and mark this one Not a tree."
            return
        }
        let distance = simd_length(Compass.offset(from: move.from, to: move.base))
        endMove()
        await model.move(tree, to: position)
        notice =
            "Moved " + move.name + " " + format.length(distance, fractionDigits: 1)
            + ", which also says it is a tree. Shared when you sync."
        rebuildOverlay([.census])
    }
}

extension ARTreeSelection {
    /// Just the id, to read its census uuid.
    fileprivate init(id: String) {
        self.init(
            id: id, title: "", detail: "", status: nil,
            baseForm: TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5))
    }
}

/// Live feedback while scanning a trunk: how much of its circumference 1.37 m above the ground is covered.
struct ScanProgressCard: View {
    let progress: ScanProgress
    /// How far round where the scan started it keeps the mesh: grown for a big trunk.
    var regionRadius: Float = TrunkScan.radius
    private let format = QuantityFormat()

    var body: some View {
        HStack(spacing: Spacing.s) {
            ZStack {
                Circle().stroke(Color.canopyLine, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, (progress.arcDegrees ?? 0) / 360))
                    .stroke(
                        progress.isWellCovered ? Color.canopyBrand : Color.canopySurvey,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(headline).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(CanopyFont.mono(.caption))
                    .foregroundStyle(Color.canopyInkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan-progress")
    }

    private var height: String { format.length(DBH.standardHeight) }

    private var headline: String {
        guard let arc = progress.arcDegrees else { return "Walk slowly round the trunk" }
        if progress.isWellCovered { return "Good coverage: finish when ready" }
        return "Covered " + format.angle(arc, fractionDigits: 0) + " of the trunk " + height + " up"
    }

    private var detail: String {
        var parts = [format.count(progress.triangleCount) + " triangles kept"]
        if progress.pointCount > 0 {
            parts.append(format.count(progress.pointCount) + " depth points")
        }
        if let diameter = progress.diameter {
            parts.append(
                "about " + format.length(diameter, fractionDigits: 2) + " across"
                    + (progress.fromDepthPoints ? " (depth)" : " (mesh)"))
        } else {
            parts.append("no trunk found " + height + " up yet")
        }
        if regionRadius > TrunkScan.radius {
            parts.append("keeping " + format.length(Double(regionRadius), fractionDigits: 1) + " round")
        }
        return parts.joined(separator: " · ")
    }
}

/// Shown when tracking jumped while scanning: what the scan kept from before may be doubled or out of line.
struct TrackingJumpCard: View {
    var onRestart: () -> Void
    var onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("Tracking jumped", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
            Text(
                "The phone lost its place and found it again, so the lime may be doubled where you came back round. "
                    + "Start again here to keep only what lines up now (ARKit's mesh stays), or keep going."
            )
            .font(.footnote)
            .foregroundStyle(Color.canopyInkMuted)
            HStack(spacing: Spacing.s) {
                Button("Keep going", action: onKeep)
                    .buttonStyle(.canopySecondary)
                Button("Start again here", systemImage: "arrow.counterclockwise", action: onRestart)
                    .buttonStyle(.canopyPrimary)
                    .accessibilityIdentifier("scan-restart")
            }
            .font(.footnote)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tracking-jump")
    }
}

/// A trunk measurement waiting to be saved.
struct Measurement: Identifiable {
    let id = UUID()
    let capture: TrunkCapture
    let position: Position
    let target: Tree?
    /// The tree's shape as the player fitted it by eye in AR, if they did.
    var form: TreeForm?
    /// The rings of that shape, with the ones fitted to the scan and checked against the tree marked.
    var profile: TreeProfile?
    /// The tree the scan was saved on when it was measured, if it was.
    var saved: Tree?
}

/// A measured trunk with the wireframe tree the player is fitting over it.
struct TreeFit {
    var capture: TrunkCapture
    var position: Position
    /// The shape the sliders were last set to, and the rings of the tree from the ground up.
    var fitting: TreeFitting
    /// World point the tree stands on.
    var base: SIMD3<Float>
    /// The ring being edited, drawn in the highlight colour.
    var selectedSection: TreeSection.ID?
    /// The tree the scan was saved on as soon as it was measured.
    var savedTree: Tree?
    /// The tree's stems measured by other scans of it, kept with this scan's.
    var otherStems: [StemMeasure] = []
    /// Whether the stems have been sorted since they were last recorded.
    var stemsChanged = false

    /// The rings of the tree, from the ground up.
    var profile: TreeProfile {
        get { fitting.profile }
        set { fitting.profile = newValue }
    }

    /// The four-slider shape the rings sum to.
    var form: TreeForm { profile.form }
}

/// Where a pickable tree is drawn in AR: its trunk base and its height, from its pick box.
struct DrawnTree: Equatable {
    var base: SIMD3<Float>
    var height: Float

    init(_ box: PickBox) {
        base = box.centre - SIMD3(0, box.size.y / 2, 0)
        height = box.size.y
    }

    /// The trees among a layer's items, by id.
    static func byID(_ items: [WireframeItem]) -> [String: DrawnTree] {
        Dictionary(
            items.compactMap { item in item.pickBox.map { (item.id, DrawnTree($0)) } }, uniquingKeysWith: { a, _ in a })
    }
}

/// The selected tree and the trees near by, for the tracker, compared as one.
struct TrackerTargets: Equatable {
    var focus: TreeTracker.Target?
    var nearby: [TreeTracker.Target]
}

/// A census tree being moved to its true spot in AR.
struct TreeMove {
    var treeID: UUID
    var name: String
    /// Where it was drawn, AR world.
    var from: SIMD3<Float>
    /// Where it stands now.
    var base: SIMD3<Float>
    var form: TreeForm
    /// Its rings, when they were fitted after a scan.
    var profile: TreeProfile?
    var lean: Lean?

    /// The trunk's radius, for finding its centre behind the side the reticle meets.
    var radius: Float { Float(form.trunkDiameter / 2) }
}

/// A crosshair at the centre of the AR view.
struct Reticle: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 28, height: 28)
            Circle().fill(Color.canopySurvey).frame(width: 6, height: 6)
        }
        .shadow(radius: 2)
        .accessibilityHidden(true)
    }
}

/// Hosts the capture session's `ARView`.
struct ARViewContainer: UIViewRepresentable {
    let session: CaptureSession

    func makeUIView(context: Context) -> UIView {
        session.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// The inputs the AR overlay is drawn from, compared as one so the view watches them in one place.
private struct OverlayInputs: Equatable {
    var sites: Int
    var registration: String?
    var origin: GeoPoint?
    var yaw: Double
    var layers: Set<SiteWireframes.Layer>
    /// Whether a scanned trunk is being fitted, when the overlay is put away.
    var fitting: Bool
}

/// Parts of the AR overlay to draw again.
struct OverlayParts: OptionSet {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Gerardus's trees.
    static let siteTrees = OverlayParts(rawValue: 1 << 0)
    /// Gerardus's buildings and streets.
    static let siteOther = OverlayParts(rawValue: 1 << 1)
    /// The census's trees.
    static let census = OverlayParts(rawValue: 1 << 2)
    /// The S2 cells on the ground.
    static let cells = OverlayParts(rawValue: 1 << 3)
    static let all: OverlayParts = [.siteTrees, .siteOther, .census, .cells]

    /// The tree layers holding the shapes that differ between two sets of adjusted shapes: census trees are keyed
    /// `census:<uuid>`, Gerardus's by their feature id.
    init(reshaping old: [String: TreeForm], _ new: [String: TreeForm]) {
        var parts: OverlayParts = []
        for key in Set(old.keys).union(new.keys) where old[key] != new[key] {
            parts.insert(key.hasPrefix(ARTreeSelection.censusPrefix) ? .census : .siteTrees)
        }
        self = parts
    }
}
