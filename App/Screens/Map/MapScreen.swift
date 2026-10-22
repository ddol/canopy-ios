import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// The park map: tree candidates and trees by status, hazard tags, optional S2 tiles, and the summary bar.
struct MapScreen: View {
    @Environment(AppModel.self) private var model
    @State private var selection: UUID?
    @State private var visibility = MapLayers.Visibility()

    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            CanopyMapView(
                layers: MapLayers(state: model.census, boundary: model.boundary, visibility: visibility),
                selection: $selection
            )
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

    private var layersMenu: some View {
        Menu {
            Toggle("Detected candidates", systemImage: "scope", isOn: $visibility.detected)
            Toggle("Hazard tags", systemImage: "exclamationmark.triangle", isOn: $visibility.tags)
            Toggle("Routes", systemImage: "point.topleft.down.to.point.bottomright.curvepath", isOn: $visibility.routes)
            Toggle("S2 tiles (level 16)", systemImage: "square.grid.3x3", isOn: $visibility.cells)
            Divider()
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
