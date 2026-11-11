import AppKit
import SwiftUI
import UpstreamKit

struct UpstreamApp: App {
    // The git chosen in Settings applies from the next launch.
    @State private var model = AppModel(
        git: Git.locate(preferred: UserDefaults.standard.string(forKey: SettingsKey.gitPath)))
    @State private var help = HelpModel()

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
            ViewCommands(model: model)
            HelpCommands(help: help)
            CommandGroup(replacing: .newItem) {
                Button(Shortcut.addLocalRepository.name) { addRepository() }
                    .keyboardShortcut(Shortcut.addLocalRepository)
            }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
        Window("Upstream Help", id: HelpView.windowID) {
            HelpView()
                .environment(help)
                .frame(minWidth: 560, minHeight: 360)
        }
        .defaultSize(width: 780, height: 560)
        // Opened from the Help menu only: never at launch, nor restored.
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
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
