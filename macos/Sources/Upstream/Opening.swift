import AppKit
import SwiftUI
import UpstreamKit

// Opening a repository, or a file in it, in another app
// (docs/plans/009_repositories_and_settings.md).

/// An editor or terminal, known by its bundle ID so it is found wherever it
/// is installed, and opened with the folder as a document, which every app
/// here takes as "open this folder".
struct ExternalApp: Identifiable, Hashable {
    let name: String
    let id: String

    var location: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) }

    static let editors = [
        ExternalApp(name: "Visual Studio Code", id: "com.microsoft.VSCode"),
        ExternalApp(name: "Visual Studio Code - Insiders", id: "com.microsoft.VSCodeInsiders"),
        ExternalApp(name: "VSCodium", id: "com.vscodium"),
        ExternalApp(name: "Cursor", id: "com.todesktop.230313mzl4w4u92"),
        ExternalApp(name: "Windsurf", id: "com.exafunction.windsurf"),
        ExternalApp(name: "Zed", id: "dev.zed.Zed"),
        ExternalApp(name: "Sublime Text", id: "com.sublimetext.4"),
        ExternalApp(name: "Xcode", id: "com.apple.dt.Xcode"),
        ExternalApp(name: "BBEdit", id: "com.barebones.bbedit"),
        ExternalApp(name: "Nova", id: "com.panic.Nova"),
        ExternalApp(name: "TextMate", id: "com.macromates.TextMate"),
        ExternalApp(name: "MacVim", id: "org.vim.MacVim"),
        ExternalApp(name: "IntelliJ IDEA", id: "com.jetbrains.intellij"),
        ExternalApp(name: "IntelliJ IDEA CE", id: "com.jetbrains.intellij.ce"),
        ExternalApp(name: "WebStorm", id: "com.jetbrains.WebStorm"),
        ExternalApp(name: "PyCharm", id: "com.jetbrains.pycharm"),
        ExternalApp(name: "PyCharm CE", id: "com.jetbrains.pycharm.ce"),
        ExternalApp(name: "GoLand", id: "com.jetbrains.goland"),
        ExternalApp(name: "CLion", id: "com.jetbrains.CLion"),
        ExternalApp(name: "RustRover", id: "com.jetbrains.rustrover"),
        ExternalApp(name: "PhpStorm", id: "com.jetbrains.PhpStorm"),
        ExternalApp(name: "RubyMine", id: "com.jetbrains.rubymine"),
        ExternalApp(name: "Rider", id: "com.jetbrains.rider"),
        ExternalApp(name: "Android Studio", id: "com.google.android.studio"),
    ]

    static let terminals = [
        ExternalApp(name: "Terminal", id: "com.apple.Terminal"),
        ExternalApp(name: "iTerm2", id: "com.googlecode.iterm2"),
        ExternalApp(name: "Ghostty", id: "com.mitchellh.ghostty"),
        ExternalApp(name: "Warp", id: "dev.warp.Warp-Stable"),
        ExternalApp(name: "kitty", id: "net.kovidgoyal.kitty"),
        ExternalApp(name: "WezTerm", id: "com.github.wez.wezterm"),
    ]

    static func installed(_ apps: [ExternalApp]) -> [ExternalApp] { apps.filter { $0.location != nil } }

    /// The one chosen in Settings under `key`, if it is still installed;
    /// otherwise the first installed, as GitHub Desktop picks an editor.
    static func chosen(_ apps: [ExternalApp], id: String?) -> ExternalApp? {
        let installed = installed(apps)
        return installed.first { $0.id == id } ?? installed.first
    }

    static var editor: ExternalApp? {
        chosen(editors, id: UserDefaults.standard.string(forKey: SettingsKey.editor))
    }
    static var terminal: ExternalApp? {
        chosen(terminals, id: UserDefaults.standard.string(forKey: SettingsKey.terminal))
    }
}

/// The `UserDefaults` keys of Settings → General.
enum SettingsKey {
    static let editor = "editor"
    static let terminal = "terminal"
    static let cloneFolder = "cloneFolder"
    /// Read by `UpstreamApp` at launch and passed to `Git.locate(preferred:)`.
    static let gitPath = "gitPath"
}

/// Where new clones and repositories go unless the user picks another
/// folder. `~/Developer` rather than GitHub Desktop's `~/Documents/GitHub`:
/// Finder gives it its own icon, it names no forge, and it is outside
/// Documents, which iCloud may sync.
var cloneFolder: URL {
    let saved = UserDefaults.standard.string(forKey: SettingsKey.cloneFolder) ?? ""
    return saved.isEmpty
        ? FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Developer", directoryHint: .isDirectory)
        : URL(fileURLWithPath: saved)
}

/// Opens a repository or a file in the editor chosen in Settings, or in
/// the file's default app when no known editor is installed.
@MainActor func openInEditor(_ url: URL) {
    open(url, with: ExternalApp.editor)
}

/// Opens a repository's folder in the terminal chosen in Settings.
@MainActor func openInTerminal(_ url: URL) {
    open(url, with: ExternalApp.terminal)
}

/// Opens a repository's folder in Finder; `open` would launch a folder
/// that happens to be a package instead.
@MainActor func showInFinder(_ url: URL) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
}

@MainActor private func open(_ url: URL, with app: ExternalApp?) {
    guard let location = app?.location else {
        NSWorkspace.shared.open(url)
        return
    }
    NSWorkspace.shared.open([url], withApplicationAt: location, configuration: .init()) { _, error in
        guard let message = error?.localizedDescription else { return }
        Task { @MainActor in
            let alert = NSAlert()
            alert.messageText = "Could not open \(url.lastPathComponent) in \(app?.name ?? "the app")"
            alert.informativeText = message
            alert.runModal()
        }
    }
}

/// A folder chosen in an open panel, or nil if the user cancelled.
@MainActor func chooseFolder(prompt: String, startingAt start: URL? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = prompt
    panel.directoryURL = start
    return panel.runModal() == .OK ? panel.url : nil
}

/// File → New Repository and Clone Repository, and the Repository menu with
/// GitHub Desktop's shortcuts.
struct RepositoryCommands: Commands {
    let model: AppModel
    // Read here so the menu's names follow a change in Settings.
    @AppStorage(SettingsKey.editor) private var editor = ""
    @AppStorage(SettingsKey.terminal) private var terminal = ""

    var body: some Commands {
        CommandGroup(before: .newItem) {
            Button("New Repository…") { model.library.sheet = .create }
                .keyboardShortcut("n")
        }
        CommandGroup(after: .newItem) {
            Button("Clone Repository…") { model.library.sheet = .clone }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandMenu("Repository") {
            Group {
                Button("Open in \(ExternalApp.chosen(ExternalApp.editors, id: editor)?.name ?? "Editor")") {
                    model.selected.map(openInEditor)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                Button(
                    "Open in \(ExternalApp.chosen(ExternalApp.terminals, id: terminal)?.name ?? "Terminal")"
                ) {
                    model.selected.map(openInTerminal)
                }
                .keyboardShortcut("`", modifiers: .control)
                Button("Show in Finder") { model.selected.map(showInFinder) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            .disabled(model.selected.map { model.library.missing.contains($0) } ?? true)
            Divider()
            PublishRepositoryButton(model: model)
        }
    }
}
