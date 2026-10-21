import CanopyCapture
import CanopyDesign
import CanopyModel
import CanopyStore
import QuickLook
import SwiftUI

/// The result of a trunk measurement: DBH and lean with uncertainties, fit quality, and Save.
struct MeasurementSheet: View {
    let measurement: Measurement

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: Tree?
    @State private var shareURL: URL?
    @State private var preview: PreviewFile?
    private let format = QuantityFormat()

    private var analysis: TrunkAnalysis.Result { measurement.capture.analysis }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("DBH at 1.37 m")
                            .font(.subheadline)
                            .foregroundStyle(Color.canopyInkMuted)
                        Text(format.length(analysis.dbh.diameter.value, uncertainty: analysis.dbh.diameter.uncertainty))
                            .font(CanopyFont.mono(.largeTitle, weight: .semibold))
                            .accessibilityIdentifier("dbh-value")
                    }
                    if let lean = analysis.lean {
                        LabeledContent("Lean") {
                            Text(leanText(lean)).font(CanopyFont.mono())
                        }
                    }
                }

                Section("Fit") {
                    LabeledContent("Points at breast height", value: "\(analysis.circle.pointCount)")
                    LabeledContent("Circumference covered") {
                        Text(format.angle(analysis.circle.arc * 180 / .pi, fractionDigits: 0)).font(CanopyFont.mono())
                    }
                    LabeledContent("RMS residual") {
                        Text(format.length(analysis.circle.rmsResidual, fractionDigits: 3)).font(CanopyFont.mono())
                    }
                    LabeledContent("Evidence mesh") {
                        Text(
                            "\(measurement.capture.evidence.triangleCount) triangles, "
                                + "\(format.count(measurement.capture.glb.count / 1024))\u{202F}KiB"
                        )
                        .font(CanopyFont.mono(.footnote))
                    }
                }

                Section {
                    if saved != nil {
                        Label("Saved. Shared when you sync.", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.canopyBrand)
                    } else {
                        Button(
                            measurement.target == nil ? "Save as a new tree" : "Save measurement",
                            systemImage: "square.and.arrow.down"
                        ) {
                            Task { await save() }
                        }
                        Button("Retake", systemImage: "arrow.counterclockwise", role: .cancel) {
                            dismiss()
                        }
                    }
                } footer: {
                    Text("Saves the colourless, cropped mesh as evidence. No photo is taken.")
                }

                #if DEBUG
                    Section("Debug") {
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share GLB", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Preview in Quick Look", systemImage: "cube") {
                            preview = (try? QuickLookPreview.usdz(for: measurement.capture.evidence)).map(
                                PreviewFile.init)
                        }
                    }
                #endif
            }
            .navigationTitle("Trunk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $preview) { file in
                QuickLookView(url: file.url)
                    .ignoresSafeArea()
            }
        }
    }

    private func leanText(_ lean: Lean) -> String {
        var text = format.angle(lean.angle.value, uncertainty: lean.angle.uncertainty)
        if let azimuth = lean.azimuth {
            text += " toward " + format.angle(azimuth.value, fractionDigits: 0)
        }
        return text
    }

    private func save() async {
        let capture = measurement.capture
        saved = await model.saveTrunkMeasurement(
            dbh: capture.analysis.dbh,
            lean: capture.analysis.lean,
            glb: capture.glb,
            evidenceMesh: (capture.evidence.vertexCount, capture.evidence.triangleCount),
            cropRadius: capture.cropRadius,
            tree: measurement.target,
            position: measurement.position
        )
        if saved != nil {
            shareURL = try? model.shareableGLB(BlobStore.reference(for: capture.glb))
        }
    }
}

/// Quick Look for a local file.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

/// A file to preview, identified by its URL.
struct PreviewFile: Identifiable {
    let url: URL
    var id: URL { url }
}
