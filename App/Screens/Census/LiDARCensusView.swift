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
    @State private var overlayLayers: Set<SiteWireframes.Layer> = [.trees, .buildings]
    @State private var showsCensusTrees = true
    /// The AR session origin's map position, from the best GPS fix so far and the camera's offset then.
    @State private var sessionOrigin: GeoPoint?
    @State private var sessionOriginAccuracy = Double.infinity
    /// The tile whose site was last asked for on arrival, so a slow server is asked once.
    @State private var autoLoadTile: S2CellID?
    @State private var loadingVectors = false
    /// The tree picked by tapping, and the shapes the player has adjusted, by wireframe id.
    @State private var selection: ARTreeSelection?
    @State private var treeForms: [String: TreeForm] = [:]
    private let format = QuantityFormat()

    var body: some View {
        watching(scene)
            .onAppear {
                capture.start()
                location.start()
            }
            .onDisappear {
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
                    capture.cancelScan()
                    capture.hideTree()
                    fit = nil
                }
                .presentationDetents([.medium, .large])
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
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(Spacing.xs)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
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
                form: fitFormBinding, onMoveHere: moveTreeHere, onBack: stopFitting, onMeasurement: showMeasurement)
        } else if let selection {
            SelectedTreePanel(
                selection: selection, form: selectedFormBinding, isAdjusted: treeForms[selection.id] != nil,
                onReset: resetSelectedForm, onScan: startScan, onDone: deselect)
        } else {
            controls
        }
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
            .onChange(of: model.loadedVectors.count) { rebuildOverlay() }
            .onChange(of: registered?.registrationID) { rebuildOverlay() }
            .onChange(of: sessionOrigin) { rebuildOverlay() }
            .onChange(of: overlayLayers) { rebuildOverlay() }
            .onChange(of: showsCensusTrees) { rebuildOverlay(site: false) }
            .onChange(of: model.census.trees.count) { rebuildOverlay(site: false) }
            .onChange(of: model.aerial) {
                guard loadingVectors, case .working(let message) = model.aerial else { return }
                notice = message
            }
    }

    // MARK: Target

    private var nearby: [(Tree, Double)] {
        guard let here = location.geoPoint else { return [] }
        return model.census.trees(near: here, within: 60, limit: 8)
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
            overlayMenu
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
            var form = selection.map { treeForms[$0.id] ?? $0.baseForm } ?? TreeForm(dbh: result.analysis.dbh)
            form.trunkDiameter = result.analysis.dbh.diameter.value
            form = form.clamped
            deselect()
            fit = TreeFit(capture: result, position: position, form: form, base: result.trunkBase)
            capture.showTree(form, lean: result.analysis.lean, at: result.trunkBase)
            notice = "Step back and move the sliders until the wireframe matches the tree."
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

    /// A slider's binding into the fitted form: every change redraws the tree.
    private var fitFormBinding: Binding<TreeForm> {
        Binding(
            get: { fit?.form ?? TreeForm(trunkDiameter: 0.3, height: 8, crownHeight: 5, crownWidth: 5) },
            set: { form in
                guard var fit else { return }
                fit.form = form.clamped
                self.fit = fit
                capture.showTree(fit.form, lean: fit.capture.analysis.lean, at: fit.base)
            })
    }

    /// Stands the tree on the ground under the centre of the view instead.
    private func moveTreeHere() {
        guard var fit else { return }
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
        capture.showTree(fit.form, lean: fit.capture.analysis.lean, at: fit.base)
        notice = nil
    }

    /// Back to scanning: the scan keeps running, the wireframe comes down.
    private func stopFitting() {
        capture.hideTree()
        fit = nil
        notice = nil
    }

    private func showMeasurement() {
        guard let fit else { return }
        notice = nil
        capture.pause()
        measurement = Measurement(capture: fit.capture, position: fit.position, target: target, form: fit.form)
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
            case .done(let message), .failed(let message): notice = message
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

    /// Draws the site layers and the census trees again from what is loaded and where the session is placed.
    /// `site: false` redraws only the census trees.
    private func rebuildOverlay(site: Bool = true) {
        let sites = placedSites()
        let camera = capture.cameraPosition ?? .zero
        if site {
            for layer in SiteWireframes.Layer.allCases {
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
                        centre: SIMD2(Float(centre.x), Float(centre.y)), forms: treeForms)
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
        rebuildCensusTrees(sites: sites)
    }

    /// The census's trees within 120 m, as wireframes of what is known about them.
    private func rebuildCensusTrees(sites: [PlacedSite]) {
        let name = "census-trees"
        guard showsCensusTrees, let here = location.geoPoint ?? sessionOrigin else {
            capture.hideWireframes(named: name)
            return
        }
        let arGround = arGroundAtOrigin
        let items = model.census.trees(near: here, within: 120, limit: 400).compactMap { tree, _ -> WireframeItem? in
            let geo = tree.position.geo
            let base: SIMD3<Float>
            if let site = sites.first(where: {
                ARSiteFrame.groundHeight($0.loaded.vectors.ground, at: $0.frame.site(of: geo)) != nil
            }) ?? sites.first {
                let xy = site.frame.site(of: geo)
                let z =
                    ARSiteFrame.groundHeight(site.loaded.vectors.ground, at: xy)
                    ?? Self.typicalGround(site.loaded.vectors)
                base = site.frame.arkit(SIMD3<Double>(xy.x, xy.y, z))
            } else if let sessionOrigin {
                let enu = LocalFrame(origin: sessionOrigin).enu(of: geo)
                base = SIMD3(Float(enu.east), arGround, Float(-enu.north))
            } else {
                return nil
            }
            let id = ARTreeSelection.censusPrefix + tree.id.uuidString
            return SiteWireframes.treeItem(
                id: id, form: treeForms[id] ?? Self.censusForm(tree), lean: tree.lean, at: base)
        }
        capture.showWireframes(
            WireframeLayer(name: name, items: items, color: Self.censusColor, lineWidth: 0.015))
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
                selection.map { treeForms[$0.id] ?? $0.baseForm }
                    ?? TreeForm(dbh: DBH(diameter: Quantity(0.3, uncertainty: 0.1), method: .estimate))
            },
            set: { form in
                guard let selection else { return }
                treeForms[selection.id] = form.clamped
                rebuildTrees(for: selection)
            })
    }

    private func resetSelectedForm() {
        guard let selection else { return }
        treeForms[selection.id] = nil
        rebuildTrees(for: selection)
    }

    /// Redraws the trees a selection belongs to: the census layer, or the site trees.
    private func rebuildTrees(for selection: ARTreeSelection) {
        if selection.censusID != nil {
            rebuildOverlay(site: false)
        } else {
            let sites = placedSites()
            let camera = capture.cameraPosition ?? .zero
            var seen: Set<String> = []
            var items: [WireframeItem] = []
            for site in sites {
                let centre = site.frame.site(ofARKit: camera)
                for item in SiteWireframes.items(
                    site.loaded.vectors.features, layer: .trees, frame: site.frame,
                    centre: SIMD2(Float(centre.x), Float(centre.y)), forms: treeForms)
                where seen.insert(item.id).inserted {
                    items.append(item)
                }
            }
            capture.showWireframes(
                WireframeLayer(name: "site-trees", items: items, color: Self.color(of: .trees), lineWidth: 0.015))
        }
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
        if let diameter = progress.diameter {
            parts.append("about " + format.length(diameter, fractionDigits: 2) + " across")
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
}

/// A measured trunk with the wireframe tree the player is fitting over it.
struct TreeFit {
    var capture: TrunkCapture
    var position: Position
    var form: TreeForm
    /// World point the tree stands on.
    var base: SIMD3<Float>
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
