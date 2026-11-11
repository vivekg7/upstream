import SwiftUI

/// Help → Upstream Help and Keyboard Shortcuts: one window of topics, drawn
/// by the app rather than an Apple Help book, so it needs no HTML, no
/// index and no Help Viewer, and opens at once, offline
/// (docs/plans/010_keyboard_and_help.md).
struct HelpView: View {
    static let windowID = "help"
    @Environment(HelpModel.self) private var help
    /// The topics take the keyboard when the window opens, so ↑ and ↓
    /// page through them at once.
    @FocusState private var topicsFocused: Bool

    var body: some View {
        @Bindable var help = help
        NavigationSplitView {
            List(HelpTopic.allCases, selection: $help.topic) { topic in
                Label(topic.title, systemImage: topic.symbol)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .focused($topicsFocused)
            // A turn later: set in onAppear itself, the list was not yet able to take it.
            .onAppear { Task { topicsFocused = true } }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let topic = help.topic {
                        Text(topic.title).font(.title.bold())
                        if topic == .shortcuts {
                            ShortcutsPage()
                        } else {
                            ForEach(Array(topic.paragraphs.enumerated()), id: \.offset) { _, text in
                                Paragraph(text: text)
                            }
                        }
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: 620, alignment: .leading)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("Upstream Help")
    }
}

/// Which topic the help window shows: the Help menu sets it before opening
/// the window, so Keyboard Shortcuts opens on its own page.
@MainActor @Observable final class HelpModel {
    var topic: HelpTopic? = .gettingStarted
}

/// The Help menu, in place of SwiftUI's "Help isn't available" item.
struct HelpCommands: Commands {
    let help: HelpModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button(Shortcut.help.name) {
                // Back to the topics, unless a topic is already open.
                if help.topic == nil || help.topic == .shortcuts { help.topic = .gettingStarted }
                openWindow(id: HelpView.windowID)
            }
            .keyboardShortcut(Shortcut.help)
            Button(Shortcut.keyboardShortcuts.name) {
                help.topic = .shortcuts
                openWindow(id: HelpView.windowID)
            }
            .keyboardShortcut(Shortcut.keyboardShortcuts)
        }
    }
}

/// A paragraph of inline Markdown; one starting "- " is a bullet.
private struct Paragraph: View {
    let text: String

    var body: some View {
        if text.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(LocalizedStringKey(String(text.dropFirst(2))))
            }
            .padding(.leading, 4)
        } else {
            Text(LocalizedStringKey(text))
        }
    }
}

/// The whole shortcut table, a section per menu.
private struct ShortcutsPage: View {
    var body: some View {
        Text(
            "Menu items show their shortcut beside them too. The arrow keys and Space work in the lists."
        )
        .foregroundStyle(.secondary)
        ForEach(Shortcut.Group.allCases, id: \.self) { group in
            Text(group.rawValue).font(.headline).padding(.top, 6)
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                ForEach(Shortcut.all.filter { $0.group == group }) { shortcut in
                    GridRow {
                        Text(shortcut.label)
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 70, alignment: .trailing)
                        Text(shortcut.name)
                    }
                }
            }
        }
    }
}

enum HelpTopic: String, CaseIterable, Identifiable {
    case gettingStarted, changes, history, branches, remotes, conflicts, pullRequests, settings, shortcuts

    var id: Self { self }

    var title: String {
        switch self {
        case .gettingStarted: "Getting Started"
        case .changes: "Committing Changes"
        case .history: "History"
        case .branches: "Branches"
        case .remotes: "Fetch, Pull and Push"
        case .conflicts: "Conflicts"
        case .pullRequests: "Pull Requests and CI"
        case .settings: "Settings"
        case .shortcuts: "Keyboard Shortcuts"
        }
    }

    var symbol: String {
        switch self {
        case .gettingStarted: "star"
        case .changes: "checkmark.square"
        case .history: "clock"
        case .branches: "arrow.triangle.branch"
        case .remotes: "arrow.up.arrow.down"
        case .conflicts: "exclamationmark.triangle"
        case .pullRequests: "arrow.triangle.pull"
        case .settings: "gearshape"
        case .shortcuts: "keyboard"
        }
    }

    /// The topic's text, in the words of docs/REQUIREMENTS.md. Shortcuts
    /// come from the table, so a changed key changes here too.
    var paragraphs: [String] {
        typealias S = Shortcut
        switch self {
        case .gettingStarted:
            return [
                """
                Upstream is a git client. Everything it does runs your own `git`, so a terminal \
                opened on the same repository always shows what Upstream shows.
                """,
                "**Add a repository** from the File menu, or the **+** at the bottom of the sidebar:",
                "- **Add Local Repository…** (\(S.addLocalRepository.label)) for a folder already on this Mac.",
                "- **Clone Repository…** (\(S.cloneRepository.label)) from a URL, or from your account's repositories.",
                "- **New Repository…** (\(S.newRepository.label)) to start one, with a README, `.gitignore` and licence if you like.",
                """
                The sidebar groups repositories by owner, read from each one's remote, \
                with the three you opened last under **Recent**. Hover over a section's \
                header and click its arrow to collapse it. **Filter Repositories** \
                (\(S.filterRepositories.label)) to find one by name, then ↓ to open the first \
                match. A folder with a lock is private on the forge you signed in to.
                """,
                """
                A folder that has moved or gone shows a warning: right-click it to **Locate…** it \
                or **Remove from List**. Removing never touches the folder.
                """,
                """
                Right-click a repository, or use the Repository menu, to open it in your editor \
                (\(S.openInEditor.label)), terminal (\(S.openInTerminal.label)) or Finder \
                (\(S.showInFinder.label)).
                """,
            ]
        case .changes:
            return [
                """
                **Changes** (\(S.showChanges.label)) lists every changed file, with the selected \
                file's diff beside it.
                """,
                """
                **The checkboxes choose what is committed.** New changes start checked. If you \
                staged something in a terminal, exactly that starts checked instead. Space checks \
                or unchecks the selected files.
                """,
                """
                **Part of a file:** click a line's number in the diff to check or uncheck that \
                line, or a hunk's header for the whole hunk. This works in the split view too, but \
                not while whitespace is hidden, since that diff is not the one committed.
                """,
                """
                Write a summary, and a description if you like, then **Commit** \
                (\(S.commit.label)). **Amend last commit** replaces the previous commit, with a \
                warning if it is already pushed. Add co-authors with the person button.
                """,
                """
                **Discard** a file or some lines from the right-click menu. What you discard goes \
                to the **Trash**, so it can be got back.
                """,
                """
                **Ignore** an untracked file, or every file with its extension, from the \
                right-click menu. Upstream adds it to the top-level `.gitignore`.
                """,
                """
                **Stash** (\(S.stash.label)) puts your changes aside on this branch. They wait \
                under the changes until you **Restore** or discard them. Upstream also offers to \
                stash when you switch branches with changes.
                """,
                "The list follows the files on its own: there is no need to refresh.",
            ]
        case .history:
            return [
                """
                **History** (\(S.showHistory.label)) lists the current branch's commits. Select one \
                to see its files and their diffs. Commits not pushed yet are marked, and tags and \
                branches show on the commit they point at.
                """,
                "Right-click a commit to:",
                "- create a branch or a tag from it,",
                "- revert it, or cherry-pick it from another branch,",
                "- reset the branch to it, after confirming. Your changes stay in the working tree.",
                "- copy its SHA, or view it on the web.",
                """
                **Undo Commit** takes back the last commit while it is not pushed: its changes \
                come back checked, and its message back into the commit fields.
                """,
                """
                **Compare…** shows another branch beside this one: **Behind**, its commits this \
                branch lacks, and **Ahead**, this branch's commits it lacks.
                """,
            ]
        case .branches:
            return [
                """
                The current branch is in the toolbar, with how far it is ahead (↑) and behind (↓) \
                its upstream. Click it, or **Show Branches** (\(S.showBranches.label)), to switch, \
                create, rename or delete branches.
                """,
                """
                **Merge** (\(S.merge.label)), **Squash and Merge** (\(S.squashMerge.label)) and \
                **Rebase** (\(S.rebase.label)) say before they start whether they will conflict.
                """,
                """
                Switching with uncommitted changes asks whether to leave them on this branch or \
                bring them along.
                """,
            ]
        case .remotes:
            return [
                """
                **Fetch** (\(S.fetch.label)), **Pull** (\(S.pull.label)) and **Push** \
                (\(S.push.label)) are in the toolbar and the Branch menu. Pull follows your \
                `pull.rebase` setting. A branch that is not on the remote yet is published by the \
                same Push.
                """,
                """
                While Upstream is in front, it fetches the selected repository every five \
                minutes. In the background it fetches nothing.
                """,
                """
                After an amend or a rebase, a **force push** asks first, and refuses if someone \
                else pushed since your last fetch (`--force-with-lease --force-if-includes`).
                """,
                """
                SSH and HTTPS remotes work through your own keys and credential helpers, on any \
                host.
                """,
            ]
        case .conflicts:
            return [
                """
                When a merge, rebase, cherry-pick or revert stops on conflicts, a banner above the \
                changes says so and counts what is left.
                """,
                """
                Right-click a conflicted file to use the version from one branch, mark it \
                resolved, or open it in your editor. When none are left, **Continue** \
                (\(S.commit.label)), or **Abort** from the banner.
                """,
                "What is staged is what continues. Other changes stay in the working tree.",
            ]
        case .pullRequests:
            return [
                """
                **Sign in** under Settings → Accounts, with your browser or a token. GitHub \
                Enterprise Server is signed in by its host. The token is kept in your Keychain.
                """,
                """
                Signed in, the toolbar lists the repository's open pull requests with their CI \
                state. **Check Out** works for pull requests from forks too.
                """,
                """
                The toolbar also shows the current branch's CI, with the failing checks listed \
                and a link to each. A notification says when its checks finish.
                """,
                """
                **Create Pull Request** (\(S.createPullRequest.label)) opens GitHub's own form in \
                your browser, with the branch filled in.
                """,
            ]
        case .settings:
            return [
                """
                **Settings** (\(S.settings.label)) holds your name and email (git's global \
                `user.name` and `user.email`), the default branch name, your editor and terminal, \
                where clones go, and which git to use. Appearance follows the system.
                """,
                """
                Upstream talks only to the forges you sign in to. It sends no telemetry, and \
                plain git works with every host without an account.
                """,
            ]
        case .shortcuts:
            return []
        }
    }
}
