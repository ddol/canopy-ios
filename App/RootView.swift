import SwiftUI

/// The tab shell: Map · Census · Proposals · Me, plus Tag when limb tagging is switched on (`Features`). Proposals is
/// badged with the other players' changes waiting for this player. On iPad the tabs adapt to a sidebar.
struct RootView: View {
    enum Section: Hashable {
        case map
        case census
        case tag
        case proposals
        case me
    }

    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.section) {
            Tab("Map", systemImage: "map", value: Section.map) {
                MapScreen()
            }
            Tab("Census", systemImage: "tree", value: Section.census) {
                CensusScreen()
            }
            if Features.limbTagging {
                Tab("Tag", systemImage: "exclamationmark.triangle", value: Section.tag) {
                    TagScreen()
                }
            }
            Tab("Proposals", systemImage: "checklist", value: Section.proposals) {
                ProposalsScreen()
            }
            .badge(model.proposalsAwaitingPlayer)
            Tab("Me", systemImage: "person.crop.circle", value: Section.me) {
                MeScreen()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } }),
            presenting: model.error
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }
}

#Preview {
    RootView()
        .environment(AppModel.live(arguments: ["-ui-testing"]))
}
