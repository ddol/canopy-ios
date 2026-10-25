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

                if !tree.evidenceRefs.isEmpty {
                    Section {
                        ForEach(tree.evidenceRefs, id: \.rawValue) { ref in
                            EvidenceRow(ref: ref)
                        }
                    } header: {
                        Text("Evidence")
                    } footer: {
                        Text(
                            "Colourless meshes of the trunk, cropped to it: no photos. A scan from another device comes "
                                + "down from the server when you preview it.")
                    }
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
                    LabeledContent("S2 L16 tile") {
                        S2CellLabel(tree.position.tile)
                    }
                    LabeledContent("S2 L19 chunk") {
                        S2CellLabel(tree.position.chunk)
                    }
                }

                Section("Record") {
                    LabeledContent("Tree id") {
                        Text(tree.id.uuidString.lowercased()).font(CanopyFont.mono(.caption2))
                    }
                    LabeledContent("Version", value: "\(tree.meta.version)")
                    if tree.meta.playerID == .aerialSurvey {
                        LabeledContent("Source", value: model.candidateSources[tree.id] ?? "Synthetic sample")
                    }
                }
            }
            .navigationTitle(tree.name)
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
