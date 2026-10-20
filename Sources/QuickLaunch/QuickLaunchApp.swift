import SwiftUI

@main
struct QuickLaunchApp: App {
    var body: some Scene {
        MenuBarExtra("QuickLaunch", systemImage: "bolt.fill") {
            Button("Quit QuickLaunch") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
