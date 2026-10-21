import SwiftUI

struct MapScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Map", systemImage: "map", description: Text("The park map with tree candidates."))
                .navigationTitle("Map")
        }
    }
}

#Preview {
    MapScreen()
}
