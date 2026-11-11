import SwiftUI
import UpstreamKit

/// Repositories, then the selected one's changes, then the selected file's
/// diff: the three columns GitHub Desktop users already know.
struct MainView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(model.repositories, id: \.self, selection: $model.selected) { url in
                Label(url.lastPathComponent, systemImage: "folder")
                    .help(url.path)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Remove from List") { model.remove(url) }
                    }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } content: {
            ChangesView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            DiffView()
        }
        .toolbar {
            if let branch = model.status?.branch {
                ToolbarItem(placement: .navigation) { BranchLabel(branch: branch) }
            }
        }
        .navigationTitle(model.selected?.lastPathComponent ?? "Upstream")
        .overlay {
            if model.git == nil {
                ContentUnavailableView(
                    "Git is not installed", systemImage: "exclamationmark.triangle",
                    description: Text(
                        "Install the Command Line Tools with xcode-select --install, then reopen Upstream."))
            } else if model.repositories.isEmpty {
                ContentUnavailableView(
                    "No repositories", systemImage: "folder.badge.plus",
                    description: Text("File → Add Local Repository… (⌘O)"))
            }
        }
        .task { await model.refresh() }
    }
}

private struct BranchLabel: View {
    let branch: BranchInfo

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
            Text(branch.head ?? "Detached HEAD")
            if branch.ahead > 0 { Text("↑\(branch.ahead)").monospacedDigit() }
            if branch.behind > 0 { Text("↓\(branch.behind)").monospacedDigit() }
        }
        .padding(.horizontal, 8)
        .help(branch.upstream.map { "Tracking \($0)" } ?? "No upstream branch")
    }
}
