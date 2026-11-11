import SwiftUI
import UpstreamKit

/// The sidebar: every repository the user added, grouped by owner and
/// filterable (docs/plans/009_repositories_and_settings.md). Rows carry no
/// change counts or ahead/behind: those would cost a `git status` per
/// repository, and the selected one's are already in the toolbar.
struct RepositoryList: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""

    var body: some View {
        @Bindable var model = model
        @Bindable var library = model.library
        List(selection: $model.selected) {
            if library.loaded {
                ForEach(library.groups(filter: filter), id: \.owner) { group in
                    Section {
                        ForEach(group.repositories, id: \.self, content: row)
                    } header: {
                        if let owner = group.owner {
                            Text(owner.path).help(owner.description)
                        } else {
                            Text("Other")
                        }
                    }
                }
            } else {
                ForEach(model.repositories, id: \.self, content: row)
            }
        }
        .searchable(text: $filter, placement: .sidebar, prompt: "Filter")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Menu {
                Button("New Repository…") { library.sheet = .create }
                Button("Add Local Repository…") {
                    if let url = chooseFolder(prompt: "Add Repository") { Task { await model.add(url) } }
                }
                Button("Clone Repository…") { library.sheet = .clone }
            } label: {
                // A bubble in the accent colour: a bare plus sat on whichever
                // row scrolled under it and read as part of it. Drawn, not
                // `.glassProminent`, which is clear grey glass whenever the
                // window is not key, and the rows showed through it.
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor, in: .circle)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .contentShape(.circle)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .accessibilityLabel("Add")
            .help("Add a repository")
            .fixedSize()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .sheet(item: $library.sheet) { sheet in
            switch sheet {
            case .clone: CloneSheet()
            case .create: CreateSheet()
            }
        }
        // Folders are checked again whenever the app comes to the front, a
        // stat each; remotes are read once per repository (see `update`).
        // Signing in asks the new host which of its repositories are private.
        .task(
            id: Trigger(
                repositories: model.repositories, selected: model.selected, active: model.isActive,
                hosts: model.forge.accounts.map(\.host))
        ) {
            await library.update()
        }
    }

    private struct Trigger: Equatable {
        let repositories: [URL]
        let selected: URL?
        let active: Bool
        let hosts: [String]
    }

    private func row(_ url: URL) -> some View {
        let missing = model.library.missing.contains(url)
        let isPrivate = !missing && model.library.isPrivate(url) == true
        return Label {
            Text(url.lastPathComponent).foregroundStyle(missing ? .secondary : .primary)
        } icon: {
            if missing {
                Image(systemName: "exclamationmark.triangle")
            } else if isPrivate {
                PrivateFolder()
            } else {
                Image(systemName: "folder")
            }
        }
        .help(missing ? "Not found at \(url.path)" : isPrivate ? "\(url.path) (private)" : url.path)
        // A missing folder has nothing to show; it can only be located or removed.
        .selectionDisabled(missing)
        .contextMenu {
            if missing {
                Button("Locate…") { locate(url) }
            } else {
                Button("Open in \(ExternalApp.editor?.name ?? "Editor")") { openInEditor(url) }
                Button("Open in \(ExternalApp.terminal?.name ?? "Terminal")") { openInTerminal(url) }
                Button("Show in Finder") { showInFinder(url) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
            Divider()
            Button("Remove from List") { model.remove(url) }
        }
    }

    private func locate(_ url: URL) {
        guard let new = chooseFolder(prompt: "Locate", startingAt: url.deletingLastPathComponent()) else {
            return
        }
        Task { await model.library.locate(url, at: new) }
    }
}

/// A folder with a lock in its corner, for a private repository. SF Symbols
/// has no such symbol, so the lock is drawn over the folder, with a gap cut
/// out of the folder around it: a mask, not a fill, so the sidebar's
/// material and a selected row's colour show through. The hole is an
/// even-odd path; a `destinationOut` blend in the mask erased the whole
/// folder in the sidebar's vibrant rendering.
private struct PrivateFolder: View {
    var body: some View {
        Image(systemName: "folder")
            .mask { Notch().fill(style: FillStyle(eoFill: true)) }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill").font(.system(size: 8, weight: .bold)).offset(x: 3, y: 2)
            }
            .accessibilityLabel("Private")
    }

    /// Everything but the lock's corner, with a point to spare around it.
    private struct Notch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path(rect.insetBy(dx: -4, dy: -4))
            path.addRoundedRect(
                in: CGRect(x: rect.maxX - 5, y: rect.maxY - 7.5, width: 10, height: 12),
                cornerSize: CGSize(width: 2, height: 2))
            return path
        }
    }
}
