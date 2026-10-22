import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// Census without LiDAR: confirm or reject the trees near you, or add one at your location.
struct VerificationCensusView: View {
    @Environment(AppModel.self) private var model
    @State private var location = LocationProvider()
    private let format = QuantityFormat()

    var body: some View {
        List {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("This device has no LiDAR")
                            .font(.headline)
                        Text(
                            "Trunk measurement and 3D tagging need an iPhone or iPad Pro with LiDAR. "
                                + "You can still confirm trees, mark candidates that are not trees, "
                                + "add trees at your location, and tag hazards."
                        )
                        .font(.subheadline)
                        .foregroundStyle(Color.canopyInkMuted)
                    }
                } icon: {
                    Image(systemName: "sensor.tag.radiowaves.forward")
                        .foregroundStyle(Color.canopySurvey)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("no-lidar-message")
            }

            Section {
                Button("New tree at my location", systemImage: "plus.circle") {
                    guard let point = location.geoPoint else { return }
                    let sigma = location.accuracy ?? 10
                    Task {
                        await model.addTree(
                            at: Position(geo: point, covariance: .isotropic(horizontal: sigma, vertical: sigma)))
                    }
                }
                .disabled(location.geoPoint == nil)
            } footer: {
                Text("Placed at your GPS position, with its accuracy as the uncertainty.")
            }

            Section {
                ForEach(nearby, id: \.0.id) { tree, distance in
                    TreeVerificationRow(tree: tree, distance: distance)
                }
            } header: {
                Text(location.geoPoint == nil ? "Trees near the park centre" : "Trees near you")
            } footer: {
                if location.geoPoint == nil {
                    Text(
                        location.isDenied
                            ? "Location is off, so the list starts from the park centre." : "Waiting for your location…"
                    )
                }
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }

    private var nearby: [(Tree, Double)] {
        model.census.trees(near: location.geoPoint ?? MapViewport.goldenGatePark.center, limit: 20)
    }
}

/// One tree with its status, distance and the verification actions.
struct TreeVerificationRow: View {
    let tree: Tree
    let distance: Double
    @Environment(AppModel.self) private var model
    private let format = QuantityFormat()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                StatusBadge(tree.displayStatus.presentation)
                Spacer()
                Text(format.length(distance, fractionDigits: 0))
                    .font(CanopyFont.mono(.subheadline))
                    .foregroundStyle(Color.canopyInkMuted)
            }
            if tree.effectiveStatus == .detected {
                HStack(spacing: Spacing.s) {
                    Button("Confirm tree", systemImage: "checkmark.circle") {
                        Task { await model.confirm(tree) }
                    }
                    .buttonStyle(.canopyPrimary)
                    Button("Not a tree", systemImage: "xmark.circle") {
                        Task { await model.reject(tree) }
                    }
                    .buttonStyle(.canopySecondary)
                }
                .labelStyle(.titleAndIcon)
                .font(.subheadline)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}
