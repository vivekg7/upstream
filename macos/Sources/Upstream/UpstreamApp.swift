import AppKit
import SwiftUI
import UpstreamKit

struct UpstreamApp: App {
    // The git chosen in Settings applies from the next launch.
    @State private var model = AppModel(
        git: Git.locate(preferred: UserDefaults.standard.string(forKey: SettingsKey.gitPath)))

    var body: some Scene {
        Window("Upstream", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 500)
                // The file watcher refreshes while the app is in front; in
                // the background it only notes that something changed
                // (docs/plans/004_refreshing_on_file_changes.md).
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                ) { _ in model.setActive(true) }
                .onReceive(
                    NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
                ) { _ in model.setActive(false) }
                // Launched behind another app (a login item, `open -g`), it
                // starts in the background rather than assuming the front.
                .onAppear { model.setActive(NSApp.isActive) }
        }
        .commands {
            RepositoryCommands(model: model)
            BranchCommands(model: model)
            CommandGroup(replacing: .newItem) {
                Button("Add Local Repository…") { addRepository() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
            }
        }
        Settings {
            SettingsView()
                .environment(model)
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
