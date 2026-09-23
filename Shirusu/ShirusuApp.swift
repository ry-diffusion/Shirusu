import SwiftUI

@main
struct ShirusuApp: App {
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .frame(minWidth: 720, minHeight: 440)
        }
        .defaultSize(width: 900, height: 600)
        Settings {
            ModelPreferencesView()
                .environment(app)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

    }
}
