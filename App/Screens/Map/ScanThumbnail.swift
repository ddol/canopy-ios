import CanopyDesign
import CanopyModel
import SwiftUI
import UIKit

/// The picture of one evidence mesh (`AppModel.scanPreview`): the colourless geometry from a three-quarter view, never
/// a photo. A scan from another device shows a placeholder until its mesh is on this device. Tapping it runs `action`.
struct ScanThumbnail: View {
    let ref: BlobRef
    /// Whether the mesh is on this device. The picture is made when it is, and again when it becomes so.
    let isLocal: Bool
    var side: CGFloat = 96
    let action: () -> Void

    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Button(action: action) { picture }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(image == nil ? "" : "Drawn")
            .accessibilityHint("Opens the scan in 3D")
            .accessibilityIdentifier("scan-preview")
            .task(id: isLocal) { await load() }
    }

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Color.canopySunken)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(Spacing.xxs)
            } else if failed {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.canopyInkMuted)
            } else if isLocal {
                ProgressView()
            } else {
                Image(systemName: "icloud.and.arrow.down")
                    .foregroundStyle(Color.canopyInkMuted)
            }
        }
        .frame(width: side, height: side)
        .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
    }

    private var accessibilityLabel: String {
        if image != nil { return "Picture of the scanned mesh" }
        if failed { return "The scan could not be drawn" }
        return isLocal ? "Drawing the scan" : "Scan not on this device yet"
    }

    private func load() async {
        guard image == nil else { return }
        do {
            guard let url = try await model.scanPreview(ref) else { return }
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            image = await UIImage(data: data)?.byPreparingForDisplay()
            failed = image == nil
        } catch is CancellationError {
        } catch {
            failed = true
        }
    }
}
