import CanopyDesign
import CanopyModel
import SwiftUI

/// Every scan this device has recorded, newest first: the colourless meshes kept as evidence for measurements (and
/// limb tags), each with its tree, what it measured, and Preview and Share.
struct ScansScreen: View {
    @Environment(AppModel.self) private var model
    @State private var scans: [Evidence] = []
    @State private var loaded = false
    private let format = QuantityFormat()

    var body: some View {
        List {
            if loaded, scans.isEmpty {
                ContentUnavailableView(
                    "No scans yet", systemImage: "cube",
                    description: Text(
                        "Scan a trunk from the Census tab. Its mesh is kept here, and shared when you sync."))
            }
            ForEach(scans) { scan in
                Section {
                    details(scan)
                    EvidenceRow(ref: scan.blob, title: label(scan.kind))
                }
            }
        }
        .navigationTitle("Your scans")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            scans = (try? await model.store.allEvidence()) ?? []
            loaded = true
        }
    }

    private func label(_ kind: Evidence.Kind) -> String {
        switch kind {
        case .trunkScan: "Trunk scan"
        case .limbScan: "Limb scan"
        }
    }

    @ViewBuilder
    private func details(_ scan: Evidence) -> some View {
        let tree = model.tree(scan.subjectID) ?? model.census.tags[scan.subjectID].flatMap { model.tree($0.treeID) }
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(tree?.name ?? "A tree no longer on the map").font(.headline)
            Text(scan.meta.createdAt, format: .dateTime.day().month().year().hour().minute())
                .font(.subheadline)
            if scan.kind == .trunkScan, let dbh = tree?.dbh {
                Text("DBH " + format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty))
                    .font(CanopyFont.mono(.subheadline))
            }
            Text(
                "\(format.count(scan.vertexCount)) vertices, \(format.count(scan.triangleCount)) triangles, "
                    + "within \(format.length(scan.cropRadius, fractionDigits: 1)) · "
                    + ByteCountFormatter.string(fromByteCount: Int64(scan.byteCount), countStyle: .file)
            )
            .font(.caption)
            .foregroundStyle(Color.canopyInkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan-row")
    }
}
