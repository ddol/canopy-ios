import CanopyDesign
import SwiftUI

@main
struct CanopyApp: App {
    @State private var model = AppModel.live()

    init() {
        CanopyFont.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(.canopyBrand)
                .task {
                    if !AppModel.isUITesting() {
                        model.players.authenticate()
                    }
                    await model.load()
                }
        }
    }
}
