import SwiftUI
import UpstreamKit

/// The current branch, and the menu to switch, create and merge, as GitHub
/// Desktop's "Current Branch" dropdown (docs/plans/005_branches_and_remotes.md).
struct BranchToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var branches = model.branches
        if let branch = model.status?.branch {
            Button {
                branches.showsList.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(branch.head ?? "Detached HEAD")
                    if branch.ahead > 0 { Text("↑\(branch.ahead)").monospacedDigit() }
                    if branch.behind > 0 { Text("↓\(branch.behind)").monospacedDigit() }
                    Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
            }
            .help(branch.upstream.map { "Tracking \($0)" } ?? "No upstream branch")
            .popover(isPresented: $branches.showsList, arrowEdge: .bottom) {
                BranchList().environment(model)
            }
        }
    }
}

/// The branches, filtered as the user types; choosing one switches to it.
private struct BranchList: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        let branches = model.branches
        let current = branches.current
        let local = branches.all.filter { !$0.isRemote && !$0.isHead && matches($0) }
            .sorted { $0.date > $1.date }
        // A remote branch already checked out locally is reached through the local one.
        let remote = branches.all.filter {
            $0.isRemote && branches.localBranch(for: $0) == nil && matches($0)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        VStack(spacing: 0) {
            HStack {
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                Button("New Branch") { open(.create(from: nil)) }
                    .disabled(!model.hasHead)
            }
            .padding(10)
            List {
                if let current, matches(current) {
                    Section("Current Branch") { BranchRow(branch: current) }
                }
                if !local.isEmpty {
                    Section("Local") { ForEach(local) { BranchRow(branch: $0) } }
                }
                if !remote.isEmpty {
                    Section("Remote") { ForEach(remote) { BranchRow(branch: $0) } }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if local.isEmpty && remote.isEmpty && current.map(matches) != true {
                    ContentUnavailableView.search(text: filter)
                }
            }
            Divider()
            HStack {
                Button("Merge into \(current?.name ?? "HEAD")…") { open(.merge(.merge, nil)) }
                    .disabled(!model.hasHead)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: 360, height: 460)
        .task { await branches.reload() }
    }

    private func matches(_ branch: Branch) -> Bool {
        filter.isEmpty || branch.name.localizedCaseInsensitiveContains(filter)
    }

    private func open(_ sheet: BranchSheet) {
        model.branches.showsList = false
        model.branches.sheet = sheet
    }
}

private struct BranchRow: View {
    @Environment(AppModel.self) private var model
    let branch: Branch

    var body: some View {
        let branches = model.branches
        Button(action: choose) {
            HStack(spacing: 8) {
                Image(
                    systemName: branch.isHead
                        ? "checkmark" : branch.isRemote ? "cloud" : "arrow.triangle.branch"
                )
                .frame(width: 16)
                .foregroundStyle(.secondary)
                Text(branch.name).lineLimit(1).truncationMode(.middle)
                Spacer()
                if let symbol = trackSymbol {
                    Image(systemName: symbol).foregroundStyle(.secondary).help(trackHelp)
                }
                Text(branch.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.activity != nil)
        .contextMenu {
            let current = branches.current?.name ?? "HEAD"
            if !branch.isHead {
                Button(branch.isRemote ? "Check Out" : "Switch to \(branch.name)", action: choose)
                Divider()
                Button("Merge into \(current)…") { open(.merge(.merge, branch)) }
                Button("Squash and Merge into \(current)…") { open(.merge(.squash, branch)) }
                Button("Rebase \(current) onto \(branch.name)…") { open(.merge(.rebase, branch)) }
                Divider()
            }
            Button("New Branch from \(branch.name)…") { open(.create(from: branch)) }
            if branch.isRemote {
                Button("Delete from \(branch.remote ?? "Remote")…") { open(.deleteRemote(branch)) }
            } else {
                Button("Rename…") { open(.rename(branch)) }
                Button("Delete…") { open(.delete(branch)) }
                    .disabled(branch.isHead)
            }
        }
    }

    private var trackSymbol: String? {
        if branch.upstreamGone { return "exclamationmark.icloud" }
        return switch branch.track {
        case .ahead: "arrow.up"
        case .behind: "arrow.down"
        case .diverged: "arrow.up.arrow.down"
        case .same, nil: nil
        }
    }

    private var trackHelp: String {
        let upstream = branch.upstream.map { $0.replacing("refs/remotes/", with: "") } ?? ""
        if branch.upstreamGone { return "\(upstream) is gone from its remote" }
        return switch branch.track {
        case .ahead: "Ahead of \(upstream)"
        case .behind: "Behind \(upstream)"
        case .diverged: "Diverged from \(upstream)"
        case .same, nil: ""
        }
    }

    /// With changes in the working tree, ask whether they come along, as
    /// GitHub Desktop does; without, switch at once.
    private func choose() {
        guard !branch.isHead else { return }
        if model.status?.files.isEmpty == false {
            open(.switching(to: branch))
        } else {
            Task { await model.branches.switchTo(branch) }
        }
    }

    private func open(_ sheet: BranchSheet) {
        model.branches.showsList = false
        model.branches.sheet = sheet
    }
}

/// Fetch, pull, push and publish, as GitHub Desktop's one button: it does
/// what the branch needs now, and its menu offers each explicitly.
struct RemoteToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let branches = model.branches
        if let action = branches.action {
            let branch = model.status?.branch
            let remote = branches.current?.upstreamRemote ?? branches.fetchRemote ?? "origin"
            let hasUpstream = branch?.upstream != nil && branches.current?.upstreamGone != true
            Menu {
                Section(lastFetched) {
                    Button("Fetch \(branches.fetchRemote ?? remote)") { Task { await branches.fetch() } }
                    Button("Pull \(remote)") { Task { await branches.pull() } }
                        .disabled(!hasUpstream)
                    Button("Push to \(remote)") { Task { await branches.push() } }
                        .disabled(!hasUpstream || branch?.ahead == 0)
                    if !hasUpstream {
                        Button("Publish Branch") { publish() }
                    }
                    if hasUpstream, let branch, branch.ahead > 0, branch.behind > 0 {
                        Button("Force Push to \(remote)…") { branches.sheet = .forcePush }
                    }
                }
            } label: {
                Label(title(action, remote), systemImage: symbol(action))
                    .labelStyle(.titleAndIcon)
            } primaryAction: {
                run(action)
            }
            .disabled(model.activity != nil || branches.isFetching)
            .help(
                branches.fetchError.map { "\(lastFetched)\nThe last background fetch failed: \($0)" }
                    ?? lastFetched)
        }
    }

    private var lastFetched: String {
        if model.branches.isFetching { return "Fetching…" }
        guard let date = model.branches.lastFetched else { return "Never fetched" }
        return "Last fetched \(date.formatted(.relative(presentation: .named)))"
    }

    private func title(_ action: RemoteAction, _ remote: String) -> String {
        let b = model.status?.branch
        return switch action {
        case .publish: "Publish Branch"
        case .pull: "Pull \(remote) ↓\(b?.behind ?? 0)"
        case .push: "Push \(remote) ↑\(b?.ahead ?? 0)"
        case .forcePush: "Force Push \(remote)"
        case .fetch: "Fetch \(model.branches.fetchRemote ?? remote)"
        }
    }

    private func symbol(_ action: RemoteAction) -> String {
        switch action {
        case .publish: "icloud.and.arrow.up"
        case .pull: "arrow.down"
        case .push: "arrow.up"
        case .forcePush: "exclamationmark.arrow.triangle.2.circlepath"
        case .fetch: "arrow.triangle.2.circlepath"
        }
    }

    private func run(_ action: RemoteAction) {
        let branches = model.branches
        switch action {
        case .publish: publish()
        case .pull: Task { await branches.pull() }
        case .push: Task { await branches.push() }
        case .forcePush: branches.sheet = .forcePush
        case .fetch: Task { await branches.fetch() }
        }
    }

    /// To origin, or the only remote; with several and no origin, ask.
    private func publish() {
        if let remote = model.branches.publishRemote {
            Task { await model.branches.publish(to: remote) }
        } else {
            model.branches.sheet = .publish
        }
    }
}

/// Every dialog the branch menu, the remote button, the stash row and the
/// menu bar open, attached to the window once.
struct BranchDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var branches = model.branches
        content.sheet(item: $branches.sheet) { sheet in
            Group {
                switch sheet {
                case .create(let from): CreateBranchSheet(from: from)
                case .rename(let branch): RenameBranchSheet(branch: branch)
                case .delete(let branch): DeleteBranchSheet(branch: branch)
                case .deleteRemote(let branch): DeleteRemoteBranchSheet(branch: branch)
                case .merge(let kind, let branch): MergeSheet(kind: kind, chosen: branch)
                case .switching(let branch): SwitchSheet(branch: branch)
                case .forcePush: ForcePushSheet()
                case .publish: PublishSheet()
                case .discardStash: DiscardStashSheet()
                }
            }
            .environment(model)
            .padding(20)
            .frame(width: 440)
        }
    }
}

/// A dialog's title, text, and Cancel beside its action.
private struct Dialog<Content: View>: View {
    @Environment(AppModel.self) private var model
    let title: String
    let action: String
    var destructive = false
    var disabled = false
    let perform: () async -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.branches.sheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action, role: destructive ? .destructive : nil) {
                    model.branches.sheet = nil
                    Task { await perform() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(disabled)
            }
        }
    }
}

/// Branch names cannot hold spaces; GitHub Desktop turns them into hyphens
/// as you type, and so does this. git checks the rest.
private func branchName(_ typed: String) -> String {
    typed.replacing(" ", with: "-")
}

private struct CreateBranchSheet: View {
    @Environment(AppModel.self) private var model
    let from: Branch?
    @State private var name = ""
    @State private var start: Branch.ID?

    var body: some View {
        let branches = model.branches
        let current = branches.current?.name ?? "HEAD"
        Dialog(
            title: "Create a Branch", action: "Create Branch", disabled: name.isEmpty,
            perform: {
                await branches.create(name, from: branches.all.first { $0.id == start && !$0.isHead })
            }
        ) {
            TextField("Name", text: Binding(get: { name }, set: { name = branchName($0) }))
                .textFieldStyle(.roundedBorder)
            Picker("Based on", selection: $start) {
                Text(current).tag(Branch.ID?.none)
                ForEach(branches.all.filter { !$0.isHead }) { Text($0.name).tag(Optional($0.id)) }
            }
            Text("Changes in the working tree come along to the new branch.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { start = from?.isHead == false ? from?.id : nil }
    }
}

private struct RenameBranchSheet: View {
    @Environment(AppModel.self) private var model
    let branch: Branch
    @State private var name = ""

    var body: some View {
        Dialog(
            title: "Rename \(branch.name)", action: "Rename", disabled: name.isEmpty || name == branch.name,
            perform: { await model.branches.rename(branch, to: name) }
        ) {
            TextField("Name", text: Binding(get: { name }, set: { name = branchName($0) }))
                .textFieldStyle(.roundedBorder)
            if let upstream = branch.upstream, !branch.upstreamGone {
                Text(
                    "It is published as \(upstream.replacing("refs/remotes/", with: "")). Renaming it here does not rename it there."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
        }
        .onAppear { name = branch.name }
    }
}

private struct DeleteBranchSheet: View {
    @Environment(AppModel.self) private var model
    let branch: Branch
    @State private var deletion: Deletion?
    @State private var alsoRemote = false

    var body: some View {
        let upstream = branch.upstreamGone ? nil : branch.upstream?.replacing("refs/remotes/", with: "")
        Dialog(
            title: "Delete \(branch.name)?", action: "Delete", destructive: true, disabled: deletion == nil,
            perform: {
                await model.branches.delete(
                    branch, force: (deletion?.unmerged ?? 0) > 0, alsoRemote: alsoRemote)
            }
        ) {
            if let deletion {
                if deletion.unmerged > 0 {
                    Label(
                        "\(branch.name) has \(deletion.unmerged == 1 ? "1 commit" : "\(deletion.unmerged) commits") that \(deletion.unmerged == 1 ? "is" : "are") not in \(deletion.into). Deleting it loses \(deletion.unmerged == 1 ? "it" : "them").",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                } else {
                    Text("All of its commits are in \(deletion.into), so none are lost.")
                }
            } else {
                ProgressView().controlSize(.small)
            }
            if let upstream {
                Toggle("Also delete \(upstream) on the remote, for everyone", isOn: $alsoRemote)
            }
        }
        .task { deletion = await model.branches.deletion(of: branch) }
    }
}

private struct DeleteRemoteBranchSheet: View {
    @Environment(AppModel.self) private var model
    let branch: Branch

    var body: some View {
        let remote = branch.remote ?? "the remote"
        Dialog(
            title: "Delete \(branch.nameOnRemote ?? branch.name) from \(remote)?", action: "Delete",
            destructive: true, perform: { await model.branches.deleteRemote(branch) }
        ) {
            Text(
                "This deletes the branch on \(remote) for everyone who uses it. Commits that no other branch there has are lost to them."
            )
        }
    }
}

private struct SwitchSheet: View {
    @Environment(AppModel.self) private var model
    let branch: Branch
    @State private var leave = false

    var body: some View {
        let current = model.branches.current?.name
        let target = branch.nameOnRemote ?? branch.name
        Dialog(
            title: "Switch to \(target)", action: "Switch Branch",
            perform: { await model.branches.switchTo(branch, leavingChanges: leave) }
        ) {
            Text("You have changes on \(current ?? "a detached HEAD").")
            Picker("", selection: $leave) {
                Text("Leave my changes on \(current ?? "HEAD")").tag(true)
                Text("Bring my changes to \(target)").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(current == nil)
            Text(
                leave
                    ? "They are stashed, and offered back under Stashed Changes when you return to \(current ?? "it")."
                    : "If they would overwrite files on \(target), git refuses and nothing changes."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { leave = current != nil }
    }
}

private struct MergeSheet: View {
    @Environment(AppModel.self) private var model
    @State var kind: MergeKind
    @State var chosen: Branch?
    @State private var filter = ""
    @State private var preview: Result<MergePreview, GitError>?

    var body: some View {
        let branches = model.branches
        let current = branches.current?.name ?? "HEAD"
        let others = branches.all.filter {
            !$0.isHead && (filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter))
        }
        Dialog(
            title: kind == .rebase ? "Rebase \(current)" : "Merge into \(current)",
            action: actionTitle, disabled: chosen == nil || !canStart,
            perform: { if let chosen { await branches.merge(kind, chosen) } }
        ) {
            Picker("", selection: $kind) {
                Text("Merge").tag(MergeKind.merge)
                Text("Squash and Merge").tag(MergeKind.squash)
                Text("Rebase").tag(MergeKind.rebase)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Filter", text: $filter).textFieldStyle(.roundedBorder)
            List(
                others,
                selection: Binding(get: { chosen?.id }, set: { id in chosen = others.first { $0.id == id } })
            ) {
                Text($0.name).tag($0.id)
            }
            .frame(height: 200)
            previewText(current)
                .font(.callout)
                .frame(minHeight: 36, alignment: .topLeading)
        }
        .task(id: [chosen?.id ?? "", "\(kind)"]) {
            preview = nil
            guard let chosen else { return }
            do {
                preview = .success(try await branches.preview(kind, chosen))
            } catch let error as GitError {
                preview = .failure(error)
            } catch {}
        }
    }

    private var actionTitle: String {
        switch kind {
        case .merge: "Create a Merge Commit"
        case .squash: "Squash and Merge"
        case .rebase: "Rebase"
        }
    }

    private var canStart: Bool {
        if case .success(let p) = preview { return p.incoming > 0 }
        return false
    }

    @ViewBuilder private func previewText(_ current: String) -> some View {
        let other = chosen?.name ?? ""
        switch preview {
        case nil:
            if chosen == nil {
                Text("Choose a branch.").foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        case .failure(let error):
            Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        case .success(let p) where p.incoming == 0:
            Text("\(current) is already up to date with \(other).").foregroundStyle(.secondary)
        case .success(let p):
            let commits = p.incoming == 1 ? "1 commit" : "\(p.incoming) commits"
            if let conflicts = p.conflicts, !conflicts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(
                        "\(conflicts.count == 1 ? "1 conflicted file" : "\(conflicts.count) conflicted files") when merging \(other) into \(current). You resolve them before committing.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    Text(conflicts.prefix(5).joined(separator: "\n") + (conflicts.count > 5 ? "\n…" : ""))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            } else if kind == .rebase {
                Text(
                    p.outgoing == 0
                        ? "This fast-forwards \(current) by \(commits) from \(other)."
                        : "This applies the \(p.outgoing == 1 ? "1 commit" : "\(p.outgoing) commits") of \(current) on top of \(other), rewriting \(p.outgoing == 1 ? "it" : "them")."
                )
            } else {
                Label(
                    kind == .squash
                        ? "Can be merged cleanly: \(commits) from \(other) become changes to commit on \(current)."
                        : "Can be merged cleanly: \(commits) from \(other) into \(current).",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        }
    }
}

private struct ForcePushSheet: View {
    @Environment(AppModel.self) private var model
    @State private var overwrites: [String]?

    var body: some View {
        let branch = model.status?.branch
        let upstream = branch?.upstream ?? "the upstream"
        let behind = branch?.behind ?? 0
        Dialog(
            title: "Force push to \(upstream)?", action: "Force Push", destructive: true,
            perform: { await model.branches.forcePush() }
        ) {
            Text(
                "This replaces \(upstream) with your \(branch?.head ?? "branch"). \(behind == 1 ? "1 commit" : "\(behind) commits") on \(upstream) that \(behind == 1 ? "is" : "are") not in your branch will be removed from it:"
            )
            if let overwrites {
                Text(
                    overwrites.map { "• \($0)" }.joined(separator: "\n")
                        + (behind > overwrites.count ? "\n…and \(behind - overwrites.count) more" : "")
                )
                .font(.callout)
            }
            Text(
                "It is refused if \(upstream) has moved since you last fetched, or holds commits that were never on your branch."
            )
            .font(.callout).foregroundStyle(.secondary)
        }
        .task { overwrites = await model.branches.forcePushOverwrites() }
    }
}

private struct PublishSheet: View {
    @Environment(AppModel.self) private var model
    @State private var remote = ""

    var body: some View {
        Dialog(
            title: "Publish \(model.status?.branch.head ?? "Branch")", action: "Publish",
            disabled: remote.isEmpty,
            perform: { await model.branches.publish(to: remote) }
        ) {
            Picker("Remote", selection: $remote) {
                ForEach(model.branches.remotes, id: \.self) { Text($0).tag($0) }
            }
        }
        .onAppear { remote = model.branches.remotes.first ?? "" }
    }
}

private struct DiscardStashSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Dialog(
            title: "Discard the stashed changes?", action: "Discard", destructive: true,
            perform: { await model.branches.discardStash() }
        ) {
            Text(
                "The changes stashed on \(model.branches.current?.name ?? "this branch") are deleted. Upstream cannot bring them back."
            )
        }
    }
}
