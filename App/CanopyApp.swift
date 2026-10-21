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
                .task { await model.load() }
        }
    }
}
