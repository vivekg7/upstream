import SwiftUI
import UpstreamKit

/// A plain unified diff. Lazy rows keep a long diff cheap to open; a
/// TextKit view with word-level highlights and a split mode replaces it
/// (docs/REQUIREMENTS.md#diff).
struct DiffView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let diff = model.diff {
            if diff.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc")
            } else if diff.lines.isEmpty {
                ContentUnavailableView("No content changes", systemImage: "doc.text")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.lines.enumerated()), id: \.offset) { _, line in
                            DiffRow(line: line)
                        }
                    }
                    .textSelection(.enabled)
                }
                .font(.system(.body, design: .monospaced))
            }
        } else {
            ContentUnavailableView(
                "Select a file to see its changes", systemImage: "doc.text.magnifyingglass")
        }
    }
}

private struct DiffRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
            Text(marker + line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .noNewline ? .secondary : .primary)
                .fixedSize()
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        .background(background)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        case .hunk, .noNewline: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: .green.opacity(0.15)
        case .removed: .red.opacity(0.15)
        case .hunk: .blue.opacity(0.08)
        case .context, .noNewline: .clear
        }
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .trailing)
            .monospacedDigit()
    }
}
