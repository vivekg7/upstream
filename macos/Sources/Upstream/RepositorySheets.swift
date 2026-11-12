import SwiftUI
import UpstreamKit

// File → Clone Repository (⌘⇧O) and New Repository (⌘N)
// (docs/plans/009_repositories_and_settings.md).

/// A URL, or one of the signed-in account's repositories, and the folder to
/// clone it into.
struct CloneSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var source = Source.url
    @State private var url = ""
    @State private var parent = cloneFolder
    /// The folder's name; follows the URL until the user edits it.
    @State private var name = ""
    @State private var cloning: Task<Void, Never>?
    @State private var failure: String?

    enum Source: Hashable { case url, account }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone a Repository").font(.headline)
            Picker("Source", selection: $source) {
                Text("URL").tag(Source.url)
                Text("Account").tag(Source.account)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Form {
                switch source {
                case .url:
                    TextField("Repository URL", text: $url, prompt: Text("https://host/owner/repo.git"))
                case .account:
                    AccountRepositoryPicker { picked in url = picked }
                        .frame(minHeight: 200)
                    LabeledContent("Repository URL", value: url.isEmpty ? "None chosen" : url)
                }
                FolderField(title: "Clone into", folder: $parent)
                TextField("Folder name", text: $name)
            }
            .disabled(cloning != nil)
            if let failure { ErrorText(failure) }
            HStack {
                if cloning != nil {
                    // git's progress is human text, which is never parsed
                    // (docs/plans/001_native_clients_on_system_git.md).
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    if let cloning { cloning.cancel() } else { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        cloning != nil || url.trimmingCharacters(in: .whitespaces).isEmpty || name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .interactiveDismissDisabled(cloning != nil)
        .onChange(of: url) { old, new in
            if name.isEmpty || name == cloneDirectoryName(for: old) { name = cloneDirectoryName(for: new) }
        }
    }

    private func clone() {
        failure = nil
        let source = url.trimmingCharacters(in: .whitespaces)
        let directory = parent.appending(path: name, directoryHint: .isDirectory)
        cloning = Task {
            do {
                try await model.library.clone(source, to: directory)
                dismiss()
            } catch is CancellationError {
            } catch {
                failure = error.localizedDescription
            }
            cloning = nil
        }
    }
}

/// A name, a place, and the first files: README, .gitignore and licence.
struct CreateSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var new = NewRepository(name: "", parent: cloneFolder)
    @State private var creating = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create a New Repository").font(.headline)
            Form {
                TextField("Name", text: $new.name)
                TextField("Description", text: $new.description)
                FolderField(title: "Local path", folder: $new.parent)
                Toggle("Initialize with a README", isOn: $new.readme)
                Picker("Git ignore", selection: $new.gitignore) {
                    Text("None").tag(String?.none)
                    ForEach(Templates.gitignoreNames, id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker("License", selection: $new.license) {
                    Text("None").tag(String?.none)
                    ForEach(Templates.licenses) { Text($0.name).tag(Optional($0.id)) }
                }
                LabeledContent("Branch", value: new.defaultBranch)
            }
            .disabled(creating)
            if let failure { ErrorText(failure) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Repository", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(creating || new.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            // The branch from init.defaultBranch, as `git init` would choose,
            // and the licence's holder from user.name.
            guard let git = model.git else { return }
            let config = GlobalConfig(git: git)
            new.defaultBranch = await config.get("init.defaultBranch") ?? "main"
            new.author = await config.get("user.name") ?? NSFullUserName()
        }
    }

    private func create() {
        failure = nil
        creating = true
        Task {
            do {
                try await model.library.create(new)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
            creating = false
        }
    }
}

/// A folder's path with a button to choose another.
struct FolderField: View {
    let title: String
    @Binding var folder: URL

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(folder.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(folder.path(percentEncoded: false))
                Spacer()
                Button("Choose…") {
                    if let url = chooseFolder(prompt: "Choose", startingAt: folder) { folder = url }
                }
            }
        }
    }
}

/// Repository → Pull All Repositories: progress, then what was pulled and
/// what was skipped and why (docs/plans/011_status_on_every_row.md).
struct PullAllSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let overview = model.overview
        let run = overview.pullAll ?? PullAllRun(total: 0)
        VStack(alignment: .leading, spacing: 12) {
            Text("Pull All Repositories").font(.headline)
            if run.isFinished {
                Text(summary(run))
            } else {
                ProgressView(value: Double(run.done), total: Double(max(run.total, 1))) {
                    Text(run.isStopping ? "Stopping…" : "Fetching and pulling \(run.done) of \(run.total)…")
                }
            }
            if !run.outcomes.isEmpty {
                List(run.outcomes) { outcome in
                    switch outcome.result {
                    case .pulled(let commits):
                        Label {
                            Text(outcome.repository.lastPathComponent)
                            Text(commits == 1 ? "1 commit" : "\(commits) commits")
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                        }
                    case .skipped(let why):
                        Label {
                            Text(outcome.repository.lastPathComponent)
                            Text(why).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .frame(minHeight: 180)
            }
            HStack {
                Spacer()
                if run.isFinished {
                    Button("Done") { overview.dismissPullAll() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Stop") { overview.stopPullAll() }.disabled(run.isStopping)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(!run.isFinished)
    }

    private func summary(_ run: PullAllRun) -> String {
        let pulled = run.outcomes.filter { if case .pulled = $0.result { true } else { false } }.count
        let skipped = run.outcomes.count - pulled
        if run.outcomes.isEmpty { return "Everything was up to date." }
        let a = pulled == 1 ? "Pulled 1 repository." : "Pulled \(pulled) repositories."
        let b = skipped == 1 ? "1 needs you." : "\(skipped) need you."
        return skipped == 0 ? a : pulled == 0 ? b : "\(a) \(b)"
    }
}

struct ErrorText: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
            .textSelection(.enabled)
    }
}
