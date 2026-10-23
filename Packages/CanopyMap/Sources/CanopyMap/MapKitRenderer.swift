import CanopyDesign
import CanopyModel
import MapKit
import SwiftUI

/// Renders the layers with MapKit for SwiftUI.
public struct MapKitRenderer: MapRenderer {
    public init() {}

    public func makeBody(
        layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport,
        onViewportChange: @escaping @MainActor (MapViewport) -> Void
    ) -> some View {
        MapKitMap(layers: layers, selection: selection, viewport: viewport, onViewportChange: onViewportChange)
    }
}

struct MapKitMap: View {
    let layers: MapLayers
    let onViewportChange: @MainActor (MapViewport) -> Void
    @Binding var selection: UUID?
    @State private var position: MapCameraPosition

    init(
        layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport,
        onViewportChange: @escaping @MainActor (MapViewport) -> Void
    ) {
        self.layers = layers
        self.onViewportChange = onViewportChange
        self._selection = selection
        self._position = State(initialValue: .region(MKCoordinateRegion(viewport)))
    }

    var body: some View {
        Map(position: $position, selection: $selection) {
            ForEach(Array(layers.boundary.enumerated()), id: \.offset) { _, ring in
                MapPolygon(coordinates: ring.map(CLLocationCoordinate2D.init))
                    .foregroundStyle(Color.canopyBrand.opacity(0.06))
                    .stroke(Color.canopyBrand.opacity(0.5), lineWidth: 1.5)
            }
            ForEach(layers.tiles) { tile in
                MapPolygon(coordinates: tile.corners.map(CLLocationCoordinate2D.init))
                    .foregroundStyle(.clear)
                    .stroke(Color.canopyLineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            ForEach(layers.routes) { route in
                MapPolyline(coordinates: route.points.map(CLLocationCoordinate2D.init))
                    .stroke(Color.canopyInkMuted, lineWidth: 3)
            }
            ForEach(layers.trees) { tree in
                Annotation("", coordinate: CLLocationCoordinate2D(tree.location), anchor: .center) {
                    TreeSymbolView(symbol: tree.symbol, status: tree.status, isSelected: selection == tree.id)
                        .accessibilityElement()
                        .accessibilityLabel("Tree, \(tree.status.presentation.label)")
                        .accessibilityIdentifier("tree-\(tree.id.uuidString)")
                        .accessibilityAddTraits(.isButton)
                }
                .annotationTitles(.hidden)
                .tag(tree.id)
            }
            ForEach(layers.tags) { tag in
                Annotation("", coordinate: CLLocationCoordinate2D(tag.location), anchor: .bottom) {
                    Image(systemName: tag.urgency.presentation.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tag.urgency.presentation.tone.foreground.color)
                        .padding(3)
                        .background(tag.urgency.presentation.tone.tint.color, in: Circle())
                        .accessibilityLabel("Hazard, \(tag.urgency.presentation.label)")
                }
                .annotationTitles(.hidden)
            }
            UserAnnotation()
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {
            MapUserLocationButton()
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            let region = context.region
            onViewportChange(
                MapViewport(
                    center: GeoPoint(latitude: region.center.latitude, longitude: region.center.longitude),
                    latitudeDelta: region.span.latitudeDelta, longitudeDelta: region.span.longitudeDelta))
        }
    }
}

/// The marker for one tree: faint dot, dashed ring, ring or solid dot.
public struct TreeSymbolView: View {
    public let symbol: TreeSymbol
    public let status: CountStatus
    public var isSelected = false

    public init(symbol: TreeSymbol, status: CountStatus, isSelected: Bool = false) {
        self.symbol = symbol
        self.status = status
        self.isSelected = isSelected
    }

    public var body: some View {
        let colour = status.presentation.tone.foreground.color
        ZStack {
            if isSelected {
                Circle().fill(colour.opacity(0.2)).frame(width: 30, height: 30)
            }
            switch symbol {
            case .faintDot:
                Circle().fill(Color.canopyLineStrong.opacity(0.55)).frame(width: 8, height: 8)
            case .dashedRing:
                Circle()
                    .strokeBorder(colour, style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
                    .frame(width: 14, height: 14)
            case .ring:
                Circle().strokeBorder(colour, lineWidth: 2.5).frame(width: 14, height: 14)
            case .solid:
                Circle().fill(colour).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(Color.canopyCard, lineWidth: 1.5))
            case .hidden:
                EmptyView()
            }
        }
        .frame(width: 30, height: 30)
        .contentShape(Circle())
    }
}

extension CLLocationCoordinate2D {
    init(_ point: GeoPoint) {
        self.init(latitude: point.latitude, longitude: point.longitude)
    }
}

extension MKCoordinateRegion {
    init(_ viewport: MapViewport) {
        self.init(
            center: CLLocationCoordinate2D(viewport.center),
            span: MKCoordinateSpan(latitudeDelta: viewport.latitudeDelta, longitudeDelta: viewport.longitudeDelta)
        )
    }
}
