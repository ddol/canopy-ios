import CanopyModel
import SwiftUI

/// Draws `MapLayers`. The MapKit renderer is the only one today; a MapLibre Native renderer (with offline
/// PMTiles) can implement the same protocol later without changing the screens.
@MainActor
public protocol MapRenderer {
    associatedtype Body: View

    /// - Parameter onViewportChange: called with the visible region when the map stops moving.
    func makeBody(
        layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport,
        onViewportChange: @escaping @MainActor (MapViewport) -> Void
    ) -> Body
}

/// The park map. Pick a renderer, or use the MapKit default.
public struct CanopyMapView<Renderer: MapRenderer>: View {
    private let renderer: Renderer
    private let layers: MapLayers
    private let viewport: MapViewport
    private var onViewportChange: @MainActor (MapViewport) -> Void = { _ in }
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
        renderer.makeBody(layers: layers, selection: $selection, viewport: viewport, onViewportChange: onViewportChange)
    }

    /// Calls `action` with the visible region whenever the map stops moving (and once when it first appears).
    public func onViewportChange(_ action: @escaping @MainActor (MapViewport) -> Void) -> Self {
        var copy = self
        copy.onViewportChange = action
        return copy
    }
}

extension CanopyMapView where Renderer == MapKitRenderer {
    public init(layers: MapLayers, selection: Binding<UUID?>, viewport: MapViewport = .goldenGatePark) {
        self.init(renderer: MapKitRenderer(), layers: layers, selection: selection, viewport: viewport)
    }
}
