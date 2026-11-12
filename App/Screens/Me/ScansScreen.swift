import CanopyDesign
import CanopyModel
import SwiftUI

/// Every scan this device has recorded, newest first: the colourless meshes kept as evidence for measurements (and
/// limb tags), each with a picture of the mesh, its tree, what it measured, Preview and Share, Show on map, and
/// aligning the tree's rings against it. One row per scan, keyed by its hash.
struct ScansScreen: View {
    @Environment(AppModel.self) private var model
    @State private var scans: [Evidence] = []
    @State private var loaded = false
    /// This player's scans from their other devices, from the server; nil until asked.
    @State private var elsewhere: [AccountScan]?
    @State private var elsewhereFailure: String?
    private let format = QuantityFormat()

    var body: some View {
        List {
            if loaded, scans.isEmpty, elsewhere?.isEmpty ?? true {
                ContentUnavailableView(
                    "No scans yet", systemImage: "cube",
                    description: Text(
                        "Scan a trunk from the Census tab on a phone or iPad with LiDAR. Its mesh is kept here, and "
                            + "shared when you sync, so your other devices list it too."))
            }
            otherDevices
            ForEach(scans, id: \.blob) { scan in
                Section {
                    details(scan)
                    EvidenceRow(ref: scan.blob, title: label(scan.kind))
                    if let tree = tree(of: scan) {
                        Button("Show on map", systemImage: "map") {
                            model.showOnMap(tree)
                        }
                        .accessibilityIdentifier("scan-show-on-map")
                    }
                    if scan.kind == .trunkScan, model.tree(scan.subjectID) != nil {
                        AlignScanButton(scan: scan.blob, treeID: scan.subjectID)
                    }
                }
            }
        }
        .readableColumn()
        .navigationTitle("Your scans")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            #if DEBUG || TESTING_TOOLS
                if UserDefaults.standard.bool(forKey: "canopy.sampleScan"), model.scanCount == 0 {
                    await model.addSampleScan()
                }
            #endif
            scans = (try? await model.store.allEvidence()) ?? []
            loaded = true
            await askServer()
        }
        .refreshable {
            await model.sync()
            scans = (try? await model.store.allEvidence()) ?? []
            await askServer()
        }
    }

    private func askServer() async {
        guard model.mapClient != nil else { return }
        do {
            elsewhere = try await model.scansFromOtherDevices()
            elsewhereFailure = nil
        } catch {
            elsewhereFailure =
                AppModel.isOffline(error)
                ? "Offline: your scans from other devices are listed when the server can be reached."
                : "Could not ask the server for your other scans: \(error.localizedDescription)"
        }
    }

    /// The scans this player took on their other devices: listed from the server, each downloaded when opened.
    @ViewBuilder
    private var otherDevices: some View {
        if model.mapClient != nil {
            Section {
                if let elsewhere {
                    if elsewhere.isEmpty {
                        Text("None yet. Scans you take on another device show here once it has synced.")
                            .foregroundStyle(Color.canopyInkMuted)
                    }
                    ForEach(elsewhere) { scan in
                        otherDeviceRow(scan)
                    }
                } else if let elsewhereFailure {
                    Text(elsewhereFailure).foregroundStyle(Color.canopyInkMuted)
                } else {
                    HStack(spacing: Spacing.xs) {
                        ProgressView()
                        Text("Asking the server for your scans…")
                    }
                }
            } header: {
                Text("From your other devices")
            } footer: {
                Text(
                    "Scans your Game Center account took on another phone or iPad, as the server has them. Each "
                        + "downloads when you open it; aligning its rings works here without LiDAR.")
            }
            .accessibilityIdentifier("other-device-scans")
        }
    }

    @ViewBuilder
    private func otherDeviceRow(_ scan: AccountScan) -> some View {
        let tree = model.tree(scan.subject) ?? model.census.tags[scan.subject].flatMap { model.tree($0.treeID) }
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(tree?.name ?? "A tree not on this device's map yet").font(.headline)
            Text(scan.date, format: .dateTime.day().month().year().hour().minute()).font(.subheadline)
            Text(scan.state == .waiting ? "Waiting for a second player to agree" : "On the shared map")
                .font(.caption)
                .foregroundStyle(Color.canopyInkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("other-device-scan-row")
        EvidenceRow(ref: scan.blob, title: scan.entity == .tag ? "Limb scan" : "Trunk scan")
        if let tree {
            Button("Show on map", systemImage: "map") { model.showOnMap(tree) }
            if scan.entity == .tree {
                AlignScanButton(scan: scan.blob, treeID: tree.id)
            }
        }
    }

    private func label(_ kind: Evidence.Kind) -> String {
        switch kind {
        case .trunkScan: "Trunk scan"
        case .limbScan: "Limb scan"
        }
    }

    /// The scan's tree: the one it measured, or the one its limb tag is on.
    private func tree(of scan: Evidence) -> Tree? {
        model.tree(scan.subjectID) ?? model.census.tags[scan.subjectID].flatMap { model.tree($0.treeID) }
    }

    @ViewBuilder
    private func details(_ scan: Evidence) -> some View {
        let tree = tree(of: scan)
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
