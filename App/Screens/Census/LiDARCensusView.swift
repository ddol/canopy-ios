import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
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
    /// The session registered against 3DEP: positions come from it instead of GPS while it lasts.
    @State private var registered: RegisteredScan?
    @State private var isRegistering = false
    @State private var confirmingRegistration = false
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
                if let scan = capture.scan {
                    ScanProgressCard(progress: scan.progress)
                }
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
        .confirmationDialog(
            "Register with aerial LiDAR?", isPresented: $confirmingRegistration, titleVisibility: .visible
        ) {
            Button("Upload and register") { Task { await register() } }
        } message: {
            Text(
                "Uploads the colourless 3D mesh around you (up to 60 m, geometry only, no photos) to "
                    + "\(model.gerardusURL.host() ?? "the Gerardus server") and matches it to USGS 3DEP aerial "
                    + "LiDAR, so trees you add or measure land within a few centimetres instead of GPS metres.")
        }
        // The AR session pauses under the result sheet (Quick Look's AR mode needs the camera) and resumes, with
        // the mesh and the scan, when the sheet closes.
        .sheet(item: $measurement, onDismiss: resumeCapture) { measurement in
            MeasurementSheet(measurement: measurement) {
                capture.cancelScan()
            }
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
            if capture.scan == nil {
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
                    startScan()
                } label: {
                    Label("Scan trunk", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.canopySurvey)

                registrationControl
            } else {
                HStack(spacing: Spacing.s) {
                    Button("Cancel", systemImage: "xmark") {
                        capture.cancelScan()
                        notice = nil
                    }
                    .buttonStyle(.canopySecondary)

                    Button {
                        Task { await finishScan() }
                    } label: {
                        Label(isMeasuring ? "Measuring…" : "Finish scan", systemImage: "checkmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.canopySurvey)
                    .disabled(isMeasuring)
                }
            }
        }
    }

    @ViewBuilder
    private var registrationControl: some View {
        if let registered {
            HStack {
                StatusBadge("Registered to 3DEP", systemImage: "scope", tone: .ok)
                Text("±" + QuantityFormat.thinSpace + format.length(registered.sigma, fractionDigits: 2))
                    .font(CanopyFont.mono(.footnote))
                Spacer()
            }
            .accessibilityElement(children: .combine)
        } else {
            Button {
                confirmingRegistration = true
            } label: {
                Label(isRegistering ? "Registering…" : "Register with 3DEP", systemImage: "scope")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.canopySecondary)
            .font(.footnote)
            .disabled(isRegistering)
        }
    }

    /// Where an AR world point is on the map: from the 3DEP registration when there is one, else GPS.
    private func position(of point: SIMD3<Float>, camera: SIMD3<Float>, device: GeoPoint) -> Position {
        if let registered {
            return registered.position(ofARKit: point)
        }
        return GeoReference.position(
            of: point, camera: camera, device: device, horizontalAccuracy: location.accuracy ?? 10,
            northAligned: capture.isNorthAligned)
    }

    private func register() async {
        guard let gps = location.geoPoint, let camera = capture.cameraPosition else {
            notice = "Waiting for GPS and AR tracking."
            return
        }
        isRegistering = true
        defer { isRegistering = false }
        do {
            let outcome = try await model.registerScan(
                arkitPoints: capture.worldPoints(range: 60), gps: gps, camera: camera,
                groundBelowOrigin: capture.groundHeight(under: .zero), northAligned: capture.isNorthAligned
            ) { notice = $0 }
            if let placed = outcome.placed, placed.passedGates {
                registered = placed
                notice =
                    "Registered to 3DEP. New positions are good to "
                    + format.length(placed.sigma, fractionDigits: 2) + "."
            } else {
                let failed = outcome.registration.gates.filter { !$0.passed }.map(\.name)
                let reason = outcome.registration.failureReason
                notice =
                    "No reliable match in 3DEP"
                    + (failed.isEmpty ? "" : " (failed: \(failed.joined(separator: ", ")))")
                    + (reason.isEmpty ? "" : ": \(reason)") + ". Still using GPS; look around more and try again."
            }
        } catch {
            notice = "Could not register: \(error.localizedDescription)"
        }
    }

    private func addTreeAtReticle() async {
        guard let device = location.geoPoint else {
            notice = "Waiting for a GPS fix."
            return
        }
        let position: Position
        if let hit = capture.raycastCenter(maxDistance: 15) {
            position = self.position(of: hit.position, camera: hit.cameraPosition, device: device)
        } else {
            let sigma = location.accuracy ?? 10
            position = Position(geo: device, covariance: .isotropic(horizontal: sigma, vertical: sigma))
        }
        await model.addTree(at: position)
        notice = "Added a new tree."
    }

    private func resumeCapture() {
        capture.start()
    }

    private func startScan() {
        do {
            try capture.startScan()
            notice = "Walk slowly round the trunk, keeping it in view."
        } catch {
            notice = Self.describe(error)
        }
    }

    private func finishScan() async {
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            let result = try await capture.finishScan()
            let position: Position
            if let registered {
                position = registered.position(ofARKit: result.trunkBase)
            } else if let device = location.geoPoint {
                position = self.position(of: result.trunkBase, camera: result.cameraPosition, device: device)
            } else if let target {
                position = target.position
            } else {
                notice = "Waiting for a GPS fix."
                return
            }
            notice = nil
            capture.pause()
            measurement = Measurement(capture: result, position: position, target: target)
        } catch {
            notice = Self.describe(error)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case CaptureError.noSurface: "Point the centre of the screen at the trunk, within 6 m."
        case CaptureError.notEnoughMesh: "Walk slowly round the trunk so the mesh fills in, then try again."
        case CaptureError.noGround: "Include some ground at the foot of the trunk in the scan."
        case CaptureError.notScanning: "Start a scan on the trunk first."
        case TrunkAnalysisError.notEnoughPoints:
            "Not enough of the trunk 1.37 m above the ground yet. Scan it from closer."
        case TrunkAnalysisError.arcTooShort: "Scan more of the trunk: keep walking round it."
        case TrunkAnalysisError.implausibleDiameter:
            "That does not look like a trunk. Start the scan on the trunk, about 1.37 m above the ground."
        default: "Could not measure: \(error.localizedDescription)"
        }
    }
}

/// Live feedback while scanning a trunk: how much of its circumference 1.37 m above the ground is covered.
struct ScanProgressCard: View {
    let progress: ScanProgress
    private let format = QuantityFormat()

    var body: some View {
        HStack(spacing: Spacing.s) {
            ZStack {
                Circle().stroke(Color.canopyLine, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: min(1, (progress.arcDegrees ?? 0) / 360))
                    .stroke(
                        progress.isWellCovered ? Color.canopyBrand : Color.canopySurvey,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(headline).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(CanopyFont.mono(.caption))
                    .foregroundStyle(Color.canopyInkMuted)
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.s)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.large))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan-progress")
    }

    private var height: String { format.length(DBH.standardHeight) }

    private var headline: String {
        guard let arc = progress.arcDegrees else { return "Walk slowly round the trunk" }
        if progress.isWellCovered { return "Good coverage: finish when ready" }
        return "Covered " + format.angle(arc, fractionDigits: 0) + " of the trunk " + height + " up"
    }

    private var detail: String {
        var parts = [format.count(progress.triangleCount) + " triangles kept"]
        if let diameter = progress.diameter {
            parts.append("about " + format.length(diameter, fractionDigits: 2) + " across")
        } else {
            parts.append("no trunk found " + height + " up yet")
        }
        return parts.joined(separator: " · ")
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
