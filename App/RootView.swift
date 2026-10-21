import SwiftUI

/// The tab shell: Map · Census · Tag · Me. On iPad the tabs adapt to a sidebar.
struct RootView: View {
    enum Section: Hashable {
        case map
        case census
        case tag
        case me
    }

    @State private var selection: Section = .map

    var body: some View {
        TabView(selection: $selection) {
            Tab("Map", systemImage: "map", value: Section.map) {
                MapScreen()
            }
            Tab("Census", systemImage: "tree", value: Section.census) {
                CensusScreen()
            }
            Tab("Tag", systemImage: "exclamationmark.triangle", value: Section.tag) {
                TagScreen()
            }
            Tab("Me", systemImage: "person.crop.circle", value: Section.me) {
                MeScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}

#Preview {
    RootView()
}
