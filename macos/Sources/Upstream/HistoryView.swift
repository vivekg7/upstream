import AppKit
import SwiftUI
import UpstreamKit

/// The current branch's commits, paged (docs/plans/006_history.md), or one
/// side of a comparison with another branch.
struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @State private var prompt: CommitPrompt?
    let focus: FocusState<Pane?>.Binding

    var body: some View {
        @Bindable var history = model.history
        List(selection: $history.selection) {
            ForEach(history.commits) { commit in
                CommitRow(
                    commit: commit, labels: history.labels[commit.id] ?? [],
                    unpushed: history.listedOnHead && history.unpushed.contains(commit.id)
                )
                .contextMenu { CommitActions(commit: commit, ask: { prompt = $0 }) }
            }
            if !history.atEnd && !history.commits.isEmpty {
                // Its task runs again after each page, in case the page
                // was short and this row is still in view.
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity)
                    .task(id: history.commits.count) { await history.loadMore() }
            }
        }
        .focused(focus, equals: .history)
        .onKeyPress(.leftArrow) {
            moveFocus(to: .repositories, focus, model)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard history.detail?.id == history.selection, !history.files.isEmpty else { return .ignored }
            moveFocus(to: .commitFiles, focus, model)
            return .handled
        }
        // ⌘2 puts the keyboard here before the first page has loaded, so
        // the first commit is selected when it arrives, as `moveFocus` does
        // for a list that is already there.
        .onChange(of: history.commits.first?.id) {
            if focus.wrappedValue == .history, history.selection == nil {
                history.selection = history.commits.first?.id
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { CompareBar() }
        .overlay {
            if model.status != nil, !model.hasHead {
                ContentUnavailableView("No commits yet", systemImage: "clock")
            } else if history.atEnd, history.commits.isEmpty {
                ContentUnavailableView(
                    history.compare == nil ? "No commits" : "No commits to show", systemImage: "clock")
            }
        }
        .commitPrompts($prompt)
        .task(id: model.selected) { await history.load() }
    }
}

/// "Compare…": another branch's commits that this one lacks (behind), or
/// this one's that it lacks (ahead), in GitHub Desktop's words.
private struct CompareBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var history = model.history
        HStack(spacing: 8) {
            if let other = history.compare {
                Picker("Compare", selection: $history.compareSide) {
                    Text("Behind \(history.compareCounts?.behind ?? 0)").tag(HistoryModel.CompareSide.behind)
                    Text("Ahead \(history.compareCounts?.ahead ?? 0)").tag(HistoryModel.CompareSide.ahead)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(history.branches.first { $0.ref == other }?.name ?? other)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Stop Comparing", systemImage: "xmark.circle.fill") { history.compare = nil }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            } else {
                Menu("Compare…") {
                    ForEach(history.branches) { branch in
                        Button(branch.name) { history.compare = branch.ref }
                    }
                }
                .disabled(history.branches.isEmpty)
                .fixedSize()
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

private struct CommitRow: View {
    let commit: Commit
    let labels: [RefLabel]
    let unpushed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(commit.subject).lineLimit(1)
                Spacer(minLength: 0)
                // Two at most: a commit with a dozen tags must not squeeze its subject away.
                ForEach(labels.prefix(2)) { RefBadge(label: $0) }
                if labels.count > 2 {
                    Text("+\(labels.count - 2)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(labels.dropFirst(2).map(\.name).joined(separator: ", "))
                }
            }
            HStack(spacing: 6) {
                Text("\(commit.authorName) · \(commit.date, format: .relative(presentation: .named))")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if unpushed {
                    Image(systemName: "arrow.up.circle")
                        .foregroundStyle(.secondary)
                        .help("Not pushed yet")
                        .accessibilityLabel("Not pushed yet")
                }
            }
            .font(.callout)
        }
        .padding(.vertical, 2)
        .help(commit.subject)
    }
}

private struct RefBadge: View {
    let label: RefLabel

    var body: some View {
        Label(label.name, systemImage: label.kind == .tag ? "tag" : "arrow.triangle.branch")
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: .capsule)
            .help(label.ref)
    }
}

/// The selected commit: its message and people, then its files beside the
/// selected file's diff, as GitHub Desktop lays it out.
struct HistoryDetailView: View {
    @Environment(AppModel.self) private var model
    @State private var prompt: CommitPrompt?
    let focus: FocusState<Pane?>.Binding

    var body: some View {
        let history = model.history
        if let detail = history.detail, detail.id == history.selection {
            VStack(spacing: 0) {
                CommitHeader(detail: detail, ask: { prompt = $0 })
                Divider()
                HSplitView {
                    CommitFileList(focus: focus)
                        .frame(minWidth: 180, idealWidth: 260, maxWidth: 420)
                    Group {
                        if let diff = history.fileDiff,
                            let file = history.files.first(where: { $0.id == history.selectedFile })
                        {
                            DiffView(diff: diff, path: file.path, images: images(file, of: detail))
                        } else {
                            ContentUnavailableView("No file selected", systemImage: "doc.text")
                        }
                    }
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .commitPrompts($prompt)
        } else {
            ContentUnavailableView("Select a commit", systemImage: "clock")
        }
    }

    /// The image before the commit (in its first parent, under its old name
    /// if renamed) and after. A side that is not there is left out.
    private func images(_ file: CommitFile, of detail: CommitDetail) -> (@Sendable () async -> DiffImages)? {
        guard let git = model.git, let repo = model.selected else { return nil }
        let (sha, parent) = (detail.id, detail.parents.first)
        let (old, new) = (file.originalPath ?? file.path, file.path)
        return {
            async let after = git.blob(sha, new, in: repo)
            let before = if let parent { await git.blob(parent, old, in: repo) } else { Data?.none }
            return await DiffImages(old: before, new: after)
        }
    }
}

private struct CommitHeader: View {
    @Environment(AppModel.self) private var model
    let detail: CommitDetail
    let ask: (CommitPrompt) -> Void

    var body: some View {
        let (summary, body) = Self.split(detail.message)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(summary)
                    .font(.headline)
                    .textSelection(.enabled)
                Spacer()
                Menu("Actions", systemImage: "ellipsis.circle") {
                    CommitActions(commit: detail.commit, ask: ask)
                }
                .labelStyle(.iconOnly)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            if !body.isEmpty {
                ScrollView {
                    Text(body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                person("Author", detail.authorName, detail.authorEmail, detail.authorDate)
                if detail.committerName != detail.authorName || detail.committerEmail != detail.authorEmail {
                    person("Committer", detail.committerName, detail.committerEmail, detail.committerDate)
                }
                HStack(spacing: 4) {
                    Text("Commit").foregroundStyle(.secondary)
                    Text(detail.id).monospaced().textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button("Copy SHA", systemImage: "doc.on.doc") { copy(detail.id) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                if !detail.parents.isEmpty {
                    HStack(spacing: 6) {
                        Text(detail.parents.count == 1 ? "Parent" : "Parents").foregroundStyle(.secondary)
                        ForEach(detail.parents, id: \.self) { parent in
                            Button(String(parent.prefix(7))) { model.history.selection = parent }
                                .buttonStyle(.link)
                                .monospaced()
                                .help(parent)
                        }
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
    }

    private func person(_ role: String, _ name: String, _ email: String, _ date: Date) -> some View {
        HStack(spacing: 4) {
            Text(role).foregroundStyle(.secondary)
            Text("\(name) <\(email)>").textSelection(.enabled).lineLimit(1)
            Text(date, format: .dateTime).foregroundStyle(.secondary)
        }
    }

    private static func split(_ message: String) -> (String, String) {
        let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return (
            String(parts.first ?? ""),
            parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        )
    }
}

/// The commit's files. A list, so a commit of thousands of files draws only
/// the rows in view, and only the selected file's diff is ever read.
private struct CommitFileList: View {
    @Environment(AppModel.self) private var model
    let focus: FocusState<Pane?>.Binding

    var body: some View {
        @Bindable var history = model.history
        List(history.files, selection: $history.selectedFile) { file in
            HStack(spacing: 6) {
                Text(String(file.kind.rawValue))
                    .font(.caption.monospaced().bold())
                    .foregroundStyle(color(file.kind))
                    .frame(width: 14)
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
            }
        }
        .focused(focus, equals: .commitFiles)
        .onKeyPress(.leftArrow) {
            moveFocus(to: .history, focus, model)
            return .handled
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(history.files.count == 1 ? "1 changed file" : "\(history.files.count) changed files")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
        }
    }

    private func color(_ kind: ChangeKind) -> Color {
        switch kind {
        case .added, .untracked: .green
        case .deleted: .red
        case .renamed, .copied: .blue
        case .modified, .typeChanged: .orange
        }
    }
}

// MARK: Actions on a commit

/// An action that asks for something before it runs.
enum CommitPrompt: Identifiable {
    case branch(Commit), tag(Commit), reset(Commit)

    var id: String {
        switch self {
        case .branch(let c): "branch " + c.id
        case .tag(let c): "tag " + c.id
        case .reset(let c): "reset " + c.id
        }
    }
}

/// The same menu in a row's context menu and the detail's header.
private struct CommitActions: View {
    @Environment(AppModel.self) private var model
    let commit: Commit
    let ask: (CommitPrompt) -> Void

    var body: some View {
        let history = model.history
        let onHead = history.listedOnHead
        if history.undoable?.id == commit.id {
            Button("Undo Commit") { Task { await history.undo() } }
            Divider()
        }
        Button("Create Branch from Commit…") { ask(.branch(commit)) }
        Button("Create Tag…") { ask(.tag(commit)) }
        Divider()
        if onHead {
            Button("Revert Changes in Commit") { Task { await history.revert(commit) } }
            if commit.id != model.status?.branch.oid {
                Button("Reset to Commit…") { ask(.reset(commit)) }
            }
        } else {
            Button("Cherry-pick onto \(model.status?.branch.head ?? "HEAD")") {
                Task { await history.cherryPick(commit) }
            }
        }
        Divider()
        Button("Copy SHA") { copy(commit.id) }
        ForEach(history.labels[commit.id]?.filter { $0.kind == .tag } ?? []) { tag in
            Button("Copy Tag \(tag.name)") { copy(tag.name) }
        }
        if history.canOpenOnForge {
            Button("View on the Web") {
                Task {
                    if let url = await model.forge.webURL(commit: commit.id) { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

extension View {
    /// The name prompts for a new branch or tag, and the confirmation
    /// before a reset, which says what it takes off the branch.
    fileprivate func commitPrompts(_ prompt: Binding<CommitPrompt?>) -> some View {
        modifier(CommitPrompts(prompt: prompt))
    }
}

private struct CommitPrompts: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var prompt: CommitPrompt?
    @State private var name = ""

    func body(content: Content) -> some View {
        let history = model.history
        content
            .alert(title, isPresented: isNaming, presenting: prompt) { prompt in
                TextField("Name", text: $name)
                Button("Create") {
                    let name = name.trimmingCharacters(in: .whitespaces)
                    Task {
                        switch prompt {
                        case .branch(let c): await history.createBranch(name, at: c)
                        case .tag(let c): await history.createTag(name, at: c)
                        case .reset: break
                        }
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                if case .branch(let c) = prompt {
                    Text("A new branch at \(c.shortID), switched to. Your uncommitted changes come along.")
                } else if case .tag(let c) = prompt {
                    Text("A lightweight tag at \(c.shortID).")
                }
            }
            .alert("Reset to this commit?", isPresented: isConfirming, presenting: prompt) { prompt in
                Button("Reset", role: .destructive) {
                    if case .reset(let c) = prompt { Task { await history.reset(to: c) } }
                }
                Button("Cancel", role: .cancel) {}
            } message: { prompt in
                if case .reset(let c) = prompt { Text(resetMessage(c)) }
            }
            .onChange(of: prompt?.id) { name = "" }
    }

    private var title: String {
        if case .tag = prompt { return "Create Tag" }
        return "Create Branch"
    }

    private var isNaming: Binding<Bool> {
        Binding(
            get: {
                switch prompt {
                case .branch, .tag: true
                default: false
                }
            }, set: { if !$0 { prompt = nil } })
    }

    private var isConfirming: Binding<Bool> {
        Binding(
            get: {
                if case .reset = prompt { return true }
                return false
            }, set: { if !$0 { prompt = nil } })
    }

    /// Says what leaves the branch, and warns when some of it is pushed.
    private func resetMessage(_ commit: Commit) -> String {
        let branch = model.status?.branch.head ?? "HEAD"
        let history = model.history
        let after = history.commits.prefix { $0.id != commit.id }
        var text =
            "\(branch) will point at \(commit.shortID) “\(commit.subject)”. The commits after it come off "
            + "the branch; their changes stay in your working tree, uncommitted, and nothing stays staged."
        if after.contains(where: { !history.unpushed.contains($0.id) }), model.status?.branch.upstream != nil
        {
            text += " Some of them are already pushed: pushing \(branch) afterwards will need a force push."
        }
        return text
    }
}
