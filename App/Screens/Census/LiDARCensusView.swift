import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import SwiftUI

/// Census with LiDAR: the AR view with the reconstructed mesh, Gerardus's site drawn as wireframes round the player
/// (trees, buildings, streets) with the census's own trees, the target tree, and the census actions.
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
    /// The tile whose site was last asked for on arrival, so a slow server is asked once.
    @State private var autoLoadTile: S2CellID?
    @State private var loadingVectors = false
    /// The tree picked by tapping; the shapes the player adjusts live on the model, shared with the map.
    @State private var selection: ARTreeSelection?
    private let format = QuantityFormat()

    var body: some View {
        watching(scene)
            .onAppear {
                capture.start()
                location.start()
            }
            .onDisappear {
                capture.stopAligning()
                capture.pause()
                location.stop()
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
                targetCard
                overlayStatusRow
                if let notice {
                    HStack(spacing: Spacing.xs) {
                        if loadingVectors { ProgressView().controlSize(.small) }
                        Text(notice)
                    }
                    .font(.footnote)
                    .padding(Spacing.xs)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
                    .accessibilityIdentifier("census-notice")
                }
                Spacer()
                if let scan = capture.scan, fit == nil, selection == nil {
                    ScanProgressCard(progress: scan.progress)
                }
                bottomPanel
            }
            .padding(Spacing.m)
        }
    }

    /// The fit sliders while a scanned trunk is being fitted, the selected tree's panel, else the census actions.
    @ViewBuilder
    private var bottomPanel: some View {
        if fit != nil {
            TreeFitPanel(
                fitting: fitFittingBinding, selectedSection: fitSectionBinding, onSnap: snapSelectedSection,
                isAligning: capture.isAligning, alignStatus: alignStatus, onAlign: toggleAlignment,
                onMoveHere: moveTreeHere, onBack: stopFitting, onMeasurement: showMeasurement)
        } else if let selection {
            SelectedTreePanel(
                selection: selection, form: selectedFormBinding, isAdjusted: model.treeForms[selection.id] != nil,
                onReset: resetSelectedForm, onScan: startScan, onDone: deselect)
        } else {
            controls
        }
    }

    /// What the whole overlay is drawn from: the loaded sites, the placement and the layers. The adjusted shapes are
    /// watched apart, since a slider moves them many times a second and only the trees need drawing again.
    private var overlayInputs: OverlayInputs {
        OverlayInputs(
            sites: model.loadedVectors.count, registration: registered?.registrationID, origin: sessionOrigin,
            layers: overlayLayers)
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
            }
            .onChange(of: capture.lastTap) {
                if let tap = capture.lastTap { handleTap(at: tap.point) }
            }
            .onChange(of: overlayInputs) { rebuildOverlay() }
            .onChange(of: censusInputs) { rebuildOverlay([.census, .cells]) }
            .onChange(of: model.treeForms) { old, new in rebuildOverlay(OverlayParts(reshaping: old, new)) }
            .onChange(of: capture.ringFits) { applyRingFits() }
            .onChange(of: model.aerial) {
                guard loadingVectors, case .working(let message) = model.aerial else { return }
                notice = message
            }
    }

    // MARK: Target

    private var nearby: [(Tree, Double)] {
        guard let here = location.geoPoint else { return [] }
        return model.census.trees(near: here, within: 60, limit: 8, tiles: model.censusTiles)
    }

    private var target: Tree? {
        model.tree(targetID) ?? nearby.first?.0
    }

    private var targetCard: some View {
        HStack(spacing: Spacing.s) {
            if let target {
                StatusBadge(target.displayStatus.presentation)
                if let here = location.geoPoint {
                    let distance = LocalFrame(origin: here).enu(of: target.position.geo).horizontalDistance
                    Text(format.length(distance, fractionDigits: 0))
                        .font(CanopyFont.mono(.subheadline))
                }
                if let dbh = target.dbh {
                    Text("DBH " + format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty))
                        .font(CanopyFont.mono(.subheadline))
                }
            } else {
                Label(location.geoPoint == nil ? "Waiting for GPS…" : "No tree within 60 m", systemImage: "location")
                    .font(.subheadline)
            }
            Spacer()
            Menu {
                ForEach(nearby, id: \.0.id) { tree, distance in
                    Button {
                        targetID = tree.id
                    } label: {
                        Label(
                            "\(tree.displayStatus.presentation.label), \(format.length(distance, fractionDigits: 0))",
                            systemImage: tree.displayStatus.presentation.systemImage)
                    }
                }
            } label: {
                Label("Change tree", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .disabled(nearby.isEmpty)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
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
                Button("Re-place overlay from GPS", systemImage: "scope") {
                    sessionOriginAccuracy = .infinity
                    placeSession()
                    rebuildOverlay()
                }
                .disabled(registered != nil || location.geoPoint == nil)
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
            HStack(spacing: Spacing.xs) {
                Image(systemName: "square.3.layers.3d")
                Text(overlayStatus)
            }
            .font(CanopyFont.mono(.caption))
            .foregroundStyle(Color.canopyInkMuted)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(.thinMaterial, in: Capsule())
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
            placed = "placed by GPS ±" + format.length(sessionOriginAccuracy, fractionDigits: 0)
        } else {
            placed = "waiting for GPS"
        }
        return (sites == 0 ? "No site loaded" : sites == 1 ? "1 site loaded" : "\(sites) sites loaded") + ", " + placed
    }

    // MARK: Actions

    private var controls: some View {
        VStack(spacing: Spacing.s) {
            if capture.scan == nil {
                HStack(spacing: Spacing.s) {
                    Button("Confirm tree", systemImage: "checkmark.circle") {
                        guard let target else { return }
                        Task { await model.confirm(target) }
                    }
                    .buttonStyle(.canopyPrimary)
                    .disabled(target?.effectiveStatus != .detected)

                    Button("Not a tree", systemImage: "xmark.circle") {
                        guard let target else { return }
                        Task { await model.reject(target) }
                    }
                    .buttonStyle(.canopySecondary)
                    .disabled(target?.effectiveStatus != .detected)

                    Button("New tree here", systemImage: "plus.circle") {
                        Task { await addTreeAtReticle() }
                    }
                    .buttonStyle(.canopySecondary)
                }
                .labelStyle(.titleAndIcon)
                .font(.footnote)

                Button {
                    startScan()
                } label: {
                    Label("Scan trunk", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.canopySurvey)

                registrationControl
            } else {
                HStack(spacing: Spacing.s) {
                    Button("Cancel", systemImage: "xmark") {
                        capture.cancelScan()
                        notice = nil
                    }
                    .buttonStyle(.canopySecondary)

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
        }
    }

    @ViewBuilder
    private var registrationControl: some View {
        if let registered {
            HStack {
                StatusBadge("Registered to 3DEP", systemImage: "scope", tone: .ok)
                Text("±" + QuantityFormat.thinSpace + format.length(registered.sigma, fractionDigits: 2))
                    .font(CanopyFont.mono(.footnote))
                Spacer()
            }
            .accessibilityElement(children: .combine)
        } else {
            Button {
                confirmingRegistration = true
            } label: {
                Label(isRegistering ? "Registering…" : "Register with 3DEP", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.canopySecondary)
            .font(.footnote)
            .disabled(isRegistering)
        }
    }

    /// Where an AR world point is on the map: from the 3DEP registration when there is one, else GPS.
    private func position(of point: SIMD3<Float>, camera: SIMD3<Float>, device: GeoPoint) -> Position {
        if let registered {
            return registered.position(ofARKit: point)
        }
        return GeoReference.position(
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
        do {
            try capture.startScan()
            notice = "Walk slowly round the trunk, keeping it in view."
        } catch {
            notice = Self.describe(error)
        }
    }

    private func finishScan() async {
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            let result = try await capture.finishScan()
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
            // the DBH was.
            let profile = TrunkSteps.fitted(TreeProfile(form: form), to: result, below: form.crownBase)
            let fit = TreeFit(
                capture: result, position: position, fitting: TreeFitting(shape: form, profile: profile),
                base: result.trunkBase)
            self.fit = fit
            showFit(fit)
            let steps = profile.trunk.filter { $0.source == .scan }.map(\.height).max()
            notice =
                (steps.map { "Rings are fitted to the scan up to " + format.length($0, fractionDigits: 1) + ". " } ?? "")
                + "Step back and set the shape with the sliders, then Rings → Align steps to fit the rest to the camera."
        } catch {
            notice = Self.describe(error)
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
        case TrunkAnalysisError.arcTooShort: "Scan more of the trunk: keep walking round it."
        case TrunkAnalysisError.implausibleDiameter:
            "That does not look like a trunk. Start the scan on the trunk, about 1.37 m above the ground."
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

    /// Stops aligning the rings the player moved by hand, confirmed or took out.
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
        notice = nil
        capture.stopAligning()
        capture.pause()
        measurement = Measurement(
            capture: fit.capture, position: fit.position, target: target, form: fit.form, profile: fit.profile)
    }

    // MARK: Placing the session

    /// Fixes where the AR session's origin is on the map: the GPS fix, less the camera's offset from the origin.
    /// Done again whenever a clearly better fix arrives, until a 3DEP registration takes over.
    private func placeSession() {
        guard registered == nil, let fix = location.geoPoint, let accuracy = location.accuracy,
            let camera = capture.cameraPosition, capture.isNorthAligned
        else { return }
        guard sessionOrigin == nil || accuracy < sessionOriginAccuracy - 2 else { return }
        sessionOrigin =
            LocalFrame(origin: fix).geoPoint(of: ENU(east: Double(-camera.x), north: Double(camera.z), up: 0)).point
        sessionOriginAccuracy = accuracy
    }

    /// Asks for the site under the player once per tile arrived at, when a server is set and it is not loaded yet.
    private func autoLoadVectors() {
        guard let fix = location.geoPoint, model.alignClient != nil else { return }
        let tile = fix.tile
        guard tile != autoLoadTile, !model.hasVectors(at: fix), !model.aerial.isWorking else { return }
        autoLoadTile = tile
        loadVectors(around: fix)
    }

    private func loadVectors(around point: GeoPoint) {
        guard !loadingVectors else { return }
        loadingVectors = true
        Task {
            await model.loadVectors(around: point)
            loadingVectors = false
            switch model.aerial {
            case .done(let message): notice = message
            case .failed(let message):
                notice = message
                autoLoadTile = nil
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
            guard let sessionOrigin else { return nil }
            let originSite = loaded.georeference.site(of: sessionOrigin)
            let siteGround =
                ARSiteFrame.groundHeight(loaded.vectors.ground, at: originSite) ?? Self.typicalGround(loaded.vectors)
            return PlacedSite(
                token: token, loaded: loaded,
                frame: ARSiteFrame(
                    origin: sessionOrigin, georeference: loaded.georeference, arGroundAtOrigin: arGround,
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
        let sites = placedSites()
        let camera = capture.cameraPosition ?? .zero
        if !parts.isDisjoint(with: [.siteTrees, .siteOther]) {
            for layer in SiteWireframes.Layer.allCases where layer.isSiteLayer {
                guard parts.contains(layer == .trees ? .siteTrees : .siteOther) else { continue }
                let name = "site-" + layer.rawValue
                guard overlayLayers.contains(layer), !sites.isEmpty else {
                    capture.hideWireframes(named: name)
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
        guard let sessionOrigin else { return nil }
        let enu = LocalFrame(origin: sessionOrigin).enu(of: geo)
        return SIMD3(Float(enu.east), arGround, Float(-enu.north))
    }

    /// The S2 cells round the player on the ground: level-16 tiles (surveyed ones in green) and their level-13
    /// parents, each with posts at its corners.
    private func rebuildCells(sites: [PlacedSite]) {
        let names = ["cells-l16", "cells-l16-surveyed", "cells-l13"]
        guard overlayLayers.contains(.cells), let here = location.geoPoint ?? sessionOrigin else {
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
        guard showsCensusTrees, let here = location.geoPoint ?? sessionOrigin else {
            capture.hideWireframes(named: name)
            capture.hideWireframes(named: name + "-surveyed")
            return
        }
        let arGround = arGroundAtOrigin
        var items: [WireframeItem] = []
        // Detections in a surveyed cell were looked over and left: drawn faint and thin.
        var surveyed: [WireframeItem] = []
        for (tree, _) in model.census.trees(near: here, within: 120, limit: 400, tiles: model.censusTiles) {
            guard let base = arGroundPoint(tree.position.geo, sites: sites, arGround: arGround) else { continue }
            let id = ARTreeSelection.censusPrefix + tree.id.uuidString
            var item = SiteWireframes.treeItem(
                id: id, form: model.treeProfiles[id]?.form ?? model.treeForms[id] ?? Self.censusForm(tree),
                lean: tree.lean, at: base)
            if let profile = model.treeProfiles[id] {
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
        guard fit == nil, let id = capture.pickWireframe(at: point) else { return }
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
            selection = ARTreeSelection(
                id: id, title: tree.localName ?? tree.species ?? "Census tree",
                detail: parts.isEmpty ? "No measurements yet; the shape is a guess." : parts.joined(separator: " · "),
                status: tree.displayStatus, baseForm: Self.censusForm(tree))
        } else if let tree = gerardusTree(id) {
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
                status: nil, baseForm: tree.form)
        } else {
            return
        }
        capture.highlightWireframe(id: id)
    }

    private func deselect() {
        capture.highlightWireframe(id: nil)
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

    private func gerardusTree(_ id: String) -> GerardusTree? {
        for loaded in model.loadedVectors.values {
            if let feature = loaded.vectors.features.first(where: { $0.layer == .trees && $0.line.featureID == id }),
                let tree = GerardusTree(feature.line)
            {
                return tree
            }
        }
        return nil
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
        return parts.joined(separator: " · ")
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

    /// The rings of the tree, from the ground up.
    var profile: TreeProfile {
        get { fitting.profile }
        set { fitting.profile = newValue }
    }

    /// The four-slider shape the rings sum to.
    var form: TreeForm { profile.form }
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
    var layers: Set<SiteWireframes.Layer>
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
