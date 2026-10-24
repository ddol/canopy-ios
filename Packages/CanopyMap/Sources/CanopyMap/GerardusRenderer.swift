import CanopyDesign
import CanopyModel
import SwiftUI

/// Draws the layers on a plain background, with no base map: only Gerardus's own data (canopy heights from the aerial
/// point cloud, building outlines, and roads and paths when OpenStreetMap was loaded), the park outline, tiles, routes,
/// trees and tags. Drag to pan, pinch to zoom, tap a tree to select it.
public struct GerardusRenderer: MapRenderer {
    public init() {}

    public func makeBody(
        layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport,
        onViewportChange: @escaping @MainActor (MapViewport) -> Void
    ) -> some View {
        GerardusMap(layers: layers, selection: selection, viewport: viewport, onViewportChange: onViewportChange)
    }
}

/// Points on screen from metres east and north of a centre. Flat, which is plenty across a park a few kilometres wide.
struct FlatProjection {
    static let metresPerDegreeNorth = 110_574.0

    var centre: GeoPoint
    var metresPerPoint: Double
    var size: CGSize

    var metresPerDegreeEast: Double { 111_320 * cos(centre.latitude * .pi / 180) }

    func point(_ geo: GeoPoint) -> CGPoint {
        CGPoint(
            x: size.width / 2 + (geo.longitude - centre.longitude) * metresPerDegreeEast / metresPerPoint,
            y: size.height / 2 - (geo.latitude - centre.latitude) * Self.metresPerDegreeNorth / metresPerPoint)
    }

    func geo(_ point: CGPoint) -> GeoPoint {
        GeoPoint(
            latitude: centre.latitude - (point.y - size.height / 2) * metresPerPoint / Self.metresPerDegreeNorth,
            longitude: centre.longitude + (point.x - size.width / 2) * metresPerPoint / metresPerDegreeEast)
    }

    var viewport: MapViewport {
        MapViewport(
            center: centre, latitudeDelta: size.height * metresPerPoint / Self.metresPerDegreeNorth,
            longitudeDelta: size.width * metresPerPoint / metresPerDegreeEast)
    }
}

struct GerardusMap: View {
    static let zoomRange = 0.05...20.0

    let layers: MapLayers
    let onViewportChange: @MainActor (MapViewport) -> Void
    @Binding var selection: UUID?
    @State private var centre: GeoPoint
    @State private var metresPerPoint: Double
    /// The region to fit once the size is known.
    @State private var unfitted: MapViewport?
    @State private var size = CGSize.zero
    @State private var canopy: CGImage?
    @GestureState private var pan = CGSize.zero
    @GestureState private var zoom = 1.0

    init(
        layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport,
        onViewportChange: @escaping @MainActor (MapViewport) -> Void
    ) {
        self.layers = layers
        self.onViewportChange = onViewportChange
        self._selection = selection
        self._centre = State(initialValue: viewport.center)
        self._metresPerPoint = State(initialValue: 1)
        self._unfitted = State(initialValue: viewport)
    }

    /// The projection as drawn, with any pan or pinch in progress.
    private func projection(in size: CGSize) -> FlatProjection {
        let settled = FlatProjection(centre: centre, metresPerPoint: metresPerPoint, size: size)
        let panned = settled.geo(CGPoint(x: size.width / 2 - pan.width, y: size.height / 2 - pan.height))
        return FlatProjection(
            centre: panned, metresPerPoint: (metresPerPoint / zoom).clamped(to: Self.zoomRange), size: size)
    }

    var body: some View {
        GeometryReader { proxy in
            let projection = projection(in: proxy.size)
            Canvas { context, _ in
                draw(in: &context, projection)
            }
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .updating($pan) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            let settled = FlatProjection(centre: centre, metresPerPoint: metresPerPoint, size: size)
                            centre = settled.geo(
                                CGPoint(
                                    x: size.width / 2 - value.translation.width,
                                    y: size.height / 2 - value.translation.height))
                            report()
                        },
                    MagnifyGesture()
                        .updating($zoom) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            metresPerPoint = (metresPerPoint / value.magnification).clamped(to: Self.zoomRange)
                            report()
                        }
                )
            )
            .onTapGesture(coordinateSpace: .local) { location in
                select(at: location, projection)
            }
            .onAppear { resize(to: proxy.size) }
            .onChange(of: proxy.size) { _, new in resize(to: new) }
            .overlay(alignment: .bottomLeading) {
                ScaleBar(metresPerPoint: projection.metresPerPoint)
                    .padding(Spacing.m)
                    .padding(.bottom, 64)
            }
        }
        .background(Color.canopySurface)
        .onChange(of: layers.reference, initial: true) { _, reference in
            canopy = reference?.canopy.flatMap(CanopyImage.make)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gerardus map, \(layers.trees.count) trees")
        .accessibilityIdentifier("gerardus-map")
    }

    /// Takes the new size, fitting the starting region into it the first time there is one.
    private func resize(to new: CGSize) {
        size = new
        if let region = unfitted, size.width > 0, size.height > 0 {
            let east = FlatProjection(centre: region.center, metresPerPoint: 1, size: size).metresPerDegreeEast
            metresPerPoint = max(
                region.latitudeDelta * FlatProjection.metresPerDegreeNorth / size.height,
                region.longitudeDelta * east / size.width
            ).clamped(to: Self.zoomRange)
            unfitted = nil
        }
        report()
    }

    private func report() {
        guard size.width > 0, size.height > 0 else { return }
        onViewportChange(FlatProjection(centre: centre, metresPerPoint: metresPerPoint, size: size).viewport)
    }

    private func select(at location: CGPoint, _ projection: FlatProjection) {
        let nearest = layers.trees.min {
            projection.point($0.location).distance(to: location) < projection.point($1.location).distance(to: location)
        }
        if let nearest, projection.point(nearest.location).distance(to: location) < 22 {
            selection = nearest.id
        } else {
            selection = nil
        }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, _ projection: FlatProjection) {
        let visible = CGRect(origin: .zero, size: projection.size).insetBy(dx: -30, dy: -30)
        func path(_ points: [GeoPoint], closed: Bool) -> Path {
            var path = Path()
            path.addLines(points.map(projection.point))
            if closed { path.closeSubpath() }
            return path
        }

        if let canopy, let raster = layers.reference?.canopy {
            let sw = projection.point(raster.southWest)
            let ne = projection.point(raster.northEast)
            let rect = CGRect(x: sw.x, y: ne.y, width: ne.x - sw.x, height: sw.y - ne.y)
            context.draw(Image(decorative: canopy, scale: 1).interpolation(.medium), in: rect)
        }
        for line in layers.reference?.lines ?? [] {
            let shape = path(line.points, closed: line.closed)
            switch line.kind {
            case .building:
                context.fill(shape, with: .color(Color.canopyInkMuted.opacity(0.25)))
                context.stroke(shape, with: .color(Color.canopyInkMuted), lineWidth: 1)
            case .road:
                context.stroke(shape, with: .color(Color.canopyInkMuted.opacity(0.6)), lineWidth: 3)
            case .path:
                context.stroke(
                    shape, with: .color(Color.canopyInkMuted.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            case .other:
                context.stroke(shape, with: .color(Color.canopyLineStrong), lineWidth: 1)
            }
        }
        for ring in layers.boundary {
            context.stroke(path(ring, closed: true), with: .color(Color.canopyBrand.opacity(0.6)), lineWidth: 1.5)
        }
        for tile in layers.tiles {
            context.stroke(
                path(tile.corners, closed: true), with: .color(Color.canopyLineStrong),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        for route in layers.routes {
            context.stroke(path(route.points, closed: false), with: .color(Color.canopyInkMuted), lineWidth: 3)
        }
        for tree in layers.trees {
            let centre = projection.point(tree.location)
            guard visible.contains(centre) else { continue }
            drawTree(tree, at: centre, metresPerPoint: projection.metresPerPoint, in: &context)
        }
        for tag in layers.tags {
            let centre = projection.point(tag.location)
            guard visible.contains(centre) else { continue }
            let tone = tag.urgency.presentation.tone
            let disc = Circle().path(in: CGRect(x: centre.x - 8, y: centre.y - 8, width: 16, height: 16))
            context.fill(disc, with: .color(tone.tint.color))
            var icon = context.resolve(Image(systemName: tag.urgency.presentation.systemImage))
            icon.shading = .color(tone.foreground.color)
            context.draw(icon, in: CGRect(x: centre.x - 5, y: centre.y - 5, width: 10, height: 10))
        }
    }

    private func drawTree(
        _ tree: MapLayers.TreeMarker, at centre: CGPoint, metresPerPoint: Double, in context: inout GraphicsContext
    ) {
        func circle(_ radius: CGFloat) -> Path {
            Circle().path(in: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
        }
        let colour = tree.status.presentation.tone.foreground.color
        if selection == tree.id {
            context.fill(circle(15), with: .color(colour.opacity(0.2)))
        }
        switch tree.symbol {
        case .faintDot:
            // About 4 m across on the ground, so a zoomed-out grove does not hide the canopy under it.
            context.fill(
                circle((2 / metresPerPoint).clamped(to: 2...4)), with: .color(Color.canopyLineStrong.opacity(0.8)))
        case .dashedRing:
            context.stroke(circle(6), with: .color(colour), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
        case .ring:
            context.stroke(circle(6), with: .color(colour), lineWidth: 2.5)
        case .solid:
            context.fill(circle(7), with: .color(colour))
            context.stroke(circle(7), with: .color(Color.canopyCard), lineWidth: 1.5)
        case .hidden:
            break
        }
    }
}

/// The canopy raster as an image: transparent below 2 m, then light to deep green up to 40 m.
enum CanopyImage {
    static func make(_ raster: MapLayers.Reference.Raster) -> CGImage? {
        guard raster.nx > 0, raster.ny > 0, raster.heights.count == raster.nx * raster.ny else { return nil }
        var pixels = [UInt8](repeating: 0, count: raster.nx * raster.ny * 4)
        for j in 0..<raster.ny {
            // Image rows run from the top (north); raster rows from the south.
            let row = raster.ny - 1 - j
            for i in 0..<raster.nx {
                let h = raster.heights[j * raster.nx + i]
                guard h >= 2 else { continue }
                let t = Double(min(1, (h - 2) / 38))
                let alpha = 0.85
                let k = (row * raster.nx + i) * 4
                // Premultiplied RGBA.
                pixels[k] = UInt8((0.78 - 0.68 * t) * alpha * 255)
                pixels[k + 1] = UInt8((0.90 - 0.55 * t) * alpha * 255)
                pixels[k + 2] = UInt8((0.62 - 0.47 * t) * alpha * 255)
                pixels[k + 3] = UInt8(alpha * 255)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: raster.nx, height: raster.ny, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: raster.nx * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A scale bar a round number of metres long.
struct ScaleBar: View {
    let metresPerPoint: Double
    private let format = QuantityFormat()

    var body: some View {
        // The largest 1, 2 or 5 × 10ⁿ metres that fits in 100 points.
        let target = metresPerPoint * 100
        let magnitude = pow(10, floor(log10(target)))
        let metres = [5, 2, 1].map { $0 * magnitude }.first { $0 <= target } ?? magnitude
        VStack(alignment: .leading, spacing: 2) {
            Text(format.length(metres, fractionDigits: metres < 1 ? 1 : 0))
                .font(CanopyFont.mono(.caption2))
            Rectangle().frame(width: metres / metresPerPoint, height: 3)
        }
        .foregroundStyle(Color.canopyInk)
        .padding(Spacing.xxs)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
        .accessibilityHidden(true)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(range.upperBound, Swift.max(range.lowerBound, self))
    }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}
