import AppKit
import SwiftUI
import UpstreamKit

@main
struct UpstreamApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Upstream", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 480)
                // Coming back from the editor or a terminal is when the tree
                // has changed. A file watcher replaces this later (plan 001).
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) {
                    _ in
                    Task { await model.refresh() }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Local Repository…") { addRepository() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }

    @MainActor private func addRepository() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add Repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.add(url) }
    }
}
