import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// Details and actions for one tree.
struct TreeSheet: View {
    let tree: Tree

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        StatusBadge(tree.displayStatus.presentation)
                        if let proposed = tree.proposedStatus {
                            Text(
                                "You proposed \(proposed.presentation.label.lowercased()); waiting for a second player."
                            )
                            .font(.footnote)
                            .foregroundStyle(Color.canopyInkMuted)
                        }
                    }
                    .listRowBackground(Color.clear)
                }

                Section {
                    if tree.effectiveStatus == .detected {
                        Button("Confirm tree", systemImage: "checkmark.circle") {
                            Task { await model.confirm(tree) }
                        }
                        Button("Not a tree", systemImage: "xmark.circle", role: .destructive) {
                            Task { await model.reject(tree) }
                        }
                    }
                    if tree.effectiveStatus != .removed {
                        Button("Tag a limb hazard", systemImage: "exclamationmark.triangle") {
                            dismiss()
                            model.tagLimb(on: tree)
                        }
                    }
                } footer: {
                    Text("Changes reach the shared map when a second player agrees and one of you is trusted.")
                }

                Section("Measurements") {
                    LabeledContent("DBH") {
                        if let dbh = tree.dbh {
                            Text(format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty))
                                .font(CanopyFont.mono())
                        } else {
                            Text("Not measured")
                        }
                    }
                    if let lean = tree.lean {
                        LabeledContent("Lean") {
                            Text(format.angle(lean.angle.value, uncertainty: lean.angle.uncertainty))
                                .font(CanopyFont.mono())
                        }
                    }
                    if let height = tree.height {
                        LabeledContent("Height (\(height.source.label))") {
                            Text(
                                format.length(
                                    height.height.value, uncertainty: height.height.uncertainty, fractionDigits: 1)
                            )
                            .font(CanopyFont.mono())
                        }
                    }
                    LabeledContent("Evidence scans", value: "\(tree.evidenceRefs.count)")
                    LabeledContent(
                        "Hazard tags", value: "\(model.census.tags.values.filter { $0.treeID == tree.id }.count)")
                }

                Section("Position") {
                    LabeledContent("Latitude, longitude") {
                        Text(String(format: "%.6f, %.6f", tree.position.geo.latitude, tree.position.geo.longitude))
                            .font(CanopyFont.mono(.footnote))
                    }
                    LabeledContent("Uncertainty") {
                        Text(
                            "±" + QuantityFormat.thinSpace
                                + format.length(tree.position.covariance.horizontalSigma, fractionDigits: 1)
                        )
                        .font(CanopyFont.mono())
                    }
                    LabeledContent("Tile (S2 L16)") {
                        Text(tree.position.tile.token).font(CanopyFont.mono(.footnote))
                    }
                    LabeledContent("Chunk (S2 L19)") {
                        Text(tree.position.chunk.token).font(CanopyFont.mono(.footnote))
                    }
                }

                Section("Record") {
                    LabeledContent("Tree id") {
                        Text(tree.id.uuidString.lowercased()).font(CanopyFont.mono(.caption2))
                    }
                    LabeledContent("Version", value: "\(tree.meta.version)")
                    if tree.meta.playerID == .aerialSurvey {
                        LabeledContent("Source", value: "Aerial LiDAR (synthetic sample)")
                    }
                }
            }
            .navigationTitle(tree.localName ?? tree.species ?? "Tree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

extension TreeHeight.Source {
    var label: String {
        switch self {
        case .aerialLidar: "aerial"
        case .groundLidar: "LiDAR"
        case .estimate: "estimate"
        }
    }
}
