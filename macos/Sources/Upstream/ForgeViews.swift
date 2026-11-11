import AppKit
import SwiftUI
import UpstreamKit

// Accounts, pull requests and CI (docs/plans/002_forges_github_first.md).
// The views say "Pull Request", GitHub's word; the model says "change
// request", so GitLab's "Merge Request" is a label, not a rewrite.

/// Publish when the repository has no remote; the current branch's CI
/// state; the pull requests.
struct ForgeToolbar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let forge = model.forge
        let checks = forge.checks ?? []
        // Nothing at all rather than an empty item, which AppKit measures as zero-sized.
        if forge.remotes == [] || !checks.isEmpty || forge.repo != nil {
            HStack(spacing: 4) { items(forge, checks) }
        }
    }

    @ViewBuilder private func items(_ forge: ForgeModel, _ checks: [Check]) -> some View {
        if forge.remotes == [] {
            Button("Publish Repository", systemImage: "icloud.and.arrow.up") { forge.isPublishing = true }
                .help("Publish this repository to GitHub")
        }
        if !checks.isEmpty { ChecksButton(checks: checks) }
        if forge.repo != nil { PullRequestsButton() }
    }
}

/// The window's forge sheets, attached once to its content, since a sheet
/// on a toolbar item is lost when the item overflows.
struct ForgeSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var forge = model.forge
        content.sheet(isPresented: $forge.isPublishing) { PublishSheet() }
    }
}

/// Branch → Create Pull Request (in `BranchCommands`). ⌘R is Refresh, so
/// not GitHub Desktop's ⌘R.
struct CreatePullRequestButton: View {
    let model: AppModel

    var body: some View {
        Button("Create Pull Request") { openNewChangeRequest(model.forge) }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(model.forge.newChangeRequestBlocker != nil)
    }
}

/// Repository → Publish Repository… (in `RepositoryCommands`).
struct PublishRepositoryButton: View {
    let model: AppModel

    var body: some View {
        Button("Publish Repository…") { model.forge.isPublishing = true }
            .disabled(model.selected == nil || model.forge.remotes != [])
    }
}

@MainActor private func openNewChangeRequest(_ forge: ForgeModel) {
    Task { if let url = await forge.newChangeRequestURL() { NSWorkspace.shared.open(url) } }
}

// MARK: CI

private struct CIIcon: View {
    let state: CIState?

    var body: some View {
        switch state {
        case .success: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .pending: Image(systemName: "clock.fill").foregroundStyle(.orange)
        case nil: Image(systemName: "circle").hidden()  // no checks: keeps the rows aligned
        }
    }
}

private func summary(_ checks: [Check]) -> String {
    let failed = checks.count { $0.state == .failure }
    let pending = checks.count { $0.state == .pending }
    if failed > 0 { return "\(failed) of \(checks.count) checks failed" }
    if pending > 0 { return "\(pending) of \(checks.count) checks running" }
    return "All \(checks.count) checks passed"
}

/// The current branch's CI state; its popover lists every check, failing
/// ones first, each linked to its page.
private struct ChecksButton: View {
    let checks: [Check]
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            CIIcon(state: CIState(combining: checks.map(\.state)))
        }
        .help(summary(checks))
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(summary(checks)).font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(checks) { check in
                            HStack {
                                CIIcon(state: check.state)
                                Text(check.name).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if let url = check.url { Link("Details", destination: url) }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .padding()
            .frame(width: 340)
        }
    }
}

// MARK: Pull requests

private struct PullRequestsButton: View {
    @Environment(AppModel.self) private var model
    @State private var shown = false

    var body: some View {
        let count = model.forge.changeRequests?.count ?? 0
        Button {
            shown.toggle()
        } label: {
            Label(count > 0 ? "\(count)" : "Pull Requests", systemImage: "arrow.triangle.pull")
                .labelStyle(count > 0 ? AnyLabelStyle(.titleAndIcon) : AnyLabelStyle(.iconOnly))
        }
        .help("Pull requests")
        .popover(isPresented: $shown, arrowEdge: .bottom) { PullRequestList(dismiss: { shown = false }) }
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init(_ style: some LabelStyle) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

private struct PullRequestList: View {
    @Environment(AppModel.self) private var model
    let dismiss: () -> Void

    var body: some View {
        let forge = model.forge
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Pull Requests").font(.headline)
                Spacer()
                Button("Create Pull Request") {
                    openNewChangeRequest(forge)
                    dismiss()
                }
                .disabled(forge.newChangeRequestBlocker != nil)
                .help(forge.newChangeRequestBlocker ?? "Open GitHub's form for this branch (⌥⌘R)")
            }
            if let repo = forge.repo, forge.account(for: repo.host) == nil {
                Text("Sign in to \(repo.host) in Settings → Accounts to see its pull requests.")
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
            } else if let requests = forge.changeRequests {
                if requests.isEmpty {
                    Text("No open pull requests.").foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(requests) { request in row(request) }
                        }
                    }
                    .frame(maxHeight: 400)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let problem = forge.problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(
                    .secondary)
            }
        }
        .padding()
        .frame(width: 420)
        .task { await forge.refreshChangeRequests() }
    }

    private func row(_ request: ChangeRequest) -> some View {
        HStack(alignment: .firstTextBaseline) {
            CIIcon(state: request.ci)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).lineLimit(2)
                HStack(spacing: 4) {
                    Text("#\(request.number)").monospacedDigit()
                    if let author = request.author { Text("by \(author)") }
                    if request.isDraft {
                        Text("Draft").padding(.horizontal, 4).background(.quaternary, in: .capsule)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let url = request.url {
                Link(destination: url) { Image(systemName: "safari") }.help("Open on GitHub")
            }
            Button("Check Out") {
                dismiss()
                Task { await model.forge.checkOut(request) }
            }
            .help(
                request.isFromFork
                    ? "Fetch it into pr/\(request.number)" : "Switch to \(request.sourceBranch)")
        }
    }
}

// MARK: Publishing

private struct PublishSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var owners: [String] = []
    @State private var owner = ""
    @State private var name = ""
    @State private var description = ""
    @State private var isPrivate = true

    var body: some View {
        let forge = model.forge
        let account = forge.account(for: host)
        VStack(alignment: .leading, spacing: 0) {
            Form {
                if forge.accounts.isEmpty {
                    Text("Sign in to GitHub in Settings → Accounts to publish.")
                    SettingsLink { Text("Open Settings…") }
                } else {
                    if forge.accounts.count > 1 {
                        Picker("Account", selection: $host) {
                            ForEach(forge.accounts) { Text("\($0.login) on \($0.host)").tag($0.host) }
                        }
                    }
                    Picker("Owner", selection: $owner) {
                        ForEach(owners, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Name", text: $name)
                    TextField("Description", text: $description, prompt: Text("Optional"))
                    Toggle("Keep this code private", isOn: $isPrivate)
                }
            }
            .formStyle(.grouped)
            HStack {
                if !model.hasHead { Text("Commit something first.").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Publish Repository") {
                    guard let account else { return }
                    let (owner, name, description, isPrivate) = (owner, name, description, isPrivate)
                    dismiss()
                    Task {
                        await forge.publish(
                            account: account, owner: owner, name: name, description: description,
                            isPrivate: isPrivate)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(account == nil || owner.isEmpty || name.isEmpty || !model.hasHead)
            }
            .padding()
        }
        .frame(width: 440)
        .onAppear {
            host = forge.accounts.first?.host ?? ""
            name = model.selected?.lastPathComponent.replacing(" ", with: "-") ?? ""
        }
        .task(id: host) {
            guard let account = forge.account(for: host) else { return }
            owners = [account.login]
            owner = account.login
            if let all = try? await forge.owners(for: account) { owners = all }
        }
    }
}

// MARK: Settings

/// Settings → Accounts: sign in to GitHub or a GitHub Enterprise Server.
struct AccountsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var enterprise = false
    @State private var host = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    @State private var browserSignIn: Task<Void, Never>?

    var body: some View {
        let forge = model.forge
        Form {
            Section("Accounts") {
                if forge.accounts.isEmpty {
                    Text("Not signed in. Plain git works with every host without an account.")
                        .foregroundStyle(.secondary)
                }
                ForEach(forge.accounts) { account in
                    LabeledContent {
                        Button("Sign Out") { forge.signOut(account) }
                    } label: {
                        Text(account.login)
                        Text(account.host)
                    }
                }
            }
            Section("GitHub.com") {
                if let code = forge.deviceCode {
                    LabeledContent("Enter this code on GitHub") {
                        Text(code.userCode).font(.title3.monospaced()).textSelection(.enabled)
                    }
                    HStack {
                        Button("Copy Code and Open GitHub") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(code.userCode, forType: .string)
                            NSWorkspace.shared.open(code.verificationURL)
                        }
                        Button("Cancel") { browserSignIn?.cancel() }
                    }
                } else {
                    Button("Sign In with Browser…") { signInWithBrowser() }
                        .disabled(busy)
                }
            }
            Section("Personal access token") {
                Picker("Server", selection: $enterprise) {
                    Text("GitHub.com").tag(false)
                    Text("GitHub Enterprise Server").tag(true)
                }
                if enterprise { TextField("Host", text: $host, prompt: Text("github.example.com")) }
                SecureField("Token", text: $token)
                HStack {
                    Text("A classic token with the repo, workflow and read:org scopes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let url = GitHub.newTokenURL(host: tokenHost) {
                        Link("Create one…", destination: url).font(.caption)
                    }
                    Spacer()
                    Button("Sign In") { signInWithToken() }
                        .disabled(token.isEmpty || busy || ForgeModel.host(from: tokenHost).isEmpty)
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
            Text(
                "Tokens are kept in the Keychain. Signing out deletes Upstream's copy; revoke the token on GitHub to end it there."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var tokenHost: String { enterprise ? host : "github.com" }

    private func signInWithToken() {
        busy = true
        error = nil
        Task {
            do {
                try await model.forge.signIn(host: tokenHost, token: token)
                token = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func signInWithBrowser() {
        busy = true
        error = nil
        browserSignIn = Task {
            do {
                try await model.forge.signInWithBrowser()
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

// MARK: Cloning

/// The signed-in accounts' repositories, for the clone sheet. `pick` gets
/// the chosen repository's clone URL.
struct AccountRepositoryPicker: View {
    let pick: (String) -> Void
    @Environment(AppModel.self) private var model
    @State private var repositories: [ForgeRepository]?
    @State private var error: String?
    @State private var filter = ""
    @State private var selection: ForgeRepository.ID?

    var body: some View {
        let forge = model.forge
        VStack(alignment: .leading) {
            if forge.accounts.isEmpty {
                ContentUnavailableView {
                    Label("Not signed in", systemImage: "person.crop.circle")
                } description: {
                    Text("Sign in to GitHub in Settings → Accounts to list your repositories.")
                } actions: {
                    SettingsLink { Text("Open Settings…") }
                }
            } else {
                TextField("Filter", text: $filter, prompt: Text("Filter your repositories"))
                    .textFieldStyle(.roundedBorder)
                List(shown, selection: $selection) { repository in
                    Label(repository.fullName, systemImage: repository.isPrivate ? "lock" : "book.closed")
                        .help(repository.description ?? repository.fullName)
                }
                .overlay {
                    if let error {
                        Text(error).foregroundStyle(.secondary).padding()
                    } else if repositories == nil {
                        ProgressView()
                    }
                }
            }
        }
        .task(id: forge.accounts) {
            guard !forge.accounts.isEmpty else { return }
            do {
                repositories = try await forge.repositories()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
        .onChange(of: selection) { if let selection { pick(selection) } }
    }

    private var shown: [ForgeRepository] {
        let all = repositories ?? []
        let words = filter.split(separator: " ")
        return words.isEmpty
            ? all : all.filter { r in words.allSatisfy { r.fullName.localizedStandardContains($0) } }
    }
}
