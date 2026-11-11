import AppKit
import SwiftUI
import UpstreamKit

/// The Changes tab's diff: the selected file against HEAD, with its lines
/// checkable for the commit.
struct ChangesDiffView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let diff = model.diff {
                let change = model.status?.files.first { $0.id == model.selectedFile }
                DiffView(
                    diff: diff, checked: checkedLines(diff, change), path: change?.path,
                    images: images(change), discard: { model.requestDiscardLines($0) }
                ) {
                    index in
                    model.toggleLines(diff.lines[index].kind == .hunk ? Array(diff.hunk(at: index)) : [index])
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if diff.ignoresWhitespace, !diff.lines.isEmpty {
                        Text("Lines can’t be checked while whitespace is hidden.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(6)
                            .background(.bar)
                    }
                }
            } else {
                ContentUnavailableView(
                    "Select a file to see its changes", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    /// For each line: whether it is checked, or nil where there is nothing
    /// to check (context, or a file that commits whole). A hunk header is
    /// checked when any of its lines is.
    private func checkedLines(_ diff: FileDiff, _ change: FileChange?) -> (Int) -> Bool? {
        guard diff.canSelectLines, let change else { return { _ in nil } }
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

    /// HEAD's image and the working tree's.
    private func images(_ change: FileChange?) -> (@Sendable () async -> DiffImages)? {
        guard let change, let git = model.git, let repo = model.selected else { return nil }
        let hasHead = model.hasHead
        return { await DiffImages.workingTree(change, hasHead: hasHead, in: repo, git: git) }
    }
}

/// A diff, used by Changes and History alike: unified or split, with the
/// changed words highlighted, an image side by side, and a large diff only
/// once asked for (docs/plans/007_the_diff_view.md). Where `checked` gives
/// a value, clicking a line's number calls `toggle` with its index (a hunk
/// header's index for its whole hunk), as in GitHub Desktop.
///
/// `path` names the file: an image is drawn from `images` when it has an
/// image's extension, and "Show Diff" is forgotten when it changes. The
/// split and whitespace settings are kept in the user defaults under
/// `splitKey` and `hideWhitespaceKey`; whoever loads the diff reads the
/// latter and passes `ignoringWhitespace` to `FileDiff.arguments`.
struct DiffView: View {
    static let splitKey = "diffSplit"
    static let hideWhitespaceKey = "diffHideWhitespace"

    let diff: FileDiff
    let checked: (Int) -> Bool?
    let path: String?
    let images: (@Sendable () async -> DiffImages)?
    let discard: (([Int]) -> Void)?
    let toggle: (Int) -> Void
    @AppStorage(splitKey) private var split = false
    @AppStorage(hideWhitespaceKey) private var hideWhitespace = false

    init(
        diff: FileDiff, checked: @escaping (Int) -> Bool? = { _ in nil }, path: String? = nil,
        images: (@Sendable () async -> DiffImages)? = nil, discard: (([Int]) -> Void)? = nil,
        toggle: @escaping (Int) -> Void = { _ in }
    ) {
        self.diff = diff
        self.checked = checked
        self.path = path
        self.images = images
        self.discard = discard
        self.toggle = toggle
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if let path {
                    Text(path)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .foregroundStyle(.secondary)
                        .help(path)
                }
                Spacer()
                Toggle("Hide Whitespace", isOn: $hideWhitespace)
                    .toggleStyle(.checkbox)
                Picker("View", selection: $split) {
                    Label("Unified", systemImage: "rectangle").tag(false)
                    Label("Split", systemImage: "rectangle.split.2x1").tag(true)
                }
                .pickerStyle(.segmented)
                .labelStyle(.iconOnly)
                .labelsHidden()
                .fixedSize()
                .help("Unified or split view")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.bar)
            Divider()
            DiffContent(
                diff: diff, split: split, checked: checked, path: path, images: images, discard: discard,
                toggle: toggle
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(path)
        }
    }
}

/// What goes under the options: the lines, an image, or why neither.
private struct DiffContent: View {
    let diff: FileDiff
    let split: Bool
    let checked: (Int) -> Bool?
    let path: String?
    let images: (@Sendable () async -> DiffImages)?
    let discard: (([Int]) -> Void)?
    let toggle: (Int) -> Void
    @State private var showLarge = false

    var body: some View {
        if let path, DiffImages.isImage(path), let images {
            ImageDiffView(load: images, diff: diff)
        } else if diff.exceedsCeiling {
            ContentUnavailableView(
                "This diff is too large to show", systemImage: "doc.text",
                description: Text(
                    "git printed more than \(FileDiff.byteCeiling.formatted(.byteCount(style: .file))) for it. Its checkbox still commits it whole."
                ))
        } else if diff.isBinary {
            ContentUnavailableView("Binary file", systemImage: "doc")
        } else if diff.lines.isEmpty {
            ContentUnavailableView(
                diff.ignoresWhitespace ? "Only whitespace changed" : "No content changes",
                systemImage: "doc.text")
        } else if diff.isLarge, !showLarge {
            ContentUnavailableView {
                Label("This diff is large", systemImage: "doc.text")
            } description: {
                Text(
                    "\(diff.lines.count.formatted()) lines. A diff this size is usually a generated file, such as a lockfile or a bundle."
                )
            } actions: {
                Button("Show Diff") { showLarge = true }
            }
        } else {
            DiffTable(diff: diff, split: split, checked: checked, toggle: toggle, discard: discard)
        }
    }
}

/// An image's old and new versions side by side, each with its size; an
/// added or deleted image is one side alone.
private struct ImageDiffView: View {
    let load: @Sendable () async -> DiffImages
    /// Changes with the image's blob, so a new version is loaded again.
    let diff: FileDiff
    @State private var sides: (old: Side?, new: Side?)?

    /// One version, decoded once rather than on every redraw.
    struct Side {
        let image: NSImage?
        let bytes: Int

        init(_ data: Data) {
            image = NSImage(data: data)
            bytes = data.count
        }

        /// The largest representation's pixels: an icon holds several sizes.
        var pixels: (Int, Int)? {
            guard let rep = image?.representations.max(by: { $0.pixelsWide < $1.pixelsWide }) else {
                return nil
            }
            return (rep.pixelsWide, rep.pixelsHigh)
        }
    }

    var body: some View {
        Group {
            if let sides {
                if sides.old == nil, sides.new == nil {
                    ContentUnavailableView("The image could not be read", systemImage: "photo")
                } else {
                    HStack(alignment: .top, spacing: 16) {
                        if let old = sides.old { side("Before", old, .red) }
                        if let new = sides.new { side("After", new, .green) }
                    }
                    .padding()
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: diff) {
            let loaded = await load()
            sides = (loaded.old.map(Side.init), loaded.new.map(Side.init))
        }
    }

    private func side(_ title: String, _ side: Side, _ tint: Color) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            if let image = side.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: CGFloat(side.pixels?.0 ?? 0), maxHeight: CGFloat(side.pixels?.1 ?? 0))
                    .padding(4)
                    .border(tint.opacity(0.6))
            } else {
                ContentUnavailableView("Not an image macOS can open", systemImage: "photo")
            }
            Text(
                [side.pixels.map { "\($0.0) × \($0.1)" }, side.bytes.formatted(.byteCount(style: .file))]
                    .compactMap { $0 }.joined(separator: " · ")
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
