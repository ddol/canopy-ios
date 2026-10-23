import CanopyDesign
import CanopyMap
import CanopySync
import SwiftUI

/// Settings, reached from the Me tab: the Gerardus server's address, and a connection test that shows what the
/// server says about itself.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @FocusState private var editing: Bool
    private let format = QuantityFormat()

    private var settings: ServerSettings { model.serverSettings }
    private var typed: GerardusEndpoint? { GerardusEndpoint(address) }
    private var isBlank: Bool { address.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Form {
            serverSection
            resultSections
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { address = settings.endpoint?.url.absoluteString ?? "" }
        .onDisappear(perform: save)
    }

    // MARK: Server

    private var serverSection: some View {
        Section {
            TextField("Server address", text: $address, prompt: Text(verbatim: "gerardus.local:50061"))
                .font(CanopyFont.mono(.body))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($editing)
                .onSubmit(save)
                .accessibilityIdentifier("server-address")
            if !isBlank, typed == nil {
                Label(
                    "Enter a host and port, or an http:// or https:// address without a path.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(StatusTone.watch.foreground.color)
            }
            Button("Test connection", systemImage: "antenna.radiowaves.left.and.right", action: test)
                .disabled(typed == nil || settings.check == .checking)
            if settings.endpoint != nil {
                Button("Forget this server", systemImage: "xmark.circle", role: .destructive, action: forget)
            }
        } header: {
            Text("Gerardus server")
        } footer: {
            Text(
                """
                Without a scheme the address is http:// on port \(String(GerardusEndpoint.defaultPort)). Plain http:// \
                works for .local and tailnet (.ts.net) names and IP addresses; other hosts need https://. The test \
                reads the server’s status page and sends nothing about you. Sync still uses the simulated server in \
                this build.
                """)
        }
    }

    private func save() {
        if isBlank {
            settings.save(nil)
        } else if let typed {
            settings.save(typed)
            address = typed.url.absoluteString
        }
    }

    private func test() {
        editing = false
        save()
        Task { await settings.testConnection() }
    }

    private func forget() {
        address = ""
        settings.save(nil)
    }

    // MARK: Result

    @ViewBuilder
    private var resultSections: some View {
        switch settings.check {
        case .notRun:
            EmptyView()
        case .checking:
            Section("Connection") {
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text("Connecting to \(settings.endpoint?.hostAndPort ?? "the server")…")
                }
            }
        case .failed(let reason):
            Section("Connection") {
                StatusBadge(StatusPresentation("Not connected", systemImage: "wifi.exclamationmark", tone: .hazard))
                    .accessibilityIdentifier("connection-status")
                Text(reason)
                    .accessibilityIdentifier("connection-error")
            }
        case .connected(let status, let roundTrip, let checkedAt):
            connectedSections(status, roundTrip: roundTrip, checkedAt: checkedAt)
        }
    }

    @ViewBuilder
    private func connectedSections(_ status: GerardusStatus, roundTrip: Duration, checkedAt: Date) -> some View {
        Section {
            HStack {
                StatusBadge(
                    status.isOK
                        ? StatusPresentation("Connected", systemImage: "checkmark.circle", tone: .ok)
                        : StatusPresentation(
                            "Server says “\(status.status)”", systemImage: "exclamationmark.circle", tone: .watch)
                )
                .accessibilityIdentifier("connection-status")
                Spacer()
                Text(checkedAt, style: .time)
                    .font(CanopyFont.mono(.footnote))
                    .foregroundStyle(Color.canopyInkMuted)
            }
            row("Service", status.service)
            row("Server version", status.serverVersion)
            if let commit = status.commit {
                LabeledContent("Commit") {
                    Text(verbatim: String(commit.prefix(12)))
                        .font(CanopyFont.mono(.subheadline))
                        .textSelection(.enabled)
                }
            }
            row("API", status.apiVersion, mono: true)
            row("Uptime", status.uptimeSeconds.map(format.duration(seconds:)))
            if let started = status.startDate {
                LabeledContent("Started") {
                    Text(started, format: .dateTime.day().month().hour().minute())
                }
            }
            row("Round trip", format.milliseconds(roundTrip.seconds))
            if let servesScans = status.servesScans {
                row("Scan uploads", servesScans ? "Accepted" : "Turned off")
            }
        } header: {
            Text("Connection")
        }
        Section("Reference layers") {
            if status.availableLayers.isEmpty {
                Text("None").foregroundStyle(Color.canopyInkMuted)
            }
            ForEach(status.availableLayers, id: \.self) { layer in
                Text(GerardusStatus.layerName(layer))
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?, mono: Bool = false) -> some View {
        if let value {
            LabeledContent(label) {
                Text(verbatim: value)
                    .font(mono ? CanopyFont.mono(.subheadline) : .body)
                    .textSelection(.enabled)
            }
        }
    }
}

extension Duration {
    /// The duration in seconds, as a Double.
    var seconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
    }
    .environment(AppModel.live(arguments: ["-ui-testing"]))
}
