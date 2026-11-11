import AppKit
import SwiftUI
import UpstreamKit

struct ChangesView: View {
    @Environment(AppModel.self) private var model
    /// The rows selected in the list. Several can be, for a context menu;
    /// the diff shows only when one is.
    @State private var picked: Set<FileChange.ID> = []

    var body: some View {
        let files = model.status?.files ?? []
        List(files, selection: $picked) { change in
            HStack(spacing: 8) {
                CheckBox(state: checkState(change)) { model.setChecked($0, change) }
                    .disabled(change.conflicted || model.operation != nil)
                StatusBadge(change: change)
                Text(change.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
            }
        }
        .contextMenu(forSelectionType: FileChange.ID.self) { ids in
            ChangeMenu(changes: files.filter { ids.contains($0.id) }, all: files)
        }
        .onChange(of: picked) { model.selectedFile = picked.count == 1 ? picked.first : nil }
        .onChange(of: model.selectedFile, initial: true) {
            if let file = model.selectedFile {
                if picked != [file] { picked = [file] }
            } else if picked.count == 1 {
                picked = []
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let operation = model.operation { OperationBanner(operation: operation) }
                if !files.isEmpty {
                    HStack(spacing: 8) {
                        CheckBox(state: allState(files)) { model.setAllChecked($0) }
                            .disabled(model.operation != nil)
                        Text(files.count == 1 ? "1 changed file" : "\(files.count) changed files")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(.bar)
                }
            }
        }
        .overlay {
            if model.status != nil, files.isEmpty {
                ContentUnavailableView("No local changes", systemImage: "checkmark.circle")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { StashView() }
        .safeAreaInset(edge: .bottom, spacing: 0) { CommitForm() }
        .modifier(DiscardConfirmation())
    }

    /// During an operation the checkboxes do not choose anything: what is
    /// staged is what continues, so they show that.
    private func checkState(_ change: FileChange) -> CheckBox.State {
        guard model.operation != nil else { return CheckBox.State(model.selection(of: change)) }
        if change.conflicted || change.index == nil { return .off }
        return change.worktree == nil ? .on : .mixed
    }

    private func allState(_ files: [FileChange]) -> CheckBox.State {
        let states = Set(files.filter { !$0.conflicted }.map(checkState))
        return states.count == 1 ? states.first! : .mixed
    }
}

/// A row's context menu: resolve a conflict, discard, ignore. `changes`
/// are the rows it was opened on, none when on empty space.
private struct ChangeMenu: View {
    @Environment(AppModel.self) private var model
    let changes: [FileChange]
    let all: [FileChange]

    var body: some View {
        let one = changes.count == 1 ? changes.first : nil
        if let one, one.conflicted { conflictItems(one) }
        let discardable = changes.filter { !$0.conflicted }
        if !discardable.isEmpty {
            Button(
                discardable.count == 1 ? "Discard Changes…" : "Discard Changes to \(discardable.count) Files…"
            ) {
                model.requestDiscard(discardable)
            }
            .disabled(model.operation != nil)
        }
        // Only an untracked file: git goes on tracking a tracked one whatever
        // .gitignore says (docs/plans/008_discard_ignore_and_conflicts.md).
        if let one, one.kind == .untracked {
            Button("Ignore File") { Task { await model.ignore(one, allWithItsExtension: false) } }
            if let ext = Ignore.fileExtension(of: one.path) {
                Button("Ignore All .\(ext) Files") {
                    Task { await model.ignore(one, allWithItsExtension: true) }
                }
            }
        }
        if let one, let repo = model.selected {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.appending(path: one.path)])
            }
        }
        Divider()
        Button("Discard All Changes…") { model.requestDiscard(all) }
            .disabled(model.operation != nil || !all.contains { !$0.conflicted })
    }

    /// Take a side, mark it resolved, or open it. The sides are named by
    /// branch, since during a rebase git's "ours" is the other branch.
    @ViewBuilder private func conflictItems(_ change: FileChange) -> some View {
        let branch = model.status?.branch.head
        ForEach([ConflictSide.ours, .theirs], id: \.self) { side in
            let name =
                model.operation?.label(side, currentBranch: branch)
                ?? (side == .ours ? branch ?? "HEAD" : "the other side")
            // In git's status, X is our side and Y theirs.
            let deleted = (side == .ours ? change.index : change.worktree) == .deleted
            Button(deleted ? "Delete the File, as on “\(name)”" : "Use the Version from “\(name)”") {
                Task { await model.resolve(change, taking: side) }
            }
        }
        Button("Mark as Resolved") { Task { await model.markResolved(change) } }
        if let repo = model.selected {
            // The repos area's configurable editor replaces this at merge.
            Button("Open in Editor") { openInEditor(repo.appending(path: change.path)) }
        }
        Divider()
    }
}

/// What is in progress, how many conflicts are left, and Abort.
private struct OperationBanner: View {
    @Environment(AppModel.self) private var model
    let operation: RepoOperation
    @State private var confirmingAbort = false

    var body: some View {
        let branch = model.status?.branch.head
        let left = model.status?.files.count(where: \.conflicted) ?? 0
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: left > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(left > 0 ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title(currentBranch: branch))
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(
                    left == 0
                        ? "No conflicts left."
                        : left == 1 ? "1 conflicted file" : "\(left) conflicted files"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Abort") { confirmingAbort = true }
                .disabled(model.activity != nil)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
        .confirmationDialog(
            "Abort the \(operation.kind.command)?", isPresented: $confirmingAbort, titleVisibility: .visible
        ) {
            Button("Abort \(operation.kind.title)", role: .destructive) {
                Task { await model.abortOperation() }
            }
        } message: {
            Text(operation.abortWarning(currentBranch: branch))
        }
    }
}

/// Confirms a discard, naming what it throws away and where the copy goes.
private struct DiscardConfirmation: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let request = model.discardRequest
        content.confirmationDialog(
            request.map(title) ?? "",
            isPresented: Binding(
                get: { model.discardRequest != nil }, set: { if !$0 { model.discardRequest = nil } }),
            titleVisibility: .visible, presenting: request
        ) { request in
            Button("Discard", role: .destructive) { Task { await model.discard(request) } }
        } message: { request in
            Text(message(request))
        }
    }

    private func title(_ request: DiscardRequest) -> String {
        switch request {
        case .files(let changes):
            changes.count == 1
                ? "Discard the changes to “\(changes[0].path)”?"
                : "Discard the changes to \(changes.count) files?"
        case .lines(let lines, let change, _):
            "Discard \(lines.count == 1 ? "1 line" : "\(lines.count) lines") of “\(change.path)”?"
        }
    }

    private func message(_ request: DiscardRequest) -> String {
        let folder = "“Upstream discarded changes \(model.selected?.lastPathComponent ?? "") <date>”"
        switch request {
        case .files(let changes):
            let names = changes.prefix(8).map(\.path).joined(separator: "\n")
            let more = changes.count > 8 ? "\nand \(changes.count - 8) more" : ""
            let list = changes.count == 1 ? "" : "\(names)\(more)\n\n"
            return "\(list)What they hold now goes to the Trash first, in a folder named \(folder)."
        case .lines:
            return "The whole file, as it is now, goes to the Trash first, in a folder named \(folder)."
        }
    }
}

/// Summary, description, co-authors, amend and the commit button, under the
/// changes as in GitHub Desktop. During a merge it commits the merge; during
/// a rebase, cherry-pick or revert it continues instead.
private struct CommitForm: View {
    @Environment(AppModel.self) private var model
    @State private var showCoAuthors = false

    var body: some View {
        @Bindable var model = model
        let branch = model.status?.branch
        let operation = model.operation
        VStack(alignment: .leading, spacing: 6) {
            if operation == nil || operation?.kind == .merge {
                TextField("Summary (required)", text: $model.draft.summary)
                TextField("Description", text: $model.draft.description, axis: .vertical)
                    .lineLimit(3...10)
                if showCoAuthors || !model.draft.coAuthors.isEmpty { CoAuthorsField() }
                HStack {
                    if operation == nil {
                        Toggle(
                            "Amend last commit",
                            isOn: Binding(
                                get: { model.draft.amend }, set: { on in Task { await model.setAmend(on) } })
                        )
                        .disabled(branch?.oid == nil)
                    }
                    Spacer()
                    Button("Co-Authors", systemImage: "person.badge.plus") { showCoAuthors.toggle() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help(showCoAuthors ? "Hide co-authors" : "Add co-authors")
                }
            } else {
                Text("Continuing commits what is staged, with the original commit's message.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            // Status says HEAD is already on the upstream when nothing is ahead.
            if model.draft.amend, operation == nil, let upstream = branch?.upstream, branch?.ahead == 0 {
                Text("This commit is already on \(upstream). Pushing the amended one will need a force push.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if let operation {
                Button {
                    Task { await model.continueOperation() }
                } label: {
                    Text(operation.kind == .merge ? "Commit Merge" : "Continue \(operation.kind.title)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.continueBlocker != nil || model.activity != nil)
                .help(model.continueBlocker ?? "")
            } else {
                Button {
                    Task { await model.commit() }
                } label: {
                    Text(model.draft.amend ? "Amend Last Commit" : "Commit to \(branch?.head ?? "HEAD")")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.commitBlocker != nil || model.isCommitting)
                .help(model.commitBlocker ?? "")
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(.bar)
    }
}

/// The co-authors of the next commit, and a field to add one as
/// "Name <email>", with the repository's recent authors as suggestions.
private struct CoAuthorsField: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var invalid = false

    var body: some View {
        ForEach(model.draft.coAuthors, id: \.self) { author in
            HStack(spacing: 6) {
                Image(systemName: "person.fill").foregroundStyle(.secondary)
                Text(author).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Remove \(author)", systemImage: "xmark.circle.fill") {
                    model.draft.coAuthors.removeAll { $0 == author }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .font(.callout)
        }
        TextField("Co-author: Name <email>", text: $text)
            .textInputSuggestions {
                ForEach(suggestions, id: \.self) { Text($0).textInputCompletion($0) }
            }
            .onSubmit {
                invalid = !model.addCoAuthor(text)
                if !invalid { text = "" }
            }
            .task { await model.loadAuthorSuggestions() }
        if invalid {
            Text("Type a name and an email, as in Ada Lovelace <ada@example.com>.")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    private var suggestions: [String] {
        let typed = text.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return [] }
        return Array(
            model.authorSuggestions.lazy
                .filter { $0.localizedCaseInsensitiveContains(typed) && !model.draft.coAuthors.contains($0) }
                .prefix(8))
    }
}

/// The native checkbox, including its dash for "some of it": SwiftUI shows
/// that mixed state for a toggle over sources that disagree, so a mixed
/// box is given one checked and one unchecked source.
struct CheckBox: View {
    enum State: Hashable {
        case on, off, mixed

        init(_ selection: FileSelection) {
            self =
                switch selection {
                case .all: .on
                case .nothing: .off
                case .lines: .mixed
                }
        }
    }

    let state: State
    let set: (Bool) -> Void

    init(state: State, set: @escaping (Bool) -> Void) {
        self.state = state
        self.set = set
    }

    var body: some View {
        let values: [Bool] =
            switch state {
            case .on: [true]
            case .off: [false]
            case .mixed: [true, false]
            }
        Toggle(sources: values.map { v in Binding(get: { v }, set: { set($0) }) }, isOn: \.self) {
            EmptyView()
        }
        .toggleStyle(.checkbox)
        .labelsHidden()
    }
}

private struct StatusBadge: View {
    let change: FileChange

    var body: some View {
        let (symbol, color) = look
        Image(systemName: symbol)
            .foregroundStyle(color)
            .accessibilityLabel(change.conflicted ? "Conflicted" : String(change.kind.rawValue))
    }

    private var look: (String, Color) {
        if change.conflicted { return ("exclamationmark.triangle.fill", .orange) }
        return switch change.kind {
        case .added, .untracked: ("plus.square.fill", .green)
        case .deleted: ("minus.square.fill", .red)
        case .renamed, .copied: ("arrow.right.square.fill", .blue)
        case .modified, .typeChanged: ("circle.square.fill", .yellow)
        }
    }
}
