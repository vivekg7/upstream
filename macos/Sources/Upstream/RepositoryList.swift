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
            Menu("Add", systemImage: "plus") {
                Button("New Repository…") { library.sheet = .create }
                Button("Add Local Repository…") {
                    if let url = chooseFolder(prompt: "Add Repository") { Task { await model.add(url) } }
                }
                Button("Clone Repository…") { library.sheet = .clone }
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
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
        .task(id: Trigger(repositories: model.repositories, selected: model.selected, active: model.isActive))
        {
            await library.update()
        }
    }

    private struct Trigger: Equatable {
        let repositories: [URL]
        let selected: URL?
        let active: Bool
    }

    private func row(_ url: URL) -> some View {
        let missing = model.library.missing.contains(url)
        return Label {
            Text(url.lastPathComponent).foregroundStyle(missing ? .secondary : .primary)
        } icon: {
            Image(systemName: missing ? "exclamationmark.triangle" : "folder")
        }
        .help(missing ? "Not found at \(url.path)" : url.path)
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
