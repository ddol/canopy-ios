import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyPlayers
import CanopyReference
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
                reviewSection
                syncSection
                historySection
                #if DEBUG || TESTING_TOOLS
                    debugSection
                #endif
                aboutSection
            }
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsScreen()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
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
                        .contextMenu {
                            Button("Copy player id", systemImage: "doc.on.doc") {
                                UIPasteboard.general.string = model.player.id.rawValue
                            }
                        }
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

    @ViewBuilder
    private var reviewSection: some View {
        if model.mapClient != nil {
            Section {
                if model.reviewQueue.isEmpty {
                    Text(
                        model.lastSync == nil
                            ? "Sync to see other players' changes near you."
                            : "Nothing waiting near you."
                    )
                    .foregroundStyle(Color.canopyInkMuted)
                }
                ForEach(model.reviewQueue, id: \.changeset.id) { item in
                    ReviewRow(item: item, canReject: model.serverPlayer?.isTrusted == true)
                }
            } header: {
                Text("Review (\(model.reviewQueue.count))")
            } footer: {
                Text(
                    "Agree when you have seen the change on the ground. It reaches the shared map when two players agree "
                        + "and one of them is trusted."
                        + (model.serverPlayer?.isTrusted == true ? " As a trusted player you can also reject it." : ""))
            }
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
            NavigationLink {
                SettingsScreen()
            } label: {
                LabeledContent("Gerardus server") {
                    Text(verbatim: model.serverSettings.endpoint?.hostAndPort ?? "Not set")
                        .font(CanopyFont.mono(.subheadline))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityIdentifier("server-row")
        } header: {
            Text("Sync")
        } footer: {
            Text(
                model.mapClient == nil
                    ? "No server is set, so sync uses a simulated server on this device."
                    : "Canopy syncs with this server on its own: after each change, when the map settles somewhere new, "
                        + "and when the app comes to the front. Sync now does it straight away.")
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
                .disabled(open.isEmpty || model.mapClient != nil)
                Button("Reset local data", systemImage: "trash", role: .destructive) {
                    confirmingReset = true
                }
                LabeledContent("Trees", value: format.count(model.census.trees.count))
                LabeledContent("Tags", value: format.count(model.census.tags.count))
            } header: {
                Text("Debug")
            } footer: {
                Text(
                    "A simulated trusted ranger approves every pending change on the simulated server, when no "
                        + "server is set.")
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
                Text(verbatim: changeset.tiles.map(\.familyDisplay).joined(separator: " "))
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

/// Another player's open change: what it does, to which tree, who proposed it, and Agree (or Reject, for trusted
/// players).
struct ReviewRow: View {
    let item: GerardusMapClient.OpenChangeset
    let canReject: Bool
    @Environment(AppModel.self) private var model
    @State private var rejecting = false
    @State private var reason = ""

    private var subjects: String {
        Set(item.changeset.ops.map(\.id)).compactMap { model.tree($0)?.name }.sorted().joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(ChangesetSummary.describe(item.changeset))
                .font(.body.weight(.semibold))
            if !subjects.isEmpty {
                Text(subjects).font(.subheadline)
            }
            HStack(spacing: Spacing.xs) {
                Text(item.authorAlias.isEmpty ? "A player" : item.authorAlias)
                if item.authorTrusted {
                    Image(systemName: "checkmark.shield").accessibilityLabel("trusted")
                }
                Text("·")
                Text(item.changeset.meta.createdAt, style: .relative)
            }
            .font(.caption)
            .foregroundStyle(Color.canopyInkMuted)
            HStack(spacing: Spacing.s) {
                Button("Agree", systemImage: "hand.thumbsup") {
                    Task { await model.review(item, approve: true) }
                }
                .buttonStyle(.canopyPrimary)
                .accessibilityIdentifier("review-agree")
                if canReject {
                    Button("Reject", systemImage: "hand.thumbsdown") { rejecting = true }
                        .buttonStyle(.canopySecondary)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityIdentifier("review-row")
        .alert("Reject this change?", isPresented: $rejecting) {
            TextField("Why", text: $reason)
            Button("Reject", role: .destructive) {
                let reason = reason.trimmingCharacters(in: .whitespaces)
                Task {
                    await model.review(item, approve: false, reason: reason.isEmpty ? "Not seen on the ground" : reason)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A rejected change never reaches the shared map. Say what you saw.")
        }
    }
}

/// Hosts a UIKit view controller, such as Game Center's sign-in screen.
struct ViewControllerHost: UIViewControllerRepresentable {
    let controller: UIViewController

    func makeUIViewController(context: Context) -> UIViewController { controller }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}
}

extension Bundle {
    /// "0.1.1-pre3 (20261023.1507)": the full version, which may be a pre-release, and the build number.
    var version: String {
        let short =
            infoDictionary?["CanopyVersion"] as? String
            ?? infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}

#Preview {
    MeScreen()
        .environment(AppModel.live(arguments: ["-ui-testing"]))
}
