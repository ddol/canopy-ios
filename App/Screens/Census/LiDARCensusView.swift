import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// Census with LiDAR: the AR view with the reconstructed mesh, the target tree, and the census actions.
struct LiDARCensusView: View {
    @Environment(AppModel.self) private var model
    @State private var capture = CaptureSession()
    @State private var location = LocationProvider()
    @State private var targetID: UUID?
    @State private var isMeasuring = false
    @State private var measurement: Measurement?
    @State private var notice: String?
    private let format = QuantityFormat()

    var body: some View {
        ZStack {
            ARViewContainer(session: capture)
                .ignoresSafeArea()
            Reticle()
            VStack(spacing: Spacing.s) {
                targetCard
                if let notice {
                    Text(notice)
                        .font(.footnote)
                        .padding(Spacing.xs)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
                }
                Spacer()
                controls
            }
            .padding(Spacing.m)
        }
        .onAppear {
            capture.start()
            location.start()
        }
        .onDisappear {
            capture.pause()
            location.stop()
        }
        .sheet(item: $measurement) { measurement in
            MeasurementSheet(measurement: measurement)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: Target

    private var nearby: [(Tree, Double)] {
        guard let here = location.geoPoint else { return [] }
        return model.census.trees(near: here, within: 60, limit: 8)
    }

    private var target: Tree? {
        model.tree(targetID) ?? nearby.first?.0
    }

    private var targetCard: some View {
        HStack(spacing: Spacing.s) {
            if let target {
                StatusBadge(target.displayStatus.presentation)
                if let here = location.geoPoint {
                    let distance = LocalFrame(origin: here).enu(of: target.position.geo).horizontalDistance
                    Text(format.length(distance, fractionDigits: 0))
                        .font(CanopyFont.mono(.subheadline))
                }
                if let dbh = target.dbh {
                    Text("DBH " + format.length(dbh.diameter.value, uncertainty: dbh.diameter.uncertainty))
                        .font(CanopyFont.mono(.subheadline))
                }
            } else {
                Label(location.geoPoint == nil ? "Waiting for GPS…" : "No tree within 60 m", systemImage: "location")
                    .font(.subheadline)
            }
            Spacer()
            Menu {
                ForEach(nearby, id: \.0.id) { tree, distance in
                    Button {
                        targetID = tree.id
                    } label: {
                        Label(
                            "\(tree.displayStatus.presentation.label), \(format.length(distance, fractionDigits: 0))",
                            systemImage: tree.displayStatus.presentation.systemImage)
                    }
                }
            } label: {
                Label("Change tree", systemImage: "arrow.triangle.2.circlepath")
                    .labelStyle(.iconOnly)
            }
            .disabled(nearby.isEmpty)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
    }

    // MARK: Actions

    private var controls: some View {
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Button("Confirm tree", systemImage: "checkmark.circle") {
                    guard let target else { return }
                    Task { await model.confirm(target) }
                }
                .buttonStyle(.canopyPrimary)
                .disabled(target?.effectiveStatus != .detected)

                Button("Not a tree", systemImage: "xmark.circle") {
                    guard let target else { return }
                    Task { await model.reject(target) }
                }
                .buttonStyle(.canopySecondary)
                .disabled(target?.effectiveStatus != .detected)

                Button("New tree here", systemImage: "plus.circle") {
                    Task { await addTreeAtReticle() }
                }
                .buttonStyle(.canopySecondary)
            }
            .labelStyle(.titleAndIcon)
            .font(.footnote)

            Button {
                Task { await measure() }
            } label: {
                Label(isMeasuring ? "Measuring…" : "Measure trunk", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.canopySurvey)
            .disabled(isMeasuring)
        }
    }

    private func addTreeAtReticle() async {
        guard let device = location.geoPoint else {
            notice = "Waiting for a GPS fix."
            return
        }
        let position: Position
        if let hit = capture.raycastCenter(maxDistance: 15) {
            position = GeoReference.position(
                of: hit.position, camera: hit.cameraPosition, device: device,
                horizontalAccuracy: location.accuracy ?? 10, northAligned: capture.isNorthAligned)
        } else {
            let sigma = location.accuracy ?? 10
            position = Position(geo: device, covariance: .isotropic(horizontal: sigma, vertical: sigma))
        }
        await model.addTree(at: position)
        notice = "Added a new tree."
    }

    private func measure() async {
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            let result = try await capture.measureTrunk()
            let position: Position
            if let device = location.geoPoint {
                position = GeoReference.position(
                    of: result.trunkBase, camera: result.cameraPosition, device: device,
                    horizontalAccuracy: location.accuracy ?? 10, northAligned: capture.isNorthAligned)
            } else if let target {
                position = target.position
            } else {
                notice = "Waiting for a GPS fix."
                return
            }
            notice = nil
            measurement = Measurement(capture: result, position: position, target: target)
        } catch {
            notice = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.noSurface: "Point the centre of the screen at the trunk, within 6 m."
        case CaptureError.notEnoughMesh: "Walk slowly around the trunk so the mesh fills in, then try again."
        case CaptureError.noGround: "Include some ground at the foot of the trunk in the scan."
        case TrunkAnalysisError.notEnoughPoints: "Not enough of the trunk at 1.37 m yet. Scan it from closer."
        case TrunkAnalysisError.arcTooShort: "Scan more of the trunk's side: move a few steps around it."
        case TrunkAnalysisError.implausibleDiameter:
            "That does not look like a trunk. Aim at the trunk at chest height."
        default: "Could not measure: \(error.localizedDescription)"
        }
    }
}

/// A trunk measurement waiting to be saved.
struct Measurement: Identifiable {
    let id = UUID()
    let capture: TrunkCapture
    let position: Position
    let target: Tree?
}

/// A crosshair at the centre of the AR view.
struct Reticle: View {
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2).frame(width: 28, height: 28)
            Circle().fill(Color.canopySurvey).frame(width: 6, height: 6)
        }
        .shadow(radius: 2)
        .accessibilityHidden(true)
    }
}

/// Hosts the capture session's `ARView`.
struct ARViewContainer: UIViewRepresentable {
    let session: CaptureSession

    func makeUIView(context: Context) -> UIView {
        session.view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
