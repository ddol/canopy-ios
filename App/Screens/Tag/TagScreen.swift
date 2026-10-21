import SwiftUI

struct TagScreen: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Tag", systemImage: "exclamationmark.triangle", description: Text("Tag limb hazards on a tree.")
            )
            .navigationTitle("Tag")
        }
    }
}

#Preview {
    TagScreen()
}
