import CanopyCapture
import CanopyDesign
import CanopyModel
import CanopyReference
import QuickLook
import SwiftUI

/// One evidence mesh of a tree: on this device, or on the server from another player's scan. Preview opens it in
/// Quick Look (downloading it first when needed) and Share hands over the GLB file.
struct EvidenceRow: View {
    let ref: BlobRef
    var title = "Trunk scan"
    @Environment(AppModel.self) private var model
    @State private var previewURL: URL?
    @State private var isPreparing = false

    private var isLocal: Bool { model.store.blobs.contains(ref) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label(title, systemImage: "cube")
                Spacer()
                Text(verbatim: String(ref.rawValue.prefix(12)))
                    .font(CanopyFont.mono(.caption))
                    .foregroundStyle(Color.canopyInkMuted)
            }
            HStack(spacing: Spacing.s) {
                Button("Preview", systemImage: "eye", action: preview)
                    .buttonStyle(.canopySecondary)
                    .disabled(isPreparing)
                if isLocal {
                    ShareLink(item: model.store.blobs.url(for: ref)) {
                        Label("Share GLB", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.canopySecondary)
                }
                if isPreparing {
                    ProgressView()
                }
            }
            Text(isLocal ? "On this device" : "On the server; downloaded when you preview it")
                .font(.caption)
                .foregroundStyle(Color.canopyInkMuted)
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("evidence-row")
        .quickLookPreview($previewURL)
    }

    private func preview() {
        isPreparing = true
        Task {
            defer { isPreparing = false }
            do {
                let file = try await model.evidenceFile(ref)
                // GLB is not a Quick Look format, so the mesh goes out again as a throwaway USDZ.
                previewURL = try await Task.detached {
                    try QuickLookPreview.usdz(for: try GLB.File(try Data(contentsOf: file)).mesh())
                }.value
            } catch let error as GRPCStatusError where error.code == GRPCStatusError.notFound {
                model.error = "The server does not have this scan."
            } catch {
                model.error = "Could not open the scan: \(error.localizedDescription)"
            }
        }
    }
}
