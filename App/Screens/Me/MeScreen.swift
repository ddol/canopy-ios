import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyPlayers
import CanopyReference
import SwiftUI

/// The player, their scans, sync, and (in debug builds) data tools. Their proposals and the review queue are in the
/// Proposals tab.
struct MeScreen: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingReset = false
    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            List {
                playerSection
                scansSection
                syncSection
                #if DEBUG || TESTING_TOOLS
                    debugSection
                #endif
                aboutSection
            }
            .readableColumn()
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
                StatusBadge(trustPresentation)
                    .accessibilityIdentifier("trust-badge")
            }
            if let note = trustNote {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.canopyInkMuted)
                    .accessibilityIdentifier("trust-note")
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

    /// Trust is the server's to give (`GetPlayer`): the badge says what it last said, not a flag on this phone.
    private var trustPresentation: StatusPresentation {
        Self.trust(server: model.serverPlayer, adminInThisBuild: model.adminSettings.isAdmin(model.player))
    }

    static func trust(server: GerardusMapClient.PlayerInfo?, adminInThisBuild: Bool) -> StatusPresentation {
        if server?.isAdmin == true {
            return StatusPresentation("Admin", systemImage: "checkmark.shield.fill", tone: .ok)
        }
        if server?.isTrusted == true {
            return StatusPresentation("Trusted", systemImage: "checkmark.shield", tone: .ok)
        }
        if adminInThisBuild {
            return StatusPresentation("Admin on this phone", systemImage: "shield.lefthalf.filled", tone: .proposed)
        }
        return StatusPresentation("Not trusted yet", systemImage: "shield", tone: .watch)
    }

    /// Why the server does not trust a player this build makes an admin, and what fixes it.
    private var trustNote: String? {
        Self.trustNote(
            server: model.serverPlayer, adminInThisBuild: model.adminSettings.isAdmin(model.player),
            hasServer: model.mapClient != nil, signedIn: model.player.source == .gameCenter)
    }

    static func trustNote(
        server: GerardusMapClient.PlayerInfo?, adminInThisBuild: Bool, hasServer: Bool, signedIn: Bool
    ) -> String? {
        guard signedIn else {
            return "Trust and admin go with your Game Center id. Sign in to Game Center to be recognised."
        }
        guard server?.isTrusted != true, server?.isAdmin != true else { return nil }
        guard adminInThisBuild, hasServer else { return nil }
        guard server != nil else { return "This build lists you as an admin. Sync to ask the server whether it does." }
        return "This build lists you as an admin, but the server does not trust you yet: it knows admins by the "
            + "Game Center ids (or their hashes) in GERARDUS_ADMINS. Touch and hold your player id above to copy it."
    }

    private var signInPresentation: StatusPresentation {
        switch model.players.state {
        case .signedIn: StatusPresentation("Game Center", systemImage: "gamecontroller", tone: .ok)
        case .signingIn: StatusPresentation("Signing in", systemImage: "clock", tone: .proposed)
        case .signedOut: StatusPresentation("Local player", systemImage: "iphone", tone: .moved)
        case .unavailable: StatusPresentation("Local player", systemImage: "iphone", tone: .watch)
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

    private var scansSection: some View {
        Section {
            NavigationLink {
                ScansScreen()
            } label: {
                LabeledContent("Your scans", value: format.count(model.scanCount))
            }
            .accessibilityIdentifier("scans-link")
        } footer: {
            Text(
                "Every trunk scan is kept on the device that took it as a colourless mesh, and shared with the change "
                    + "it backs. Your scans from your other devices are listed too.")
        }
    }

    #if DEBUG || TESTING_TOOLS
        private var debugSection: some View {
            Section {
                Button("Reset local data", systemImage: "trash", role: .destructive) {
                    confirmingReset = true
                }
                LabeledContent("Trees", value: format.count(model.census.trees.count))
                LabeledContent("Tags", value: format.count(model.census.tags.count))
            } header: {
                Text("Debug")
            } footer: {
                Text("Simulate trusted approval is under Proposals → Yours.")
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
