import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyPlayers
import SwiftUI

/// The player, their pending changes, sync, and (in debug builds) data tools.
struct MeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false
    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            List {
                playerSection
                pendingSection
                syncSection
                historySection
                #if DEBUG || TESTING_TOOLS
                    debugSection
                #endif
                aboutSection
            }
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: signInPresented) {
                if let controller = model.players.signInViewController {
                    ViewControllerHost(controller: controller)
                        .ignoresSafeArea()
                }
            }
            .confirmationDialog(
                "Delete all local data?", isPresented: $confirmingReset, titleVisibility: .visible
            ) {
                Button("Delete everything", role: .destructive) {
                    Task { await model.reset() }
                }
            } message: {
                Text("Removes every observation, changeset and scan on this device and reloads the sample park.")
            }
        }
    }

    private var signInPresented: Binding<Bool> {
        Binding(
            get: { model.players.signInViewController != nil },
            set: { if !$0 { model.players.signInViewController = nil } }
        )
    }

    // MARK: Sections

    private var playerSection: some View {
        Section("Player") {
            HStack(spacing: Spacing.s) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(Color.canopyBrand)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(model.player.alias).font(CanopyFont.title3)
                    Text(model.player.id.rawValue)
                        .font(CanopyFont.mono(.caption2))
                        .foregroundStyle(Color.canopyInkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack {
                StatusBadge(signInPresentation)
                Spacer()
                StatusBadge(
                    model.player.isTrusted
                        ? StatusPresentation("Trusted", systemImage: "checkmark.shield", tone: .ok)
                        : StatusPresentation("Not trusted yet", systemImage: "shield", tone: .watch))
            }
            switch model.players.state {
            case .unavailable(let reason):
                Text("Game Center is unavailable (\(reason)). You can keep playing; your records use a local id.")
                    .font(.footnote)
                    .foregroundStyle(Color.canopyInkMuted)
                Button("Try again", systemImage: "arrow.clockwise") { model.players.authenticate() }
            case .signedOut:
                Button("Sign in with Game Center", systemImage: "gamecontroller") { model.players.authenticate() }
            case .signingIn, .signedIn:
                EmptyView()
            }
        }
    }

    private var signInPresentation: StatusPresentation {
        switch model.players.state {
        case .signedIn: StatusPresentation("Game Center", systemImage: "gamecontroller", tone: .ok)
        case .signingIn: StatusPresentation("Signing in", systemImage: "clock", tone: .proposed)
        case .signedOut: StatusPresentation("Local player", systemImage: "iphone", tone: .moved)
        case .unavailable: StatusPresentation("Local player", systemImage: "iphone", tone: .watch)
        }
    }

    private var open: [Changeset] {
        model.changesets.filter(\.state.isOpen).reversed()
    }

    private var closed: [Changeset] {
        model.changesets.filter { !$0.state.isOpen }.reversed()
    }

    private var pendingSection: some View {
        Section {
            if open.isEmpty {
                Text("Nothing waiting. Confirm, measure or tag a tree to propose a change.")
                    .foregroundStyle(Color.canopyInkMuted)
            }
            ForEach(open) { changeset in
                ChangesetRow(changeset: changeset)
            }
        } header: {
            Text("Pending changes (\(open.count))")
        } footer: {
            Text("A change reaches the shared map when a second player agrees and at least one of you is trusted.")
        }
    }

    private var syncSection: some View {
        Section {
            Button {
                Task { await model.sync() }
            } label: {
                Label(model.isSyncing ? "Syncing…" : "Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.isSyncing)
            if let report = model.lastSync {
                LabeledContent("Last sync") {
                    Text(report.finishedAt, style: .time).font(CanopyFont.mono(.subheadline))
                }
                LabeledContent("Submitted", value: "\(report.submitted)")
                    .accessibilityIdentifier("sync-submitted")
                LabeledContent("Scans uploaded", value: "\(report.blobsUploaded)")
                LabeledContent("Updated", value: "\(report.updated.count)")
            } else {
                Text("Not synced yet").foregroundStyle(Color.canopyInkMuted)
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Milestone 0 syncs with a simulated server on this device. Nothing is sent over the network.")
        }
    }

    @ViewBuilder
    private var historySection: some View {
        if !closed.isEmpty {
            Section("History") {
                ForEach(closed) { changeset in
                    ChangesetRow(changeset: changeset)
                }
            }
        }
    }

    #if DEBUG || TESTING_TOOLS
        private var debugSection: some View {
            Section {
                Button("Simulate trusted approval", systemImage: "checkmark.shield") {
                    Task { await model.simulateTrustedApproval() }
                }
                .disabled(open.isEmpty)
                Button("Reset local data", systemImage: "trash", role: .destructive) {
                    confirmingReset = true
                }
                LabeledContent("Trees", value: format.count(model.census.trees.count))
                LabeledContent("Tags", value: format.count(model.census.tags.count))
            } header: {
                Text("Debug")
            } footer: {
                Text("A simulated trusted ranger approves every pending change on the fake server.")
            }
        }
    #endif

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: Bundle.main.version)
            Text("Canopy never takes or stores photos. Evidence is colourless 3D geometry, cropped to the tree.")
                .font(.footnote)
                .foregroundStyle(Color.canopyInkMuted)
            Text("Open source under the Apache License 2.0. Tree candidates in this build are synthetic.")
                .font(.footnote)
                .foregroundStyle(Color.canopyInkMuted)
        }
    }
}

/// One changeset: what it does, its state, when and where.
struct ChangesetRow: View {
    let changeset: Changeset

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Text(ChangesetSummary.describe(changeset))
                    .font(.body.weight(.semibold))
                Spacer()
                StatusBadge(changeset.state.presentation)
            }
            HStack(spacing: Spacing.xs) {
                Text(changeset.meta.createdAt, style: .relative)
                Text("·")
                Text(changeset.cells.map(\.token).joined(separator: " "))
                    .font(CanopyFont.mono(.caption))
                if !changeset.approvals.isEmpty {
                    Text("·")
                    Label("\(changeset.approvals.count)", systemImage: "hand.thumbsup")
                }
            }
            .font(.caption)
            .foregroundStyle(Color.canopyInkMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("changeset-row")
    }
}

/// Hosts a UIKit view controller, such as Game Center's sign-in screen.
struct ViewControllerHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

extension Bundle {
    var version: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    MeScreen()
        .environment(AppModel.live(arguments: ["-ui-testing"]))
}
