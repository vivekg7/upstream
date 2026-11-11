import SwiftUI
import UpstreamKit

/// A plain unified diff. Lazy rows keep a long diff cheap to open; a
/// TextKit view with word-level highlights and a split mode replaces it
/// (docs/REQUIREMENTS.md#diff). Clicking a changed line's gutter checks or
/// unchecks it for the commit, and a hunk header does the same for its
/// whole hunk, as in GitHub Desktop.
struct DiffView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let diff = model.diff {
            if diff.isBinary {
                ContentUnavailableView("Binary file", systemImage: "doc")
            } else if diff.lines.isEmpty {
                ContentUnavailableView("No content changes", systemImage: "doc.text")
            } else {
                let checked = checkedLines(diff)
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(diff.lines.enumerated()), id: \.offset) { index, line in
                            DiffRow(line: line, checked: checked(index)) {
                                model.toggleLines(line.kind == .hunk ? Array(diff.hunk(at: index)) : [index])
                            }
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

    /// For each line: whether it is checked, or nil where there is nothing
    /// to check (context, or a file that commits whole). A hunk header is
    /// checked when any of its lines is.
    private func checkedLines(_ diff: FileDiff) -> (Int) -> Bool? {
        guard diff.canSelectLines,
            let change = model.status?.files.first(where: { $0.id == model.selectedFile })
        else { return { _ in nil } }
        let selection = model.selection(of: change)
        func isOn(_ k: Int) -> Bool {
            switch selection {
            case .all: true
            case .nothing: false
            case .lines(let picked, _): picked.contains(k)
            }
        }
        return { index in
            switch diff.lines[index].kind {
            case .added, .removed: isOn(index)
            case .hunk: diff.hunk(at: index).contains(where: isOn)
            case .context, .noNewline: nil
            }
        }
    }
}

private struct DiffRow: View {
    let line: DiffLine
    let checked: Bool?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            gutter
            Text(marker + line.text)
                .foregroundStyle(line.kind == .hunk || line.kind == .noNewline ? .secondary : .primary)
                .fixedSize()
                .padding(.leading, 6)
            Spacer(minLength: 0)
        }
        // An unchecked change stays in the working tree: drawn faded.
        .background(background.opacity(checked == false ? 0.4 : 1))
    }

    /// Line numbers, tinted when the line is checked, and clickable.
    @ViewBuilder private var gutter: some View {
        let numbers = HStack(spacing: 0) {
            number(line.oldLine)
            number(line.newLine)
        }
        if let checked {
            Button(action: toggle) {
                numbers
                    .background(checked ? Color.accentColor.opacity(0.35) : .clear)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(checked ? "Uncheck line" : "Check line")
        } else {
            numbers
        }
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
