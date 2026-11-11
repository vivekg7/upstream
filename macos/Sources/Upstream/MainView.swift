import SwiftUI
import UpstreamKit

/// Repositories, then the selected one's changes or history, then the diff:
/// the columns GitHub Desktop users already know.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DiffView.hideWhitespaceKey) private var hideWhitespace = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            RepositoryList()
                .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } content: {
            VStack(spacing: 0) {
                Picker("View", selection: $model.tab) {
                    Text("Changes").tag(AppModel.Tab.changes)
                    Text("History").tag(AppModel.Tab.history)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(8)
                switch model.tab {
                case .changes: ChangesView()
                case .history: HistoryView()
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            switch model.tab {
            case .changes: ChangesDiffView()
            case .history: HistoryDetailView()
            }
        }
        .toolbar {
            if model.selected != nil {
                ToolbarItemGroup(placement: .navigation) { BranchToolbar() }
                if let activity = model.activity {
                    // Its own item without the glass: shared with the
                    // buttons, the capsule shrank to the spinner and left
                    // it off-centre. A spinner is status, not a control.
                    ToolbarItem(placement: .primaryAction) {
                        ProgressView().controlSize(.small).help(activity)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    ForgeToolbar()
                    RemoteToolbar()
                }
            }
        }
        .navigationTitle(model.selected?.lastPathComponent ?? "Upstream")
        // Whitespace changes what git is asked for, so the model reads it,
        // for Changes and History alike.
        .onChange(of: hideWhitespace, initial: true) { model.hidesWhitespace = hideWhitespace }
        .modifier(ForgeSheets())
        .modifier(BranchDialogs())
        .safeAreaInset(edge: .top, spacing: 0) {
            if let error = model.error { ErrorBanner(message: error) { model.error = nil } }
        }
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
    }
}

/// The last failure, in git's own words, until dismissed.
private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(6)
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(10)
        .background(.red.opacity(0.12))
    }
}
