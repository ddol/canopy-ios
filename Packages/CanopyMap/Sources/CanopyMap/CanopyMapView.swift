import CanopyModel
import SwiftUI

/// Draws `MapLayers`. The MapKit renderer is the only one today; a MapLibre Native renderer (with offline
/// PMTiles) can implement the same protocol later without changing the screens.
@MainActor
public protocol MapRenderer {
    associatedtype Body: View

    func makeBody(layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport) -> Body
}

/// The park map. Pick a renderer, or use the MapKit default.
public struct CanopyMapView<Renderer: MapRenderer>: View {
    private let renderer: Renderer
    private let layers: MapLayers
    private let viewport: MapViewport
    @Binding private var selection: UUID?

    public init(
        renderer: Renderer,
        layers: MapLayers,
        selection: Binding<UUID?>,
        viewport: MapViewport = .goldenGatePark
    ) {
        self.renderer = renderer
        self.layers = layers
        self.viewport = viewport
        self._selection = selection
    }

    public var body: some View {
        renderer.makeBody(layers: layers, selection: $selection, viewport: viewport)
    }
}

extension CanopyMapView where Renderer == MapKitRenderer {
    public init(layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport = .goldenGatePark) {
        self.init(renderer: MapKitRenderer(), layers: layers, selection: selection, viewport: viewport)
    }
}
