import SwiftUI
import UpstreamKit

/// "Stashed Changes" under the changes, as in GitHub Desktop: what the user
/// left on this branch when they switched away, to restore or discard
/// (docs/plans/005_branches_and_remotes.md).
struct StashView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let branches = model.branches
        if let entry = branches.stashes.first {
            HStack(spacing: 8) {
                Image(systemName: "tray.full").foregroundStyle(.secondary)
                Text(
                    branches.stashes.count == 1
                        ? "Stashed Changes" : "Stashed Changes (\(branches.stashes.count))"
                )
                .lineLimit(1)
                Spacer()
                Button("Restore") { Task { await branches.restoreStash() } }
                    .help("Brings the newest stashed changes back into the working tree")
                Button("Discard…") { branches.sheet = .discardStash }
            }
            .controlSize(.small)
            .disabled(model.activity != nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.bar)
            .help("Stashed \(entry.date.formatted(.relative(presentation: .named)))")
        }
    }
}
