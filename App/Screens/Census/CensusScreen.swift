import SwiftUI

struct CensusScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Census", systemImage: "tree", description: Text("Confirm trees and measure trunks.")
            )
            .navigationTitle("Census")
        }
    }
}

#Preview {
    CensusScreen()
}
