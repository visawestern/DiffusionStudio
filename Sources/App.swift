import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            EngineRegistry.shared.shutdown()
        }
    }
}

@main
struct DiffusionStudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

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