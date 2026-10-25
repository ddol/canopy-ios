import CanopyMap
import CanopyReference
import SwiftUI

/// Reads only the selected prepared site's public vector layers from the server in Settings.
struct VectorMapScreen: View {
    static let kirkham9th = VectorReference.kirkham9th
    let token: String
    let title: String
    @Environment(AppModel.self) private var model
    @State private var reference: VectorReference?
    @State private var error: String?
    @State private var loading = false
    @State private var reload = UUID()

    private struct LoadID: Hashable {
        var url: URL?
        var reload: UUID
    }

    var body: some View {
        Group {
            if let reference {
                VectorMapView(reference: reference)
                    .id(reload)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        DisclosureGroup("Sources and model") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(reference.attribution, id: \.self) { Text($0) }
                                if reference.features.contains(where: { $0.layer == .observed }) {
                                    Text("Measured facades: contributed registered scans (Gerardus).")
                                }
                                Text("Site: \(reference.site.l16Token)")
                                Text("Bundle: \(reference.site.bundleID)")
                                if !reference.modelID.isEmpty { Text("Model: \(reference.modelID)") }
                            }
                            .font(.caption2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        }
                        .font(.caption)
                        .padding(10)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("vector-attribution")
                    }
            } else if loading {
                ProgressView("Loading server vectors…")
                    .accessibilityIdentifier("vector-progress")
            } else {
                ContentUnavailableView {
                    Label("3D vectors unavailable", systemImage: "cube")
                } description: {
                    Text(error ?? "Set the Gerardus server in Me → Settings, then reload this view.")
                } actions: {
                    NavigationLink("Server settings") { SettingsScreen() }
                    Button("Reload") { reload = UUID() }
                }
                .accessibilityIdentifier("vector-error")
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Reload vectors", systemImage: "arrow.clockwise") { reload = UUID() }
                .disabled(loading)
        }
        .task(id: LoadID(url: model.gerardusURL, reload: reload)) {
            reference = nil
            error = nil
            guard let client = model.alignClient else { return }
            loading = true
            defer { loading = false }
            do {
                let result = try await VectorReference.load(token: token, client: client)
                try Task.checkCancellation()
                reference = result
            } catch is CancellationError {
                // Navigation away or a different endpoint cancels this load.
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
