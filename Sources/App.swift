import SwiftUI

@main
struct DiffusionStudioApp: App {
    var body: some Scene {
        WindowGroup("Diffusion Studio") {
            RootView()
        }
        .defaultSize(width: 1320, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}