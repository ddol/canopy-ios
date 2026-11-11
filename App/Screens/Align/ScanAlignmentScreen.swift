import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import CanopyReference
import SwiftUI
import simd

/// Aligning a tree's rings against one of its saved scans, with no AR and no camera: the scan's triangles in 3D, with
/// the tree's rings, its DBH on record as a circle 1.37 m up, Gerardus's tree for the place and the aerial lidar
/// points round it drawn over them. A ring can be picked, moved, resized or snapped to the scan at its height, and
/// split where the trunk forks into a ring per stem; Gerardus's tree moved onto the trunk; and the crown set against
/// the aerial points with a few controls (`CrownShape`). Save keeps it all on the phone with the scan
/// (`ScanAlignment`), and the tree is drawn in those rings in AR and on the 3D map.
struct ScanAlignmentScreen: View {
    let scan: BlobRef
    let treeID: UUID

    enum Mode: String, CaseIterable, Identifiable {
        case rings
        case canopy
        case gerardus

        var id: Self { self }

        var label: String {
            switch self {
            case .rings: "Rings"
            case .canopy: "Canopy"
            case .gerardus: "Gerardus tree"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var saved: SavedScan?
    @State private var surface: ScanSurface?
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
    /// The aerial points round the tree in the scan's frame, as the census position puts them.
    @State private var aerialPoints: [SIMD3<Float>]?
    /// The aerial points as drawn and fitted to: moved with Gerardus's tree when it is set on the trunk.
    @State private var cloud: CanopyCloud?
    @State private var crown: CrownShape?
    @State private var isLoadingPoints = false
    /// Whether the crown was saved set against the aerial points, so loading them leaves it as it is.
    @State private var crownSaved = false
    /// How far the aerial points were moved to sit on the scanned trunk (x east, z south), when they were lined up
    /// with it and there is no Gerardus tree to carry the move.
    @State private var pointShift: SIMD2<Double>?
    @State private var isRegistering = false
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
            vectorBase: vectorTree == nil ? nil : placement?.base(groundHeight: groundHeight), cloud: cloud,
            crown: mode == .canopy ? crown : nil)
    }

    var body: some View {
        NavigationStack {
            Group {
                if saved != nil, let surface {
                    VStack(spacing: 0) {
                        ScanAlignmentSceneView(surface: surface, overlay: overlay, camera: camera) { id in
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
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }
            }
        }
        .task { await open() }
        .onChange(of: mode) { _, mode in
            guard mode == .canopy else { return }
            frameCrown()
            if aerialPoints == nil, model.alignClient != nil { Task { await loadPoints() } }
        }
        .onChange(of: placement?.correction) { moveCloud() }
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
            case .canopy: canopyControls
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
            // A fit runs off the main thread and writes its ring when it ends, so nothing edits rings meanwhile.
            Group { ringEditor(ring) }
                .disabled(isFitting)
        } else {
            Text("Tap a ring in the view, or pick one above.")
                .font(.footnote)
                .foregroundStyle(Color.canopyInkMuted)
        }
    }

    @ViewBuilder
    private func ringEditor(_ ring: TreeSection) -> some View {
        MetreField(
            title: "Height", value: heightBinding(ring), range: TreeProfile.heights, step: 0.05, digits: 2)
        MetreField(
            title: "Diameter", value: diameterBinding(ring), range: 0.03...35, step: 0.01, digits: 3,
            detail: diameterDetail(ring))
        HStack {
            Text("Centre")
            Spacer()
            nudges(step: 0.01, move: moveRing)
        }
        HStack(spacing: Spacing.s) {
            Button("Snap to scan", systemImage: "scope") { snap(ring) }
                .buttonStyle(.canopyPrimary)
                .disabled(ring.part != .trunk)
                .accessibilityIdentifier("align-snap")
            Button("Looks right", systemImage: "checkmark") { confirm(ring) }
                .buttonStyle(.canopySecondary)
                .disabled(ring.source == .confirmed)
            Menu("More", systemImage: "ellipsis.circle") {
                Button("Add a ring above", systemImage: "plus") {
                    selected = profile.addSection(above: ring.id) ?? selected
                    changed()
                }
                Button("Split into stems here", systemImage: "arrow.triangle.branch") { split(ring) }
                    .disabled(ring.part != .trunk || ring.stem != nil)
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
    }

    /// The crown as a few numbers set against the aerial points: its outline, where it starts and ends, how wide it
    /// is and where it is centred.
    @ViewBuilder
    private var canopyControls: some View {
        if crown != nil {
            Picker("Outline", selection: crownBinding(\.outline)) {
                ForEach(CrownShape.Outline.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("align-crown-outline")
            MetreField(title: "Crown base", value: crownBinding(\.base), range: 0...44, step: 0.25, digits: 2)
            MetreField(title: "Top", value: crownBinding(\.top), range: 1...45, step: 0.25, digits: 2)
            MetreField(
                title: "Foliage height", value: foliageBinding, range: 0.5...45, step: 0.25, digits: 2,
                detail: "base to top")
            MetreField(title: "Width", value: crownWidthBinding, range: 0.4...35, step: 0.2, digits: 2)
            HStack {
                Text("Centre")
                Spacer()
                nudges(step: 0.1, move: moveCrown)
            }
        }
        HStack(spacing: Spacing.s) {
            Button("Fit to points", systemImage: "wand.and.stars") { fitCrown() }
                .buttonStyle(.canopyPrimary)
                .disabled(cloud == nil)
                .accessibilityIdentifier("align-crown-fit")
            Button(aerialPoints == nil ? "Load points" : "Reload", systemImage: "circle.dotted") {
                Task { await loadPoints() }
            }
            .buttonStyle(.canopySecondary)
            .disabled(isLoadingPoints || model.alignClient == nil)
            if isLoadingPoints || isRegistering { ProgressView() }
        }
        Button("Line the points up with the scan", systemImage: "scope") { Task { await registerPoints() } }
            .buttonStyle(.canopySecondary)
            .disabled(cloud == nil || isRegistering)
            .accessibilityIdentifier("align-crown-register")
        Text(canopyStatus)
            .font(.footnote)
            .foregroundStyle(Color.canopyInkMuted)
            .accessibilityIdentifier("align-crown-status")
    }

    private var canopyStatus: String {
        if model.alignClient == nil { return "Set a server in Me → Settings to load the aerial lidar points." }
        guard let cloud else { return isLoadingPoints ? "Loading the aerial points round the tree…" : "" }
        guard let crown else { return "\(format.count(cloud.points.count)) aerial points." }
        let near = cloud.points.filter {
            simd_distance(SIMD2(Double($0.x), Double($0.z)), crown.centre) <= crown.radius * 1.5
                && Double($0.y) - groundHeight >= 1.5
        }
        let held = crown.coverage(of: near, groundHeight: groundHeight)
        return "The crown holds \(Int((held * 100).rounded()))% of the \(format.count(near.count)) aerial points "
            + "round it. Green points are inside it."
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
        (ring.stem.map { "Stem \($0 + 1) · " } ?? "") + ring.part.label + " "
            + format.length(ring.height, fractionDigits: 2) + " up · "
            + format.length(ring.diameter, fractionDigits: 2) + MeasurementSheet.mark(ring.source)
    }

    /// The diameter's uncertainty when fitted, and the DBH on record beside a ring at breast height.
    private func diameterDetail(_ ring: TreeSection) -> String? {
        var parts: [String] = []
        if let sigma = ring.radiusUncertainty { parts.append("± " + format.length(2 * sigma, fractionDigits: 3)) }
        if ring.part == .trunk, abs(ring.height - DBH.standardHeight) < 0.03, let dbh = tree?.dbh {
            parts.append("DBH " + format.length(dbh.diameter.value, fractionDigits: 3))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        let lean = tree?.lean
        isFitting = true
        Task {
            defer { isFitting = false }
            do {
                let snapped = try await Task.detached {
                    try saved.snapping(ring, groundHeight: ground, lean: lean)
                }.value
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
        let lean = tree?.lean
        isFitting = true
        Task {
            defer { isFitting = false }
            let (snapped, count, stems) = await Task.detached {
                saved.snappingTrunk(current, groundHeight: ground, lean: lean)
            }.value
            profile = snapped
            if selected.flatMap(profile.section) == nil { selected = profile.trunk.first?.id }
            note = Self.snappedNote(count, stems: stems)
            changed()
        }
    }

    /// Splits a trunk ring into a ring per stem where the scan shows the trunk forked at its height.
    private func split(_ ring: TreeSection) {
        guard let saved else { return }
        let ground = groundHeight
        let current = profile
        let lean = tree?.lean
        isFitting = true
        Task {
            defer { isFitting = false }
            let result = await Task.detached { saved.splitting(current, at: ring.id, groundHeight: ground, lean: lean) }
                .value
            guard let (split, rings) = result else {
                note =
                    "The scan shows one trunk " + format.length(ring.height, fractionDigits: 2)
                    + " up, so there is nothing to split."
                return
            }
            profile = split
            selected = rings.first
            note = "Split into \(rings.count) stems, each fitted to the scan. Add rings up a stem from More."
            changed()
        }
    }

    static func snappedNote(_ count: Int, stems: Int = 0) -> String {
        let snapped =
            switch count {
            case 0: "No trunk ring could be fitted to the scan."
            case 1: "Snapped one trunk ring to the scan."
            default: "Snapped \(count) trunk rings to the scan."
            }
        return stems >= 2 ? snapped + " The trunk forks into \(stems) stems." : snapped
    }

    // MARK: Canopy

    private func crownBinding<Value>(_ path: WritableKeyPath<CrownShape, Value>) -> Binding<Value> {
        Binding(
            get: { crown![keyPath: path] },
            set: { value in
                guard var shape = crown else { return }
                shape[keyPath: path] = value
                setCrown(shape)
            })
    }

    /// The crown's height from its base to its top: changing it moves the top.
    private var foliageBinding: Binding<Double> {
        Binding(
            get: { (crown?.top ?? 0) - (crown?.base ?? 0) },
            set: { height in
                guard var shape = crown else { return }
                shape.top = shape.base + height
                setCrown(shape)
            })
    }

    private var crownWidthBinding: Binding<Double> {
        Binding(
            get: { (crown?.radius ?? 0) * 2 },
            set: { width in
                guard var shape = crown else { return }
                shape.radius = width / 2
                setCrown(shape)
            })
    }

    /// The crown set to `shape`: the profile's crown rings are drawn from it.
    private func setCrown(_ shape: CrownShape) {
        let shape = shape.clamped
        crown = shape
        // The trunk, or each stem, goes on up to the crown's base.
        profile = profile.withCrown(shape).reachingCrown(lean: tree?.lean)
        if let id = selected, profile.section(id) == nil { selected = profile.trunk.first?.id }
        changed()
    }

    /// Moves the crown's centre by `delta` on the ground (scene x and z).
    private func moveCrown(_ delta: SIMD2<Float>) {
        guard var shape = crown else { return }
        shape.centre += SIMD2(Double(delta.x), Double(delta.y))
        setCrown(shape)
    }

    private func fitCrown() {
        guard let cloud else { return }
        let ground = groundHeight
        let start = crown?.centre ?? .zero
        let reach = max((crown?.radius ?? 3) * 1.5, 4)
        Task {
            let fitted = await Task.detached {
                CrownShape.fitted(to: cloud.points, groundHeight: ground, start: start, reach: reach)
            }.value
            guard let fitted else {
                note = "Too few aerial points round the tree to fit its crown."
                return
            }
            setCrown(fitted)
            note =
                "Fitted to the aerial points: " + fitted.outline.label.lowercased() + ", "
                + format.length(fitted.radius * 2, fractionDigits: 1) + " wide, from "
                + format.length(fitted.base, fractionDigits: 1) + " to " + format.length(fitted.top, fractionDigits: 1)
                + "."
        }
    }

    /// Asks the server for the aerial points round the tree.
    private func loadPoints() async {
        guard let tree, let client = model.alignClient else { return }
        isLoadingPoints = true
        defer { isLoadingPoints = false }
        do {
            aerialPoints = try await AppModel.canopyPoints(
                around: tree.position.geo, groundHeight: groundHeight, correction: .zero, client: client,
                cache: model.referenceCache)
            moveCloud()
            // Points not yet lined up with the scan are lined up with it first, where the trunk shows in them.
            if pointShift == nil, placement?.isMoved != true { await registerPoints(quietly: true) }
            // A crown already set against the points stays; otherwise it starts fitted to them.
            if !crownSaved { fitCrown() }
        } catch let error as AerialTrees.Failure {
            note = error.localizedDescription
        } catch {
            note = "Could not load the aerial points: \(error.localizedDescription)"
        }
    }

    /// The aerial points moved with Gerardus's tree: set on the trunk, it says how far out the census position is.
    private func moveCloud() {
        guard let aerialPoints else { return }
        let correction = placement?.correction ?? .zero
        let moved = pointShift ?? SIMD2(-correction.x, correction.y)
        let shift = SIMD3(Float(moved.x), 0, Float(moved.y))
        cloud = CanopyCloud(points: shift == .zero ? aerialPoints : aerialPoints.map { $0 + shift })
    }

    /// Moves the aerial points so the returns off the trunk sit on the scan (`AerialRegistration`). Gerardus's tree,
    /// from the same lidar, moves with them, which records how far out the census position is; without one the move
    /// is kept with the points. The crown moves with them too.
    private func registerPoints(quietly: Bool = false) async {
        guard let aerialPoints, let saved else { return }
        let ground = groundHeight
        isRegistering = true
        defer { isRegistering = false }
        let found = await Task.detached {
            AerialRegistration.register(aerialPoints, to: saved.mesh, groundHeight: ground)
        }.value
        guard let found else {
            if !quietly {
                note =
                    "Too few aerial returns off the trunk to line the points up with the scan. Move Gerardus's "
                    + "tree onto the trunk to move them by hand."
            }
            return
        }
        let before = cloudShift
        if var moved = placement {
            moved.placed = moved.drawn + SIMD2(found.shift.x, -found.shift.y)
            placement = moved
            pointShift = nil
        } else {
            pointShift = found.shift
        }
        moveCloud()
        if var shape = crown {
            shape.centre += found.shift - before
            setCrown(shape)
        }
        changed()
        note =
            "Lined the aerial points up with the scan: moved "
            + format.length(simd_length(found.shift), fractionDigits: 2)
            + ", \(found.matched) of \(found.candidates) returns beside the trunk now on it (\(found.matchedBefore) before)."
    }

    /// How far the points are drawn from where the census position puts them, x and z.
    private var cloudShift: SIMD2<Double> {
        let correction = placement?.correction ?? .zero
        return pointShift ?? SIMD2(-correction.x, correction.y)
    }

    /// Turns the view to take in the whole crown.
    private func frameCrown() {
        let top = crown?.top ?? profile.form.height
        let centre = crown?.centre ?? .zero
        camera.frame(
            SIMD3(Float(centre.x), Float(groundHeight + top / 2), Float(centre.y)),
            distance: Float(max(top * 1.6, 8)))
    }

    // MARK: Opening and saving

    private func open() async {
        guard saved == nil, failure == nil else { return }
        do {
            let file = try await model.evidenceFile(scan)
            // Reading the mesh and readying it to draw take a while for a real scan: off the main thread.
            let (loaded, drawn, estimated) = try await Task.detached {
                let loaded = try SavedScan(glb: Data(contentsOf: file))
                let ground = loaded.estimatedGroundHeight ?? Double(loaded.mesh.bounds?.min.y ?? 0)
                return (loaded, ScanSurface(loaded.mesh), ground)
            }.value
            let alignment = await model.alignment(for: scan, tree: treeID)
            let ground = alignment?.groundHeight ?? estimated
            var start = alignment?.profile ?? model.treeProfiles[MapLayers.censusWireframeID(treeID)]
            if start == nil {
                // Nothing fitted yet: the census's shape, with the trunk's rings snapped to the scan, as AR starts.
                let fresh = TreeProfile(form: AppModel.knownForm(tree))
                let lean = tree?.lean
                let (snapped, count, stems) = await Task.detached {
                    loaded.snappingTrunk(fresh, groundHeight: ground, lean: lean)
                }.value
                start = snapped
                note = Self.snappedNote(count, stems: stems)
            }
            profile = start ?? profile
            crown = alignment?.crown ?? CrownShape(profile)
            crownSaved = alignment?.crown != nil
            pointShift = alignment?.aerialShift
            groundHeight = ground
            selected =
                profile.trunk.min {
                    abs($0.height - DBH.standardHeight) < abs($1.height - DBH.standardHeight)
                }?.id
            placement = alignment?.vectorTree
            findVectorTrees()
            isSaved = alignment != nil
            surface = drawn
            saved = loaded
        } catch let error as GRPCStatusError where error.code == GRPCStatusError.notFound {
            failure = "The server does not have this scan."
        } catch is GLB.Error {
            failure = "The scan's file could not be read."
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
            correctedPosition: corrected, crown: cloud == nil && !crownSaved ? nil : crown, aerialShift: pointShift)
        if await model.saveAlignment(alignment) {
            isSaved = true
            crownSaved = alignment.crown != nil
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

/// A length in metres, typed or stepped: the number can be edited, and the stepper beside it moves it by `step`.
struct MetreField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let digits: Int
    var detail: String?

    var body: some View {
        HStack(spacing: Spacing.xs) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(Color.canopyInkMuted)
                }
            }
            Spacer(minLength: Spacing.xs)
            TextField(
                title,
                value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                format: .number.precision(.fractionLength(digits))
            )
            .keyboardType(.decimalPad)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .frame(width: 76)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(Color.canopyLine.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.small))
            .accessibilityIdentifier("field-" + title.lowercased().replacingOccurrences(of: " ", with: "-"))
            Text("m").foregroundStyle(Color.canopyInkMuted)
            Stepper(title, value: $value, in: range, step: step)
                .labelsHidden()
        }
    }
}
