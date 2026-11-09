import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import SwiftUI
import simd

/// Aligning a tree's rings against one of its saved scans, with no AR and no camera: the scan's triangles in 3D, with
/// the tree's rings, its DBH on record as a circle 1.37 m up, and Gerardus's tree for the place drawn over them. A ring
/// can be picked, moved, resized or snapped to the scan at its height, and Gerardus's tree moved onto the trunk. Save
/// keeps it all on the phone with the scan (`ScanAlignment`), and the tree is drawn in those rings in AR and on the
/// 3D map.
struct ScanAlignmentScreen: View {
    let scan: BlobRef
    let treeID: UUID

    enum Mode: String, CaseIterable, Identifiable {
        case rings
        case gerardus

        var id: Self { self }

        var label: String {
            switch self {
            case .rings: "Rings"
            case .gerardus: "Gerardus tree"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: SavedScan?
    @State private var failure: String?
    @State private var profile = TreeProfile(sections: [])
    @State private var groundHeight = 0.0
    @State private var selected: TreeSection.ID?
    @State private var mode = Mode.rings
    @State private var nearby: [NearbyVectorTree] = []
    @State private var placement: VectorTreePlacement?
    @State private var note: String?
    @State private var isFitting = false
    @State private var isLoadingVectors = false
    @State private var isSaved = false
    @State private var camera = ScanAlignmentCamera()
    private let format = QuantityFormat()

    private var tree: Tree? { model.tree(treeID) }
    private var selectedRing: TreeSection? { selected.flatMap(profile.section) }
    private var vectorTree: GerardusTree? {
        placement.flatMap { placement in nearby.first { $0.tree.id == placement.id }?.tree }
    }

    private var overlay: ScanAlignmentOverlay {
        ScanAlignmentOverlay(
            profile: profile, lean: tree?.lean, groundHeight: groundHeight, selected: mode == .rings ? selected : nil,
            dbh: tree?.dbh?.diameter.value, vectorForm: vectorTree?.form,
            vectorBase: vectorTree == nil ? nil : placement?.base(groundHeight: groundHeight))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let saved {
                    VStack(spacing: 0) {
                        ScanAlignmentSceneView(mesh: saved.mesh, overlay: overlay, camera: camera) { id in
                            selected = id
                            mode = .rings
                        }
                        .overlay(alignment: .topLeading) { legend }
                        .overlay(alignment: .topTrailing) {
                            Button("Reset view", systemImage: "arrow.counterclockwise") { camera.reset() }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.canopySecondary)
                                .padding(Spacing.s)
                        }
                        Divider()
                        controls
                    }
                } else if let failure {
                    ContentUnavailableView(
                        "Could not open the scan", systemImage: "cube.transparent", description: Text(failure))
                } else {
                    ProgressView("Opening the scan…")
                }
            }
            .navigationTitle(tree?.name ?? "Align rings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saved == nil || isSaved)
                        .accessibilityIdentifier("align-save")
                }
            }
        }
        .interactiveDismissDisabled()
        .task { await open() }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Picker("Align", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            switch mode {
            case .rings: ringControls
            case .gerardus: vectorControls
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Color.canopyInkMuted)
                    .accessibilityIdentifier("align-note")
            }
        }
        .padding(Spacing.m)
        .background(Color.canopyCard)
    }

    @ViewBuilder
    private var ringControls: some View {
        HStack {
            Menu {
                ForEach(profile.sections.reversed()) { ring in
                    Button(label(ring)) { selected = ring.id }
                }
            } label: {
                Label(selectedRing.map(label) ?? "Pick a ring", systemImage: "circle.dashed")
                    .font(.subheadline.weight(.semibold))
            }
            .accessibilityIdentifier("align-ring-menu")
            Spacer()
            Button("Ring below", systemImage: "chevron.down") { step(-1) }
                .labelStyle(.iconOnly)
            Button("Ring above", systemImage: "chevron.up") { step(1) }
                .labelStyle(.iconOnly)
        }
        if let ring = selectedRing {
            Stepper(value: heightBinding(ring), in: TreeProfile.heights, step: 0.05) {
                LabeledContent("Height", value: format.length(ring.height, fractionDigits: 2))
            }
            Stepper(value: diameterBinding(ring), in: 0.03...35, step: 0.01) {
                LabeledContent("Diameter", value: diameterText(ring))
            }
            HStack {
                Text("Centre")
                Spacer()
                nudges(step: 0.01, move: moveRing)
            }
            HStack(spacing: Spacing.s) {
                Button("Snap to scan", systemImage: "scope") { snap(ring) }
                    .buttonStyle(.canopyPrimary)
                    .disabled(isFitting || ring.part != .trunk)
                    .accessibilityIdentifier("align-snap")
                Button("Looks right", systemImage: "checkmark") { confirm(ring) }
                    .buttonStyle(.canopySecondary)
                    .disabled(ring.source == .confirmed)
                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Add a ring above", systemImage: "plus") {
                        selected = profile.addSection(above: ring.id) ?? selected
                        changed()
                    }
                    Button("Take this ring out", systemImage: "minus", role: .destructive) {
                        profile.removeSection(ring.id)
                        selected = profile.section(ring.id) == nil ? nil : ring.id
                        changed()
                    }
                    Button("Snap every trunk ring", systemImage: "scope") { snapTrunk() }
                }
                .labelStyle(.iconOnly)
                if isFitting { ProgressView() }
            }
        } else {
            Text("Tap a ring in the view, or pick one above.")
                .font(.footnote)
                .foregroundStyle(Color.canopyInkMuted)
        }
    }

    @ViewBuilder
    private var vectorControls: some View {
        if let placement, let vectorTree {
            if nearby.count > 1 {
                Picker("Gerardus tree", selection: vectorBinding) {
                    ForEach(nearby, id: \.tree.id) { candidate in
                        Text(vectorLabel(candidate)).tag(candidate.tree.id)
                    }
                }
            }
            Text(describe(vectorTree))
                .font(.subheadline.weight(.semibold))
            Text(offsetText(placement))
                .font(.footnote)
                .accessibilityIdentifier("align-vector-offset")
            HStack(spacing: Spacing.s) {
                Button("Move onto trunk", systemImage: "arrow.down.to.line") {
                    self.placement?.placed = .zero
                    changed()
                }
                .buttonStyle(.canopyPrimary)
                .accessibilityIdentifier("align-vector-onto-trunk")
                Button("Back", systemImage: "arrow.uturn.backward") {
                    self.placement?.placed = placement.drawn
                    changed()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.canopySecondary)
                .disabled(!placement.isMoved)
                Spacer()
                nudges(step: 0.05, move: moveVectorTree)
            }
            if placement.isMoved {
                Text(
                    "Saving records that this tree's map position is out by "
                        + format.length(simd_length(placement.correction), fractionDigits: 2)
                        + " by Gerardus's. The census keeps its position for now."
                )
                .font(.footnote)
                .foregroundStyle(Color.canopyInkMuted)
            }
        } else {
            Text(
                placement == nil
                    ? "No Gerardus tree is loaded within 15 m of this one."
                    : "The Gerardus tree saved with this scan is not loaded. Load the vectors here to see it."
            )
            .font(.footnote)
            if let tree, model.alignClient != nil {
                HStack {
                    Button("Load vectors here", systemImage: "square.3.layers.3d") {
                        Task { await loadVectors(around: tree) }
                    }
                    .buttonStyle(.canopySecondary)
                    .disabled(isLoadingVectors)
                    if isLoadingVectors { ProgressView() }
                }
                if case .failed(let message) = model.aerial {
                    Text(message).font(.footnote).foregroundStyle(Color.canopyInkMuted)
                }
            } else {
                Text("Set a server in Me → Settings to load Gerardus's trees.")
                    .font(.footnote)
                    .foregroundStyle(Color.canopyInkMuted)
            }
        }
    }

    /// Four arrows that move something on the ground the way they point on screen, whichever way the view is turned.
    private func nudges(step: Float, move: @escaping (SIMD2<Float>) -> Void) -> some View {
        HStack(spacing: Spacing.xs) {
            Button("Left", systemImage: "arrow.left") { move(-camera.groundAxes.right * step) }
            Button("Away", systemImage: "arrow.up") { move(camera.groundAxes.away * step) }
            Button("Toward", systemImage: "arrow.down") { move(-camera.groundAxes.away * step) }
            Button("Right", systemImage: "arrow.right") { move(camera.groundAxes.right * step) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.canopySecondary)
        .buttonRepeatBehavior(.enabled)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 2) {
            legendRow("DBH on record", ScanAlignmentSceneView.dbhColor)
            legendRow("Fitted to the scan", CaptureSession.scanRingColor)
            legendRow("Aligned to the camera", CaptureSession.cameraRingColor)
            legendRow("Confirmed", CaptureSession.confirmedRingColor)
            legendRow("By eye", CaptureSession.trunkColor)
            legendRow("Picked", CaptureSession.highlightColor)
            if vectorTree != nil { legendRow("Gerardus", ScanAlignmentSceneView.vectorColor) }
        }
        .font(.caption2)
        .padding(Spacing.xs)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
        .padding(Spacing.s)
        .accessibilityElement(children: .combine)
    }

    private func legendRow(_ title: String, _ color: SIMD4<Float>) -> some View {
        HStack(spacing: Spacing.xxs) {
            Circle()
                .fill(Color(red: Double(color.x), green: Double(color.y), blue: Double(color.z)))
                .overlay(Circle().stroke(Color.canopyLine))
                .frame(width: 8, height: 8)
            Text(title)
        }
    }

    // MARK: Text

    private func label(_ ring: TreeSection) -> String {
        ring.part.label + " " + format.length(ring.height, fractionDigits: 2) + " up · "
            + format.length(ring.diameter, fractionDigits: 2) + MeasurementSheet.mark(ring.source)
    }

    private func diameterText(_ ring: TreeSection) -> String {
        let diameter = format.length(ring.diameter, uncertainty: ring.radiusUncertainty.map { 2 * $0 })
        guard ring.part == .trunk, abs(ring.height - DBH.standardHeight) < 0.03, let dbh = tree?.dbh else {
            return diameter
        }
        return diameter + " (DBH " + format.length(dbh.diameter.value, fractionDigits: 3) + ")"
    }

    private func describe(_ tree: GerardusTree) -> String {
        var parts = [tree.commonName ?? tree.species ?? "Gerardus tree"]
        parts.append(format.length(tree.form.height, fractionDigits: 0) + " tall")
        if tree.measured.contains("dbh_m") {
            parts.append("DBH " + format.length(tree.form.trunkDiameter, fractionDigits: 2))
        }
        return parts.joined(separator: " · ")
    }

    private func vectorLabel(_ candidate: NearbyVectorTree) -> String {
        (candidate.tree.commonName ?? "Tree") + ", " + format.length(candidate.distance, fractionDigits: 1) + " away"
    }

    private func offsetText(_ placement: VectorTreePlacement) -> String {
        let offset = placement.placed
        let distance = simd_length(offset)
        guard distance >= 0.005 else { return "Its base is on the trunk." }
        let east = offset.x >= 0 ? " east" : " west"
        let north = offset.y >= 0 ? " north" : " south"
        return "Its base is " + format.length(distance, fractionDigits: 2) + " from the trunk: "
            + format.length(abs(offset.x), fractionDigits: 2) + east + ", "
            + format.length(abs(offset.y), fractionDigits: 2) + north + "."
    }

    static func explain(_ error: any Error) -> String {
        switch error as? TrunkAnalysisError {
        case .notEnoughPoints(let count):
            "The scan has too little of the trunk at that height (\(count) points)."
        case .arcTooShort(let degrees):
            "The scan covers only \(Int(degrees.rounded()))° of the trunk there; a ring needs 60°."
        case .implausibleDiameter(let diameter):
            "The scan there fits a circle \(QuantityFormat().length(diameter, fractionDigits: 2)) across, which is "
                + "no trunk."
        case nil:
            error.localizedDescription
        }
    }

    // MARK: Editing

    private func heightBinding(_ ring: TreeSection) -> Binding<Double> {
        Binding(
            get: { ring.height },
            set: { height in
                edit(ring.id) { $0.height = height }
            })
    }

    private func diameterBinding(_ ring: TreeSection) -> Binding<Double> {
        Binding(
            get: { ring.diameter },
            set: { diameter in
                edit(ring.id) { $0.radius = diameter / 2 }
            })
    }

    private var vectorBinding: Binding<String> {
        Binding(
            get: { placement?.id ?? "" },
            set: { id in
                guard let candidate = nearby.first(where: { $0.tree.id == id }) else { return }
                placement = VectorTreePlacement(id: id, drawn: candidate.offset)
                changed()
            })
    }

    /// A ring changed by hand is set by eye from then on.
    private func edit(_ id: TreeSection.ID, _ change: (inout TreeSection) -> Void) {
        guard var ring = profile.section(id) else { return }
        change(&ring)
        ring.source = .eye
        ring.radiusUncertainty = nil
        profile[id] = ring
        changed()
    }

    /// Moves the picked ring's centre by `delta` on the ground (scene x and z).
    private func moveRing(_ delta: SIMD2<Float>) {
        guard let ring = selectedRing else { return }
        let centre = WireframeTree.centre(of: ring, lean: tree?.lean)
        let start = ring.offset ?? SIMD2(Double(centre.x), Double(centre.z))
        edit(ring.id) { $0.offset = start + SIMD2(Double(delta.x), Double(delta.y)) }
    }

    /// Moves Gerardus's tree by `delta` on the ground (scene x east and z south).
    private func moveVectorTree(_ delta: SIMD2<Float>) {
        placement?.placed += SIMD2(Double(delta.x), -Double(delta.y))
        changed()
    }

    private func confirm(_ ring: TreeSection) {
        var confirmed = ring
        confirmed.source = .confirmed
        profile[ring.id] = confirmed
        changed()
    }

    private func step(_ direction: Int) {
        let rings = profile.sections
        guard !rings.isEmpty else { return }
        guard let index = rings.firstIndex(where: { $0.id == selected }) else {
            selected = rings.first?.id
            return
        }
        selected = rings[min(max(index + direction, 0), rings.count - 1)].id
    }

    private func changed() {
        isSaved = false
    }

    private func snap(_ ring: TreeSection) {
        guard let saved else { return }
        let ground = groundHeight
        isFitting = true
        Task {
            defer { isFitting = false }
            do {
                let snapped = try await Task.detached { try saved.snapping(ring, groundHeight: ground) }.value
                profile[ring.id] = snapped
                note =
                    "Fitted to the scan " + format.length(ring.height, fractionDigits: 2) + " up: "
                    + format.length(snapped.diameter, fractionDigits: 3) + " across."
                changed()
            } catch {
                note = Self.explain(error)
            }
        }
    }

    private func snapTrunk() {
        guard let saved else { return }
        let ground = groundHeight
        let current = profile
        isFitting = true
        Task {
            defer { isFitting = false }
            let (snapped, count) = await Task.detached { saved.snappingTrunk(current, groundHeight: ground) }.value
            profile = snapped
            note = Self.snappedNote(count)
            changed()
        }
    }

    static func snappedNote(_ count: Int) -> String {
        switch count {
        case 0: "No trunk ring could be fitted to the scan."
        case 1: "Snapped one trunk ring to the scan."
        default: "Snapped \(count) trunk rings to the scan."
        }
    }

    // MARK: Opening and saving

    private func open() async {
        guard saved == nil, failure == nil else { return }
        do {
            let file = try await model.evidenceFile(scan)
            let loaded = try await Task.detached { try SavedScan(glb: Data(contentsOf: file)) }.value
            let alignment = await model.alignment(for: scan)
            let ground =
                alignment?.groundHeight ?? loaded.estimatedGroundHeight ?? Double(loaded.mesh.bounds?.min.y ?? 0)
            var start = alignment?.profile ?? model.treeProfiles[MapLayers.censusWireframeID(treeID)]
            if start == nil {
                // Nothing fitted yet: the census's shape, with the trunk's rings snapped to the scan, as AR starts.
                let fresh = TreeProfile(form: AppModel.knownForm(tree))
                let (snapped, count) = await Task.detached { loaded.snappingTrunk(fresh, groundHeight: ground) }.value
                start = snapped
                note = Self.snappedNote(count)
            }
            profile = start ?? profile
            groundHeight = ground
            selected =
                profile.trunk.min {
                    abs($0.height - DBH.standardHeight) < abs($1.height - DBH.standardHeight)
                }?.id
            placement = alignment?.vectorTree
            findVectorTrees()
            isSaved = alignment != nil
            saved = loaded
        } catch let error as GRPCStatusError where error.code == GRPCStatusError.notFound {
            failure = "The server does not have this scan."
        } catch {
            failure = error.localizedDescription
        }
    }

    private func findVectorTrees() {
        guard let tree else { return }
        nearby = model.vectorTrees(near: tree)
        if placement == nil, let nearest = nearby.first {
            placement = VectorTreePlacement(id: nearest.tree.id, drawn: nearest.offset)
        }
    }

    private func loadVectors(around tree: Tree) async {
        isLoadingVectors = true
        defer { isLoadingVectors = false }
        await model.loadVectors(around: tree.position.geo)
        findVectorTrees()
    }

    private func save() async {
        let corrected = placement.flatMap { placement in
            placement.isMoved ? tree.map { placement.corrected($0.position.geo) } : nil
        }
        let alignment = ScanAlignment(
            scan: scan, treeID: treeID, profile: profile, groundHeight: groundHeight, vectorTree: placement,
            correctedPosition: corrected)
        if await model.saveAlignment(alignment) {
            isSaved = true
            note = "Saved on this phone with the scan. The tree is drawn in these rings in AR and on the 3D map."
        }
    }
}

/// Opens a trunk scan to align the tree's rings against it (`ScanAlignmentScreen`), full screen.
struct AlignScanButton: View {
    let scan: BlobRef
    let treeID: UUID
    @State private var isPresented = false

    var body: some View {
        Button("Align rings with the scan", systemImage: "scope") { isPresented = true }
            .accessibilityIdentifier("align-scan")
            .fullScreenCover(isPresented: $isPresented) {
                ScanAlignmentScreen(scan: scan, treeID: treeID)
            }
    }
}
