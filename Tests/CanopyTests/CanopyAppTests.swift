import Testing

@testable import Canopy

@MainActor
@Test func rootViewStartsOnMap() {
    _ = RootView()
}
