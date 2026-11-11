import AppKit
import SwiftUI
import UpstreamKit

/// The diff's lines in an `NSTableView`: rows of one fixed height, each
/// drawn in a single pass, and only the visible ones exist. SwiftUI's lazy
/// stack kept every row it had shown alive (570 MB after scrolling 4,500
/// lines) and took 70 ms a frame to scroll fast; this takes 3 ms and stays
/// near 60 MB (docs/plans/007_the_diff_view.md).
struct DiffTable: NSViewRepresentable {
    let diff: FileDiff
    let split: Bool
    let checked: (Int) -> Bool?
    let toggle: (Int) -> Void
    /// Offered on a right-click when set: discard these lines' changes.
    let discard: (([Int]) -> Void)?

    func makeCoordinator() -> DiffTableController { DiffTableController() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(diff: diff, split: split, checked: checked, toggle: toggle)
        context.coordinator.discard = discard
    }
}

/// Owns the table and answers it: the rows, their drawing, the word
/// highlights (worked out for a row when it is first drawn, then kept).
@MainActor final class DiffTableController: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scrollView = NSScrollView()
    let table = DiffTableView()
    private let column = NSTableColumn(identifier: .init("line"))

    private(set) var diff = FileDiff(parsing: Data())
    private(set) var split = false
    private(set) var checked: (Int) -> Bool? = { _ in nil }
    private(set) var toggle: (Int) -> Void = { _ in }
    var discard: (([Int]) -> Void)?
    /// In the unified view each row is one line, on both "sides".
    private(set) var rows: [SplitRow] = []
    private var partners: [Int: Int] = [:]
    private var words: [Int: [Range<Int>]] = [:]
    /// The width of one line-number column.
    private(set) var numberWidth: CGFloat = 0
    private var textWidth: CGFloat = 0

    override init() {
        super.init()
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.rowHeight = DiffMetrics.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none  // drawn by the row, under its own colours
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = .textBackgroundColor
        table.controller = self
        table.dataSource = self
        table.delegate = self
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
    }

    func update(
        diff: FileDiff, split: Bool, checked: @escaping (Int) -> Bool?, toggle: @escaping (Int) -> Void
    ) {
        self.checked = checked
        self.toggle = toggle
        let newDiff = diff != self.diff
        guard newDiff || split != self.split else {
            redrawVisibleRows()  // only the checkboxes can have changed
            return
        }
        self.diff = diff
        self.split = split
        rows = split ? diff.splitRows : diff.lines.indices.map { SplitRow(old: $0, new: $0) }
        if newDiff {
            partners = diff.partners
            words = [:]
            measure()
        }
        // Split halves share the width, clipping long lines; unified scrolls
        // sideways to the longest line.
        column.minWidth = split ? 0 : 2 * numberWidth + textWidth
        column.width = max(column.minWidth, scrollView.contentView.bounds.width)
        table.reloadData()
        // Another file is another table (`DiffView` keys it by path), so a
        // reload keeps the place: the same file, edited, does not jump.
        table.sizeLastColumnToFit()
    }

    /// Line numbers' and the longest line's widths: the font is monospaced.
    private func measure() {
        let biggest = diff.lines.reduce(0) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        let a = DiffMetrics.advance
        numberWidth = CGFloat(max(3, String(biggest).count)) * a + 12
        // A cut line ends in a note of some 50 characters.
        let columns = diff.widestLine(cappedAt: Self.maxDrawn + 50)
        textWidth = CGFloat(columns + 1) * a + 2 * DiffMetrics.textInset
    }

    /// Longer lines are drawn cut short, with a note: laying out a megabyte
    /// of minified code on one line would stall every frame. The committed
    /// bytes and the copied text are whole.
    static let maxDrawn = 1_000

    /// Whether the row is one line across the width: every row of the
    /// unified view, and a hunk header in the split view.
    func spansBothSides(_ row: Int) -> Bool {
        !split || (rows[row].old.map { diff.lines[$0].kind == .hunk } ?? false)
    }

    /// The changed words of line `k` against its partner, worked out once.
    func words(_ k: Int) -> [Range<Int>] {
        if let known = words[k] { return known }
        guard let partner = partners[k] else { return [] }
        let (old, new) = diff.lines[k].kind == .removed ? (k, partner) : (partner, k)
        let changes = WordDiff.changes(old: diff.lines[old].text, new: diff.lines[new].text)
        words[old] = changes?.old ?? []
        words[new] = changes?.new ?? []
        return words[k] ?? []
    }

    func redrawVisibleRows() {
        table.enumerateAvailableRowViews { rowView, _ in
            rowView.subviews.forEach { $0.needsDisplay = true }
        }
    }

    // MARK: NSTableViewDataSource, NSTableViewDelegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view =
            tableView.makeView(withIdentifier: DiffRowView.id, owner: nil) as? DiffRowView ?? DiffRowView()
        view.identifier = DiffRowView.id
        view.controller = self
        view.row = row
        view.needsDisplay = true
        return view
    }

    func tableViewSelectionDidChange(_ notification: Notification) { redrawVisibleRows() }

    func accessibilityLabel(_ row: Int) -> String? {
        lines(of: row).map { k in
            let line = diff.lines[k]
            return (line.kind == .added ? "Added: " : line.kind == .removed ? "Removed: " : "") + line.text
        }.joined(separator: "; ")
    }

    func accessibilityActions(_ row: Int) -> [NSAccessibilityCustomAction] {
        lines(of: row).compactMap { k in
            guard let on = checked(k) else { return nil }
            return NSAccessibilityCustomAction(name: on ? "Uncheck line" : "Check line") { [weak self] in
                self?.toggle(k)
                return true
            }
        }
    }

    /// The lines a row shows: one, or an old and a new side by side.
    private func lines(of row: Int) -> [Int] {
        guard row < rows.count else { return [] }
        let r = rows[row]
        return [r.old, r.new == r.old ? nil : r.new].compactMap { $0 }
    }

    /// The line whose number is at `x` in `row`, when it can be checked: a
    /// click there checks or unchecks it, or a hunk header's whole hunk.
    func checkable(row: Int, x: CGFloat) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        let r = rows[row]
        let half = floor(table.bounds.width / 2)
        let k =
            spansBothSides(row)
            ? (x < 2 * numberWidth ? r.old : nil)
            : x < numberWidth ? r.old : (x >= half && x < half + numberWidth ? r.new : nil)
        return k.flatMap { checked($0) != nil ? $0 : nil }
    }

    /// The selected rows' lines, whole and without markers, for ⌘C.
    func copySelection() {
        var lines = IndexSet()
        for row in table.selectedRowIndexes where row < rows.count {
            if let k = rows[row].old { lines.insert(k) }
            if let k = rows[row].new { lines.insert(k) }
        }
        guard !lines.isEmpty else { return }
        let text = lines.map { diff.lines[$0].text }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// The right-click menu on `row`: copy, and discard the line, its hunk
    /// (on a hunk header), or the selected lines when `row` is among them.
    func menu(row: Int) -> NSMenu? {
        guard row >= 0, row < rows.count else { return nil }
        if !table.isRowSelected(row) {
            table.selectRowIndexes([row], byExtendingSelection: false)
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy", action: #selector(DiffTableView.copy(_:)), keyEquivalent: "")
        guard discard != nil else { return menu }
        let selected = table.selectedRowIndexes.flatMap { lines(of: $0) }
        let targets: [Int]
        let title: String
        if selected.count == 1, diff.lines[selected[0]].kind == .hunk {
            (targets, title) = (Array(diff.hunk(at: selected[0])), "Discard Hunk…")
        } else {
            targets = selected.filter { [.added, .removed].contains(diff.lines[$0].kind) }
            title = targets.count == 1 ? "Discard Line…" : "Discard Selected Lines…"
        }
        guard targets.contains(where: { checked($0) != nil }) else { return menu }
        menu.addItem(.separator())
        let item = menu.addItem(withTitle: title, action: #selector(discardChosen(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = targets
        return menu
    }

    @objc private func discardChosen(_ item: NSMenuItem) {
        if let targets = item.representedObject as? [Int] { discard?(targets) }
    }

    // MARK: Drawing

    /// Draws `row` whole: in the unified view a line with its old and new
    /// numbers; in the split view the old line on the left and the new on
    /// the right, each with its own number.
    func draw(row: Int, in bounds: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        guard row < rows.count else { return }
        let r = rows[row]
        let selected = table.isRowSelected(row)
        if spansBothSides(row) {
            draw(r.old ?? r.new, numbers: 2, in: bounds, selected: selected)
            return
        }
        let half = floor(bounds.width / 2)
        let height = bounds.height
        draw(
            r.old, numbers: 1, side: .old, in: NSRect(x: 0, y: 0, width: half, height: height),
            selected: selected)
        draw(
            r.new, numbers: 1, side: .new,
            in: NSRect(x: half, y: 0, width: bounds.width - half, height: height),
            selected: selected)
        NSColor.separatorColor.setFill()
        NSRect(x: half, y: 0, width: 1, height: height).fill()
    }

    private enum Side { case old, new, both }

    private func draw(_ k: Int?, numbers: Int, side: Side = .both, in rect: NSRect, selected: Bool) {
        let gutter = CGFloat(numbers) * numberWidth
        guard let k else {
            // The empty side of an unpaired change.
            NSColor.quaternaryLabelColor.withAlphaComponent(0.05).setFill()
            rect.fill()
            return
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        rect.clip()
        let line = diff.lines[k]
        let checked = checked(k)
        // An unchecked change stays in the working tree: drawn faded.
        if let (fill, alpha) = Self.background(line.kind) {
            fill.withAlphaComponent(checked == false ? alpha * 0.4 : alpha).setFill()
            rect.fill()
        }
        if selected {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.6).setFill()
            rect.fill()
        }
        if checked == true {
            NSColor.controlAccentColor.withAlphaComponent(0.35).setFill()
            NSRect(x: rect.minX, y: rect.minY, width: gutter, height: rect.height).fill()
        }
        let y = rect.minY + (rect.height - DiffMetrics.lineHeight) / 2
        let shown: [Int?] =
            switch side {
            case .both: [line.oldLine, line.newLine]
            case .old: [line.oldLine]
            case .new: [line.newLine]
            }
        for (i, n) in shown.enumerated() {
            guard let n else { continue }
            let s = String(n) as NSString
            let x = rect.minX + CGFloat(i + 1) * numberWidth - CGFloat(s.length) * DiffMetrics.advance - 6
            s.draw(at: NSPoint(x: x, y: y), withAttributes: DiffMetrics.number)
        }
        text(line, k, marker: !split).draw(at: NSPoint(x: rect.minX + gutter + DiffMetrics.textInset, y: y))
    }

    /// The line's text, cut at `maxDrawn`, with its changed words highlighted.
    private func text(_ line: DiffLine, _ k: Int, marker: Bool) -> NSAttributedString {
        let prefix: String =
            switch line.kind {
            case _ where !marker: ""
            case .added: "+"
            case .removed: "-"
            case .context: " "
            case .hunk, .noNewline: ""
            }
        let s = NSMutableAttributedString(string: prefix, attributes: DiffMetrics.text)
        let full = line.text as NSString
        let cut = full.length > Self.maxDrawn
        let body =
            cut
            ? full.substring(  // whole characters, not half a surrogate pair
                with: full.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: Self.maxDrawn))
            )
            : line.text
        let quiet = line.kind == .hunk || line.kind == .noNewline
        s.append(NSAttributedString(string: body, attributes: quiet ? DiffMetrics.quiet : DiffMetrics.text))
        if line.kind == .added || line.kind == .removed, let (tint, _) = Self.background(line.kind) {
            let length = (body as NSString).length
            for r in words(k) where r.lowerBound < length {
                let range = NSRange(
                    location: prefix.utf16.count + r.lowerBound,
                    length: min(r.upperBound, length) - r.lowerBound)
                s.addAttribute(.backgroundColor, value: tint.withAlphaComponent(0.35), range: range)
            }
        }
        if cut {
            let more = (full.length - (body as NSString).length).formatted()
            s.append(
                NSAttributedString(
                    string: "  … \(more) more characters, copy the line to see them",
                    attributes: DiffMetrics.quiet))
        }
        return s
    }

    private static func background(_ kind: DiffLine.Kind) -> (NSColor, CGFloat)? {
        switch kind {
        case .added: (.systemGreen, 0.15)
        case .removed: (.systemRed, 0.15)
        case .hunk: (.systemBlue, 0.08)
        case .context, .noNewline: nil
        }
    }
}

/// Clicks on line numbers, and copying.
final class DiffTableView: NSTableView {
    weak var controller: DiffTableController?

    @objc func copy(_ sender: Any?) { controller?.copySelection() }

    override func menu(for event: NSEvent) -> NSMenu? {
        controller?.menu(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    /// A click on a line number checks or unchecks the line; anywhere else
    /// selects rows, for copying.
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let controller, let k = controller.checkable(row: row(at: p), x: p.x) {
            controller.toggle(k)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// One row, drawn whole by the controller. It reads to VoiceOver as its
/// line, with checking it offered as an action.
final class DiffRowView: NSView {
    static let id = NSUserInterfaceItemIdentifier("DiffRow")
    weak var controller: DiffTableController?
    var row = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) { controller?.draw(row: row, in: bounds) }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { controller?.accessibilityLabel(row) }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        controller?.accessibilityActions(row)
    }
}

/// The font and the sizes every row shares.
@MainActor enum DiffMetrics {
    static let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
    static let lineHeight = ceil(font.ascender - font.descender + font.leading)
    static let rowHeight = lineHeight + 3
    static let textInset: CGFloat = 6

    static let paragraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = 4 * advance
        style.lineBreakMode = .byClipping
        return style
    }()
    static let text: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
    ]
    static let quiet: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
    ]
    static let number: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.tertiaryLabelColor,
    ]
}
