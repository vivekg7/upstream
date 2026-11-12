import SwiftUI
import UpstreamKit

/// Repositories, then the selected one's changes or history, then the diff:
/// the columns GitHub Desktop users already know.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DiffView.hideWhitespaceKey) private var hideWhitespace = false
    @FocusState private var focus: Pane?
    @State private var columns = NavigationSplitViewVisibility.automatic

    var body: some View {
        @Bindable var model = model
        NavigationSplitView(columnVisibility: $columns) {
            RepositoryList(focus: $focus)
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
                case .changes: ChangesView(focus: $focus)
                case .history: HistoryView(focus: $focus)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 300)
        } detail: {
            switch model.tab {
            case .changes: ChangesDiffView()
            case .history: HistoryDetailView(focus: $focus)
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
        .focusedSceneValue(\.goTo, GoTo { go($0) })
        // Whitespace changes what git is asked for, so the model reads it,
        // for Changes and History alike.
        .onChange(of: hideWhitespace, initial: true) { model.hidesWhitespace = hideWhitespace }
        .modifier(ForgeSheets())
        .sheet(
            isPresented: Binding {
                model.overview.pullAll != nil
            } set: {
                if !$0 { model.overview.dismissPullAll() }
            }
        ) {
            PullAllSheet()
        }
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
                    description: Text("File → Add Local Repository… (\(Shortcut.addLocalRepository.label))"))
            }
        }
    }

    /// The View menu's ⌘1, ⌘2 and ⌘T: show the pane, then put the keyboard
    /// in it.
    private func go(_ pane: Pane) {
        switch pane {
        case .changes: model.tab = .changes
        case .history: model.tab = .history
        case .filter, .repositories: if columns == .detailOnly || columns == .doubleColumn { columns = .all }
        case .commitFiles: break
        }
        // A tab's list exists only once the tab shows, so wait a turn.
        Task { moveFocus(to: pane, $focus, model) }
    }
}

/// Puts the keyboard in `pane`. A list with nothing selected selects its
/// first row on the way in, so its diff shows and ↓ goes on from there;
/// only on the way in from the keyboard, not whenever the list has focus,
/// which it is given at launch.
@MainActor func moveFocus(to pane: Pane, _ focus: FocusState<Pane?>.Binding, _ model: AppModel) {
    let history = model.history
    switch pane {
    case .changes: if model.selectedFile == nil { model.selectedFile = model.status?.files.first?.id }
    case .history: if history.selection == nil { history.selection = history.commits.first?.id }
    case .commitFiles: if history.selectedFile == nil { history.selectedFile = history.files.first?.id }
    case .filter, .repositories: break
    }
    focus.wrappedValue = pane
}

/// The parts of the main window the keyboard moves between, in order from
/// left to right (docs/plans/010_keyboard_and_help.md). ← and → move
/// between the lists, as between Finder's columns; the diff is left to
/// the mouse and Tab, since its arrow keys select lines for copying.
enum Pane: Hashable {
    case filter, repositories, changes, history, commitFiles
}

/// Moves the keyboard to a pane of the main window, for the View menu.
/// Always equal: what it captures (the view's state storage and the model)
/// is the same on every update, and a bare closure would rebuild the menus
/// each time.
struct GoTo: Equatable {
    let go: (Pane) -> Void

    func callAsFunction(_ pane: Pane) { go(pane) }
    static func == (_: GoTo, _: GoTo) -> Bool { true }
}

extension FocusedValues {
    @Entry var goTo: GoTo?
}

/// View → Show Changes, Show History, Filter Repositories and Refresh.
struct ViewCommands: Commands {
    let model: AppModel
    @FocusedValue(\.goTo) private var goTo

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Group {
                Button(Shortcut.showChanges.name) { goTo?(.changes) }
                    .keyboardShortcut(Shortcut.showChanges)
                Button(Shortcut.showHistory.name) { goTo?(.history) }
                    .keyboardShortcut(Shortcut.showHistory)
                Button(Shortcut.filterRepositories.name) { goTo?(.filter) }
                    .keyboardShortcut(Shortcut.filterRepositories)
            }
            .disabled(goTo == nil)
            Divider()
            Button(Shortcut.refresh.name) { Task { await model.refresh() } }
                .keyboardShortcut(Shortcut.refresh)
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
