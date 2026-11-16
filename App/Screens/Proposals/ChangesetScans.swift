import CanopyCapture
import CanopyDesign
import CanopyModel
import CanopyReference
import QuickLook
import SwiftUI

/// The scans a change brings: their evidence meshes (`evidenceRefs` on a tree, `evidenceRef` on a tag), in the order
/// it names them, each once.
extension Changeset {
    var scans: [BlobRef] {
        var seen: Set<BlobRef> = []
        var refs: [BlobRef] = []
        for op in ops {
            var named: [BlobRef] = []
            if case .array(let values)? = op.fields["evidenceRefs"] {
                named = values.compactMap { $0.stringValue.flatMap(BlobRef.init(rawValue:)) }
            }
            if let ref = op.fields["evidenceRef"]?.stringValue.flatMap(BlobRef.init(rawValue:)) {
                named.append(ref)
            }
            for ref in named where seen.insert(ref).inserted { refs.append(ref) }
        }
        return refs
    }
}

/// The pictures of a proposal's scans, in a row: each downloaded from the server when the row shows, if this device
/// does not have it, and opened in Quick Look when tapped.
struct ChangesetScans: View {
    let refs: [BlobRef]
    var side: CGFloat = 72
    /// At most this many pictures; the rest are counted.
    var limit = 3

    @Environment(AppModel.self) private var model
    @State private var local: Set<BlobRef> = []
    @State private var previewURL: URL?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(refs.prefix(limit), id: \.self) { ref in
                ScanThumbnail(ref: ref, isLocal: local.contains(ref), side: side) { preview(ref) }
                    .task { await fetch(ref) }
            }
            if refs.count > limit {
                Text("+\(refs.count - limit)")
                    .font(.caption)
                    .foregroundStyle(Color.canopyInkMuted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("changeset-scans")
        .quickLookPreview($previewURL)
    }

    /// Brings the mesh to this device, so its picture can be drawn.
    private func fetch(_ ref: BlobRef) async {
        if model.store.blobs.contains(ref) {
            local.insert(ref)
            return
        }
        guard model.mapClient != nil, (try? await model.evidenceFile(ref)) != nil else { return }
        local.insert(ref)
    }

    private func preview(_ ref: BlobRef) {
        Task {
            do {
                let file = try await model.evidenceFile(ref)
                local.insert(ref)
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
