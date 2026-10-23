import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// The park map: tree candidates and trees by status, hazard tags, optional S2 tiles, and the summary bar.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var visibility = MapLayers.Visibility()
    /// The visible region, once the map has reported one; detected trees are drawn only around it.
    @State private var viewport: MapViewport?

    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            CanopyMapView(
                layers: MapLayers(
                    state: model.census, boundary: model.boundary, visibility: visibility, region: viewport,
                    detectedLimit: detectedLimit),
                selection: $selection
            )
            .onViewportChange { viewport = $0 }
            .safeAreaInset(edge: .top) {
                SummaryBar([
                    .init(label: "Confirmed", value: format.count(model.summary.confirmed)),
                    .init(label: "Estimated", value: format.count(model.summary.estimated)),
                    .init(label: "Coverage", value: coverage),
                ])
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("summary-bar")
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.xs)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    aerialStatus
                    if !model.aerialAttribution.isEmpty {
                        Text("Trees: " + model.aerialAttribution.joined(separator: " · "))
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
        }
    }

    /// How many detected trees to draw: a park-wide view shows a sample, a neighbourhood view shows more. Each marker is
    /// a view, and hundreds of them make the map sluggish.
    private var detectedLimit: Int {
        guard let viewport else { return 200 }
        return viewport.latitudeDelta > 0.008 ? 250 : 400
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
            Toggle("Detected candidates", systemImage: "scope", isOn: $visibility.detected)
            Toggle("Hazard tags", systemImage: "exclamationmark.triangle", isOn: $visibility.tags)
            Toggle("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $visibility.routes)
            Toggle("S2 L16 tiles", systemImage: "square.grid.3x3", isOn: $visibility.tiles)
            Divider()
            Section("Aerial LiDAR") {
                Button("Load real trees here", systemImage: "tree") {
                    let centre = viewport?.center ?? MapViewport.goldenGatePark.center
                    Task { await model.loadAerialTrees(around: centre) }
                }
                .disabled(model.aerial.isWorking)
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
