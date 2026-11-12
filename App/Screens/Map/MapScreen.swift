import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// The park map: tree candidates and trees by status, hazard tags, optional S2 tiles, and the summary bar.
struct MapScreen: View {
    /// What the map is drawn on.
    enum BaseMap: String {
        /// Apple's map, with Canopy's layers on top.
        case apple
        /// No base map: Gerardus's sites (ground, reconstructed buildings, streets, trees) and the census's trees in 3D
        /// (`WireframeRenderer`). The app's one 3D view of the map; the AR view is the other 3D view.
        case gerardus
    }

    /// The screens the Layers menu opens over the map.
    enum Page: Hashable {
        case surveyedCells
        case serverCells
    }

    @Environment(AppModel.self) private var model
    /// The screens open over the map, so Show on map can go back to it.
    @State private var path: [Page] = []
    @State private var selection: UUID?
    @State private var visibility = MapLayers.Visibility(tags: Features.limbTagging)
    /// The visible region, once the map has reported one; detected trees are drawn only around it.
    @State private var viewport: MapViewport?
    /// Where to move the map, such as to trees just loaded.
    @State private var focus: MapFocus?
    @AppStorage("canopy.baseMap") private var baseMap = BaseMap.apple
    /// Whether the data credit under the map is open: closed, it is a small "Data" tag.
    @State private var showsAttribution = false
    /// Where the player is, asked for once so the map can open there when that is not San Francisco.
    @State private var location = LocationProvider()
    @State private var openedAtPlayer = false

    private let format = QuantityFormat()

    var body: some View {
        let layers = layers
        NavigationStack(path: $path) {
            map(layers)
                .safeAreaInset(edge: .top) {
                    VStack(spacing: Spacing.xs) {
                        SummaryBar([
                            .init(label: "Confirmed", value: format.count(model.summary.confirmed)),
                            .init(label: "Estimated", value: format.count(model.summary.estimated)),
                            .init(label: "Coverage", value: coverage),
                        ])
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("summary-bar")
                        .padding(.horizontal, Spacing.m)
                        StatusFilterBar(shown: $visibility.statuses, counts: statusCounts)
                    }
                    .padding(.top, Spacing.xs)
                }
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        if baseMap == .gerardus, visibility.vectors, model.mapReference == nil, !model.aerial.isWorking
                        {
                            Text("No vectors loaded here yet. Layers → Load vectors in view draws Gerardus's sites.")
                                .font(.footnote)
                                .padding(Spacing.xs)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
                        }
                        if model.phase == .loading {
                            // The map is up before the store is read; the trees fill in when it is.
                            HStack(spacing: Spacing.xs) {
                                ProgressView()
                                Text("Reading the trees on this phone…").font(.footnote)
                            }
                            .padding(Spacing.xs)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("map-loading")
                        }
                        aerialStatus
                        detailNote(layers)
                        if showsLoadVectors {
                            Button("Load vectors here", systemImage: "square.stack.3d.down.right") {
                                Task { await model.loadVectors(around: centre) }
                            }
                            .buttonStyle(.canopySecondary)
                            .accessibilityIdentifier("load-vectors-here")
                        }
                        if !model.mapAttribution.isEmpty { attribution }
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.bottom, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .navigationTitle("Map")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        layersMenu
                    }
                }
                .navigationDestination(for: Page.self) { page in
                    switch page {
                    case .surveyedCells: SurveyedCellsScreen(viewport: viewport ?? Self.startViewport)
                    case .serverCells: ServerCellsScreen(viewport: viewport ?? Self.startViewport)
                    }
                }
                .sheet(item: selectedTree) { tree in
                    TreeSheet(tree: tree)
                        .presentationDetents([.medium, .large])
                }
                .onChange(of: model.mapTarget, initial: true) { showMapTarget() }
                .onAppear { if !openedAtPlayer { location.start() } }
                .onDisappear { location.stop() }
                .onChange(of: location.geoPoint) { _, fix in openAtPlayer(fix) }
                #if DEBUG || TESTING_TOOLS
                    // For profiling a load with Instruments without UI automation: launch with
                    // `-canopy.loadTreesAtLaunch YES` (and a server) to load the trees in view once the app is ready.
                    .task(id: model.phase) {
                        guard model.phase == .ready else { return }
                        // `-canopy.detectParkAtLaunch YES` runs Layers → Detect every park tile in full.
                        if UserDefaults.standard.bool(forKey: "canopy.detectParkAtLaunch") {
                            try? await Task.sleep(for: .seconds(2))
                            model.detectPark()
                            return
                        }
                        guard UserDefaults.standard.bool(forKey: "canopy.loadTreesAtLaunch") else { return }
                        try? await Task.sleep(for: .seconds(2))
                        await loadTreesInView()
                    }
                #endif
        }
    }

    /// What the map draws, made once per update and shared by the map and the note under it.
    private var layers: MapLayers {
        MapTiming.measure("layers") {
            MapLayers(
                // Before the map reports where it is, the region it opens on: without one, everything is drawn in full.
                state: model.census, boundary: model.boundary, visibility: visibility,
                region: viewport ?? Self.startViewport,
                detectedLimit: detectedLimit, reference: model.mapReference, surveyed: Set(model.surveyedCells.keys),
                treeForms: model.treeForms, treeProfiles: model.treeProfiles, censusTiles: model.censusTiles,
                remoteTiles: model.serverTiles, pulledTiles: model.followedTiles, own: model.ownTrees,
                detectedTiles: model.detectedTiles)
        }
    }

    @ViewBuilder
    private func map(_ layers: MapLayers) -> some View {
        switch baseMap {
        case .apple:
            CanopyMapView(layers: layers, selection: $selection, viewport: viewport ?? Self.startViewport)
                .focus(focus)
                .onViewportChange {
                    viewport = $0
                    model.mapDidSettle($0)
                }
        case .gerardus:
            CanopyMapView(
                renderer: WireframeRenderer(), layers: layers, selection: $selection,
                viewport: viewport ?? Self.startViewport
            )
            .focus(focus)
            .onViewportChange {
                viewport = $0
                model.mapDidSettle($0)
            }
        }
    }

    /// Loads the real trees in the site at the map centre (its tile and the 8 round it), then goes to them if the map
    /// showed much more: a zoomed-out map loads only its middle, which would be a dot.
    private func loadTreesInView() async {
        let centre = centre
        let shown = viewport?.cornerDistance ?? 0
        await model.loadAerialTrees(around: centre)
        let site = MapViewport(around: centre.tile, margin: 3.5)
        if case .done = model.aerial, shown > site.cornerDistance * 1.5 {
            focus = MapFocus(site)
        }
    }

    /// Where the map opens: the whole park, or in debug and testing builds the region in the `canopy.mapStart` default
    /// ("latitude,longitude,radius in metres"), which UI tests pass as a launch argument to open close enough for
    /// trees to be drawn.
    static var startViewport: MapViewport {
        #if DEBUG || TESTING_TOOLS
            let parts = (UserDefaults.standard.string(forKey: "canopy.mapStart") ?? "").split(separator: ",")
                .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 3 {
                return MapViewport(center: GeoPoint(latitude: parts[0], longitude: parts[1]), radius: parts[2])
            }
        #endif
        return .goldenGatePark
    }

    /// Opens the map where the player is, once, when the first fix is outside the city: the map starts on Golden Gate
    /// Park, and the app places no limit on where trees can be scanned. A map the player has already moved, or sent
    /// to a tree, is left alone.
    private func openAtPlayer(_ fix: GeoPoint?) {
        guard !openedAtPlayer, let fix else { return }
        openedAtPlayer = true
        location.stop()
        guard let region = MapViewport.opening(at: fix), viewport == nil, model.mapTarget == nil else { return }
        focus = MapFocus(region)
    }

    /// The middle of the map in view.
    private var centre: GeoPoint { (viewport ?? Self.startViewport).center }

    /// Offer to load the vectors where the map is when they are shown, a server is set, the map is close enough to be
    /// worth it, and that site is not loaded yet.
    private var showsLoadVectors: Bool {
        visibility.vectors && model.alignClient != nil && !model.aerial.isWorking
            && (viewport?.cornerDistance ?? .infinity) <= 600 && !model.hasVectors(at: centre)
    }

    /// Where the map's data comes from: a "Data" tag that twirls open to the credits.
    private var attribution: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
            Button {
                withAnimation(.snappy) { showsAttribution.toggle() }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(showsAttribution ? 90 : 0))
                    Text("Data")
                }
            }
            .buttonStyle(.plain)
            // The tag is 13 pt tall: grow what answers a touch to a thumb's size without growing the tag.
            .padding(Spacing.m)
            .contentShape(Rectangle())
            .padding(-Spacing.m)
            .accessibilityIdentifier("aerial-attribution-toggle")
            .accessibilityValue(showsAttribution ? "Open" : "Closed")
            if showsAttribution {
                Text(model.mapAttribution.joined(separator: " · "))
                    .accessibilityIdentifier("aerial-attribution")
                    .transition(.opacity)
            }
        }
        .font(.caption2)
        .foregroundStyle(Color.canopyInkMuted)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
    }

    /// Says when only some tiles are drawn in full, and how to see the rest.
    @ViewBuilder
    private func detailNote(_ layers: MapLayers) -> some View {
        let patches = layers.summaries.count
        if model.aerial == .idle, patches > 0 {
            let detail = layers.detail
            Text(
                detail.drawsAnyDetail
                    ? "Trees drawn in the \(MapDetail.detailedTileLimit) tiles nearest the centre; \(patches) more "
                        + "shaded by how many they hold. Tap one to go there."
                    : "Zoomed out: \(patches) \(detail.summaryLevel == 13 ? "cells" : "tiles") shaded by how many "
                        + "trees they hold, outlined where detected in full. Zoom in or tap one to see its trees."
            )
            .font(.caption)
            .foregroundStyle(Color.canopyInkMuted)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, Spacing.xxs)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
            .accessibilityIdentifier("map-detail-note")
        }
    }

    /// How many detected trees to draw in the tiles drawn in full. On Apple's map each marker is a view, and hundreds of
    /// them make it sluggish, so a wide view shows a sample and a neighbourhood view shows more. The Gerardus map batches
    /// its trees and draws every one in those tiles.
    private var detectedLimit: Int {
        if baseMap == .gerardus { return .max }
        guard let viewport else { return 200 }
        return viewport.latitudeDelta > 0.008 ? 250 : 400
    }

    /// Counted once per census with the tiles, not on every update.
    private var statusCounts: [CountStatus: Int] {
        let total = model.censusTiles.total
        return Dictionary(uniqueKeysWithValues: CountStatus.allCases.map { ($0, total[$0]) })
    }

    /// One decimal below 10 %, so the first few trees show progress.
    private var coverage: String {
        let fraction = model.summary.coverage
        return format.percent(fraction, fractionDigits: fraction > 0 && fraction < 0.1 ? 1 : 0)
    }

    /// Another screen asked to show a tree (`AppModel.showOnMap`, such as a scan's Show on map): close any screen open
    /// over the map (the tab keeps it while another tab is shown), go to the tree, draw its status if the chips hide
    /// it, and select it.
    private func showMapTarget() {
        guard let id = model.mapTarget else { return }
        model.mapTarget = nil
        path.removeAll()
        guard let tree = model.tree(id) else { return }
        if tree.displayStatus != .removed { visibility.statuses.insert(tree.displayStatus) }
        focus = MapFocus(.showing(tree.position.geo))
        selection = id
    }

    private var selectedTree: Binding<Tree?> {
        Binding(
            get: { model.tree(selection) },
            set: { selection = $0?.id }
        )
    }

    @ViewBuilder
    private var aerialStatus: some View {
        switch model.aerial {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack(spacing: Spacing.xs) {
                ProgressView()
                Text(message).font(.footnote)
            }
            .padding(Spacing.xs)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("aerial-progress")
        case .done(let message), .failed(let message):
            HStack(alignment: .top, spacing: Spacing.xs) {
                if case .failed = model.aerial {
                    StatusBadge("Failed", systemImage: "exclamationmark.triangle", tone: .hazard)
                } else {
                    StatusBadge("Loaded", systemImage: "checkmark.circle", tone: .ok)
                }
                Text(message).font(.footnote)
                Spacer(minLength: 0)
                Button("Dismiss", systemImage: "xmark") { model.aerial = .idle }
                    .labelStyle(.iconOnly)
            }
            .padding(Spacing.xs)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("aerial-result")
        }
    }

    private var layersMenu: some View {
        Menu {
            Section("Base map") {
                Picker("Base map", selection: $baseMap) {
                    Label("Apple Maps", systemImage: "map").tag(BaseMap.apple)
                    Label("Gerardus 3D", systemImage: "view.3d").tag(BaseMap.gerardus)
                }
                if baseMap == .gerardus, visibility.vectors {
                    Toggle("Ground", systemImage: "mountain.2", isOn: $visibility.ground)
                }
            }
            if Features.limbTagging {
                Toggle("Hazard tags", systemImage: "exclamationmark.triangle", isOn: $visibility.tags)
            }
            Toggle("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $visibility.routes)
            Toggle("S2 cells (L13 and L16)", systemImage: "square.grid.3x3", isOn: $visibility.tiles)
            if model.showsWholeCity {
                Button("Whole city", systemImage: "building.2") {
                    focus = MapFocus(.sanFrancisco)
                }
                .accessibilityIdentifier("map-whole-city")
            }
            Button("Surveyed cells (L16)", systemImage: "checkmark.square") { path.append(.surveyedCells) }
            Divider()
            Section("Aerial LiDAR") {
                Button("Load real trees in view", systemImage: "tree") {
                    Task { await loadTreesInView() }
                }
                .disabled(model.aerial.isWorking)
                if model.isAdmin {
                    if model.parkDetection?.isRunning == true {
                        Button("Stop detecting the park", systemImage: "stop.circle") {
                            model.parkDetection?.cancel()
                        }
                        .accessibilityIdentifier("detect-park-stop")
                    } else {
                        Button("Detect every park tile in full", systemImage: "square.grid.3x3.fill") {
                            model.detectPark()
                        }
                        .disabled(model.aerial.isWorking)
                        .accessibilityIdentifier("detect-park")
                    }
                }
            }
            Section("Gerardus vectors") {
                // Off by default: buildings, streets and Gerardus's trees are loaded and drawn only when asked for.
                Toggle("Show vectors", systemImage: "square.stack.3d.down.right", isOn: $visibility.vectors)
                    .accessibilityIdentifier("show-vectors")
                Button("Load vectors in view", systemImage: "arrow.down.circle") {
                    visibility.vectors = true
                    Task { await model.loadVectors(around: centre) }
                }
                .disabled(model.aerial.isWorking)
                Button("Server cells (L13)", systemImage: "square.grid.2x2") { path.append(.serverCells) }
            }
            Section("Legend") {
                ForEach([CountStatus.detected, .proposed, .confirmed, .verified], id: \.self) { status in
                    Label(status.presentation.label, systemImage: status.presentation.systemImage)
                }
            }
        } label: {
            Label("Layers", systemImage: "square.3.layers.3d")
        }
    }
}

#Preview {
    MapScreen()
        .environment(AppModel.live(arguments: ["-ui-testing"]))
}
