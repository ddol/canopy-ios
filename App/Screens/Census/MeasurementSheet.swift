import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyStore
import QuickLook
import SwiftUI

/// The result of a trunk measurement: DBH and lean with uncertainties, fit quality, and Save.
struct MeasurementSheet: View {
    let measurement: Measurement
    /// Called once the measurement is saved.
    var onSaved: () -> Void = {}

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: Tree?
    @State private var shareURL: URL?
    @State private var previewURL: URL?
    private let format = QuantityFormat()

    private var analysis: TrunkAnalysis.Result { measurement.capture.analysis }

    /// How a kept ring was set, after its diameter.
    static func mark(_ source: TreeSection.Source) -> String {
        switch source {
        case .eye: ""
        case .scan: " (scan)"
        case .camera: " (camera)"
        case .confirmed: " ✓"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Trunk diameter " + format.length(analysis.dbh.height) + " above the ground")
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

                if let form = measurement.form {
                    Section {
                        LabeledContent("Height") {
                            Text(format.length(form.height, fractionDigits: 1)).font(CanopyFont.mono())
                        }
                        LabeledContent("Foliage") {
                            Text(
                                format.length(form.crownHeight, fractionDigits: 1) + " tall, "
                                    + format.length(form.crownWidth, fractionDigits: 1) + " wide"
                            )
                            .font(CanopyFont.mono())
                        }
                        LabeledContent("Trunk diameter by eye") {
                            Text(format.length(form.trunkDiameter, fractionDigits: 2)).font(CanopyFont.mono())
                        }
                        if let profile = measurement.profile {
                            ForEach(profile.sections.filter(\.isKept)) { ring in
                                LabeledContent(
                                    ring.part.label + " " + format.length(ring.height, fractionDigits: 2) + " up"
                                ) {
                                    Text(format.length(ring.diameter, fractionDigits: 2) + Self.mark(ring.source))
                                        .font(CanopyFont.mono())
                                }
                            }
                        }
                    } header: {
                        Text("Fitted in AR")
                    } footer: {
                        Text(
                            "From the wireframe you matched to the tree. Rings marked (scan) were fitted to the scan's "
                                + "points at that height, (camera) to the trunk's edges in the camera image; ✓ ones you "
                                + "confirmed against the tree. The rings are kept on this phone with the scan, to align again "
                                + "from it later; the shape is not shared yet.")
                    }
                }

                Section("Fit") {
                    LabeledContent(
                        "Points at " + format.length(analysis.dbh.height), value: "\(analysis.circle.pointCount)")
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
                        Button("Keep scanning", systemImage: "arrow.counterclockwise", role: .cancel) {
                            dismiss()
                        }
                    }
                } footer: {
                    Text(
                        "Saves the colourless mesh of the trunk as evidence. No photo is taken. "
                            + "Keep scanning to walk round more of the trunk and measure again.")
                }

                #if DEBUG || TESTING_TOOLS
                    Section("Debug") {
                        if let shareURL {
                            ShareLink(item: shareURL) {
                                Label("Share GLB", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button("Preview in Quick Look", systemImage: "cube") {
                            previewURL = try? QuickLookPreview.usdz(for: measurement.capture.evidence)
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
            // SwiftUI's own Quick Look presentation has a Done button; Quick Look's 3D viewer takes the swipe that
            // would close a sheet.
            .quickLookPreview($previewURL)
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
        if let saved {
            // The wireframe drawn for this tree, in AR and on the map, is now the one fitted to it.
            let key = MapLayers.censusWireframeID(saved.id)
            if let form = measurement.form { model.treeForms[key] = form }
            // The rings are kept with the scan, to correct later against it (`ScanAlignmentScreen`).
            if let profile = measurement.profile {
                await model.saveAlignment(
                    ScanAlignment(
                        scan: BlobStore.reference(for: capture.glb), treeID: saved.id, profile: profile,
                        groundHeight: capture.groundHeight))
            }
            shareURL = try? model.shareableGLB(BlobStore.reference(for: capture.glb))
            onSaved()
        }
    }
}
