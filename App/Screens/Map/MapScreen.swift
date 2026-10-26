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
        /// No base map: only Gerardus's own data (`GerardusRenderer`).
        case gerardus
    }

    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var visibility = MapLayers.Visibility(tags: Features.limbTagging)
    /// The visible region, once the map has reported one; detected trees are drawn only around it.
    @State private var viewport: MapViewport?
    /// Where to move the map, such as to trees just loaded.
    @State private var focus: MapFocus?
    @AppStorage("canopy.baseMap") private var baseMap = BaseMap.apple

    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            map
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
                        if baseMap == .gerardus, model.mapReference == nil, !model.aerial.isWorking {
                            Text(
                                "Only trees so far. Layers → Load real trees in view draws the canopy and outlines here."
                            )
                            .font(.footnote)
                            .padding(Spacing.xs)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.medium))
                        }
                        aerialStatus
                        if showsLoadVectors {
                            Button("Load vectors here", systemImage: "square.stack.3d.down.right") {
                                Task { await model.loadVectors(around: centre) }
                            }
                            .buttonStyle(.canopySecondary)
                            .accessibilityIdentifier("load-vectors-here")
                        }
                        if !model.mapAttribution.isEmpty {
                            Text("Data: " + model.mapAttribution.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(Color.canopyInkMuted)
                                .padding(.horizontal, Spacing.xs)
                                .padding(.vertical, Spacing.xxs)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
                                .accessibilityIdentifier("aerial-attribution")
                        }
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
                .sheet(item: selectedTree) { tree in
                    TreeSheet(tree: tree)
                        .presentationDetents([.medium, .large])
                }
                #if DEBUG || TESTING_TOOLS
                    // For profiling a load with Instruments without UI automation: launch with
                    // `-canopy.loadTreesAtLaunch YES` (and a server) to load the trees in view once the app is ready.
                    .task(id: model.phase) {
                        guard model.phase == .ready, UserDefaults.standard.bool(forKey: "canopy.loadTreesAtLaunch")
                        else { return }
                        try? await Task.sleep(for: .seconds(2))
                        await loadTreesInView()
                    }
                #endif
        }
    }

    @ViewBuilder
    private var map: some View {
        let layers = MapLayers(
            state: model.census, boundary: model.boundary, visibility: visibility, region: viewport,
            detectedLimit: detectedLimit, reference: model.mapReference)
        switch baseMap {
        case .apple:
            CanopyMapView(layers: layers, selection: $selection, viewport: viewport ?? .goldenGatePark)
                .focus(focus)
                .onViewportChange {
                    viewport = $0
                    model.mapDidSettle($0)
                }
        case .gerardus:
            CanopyMapView(
                renderer: GerardusRenderer(), layers: layers, selection: $selection,
                viewport: viewport ?? .goldenGatePark
            )
            .focus(focus)
            .onViewportChange {
                viewport = $0
                model.mapDidSettle($0)
            }
        }
    }

    /// Loads the real trees in view, then goes to them if the map showed much more than was loaded: a zoomed-out map
    /// loads only its middle, which would be a dot.
    private func loadTreesInView() async {
        let radius = viewport?.cornerDistance ?? AppModel.aerialRadiusLimit
        let centre = centre
        await model.loadAerialTrees(around: centre, radius: radius)
        if case .done = model.aerial, radius > AppModel.aerialRadiusLimit * 1.5 {
            focus = MapFocus(MapViewport(center: centre, radius: AppModel.aerialRadiusLimit * 1.1))
        }
    }

    /// The middle of the map in view.
    private var centre: GeoPoint { (viewport ?? .goldenGatePark).center }

    /// Offer to load the vectors where the map is when they are shown, a server is set, the map is close enough to be
    /// worth it, and that site is not loaded yet.
    private var showsLoadVectors: Bool {
        visibility.vectors && model.alignClient != nil && !model.aerial.isWorking
            && (viewport?.cornerDistance ?? .infinity) <= 600 && !model.hasVectors(at: centre)
    }

    /// How many detected trees to draw. On Apple's map each marker is a view, and hundreds of them make it sluggish, so a
    /// park-wide view shows a sample and a neighbourhood view shows more. The Gerardus map draws them all.
    private var detectedLimit: Int {
        if baseMap == .gerardus { return .max }
        guard let viewport else { return 200 }
        return viewport.latitudeDelta > 0.008 ? 250 : 400
    }

    private var statusCounts: [CountStatus: Int] {
        Dictionary(grouping: model.census.trees.values, by: \.displayStatus).mapValues(\.count)
    }

    /// One decimal below 10 %, so the first few trees show progress.
    private var coverage: String {
        let fraction = model.summary.coverage
        return format.percent(fraction, fractionDigits: fraction > 0 && fraction < 0.1 ? 1 : 0)
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
                    Label("Gerardus only", systemImage: "square.3.layers.3d.down.right").tag(BaseMap.gerardus)
                }
            }
            if Features.limbTagging {
                Toggle("Hazard tags", systemImage: "exclamationmark.triangle", isOn: $visibility.tags)
            }
            Toggle("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $visibility.routes)
            Toggle("S2 L16 tiles", systemImage: "square.grid.3x3", isOn: $visibility.tiles)
            Divider()
            Section("Aerial LiDAR") {
                Button("Load real trees in view", systemImage: "tree") {
                    Task { await loadTreesInView() }
                }
                .disabled(model.aerial.isWorking)
            }
            Section("Gerardus vectors") {
                Toggle("Show vectors", systemImage: "square.stack.3d.down.right", isOn: $visibility.vectors)
                Button("Load vectors in view", systemImage: "arrow.down.circle") {
                    Task { await model.loadVectors(around: centre) }
                }
                .disabled(model.aerial.isWorking)
            }
            Section("3D vectors") {
                NavigationLink {
                    VectorMapScreen(token: VectorMapScreen.kirkham9th, title: "Kirkham & 9th")
                } label: {
                    Label("Kirkham & 9th in 3D", systemImage: "cube")
                }
                NavigationLink {
                    VectorMapScreen(
                        token: (viewport ?? .goldenGatePark).center.tile.token, title: "3D vectors in view")
                } label: {
                    Label("3D vectors in view", systemImage: "view.3d")
                }
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
