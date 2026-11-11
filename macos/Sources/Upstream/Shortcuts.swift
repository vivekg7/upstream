import SwiftUI

/// Every keyboard shortcut in the app, in one table. The menus bind theirs
/// from here and Help → Keyboard Shortcuts lists the table, so the page
/// cannot fall out of step with the menus
/// (docs/plans/010_keyboard_and_help.md). The letters are GitHub Desktop's
/// wherever it has one.
struct Shortcut: Identifiable {
    let name: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let group: Group
    /// For a row that stands for more than one key, such as ↑ ↓.
    var keys: String?

    var id: String { name }

    enum Group: String, CaseIterable {
        case repositories = "Repositories"
        case view = "View"
        case moving = "Moving Around"
        case changes = "Changes"
        case branches = "Branches"
        case app = "Upstream"
    }

    /// As the menus write it: modifiers in Apple's order, then the key.
    var label: String {
        if let keys { return keys }
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.glyph(key)
    }

    private static func glyph(_ key: KeyEquivalent) -> String {
        switch key {
        case .return: "↩"
        case .space: "Space"
        case .tab: "⇥"
        case .escape: "⎋"
        case .leftArrow: "←"
        case .rightArrow: "→"
        case .upArrow: "↑"
        case .downArrow: "↓"
        default: String(key.character).uppercased()
        }
    }

    static let all: [Shortcut] = [
        newRepository, addLocalRepository, cloneRepository, openInEditor, openInTerminal, showInFinder,
        showChanges, showHistory, filterRepositories, refresh,
        moveRows, nextColumn, previousColumn, intoMatches, nextField,
        toggleChecked, commit,
        showBranches, newBranch, renameBranch, stash, merge, squashMerge, rebase, fetch, pull, push,
        createPullRequest,
        settings, help, keyboardShortcuts,
    ]

    // MARK: Repositories

    static let newRepository = Shortcut("New Repository…", "n", .command, .repositories)
    static let addLocalRepository = Shortcut("Add Local Repository…", "o", .command, .repositories)
    static let cloneRepository = Shortcut("Clone Repository…", "o", [.command, .shift], .repositories)
    static let openInEditor = Shortcut("Open in Editor", "a", [.command, .shift], .repositories)
    static let openInTerminal = Shortcut("Open in Terminal", "`", .control, .repositories)
    static let showInFinder = Shortcut("Show in Finder", "f", [.command, .shift], .repositories)

    // MARK: View

    static let showChanges = Shortcut("Show Changes", "1", .command, .view)
    static let showHistory = Shortcut("Show History", "2", .command, .view)
    static let filterRepositories = Shortcut("Filter Repositories", "t", .command, .view)
    static let refresh = Shortcut("Refresh", "r", .command, .view)

    // MARK: Moving around: handled by the lists themselves, listed only.

    static let moveRows = Shortcut(
        "Previous or next repository, file or commit", .downArrow, [], .moving, keys: "↑ ↓")
    static let nextColumn = Shortcut("Into the next column", .rightArrow, [], .moving)
    static let previousColumn = Shortcut("Back to the previous column", .leftArrow, [], .moving)
    /// The search field's own: Return does nothing there.
    static let intoMatches = Shortcut("From the filter into its matches", .downArrow, [], .moving)
    static let nextField = Shortcut("Next or previous field", .tab, [], .moving, keys: "⇥  ⇧⇥")

    // MARK: Changes

    static let toggleChecked = Shortcut("Check or uncheck the selected files", .space, [], .changes)
    static let commit = Shortcut("Commit, or continue a merge or rebase", .return, .command, .changes)

    // MARK: Branches

    static let showBranches = Shortcut("Show Branches", "b", .command, .branches)
    static let newBranch = Shortcut("New Branch…", "n", [.command, .shift], .branches)
    static let renameBranch = Shortcut("Rename Branch…", "r", [.command, .shift], .branches)
    static let stash = Shortcut("Stash All Changes", "s", [.command, .shift], .branches)
    static let merge = Shortcut("Merge into Current Branch…", "m", [.command, .shift], .branches)
    static let squashMerge = Shortcut(
        "Squash and Merge into Current Branch…", "m", [.command, .shift, .option], .branches)
    static let rebase = Shortcut("Rebase Current Branch…", "e", [.command, .shift], .branches)
    static let fetch = Shortcut("Fetch", "t", [.command, .shift], .branches)
    static let pull = Shortcut("Pull", "p", [.command, .shift], .branches)
    static let push = Shortcut("Push, or Publish Branch", "p", .command, .branches)
    /// Not GitHub Desktop's ⌘R, which is Refresh here.
    static let createPullRequest = Shortcut("Create Pull Request", "r", [.command, .option], .branches)

    // MARK: Upstream

    /// SwiftUI's own, for the Settings scene; listed only.
    static let settings = Shortcut("Settings…", ",", .command, .app)
    /// Shown as ⌘?, as Apple's apps show theirs, though macOS takes ⇧⌘/
    /// first to open the Help menu's search, where this is the top item.
    static let help = Shortcut("Upstream Help", "?", .command, .app)
    static let keyboardShortcuts = Shortcut("Keyboard Shortcuts", "/", .command, .app)

    init(
        _ name: String, _ key: KeyEquivalent, _ modifiers: EventModifiers, _ group: Group,
        keys: String? = nil
    ) {
        self.name = name
        self.key = key
        self.modifiers = modifiers
        self.group = group
        self.keys = keys
    }
}

extension View {
    func keyboardShortcut(_ shortcut: Shortcut) -> some View {
        keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
    }
}
