import AppKit
import SwiftUI

@main
struct RenderPanel {
    @MainActor
    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let width = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 1320 : 1320
        let height = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 880 : 880
        let sidebar = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "sidebar"

        UserDefaults.standard.set(sidebar, forKey: "DiffusionStudio.logSidebar")

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let hosting = NSHostingView(rootView: RootView())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: height), display: true)

        for _ in 0..<10 {
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fail("ERR: нет bitmap")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fail("ERR: нет png")
            return
        }
        do {
            try png.write(to: out)
            print("OK: \(out.path) \(rep.pixelsWide)×\(rep.pixelsHigh)")
        } catch {
            fail("ERR: \(error)")
        }
    }

    static func fail(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}