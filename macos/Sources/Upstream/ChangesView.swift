import SwiftUI
import UpstreamKit

struct ChangesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let files = model.status?.files ?? []
        List(files, selection: $model.selectedFile) { change in
            HStack(spacing: 8) {
                StatusBadge(change: change)
                Text(change.path)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
            }
        }
        .overlay {
            if model.status != nil, files.isEmpty {
                ContentUnavailableView("No local changes", systemImage: "checkmark.circle")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let error = model.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .navigationTitle("\(files.count) changed files")
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
