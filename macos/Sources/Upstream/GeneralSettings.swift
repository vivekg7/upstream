import SwiftUI
import UpstreamKit

/// Name and email, the default branch, the editor, the terminal, the clone
/// folder, the repository list's status (docs/plans/011_status_on_every_row.md)
/// and the git to use (docs/plans/009_repositories_and_settings.md).
/// The git settings live in the global git config, read and written
/// through git, so a terminal sees the same values; the rest are the app's
/// own and live in `UserDefaults`.
struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var email = ""
    @State private var branch = ""
    /// What the global config said when read, to tell what the user changed.
    @State private var saved = (name: "", email: "", branch: "")
    @State private var failure: String?
    @AppStorage(SettingsKey.editor) private var editor = ""
    @AppStorage(SettingsKey.terminal) private var terminal = ""
    @AppStorage(SettingsKey.cloneFolder) private var cloneFolderPath = ""
    @AppStorage(SettingsKey.gitPath) private var gitPath = ""

    var body: some View {
        Form {
            Section("Git identity and defaults") {
                TextField("Name", text: $name)
                TextField("Email", text: $email)
                if !email.isEmpty, !GlobalConfig.isValidEmail(email) {
                    ErrorText("This does not look like an email address.")
                }
                TextField("Default branch", text: $branch, prompt: Text("main"))
                HStack {
                    if let failure { ErrorText(failure) }
                    Spacer()
                    Button("Save", action: save)
                        .disabled(
                            (name, email, branch) == saved
                                || (!email.isEmpty && !GlobalConfig.isValidEmail(email)))
                }
            }
            Section("Apps") {
                AppPicker(title: "Editor", apps: ExternalApp.editors, selection: $editor)
                AppPicker(title: "Terminal", apps: ExternalApp.terminals, selection: $terminal)
                FolderField(
                    title: "Clone and create in",
                    folder: Binding(get: { cloneFolder }, set: { cloneFolderPath = $0.path }))
            }
            Section("Repository list") {
                Toggle(
                    "Show status in the repository list",
                    isOn: Binding {
                        model.overview.isOn
                    } set: {
                        model.overview.setOn($0)
                    })
                Text(
                    "↓ and ↑ for commits to pull and push, and a dot for uncommitted changes. While Upstream is in front, a repository is fetched at most every 30 minutes, and on GitHub only when someone pushed to it."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Git") {
                LabeledContent("Using", value: model.git?.executable.path ?? "No git found")
                if let version = model.library.gitVersion {
                    LabeledContent("Version", value: version.description)
                    if !version.isSupported { ErrorText(version.warning) }
                }
                LabeledContent("Use another git") {
                    HStack {
                        TextField("Path", text: $gitPath, prompt: Text("Found automatically"))
                            .labelsHidden()
                        Button("Choose…", action: chooseGit)
                    }
                }
                if !gitPath.isEmpty, !FileManager.default.isExecutableFile(atPath: gitPath) {
                    ErrorText("No executable at this path; the one found automatically is used.")
                } else if gitPath != (model.git?.executable.path ?? "") && !gitPath.isEmpty {
                    Text("Takes effect when Upstream is next opened.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task { await load() }
    }

    private var config: GlobalConfig? { model.git.map { GlobalConfig(git: $0) } }

    private func load() async {
        guard let config else { return }
        saved = (
            await config.get("user.name") ?? "", await config.get("user.email") ?? "",
            await config.get("init.defaultBranch") ?? ""
        )
        (name, email, branch) = saved
    }

    private func save() {
        guard let config else { return }
        failure = nil
        Task {
            do {
                let branch = branch.trimmingCharacters(in: .whitespaces)
                if !branch.isEmpty, !(await config.isValidBranch(branch)) {
                    failure = "“\(branch)” is not a valid branch name."
                    return
                }
                if name != saved.name { try await config.set("user.name", name) }
                if email != saved.email { try await config.set("user.email", email) }
                if branch != saved.branch { try await config.set("init.defaultBranch", branch) }
                await load()
            } catch {
                failure = error.localizedDescription
            }
        }
    }

    private func chooseGit() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Use This git"
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        if panel.runModal() == .OK, let url = panel.url { gitPath = url.path }
    }
}

/// The installed apps of a kind, with the default named when nothing is
/// chosen yet.
private struct AppPicker: View {
    let title: String
    let apps: [ExternalApp]
    @Binding var selection: String

    var body: some View {
        let installed = ExternalApp.installed(apps)
        Picker(title, selection: $selection) {
            Text("Automatic (\(installed.first?.name ?? "default app"))").tag("")
            ForEach(installed) { Text($0.name).tag($0.id) }
        }
    }
}
