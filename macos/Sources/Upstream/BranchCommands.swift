import SwiftUI
import UpstreamKit

/// The Branch menu, with GitHub Desktop's shortcuts
/// (docs/plans/005_branches_and_remotes.md).
struct BranchCommands: Commands {
    let model: AppModel

    var body: some Commands {
        let branches = model.branches
        let ready = model.selected != nil && model.activity == nil
        let current = branches.current
        CommandMenu("Branch") {
            Button("Show Branches") { branches.showsList = true }
                .keyboardShortcut(Shortcut.showBranches)
                .disabled(model.status == nil)
            Button("New Branch…") { branches.sheet = .create(from: nil) }
                .keyboardShortcut(Shortcut.newBranch)
                .disabled(!ready || !model.hasHead)
            Button("Rename…") { if let current { branches.sheet = .rename(current) } }
                .keyboardShortcut(Shortcut.renameBranch)
                .disabled(!ready || current == nil)
            Divider()
            Button("Stash All Changes") { Task { await branches.stashChanges() } }
                .keyboardShortcut(Shortcut.stash)
                .disabled(!ready || current == nil || model.status?.files.isEmpty != false)
            Divider()
            Button("Merge into Current Branch…") { branches.sheet = .merge(.merge, nil) }
                .keyboardShortcut(Shortcut.merge)
                .disabled(!ready || !model.hasHead)
            Button("Squash and Merge into Current Branch…") { branches.sheet = .merge(.squash, nil) }
                .keyboardShortcut(Shortcut.squashMerge)
                .disabled(!ready || !model.hasHead)
            Button("Rebase Current Branch…") { branches.sheet = .merge(.rebase, nil) }
                .keyboardShortcut(Shortcut.rebase)
                .disabled(!ready || current == nil)
            Divider()
            Button("Fetch") { Task { await branches.fetch() } }
                .keyboardShortcut(Shortcut.fetch)
                .disabled(!ready || branches.fetchRemote == nil)
            Button("Pull") { Task { await branches.pull() } }
                .keyboardShortcut(Shortcut.pull)
                .disabled(!ready || current?.upstreamRemote == nil || current?.upstreamGone == true)
            Button(branches.action == .publish ? "Publish Branch" : "Push") { push() }
                .keyboardShortcut(Shortcut.push)
                .disabled(!ready || !(branches.action == .publish || (model.status?.branch.ahead ?? 0) > 0))
            Divider()
            CreatePullRequestButton(model: model)
        }
    }

    /// ⌘P publishes a branch that has no upstream, as GitHub Desktop's does.
    private func push() {
        let branches = model.branches
        if branches.action == .publish {
            if let remote = branches.publishRemote {
                Task { await branches.publish(to: remote) }
            } else {
                branches.sheet = .publish
            }
        } else if branches.action == .forcePush {
            branches.sheet = .forcePush
        } else {
            Task { await branches.push() }
        }
    }
}
