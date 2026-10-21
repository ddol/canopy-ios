import SwiftUI

struct MeScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Me", systemImage: "person.crop.circle", description: Text("Sign in and see your pending changes.")
            )
            .navigationTitle("Me")
        }
    }
}

#Preview {
    MeScreen()
}
