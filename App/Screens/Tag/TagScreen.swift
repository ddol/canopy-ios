import CanopyCapture
import CanopyDesign
import CanopyMap
import CanopyModel
import SwiftUI

/// Tag a limb hazard: pick a tree, place the limb point (in 3D with LiDAR, or by height), describe it.
struct TagScreen: View {
    @Environment(AppModel.self) private var model
    @State private var location = LocationProvider()
    @State private var treeID: UUID?
    @State private var placement: LimbPlacement?
    @State private var manualHeight = 5.0
    @State private var issue = Tag.Issue.deadwood
    @State private var couldHit = Tag.Target.path
    @State private var sizeClass = Tag.SizeClass.medium
    @State private var urgency = Tag.Urgency.moderate
    @State private var isPlacing = false
    @State private var lastSaved: Tag?
    private let format = QuantityFormat()

    var body: some View {
        NavigationStack {
            Form {
                treeSection
                if let tree {
                    pointSection(tree)
                    describeSection
                    Section {
                        Button("Save tag", systemImage: "exclamationmark.triangle") {
                            Task { await save(on: tree) }
                        }
                        .buttonStyle(.canopyPrimary)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                    } footer: {
                        Text("Saved as proposed. It reaches the shared map when a second player agrees.")
                    }
                    existingTags(tree)
                }
            }
            .navigationTitle("Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let tree else { return }
                        Task { await save(on: tree) }
                    }
                    .disabled(tree == nil)
                }
            }
            .onAppear {
                location.start()
                if let target = model.tagTarget {
                    treeID = target
                    model.tagTarget = nil
                }
            }
            .onDisappear { location.stop() }
            .onChange(of: model.tagTarget) { _, target in
                guard let target else { return }
                treeID = target
                placement = nil
                model.tagTarget = nil
            }
            .sheet(isPresented: $isPlacing) {
                if let tree {
                    LimbPlacementView(tree: tree, location: location) { placed in
                        placement = placed
                        isPlacing = false
                    }
                }
            }
        }
    }

    private var tree: Tree? { model.tree(treeID) }

    private var nearby: [(Tree, Double)] {
        model.census.trees(near: location.geoPoint ?? MapViewport.goldenGatePark.center, limit: 15)
    }

    // MARK: Sections

    private var treeSection: some View {
        Section("Tree") {
            if let tree {
                HStack {
                    StatusBadge(tree.displayStatus.presentation)
                    S2CellLabel(tree.position.chunk)
                    Spacer()
                }
                if let lastSaved, lastSaved.treeID == tree.id {
                    HStack {
                        Label("Saved: \(lastSaved.issue.label.lowercased())", systemImage: "checkmark.circle")
                            .foregroundStyle(Color.canopyBrand)
                        Spacer()
                        StatusBadge(lastSaved.status.presentation)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tag-saved")
                }
            }
            Picker("Choose a tree", selection: $treeID) {
                Text("None").tag(UUID?.none)
                ForEach(nearby, id: \.0.id) { tree, distance in
                    Text("\(tree.displayStatus.presentation.label), \(format.length(distance, fractionDigits: 0))")
                        .tag(UUID?.some(tree.id))
                }
                if let tree, !nearby.contains(where: { $0.0.id == tree.id }) {
                    Text("Selected tree").tag(UUID?.some(tree.id))
                }
            }
            .pickerStyle(.navigationLink)
        }
    }

    private func pointSection(_ tree: Tree) -> some View {
        Section {
            if let placement {
                LabeledContent("Height above ground") {
                    Text(format.length(placement.height.value, uncertainty: placement.height.uncertainty))
                        .font(CanopyFont.mono())
                }
                LabeledContent("Limb scan", value: placement.evidence == nil ? "None" : "Cropped mesh, 1 m around")
                Button("Clear point", systemImage: "xmark", role: .destructive) { self.placement = nil }
            } else {
                Stepper(value: $manualHeight, in: 0.5...45, step: 0.5) {
                    LabeledContent("Height above ground") {
                        Text(format.length(manualHeight, fractionDigits: 1)).font(CanopyFont.mono())
                    }
                }
            }
            if LiDAR.isAvailable {
                Button("Place limb point in 3D", systemImage: "scope") { isPlacing = true }
            }
        } header: {
            Text("Limb point")
        } footer: {
            Text(
                LiDAR.isAvailable
                    ? "Aim at the limb within about 5 m; the point snaps to the LiDAR mesh."
                    : "Estimate the height; the point is placed at the tree.")
        }
    }

    private var describeSection: some View {
        Section("Hazard") {
            Picker("Issue", selection: $issue) {
                ForEach(Tag.Issue.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Could hit", selection: $couldHit) {
                ForEach(Tag.Target.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Picker("Limb size", selection: $sizeClass) {
                ForEach(Tag.SizeClass.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Limb diameter: " + sizeClass.label)
                .font(.footnote)
                .foregroundStyle(Color.canopyInkMuted)
            Picker("Urgency", selection: $urgency) {
                ForEach(Tag.Urgency.allCases, id: \.self) { urgency in
                    Label(urgency.presentation.label, systemImage: urgency.presentation.systemImage).tag(urgency)
                }
            }
            HStack {
                Text("Shown as")
                Spacer()
                StatusBadge(urgency.presentation)
            }
        }
    }

    @ViewBuilder
    private func existingTags(_ tree: Tree) -> some View {
        let tags = model.tags(on: tree)
        if !tags.isEmpty {
            Section("Tags on this tree") {
                ForEach(tags) { tag in
                    HStack {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(tag.issue.label).font(.body.weight(.semibold))
                            Text(
                                "\(tag.couldHit.label) · \(tag.sizeClass.shortLabel) · "
                                    + format.length(tag.point.heightAboveGround.value, fractionDigits: 1)
                            )
                            .font(.footnote)
                            .foregroundStyle(Color.canopyInkMuted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: Spacing.xxs) {
                            StatusBadge(tag.status.presentation)
                            StatusBadge(tag.urgency.presentation)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("tag-\(tag.id.uuidString)")
                }
            }
        }
    }

    // MARK: Saving

    private func save(on tree: Tree) async {
        let point: Tag.Point
        if let placement {
            point = Tag.Point(position: placement.position, heightAboveGround: placement.height)
        } else {
            point = Tag.Point(position: tree.position, heightAboveGround: Quantity(manualHeight, uncertainty: 1))
        }
        lastSaved = await model.placeTag(
            on: tree, point: point, issue: issue, couldHit: couldHit, sizeClass: sizeClass, urgency: urgency,
            evidence: placement?.evidence)
        if lastSaved != nil {
            placement = nil
        }
    }
}

/// A limb point placed in 3D.
struct LimbPlacement {
    var position: Position
    var height: Quantity
    var evidence: AppModel.LimbEvidence?
}

/// Aim at a limb and place a point on the LiDAR mesh within about 5 m.
struct LimbPlacementView: View {
    let tree: Tree
    let location: LocationProvider
    let onPlace: (LimbPlacement) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var capture = CaptureSession()
    @State private var notice: String?

    static let maxDistance: Float = 5

    var body: some View {
        NavigationStack {
            ZStack {
                ARViewContainer(session: capture).ignoresSafeArea()
                Reticle()
                VStack {
                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .padding(Spacing.xs)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
                    }
                    Spacer()
                    Button("Place limb point", systemImage: "scope") { place() }
                        .buttonStyle(.canopySurvey)
                }
                .padding(Spacing.m)
            }
            .navigationTitle("Place limb point")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { capture.start() }
            .onDisappear { capture.pause() }
        }
    }

    private func place() {
        guard let hit = capture.raycastCenter(maxDistance: Self.maxDistance) else {
            notice = "Nothing in the mesh within 5 m. Move closer, or scan the limb first."
            return
        }
        guard let ground = capture.groundHeight(under: hit.position) else {
            notice = "Could not find the ground under the limb yet. Scan the base of the tree."
            return
        }
        let position: Position
        if let device = location.geoPoint {
            position = GeoReference.position(
                of: hit.position, camera: hit.cameraPosition, device: device,
                horizontalAccuracy: location.accuracy ?? 10, northAligned: capture.isNorthAligned)
        } else {
            position = tree.position
        }
        let evidence = (try? capture.captureLimb(at: hit)).map { mesh, glb in
            AppModel.LimbEvidence(
                glb: glb, vertexCount: mesh.vertexCount, triangleCount: mesh.triangleCount, cropRadius: 1)
        }
        // LiDAR range noise is a centimetre or two; the ground estimate dominates.
        let height = Quantity(Double(hit.position.y - ground), uncertainty: 0.1)
        onPlace(LimbPlacement(position: position, height: height, evidence: evidence))
    }
}
