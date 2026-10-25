import CanopyDesign
import SwiftUI

@main
struct CanopyApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CanopyFont.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .defaultAppStorage(model.preferences)
                .tint(.canopyBrand)
                .task {
                    if !AppModel.isTesting() {
                        model.players.authenticate()
                    }
                    await model.load()
                    model.syncSoon(after: .zero)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.syncSoon(after: .zero) }
                }
        }
    }
}
