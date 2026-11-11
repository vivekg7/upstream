import SwiftUI
import UpstreamKit

struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let files = model.status?.files ?? []
        List(files, selection: $model.selectedFile) { change in
            HStack(spacing: 8) {
                CheckBox(state: CheckBox.State(model.selection(of: change))) { model.setChecked($0, change) }
                    .disabled(change.conflicted)
                StatusBadge(change: change)
                Text(change.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if !files.isEmpty {
                HStack(spacing: 8) {
                    CheckBox(state: allState(files)) { model.setAllChecked($0) }
                    Text(files.count == 1 ? "1 changed file" : "\(files.count) changed files")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
        }
        .overlay {
            if model.status != nil, files.isEmpty {
                ContentUnavailableView("No local changes", systemImage: "checkmark.circle")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { CommitForm() }
    }

    private func allState(_ files: [FileChange]) -> CheckBox.State {
        let states = Set(files.filter { !$0.conflicted }.map { CheckBox.State(model.selection(of: $0)) })
        return states.count == 1 ? states.first! : .mixed
    }
}

/// Summary, description, amend and the commit button, under the changes as
/// in GitHub Desktop.
private struct CommitForm: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let branch = model.status?.branch
        VStack(alignment: .leading, spacing: 6) {
            TextField("Summary (required)", text: $model.draft.summary)
            TextField("Description", text: $model.draft.description, axis: .vertical)
                .lineLimit(3...10)
            Toggle(
                "Amend last commit",
                isOn: Binding(get: { model.draft.amend }, set: { on in Task { await model.setAmend(on) } })
            )
            .disabled(branch?.oid == nil)
            // Status says HEAD is already on the upstream when nothing is ahead.
            if model.draft.amend, let upstream = branch?.upstream, branch?.ahead == 0 {
                Text("This commit is already on \(upstream). Pushing the amended one will need a force push.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
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
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(10)
        .background(.bar)
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
