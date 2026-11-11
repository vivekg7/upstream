# 007 — The diff view

**Status:** `IN PROGRESS` — renderer, split view, hidden whitespace, word highlights, image diff, the size guards and the discard menu, in Changes and History
**Started:** 2026-11-11

## Problem

The skeleton's diff was a SwiftUI `LazyVStack` of `Text` rows in a
two-way `ScrollView`. [REQUIREMENTS](../REQUIREMENTS.md#lightweight-and-fast)
asks that a 10,000-line diff open and scroll smoothly, and the
[Diff](../REQUIREMENTS.md#diff) section asks for what GitHub Desktop users
already have: a split view, hiding whitespace, word-level highlights and
images side by side. A diff can also be far larger than anything worth
drawing. A generated file of hundreds of megabytes would be read whole into
memory by `Git.run`, and then parsed.

The view is shared: the Changes tab checks lines in it for the commit
([003](003_the_checkbox_commit.md)), and the History tab shows a commit's
files in it without checkboxes.

## Measurements

Release build, M-series Mac, macOS 27.2, git 2.54, 2026-11-11. The bare
`Upstream` binary was opened on a scratch repository, with a temporary hook
that selected a file and then scrolled the diff programmatically. Each step
was forced through layout, display and a `CATransaction` flush, so drawing
counts. Memory is `footprint`'s `phys_footprint`
([measuring](../memory/measuring-the-mac-app.md)). One window, about
900 × 550 points. The diffs edit every other line, about 86 bytes a line;
the long line is one 1 MB line of minified code with a change in the middle.

| Diff                             | Renderer                     | Open (git + parse, first draw) | Fast scroll, 600 pt a step | Footprint after scrolling 72,000 pt |
| -------------------------------- | ---------------------------- | ------------------------------ | -------------------------- | ----------------------------------- |
| none selected                    | —                            | —                              | —                          | 37 MB                               |
| 1,000 lines                      | SwiftUI                      | 65 + 37 ms                     | 50 ms                      | 223 MB                              |
| 10,000 lines                     | SwiftUI                      | 44 + 42 ms                     | 69 ms                      | 572 MB                              |
| 10,000 lines                     | SwiftUI, no `.textSelection` | 53 + 22 ms                     | 24 ms                      | 258 MB                              |
| 100,000 lines                    | SwiftUI                      | 122 + 40 ms                    | 65 ms                      | 619 MB                              |
| one 1 MB line                    | SwiftUI                      | 53 + 22 ms                     | —                          | 92 MB                               |
| 1,000 lines                      | `NSTableView`                | 29 + 23 ms                     | 3 ms                       | 58 MB                               |
| 10,000 lines                     | `NSTableView`                | 25–44 + 23–49 ms               | 3.0 ms (max 3.7)           | 64 MB (47 MB before scrolling)      |
| 10,000 lines, split              | `NSTableView`                | 40 + 27 ms                     | 3.5 ms                     | 64 MB                               |
| 100,000 lines, after "Show Diff" | `NSTableView`                | 112–144 + 23–36 ms             | 3.1 ms                     | 93–108 MB                           |
| one 1 MB line                    | `NSTableView`                | 41 + 11 ms                     | —                          | 46 MB                               |

SwiftUI opened quickly because the stack is lazy. But it kept every row it
had shown alive, so memory grew with every row scrolled past, about 100 KB
a row. A fast scroll laid out some 37 new rows in 50 to 70 ms, which is
15–20 frames a second. Slow scrolling (50 points a step) was fine at 4 ms.
Dropping `.textSelection` halved the cost but did not cure it.

Two findings from building the table version:

- **Counting tabs per line in the app took 200 ms for 100,000 lines** when
  done over each line's `String`. The same loop over the diff's bytes in
  `UpstreamKit` takes 5 ms, so `FileDiff.widestLine(cappedAt:)` does the
  counting there.
- **Don't drive the app by walking SwiftUI's view tree from inside a
  `Task`.** The first measuring hook found the table that way and then
  sent it a click. One run in ten then crashed inside SwiftUI,
  `EXC_BAD_ACCESS` in `swift_task_isMainExecutor`, with a stack address as
  the executor. With the walk taken out and the same clicks sent, none of
  120 runs crashed. The table had briefly been rebuilt around that crash
  (nonisolated data source methods, layer-drawn rows); that was undone
  once the cause was found.

## Options

### Renderer

- **A. Keep the SwiftUI stack, tuned.** Rejected on the numbers above:
  memory grows without bound as the user scrolls, and fast scrolling drops
  frames. Removing text selection still left 24 ms a step.
- **B. SwiftUI `List`.** It is backed by a table on macOS, but each row is
  still a hosted SwiftUI view, and it has no horizontal scrolling for long
  lines. Not pursued once C was measured.
- **C. A view-based `NSTableView` with one fixed row height, in an
  `NSViewRepresentable`.** Chosen. Only the visible rows exist and they are
  reused. Each row is one `NSView` that draws its gutter, background, text
  and highlights in a single `draw(_:)`, with no subviews. With a fixed
  height, scrolling to any row costs the same whether the diff has a
  thousand lines or a hundred thousand.
- **D. One TextKit 2 `NSTextView` holding the whole diff.** Rejected.
  Text selection would come free, but the gutter that checks lines, the
  faded unchecked lines, per-line backgrounds and a split view would all
  have to be drawn over text layout fragments. The text storage would also
  be a second copy of the whole diff, with attributes.
- **E. One custom view that draws only the visible rows.** Rejected. It
  would reimplement what the table already does: reuse, selection,
  scrolling and accessibility.

What C costs: text cannot be selected inside a line. Rows are selected
instead (click, shift-click, ⌘A) and ⌘C copies their lines whole, without
the `+`/`-` markers.

### Very long lines

A megabyte of minified code on one line would be laid out on every draw.
**A line is drawn up to 1,000 characters**, followed by a note of how many
more there are and that copying the line gets them. The parse, the copied
text and the committed bytes are never cut. Word highlights stop at the
same length. The horizontal scroll width comes from the longest line, so
the cut also keeps it bounded.

### Large diffs

GitHub Desktop asks before drawing a large diff, and refuses one past a
hard limit. We do both.

- **The prompt.** More than **20,000 lines or 4 MB** shows "This diff is
  large" with **Show Diff**. Lines catch a long diff, bytes catch a few
  enormous lines. The renderer copes with far more (100,000 lines above),
  so the prompt does not exist for speed. A diff that size is nearly always
  a generated file (a lockfile, a bundle) that the user did not mean to
  read. It sits at twice the 10,000-line target, so ordinary diffs never
  meet it. "Show Diff" is remembered until another file is shown.
- **The ceiling.** No diff read for the screen exceeds **16 MB**. Options
  considered:
  - Run `git diff --numstat` first. Rejected: it computes the diff twice to
    learn its size, and counts lines, not bytes, so one 300 MB line passes.
  - Check the files' sizes first. Rejected: a diff's size is not the files'
    size, and it would need a stat or a `cat-file -s` per side, per file.
  - **Read with a cap.** Chosen. `Git.run` takes a `limit`; past it, git is
    terminated and the result says `truncated`. Nothing is parsed, the view
    says "This diff is too large to show", and the file's checkbox still
    commits it whole (`git add` never reads it into the app). The parse
    holds about three times the bytes (the bytes, a `String` per line and
    the ranges), so 16 MB, some 200,000 lines of code, is the most we hold.
    The staged-lines reading in `AppModel` has the same cap; past it, that
    file starts unchecked, as when its staged lines cannot be told apart.

### Split view

Removed lines go on the left and added lines on the right. Within each run
of changes they are paired in order, and the shorter side is padded with
empty rows. Context shows on both sides. A hunk header spans the width. A
"\ No newline" marker stays on the side of the line it belongs to.

**Lines can be checked in the split view too**: the number on either side
checks that side's line, and a hunk header's number checks the hunk. There
was no reason to make users switch views to commit part of a file. The two
halves share the width and clip long lines instead of scrolling sideways.
Unified is the view for very wide lines.

### Hidden whitespace

`FileDiff.arguments(…, ignoringWhitespace: true)` adds `-w`. The diff
shown is then not the one that would be committed, so
`canSelectLines` is false. **Lines cannot be checked while whitespace is
hidden**, which is what GitHub Desktop does, and a note under the diff says
so. File checkboxes still work. A file's lines chosen before hiding are
kept. The stale-selection check (the file is unchecked when its diff
changes) is skipped for a `-w` diff, because the two never match. The
commit re-reads the real diff and compares it anyway.

### Word highlights

- **git's `--word-diff=porcelain`.** Rejected. It is a second git run for
  every diff shown, and its idea of which words changed does not follow
  our line pairing or the checkbox lines.
- **Characters.** Rejected. Highlighting single characters inside words is
  noise.
- **Tokens with Myers' O(ND) diff, our own.** Chosen. `WordDiff` splits a
  line into words (letters, digits, `_`), runs of whitespace, and single
  punctuation marks. A removed line and the added line beside it in the
  split view are compared, so the pairs are the same in both views. The
  cost is capped. Lines over 1,000 characters are skipped. The search stops
  at 200 edits, which bounds the work at O((n + m) · 200) and the trace at
  200² integers. It also gives up when the lines share less than half
  their tokens, because highlighting most of both says nothing the red and
  green do not. The result for a pair is worked out when a row is first
  drawn, then kept.

### Images

png, jpg/jpeg, gif, heic, webp, tiff, bmp and ico, by extension, are drawn
side by side: "Before" and "After", each with its pixel size and byte size.
An added or deleted image shows one side. For the Changes tab, the old side
is `git cat-file blob HEAD:<path>`, under the original path for a rename,
and the new side is the working file. Each side is capped at 64 MB. The
loader is a closure passed to `DiffView`, so History supplies its own from
the parent and the commit through `Git.blob(_:_:in:)`.

### Settings

The split view and hidden whitespace are kept with `@AppStorage`
(`diffSplit`, `diffHideWhitespace`), set from a bar above the diff. Hiding
whitespace changes what git is asked for, so the view that loads the diff
reads the same key. `ChangesDiffView` passes it to
`AppModel.hidesWhitespace`.

## Decision

An `NSTableView` renderer with fixed-height, single-draw rows, and a split
view in which lines can still be checked. Whitespace hiding turns off line
checking. Word highlights use our own capped Myers diff over tokens. A
large diff asks before it is drawn, and a 16 MB read ceiling is enforced by
`Git.run`. Images are drawn side by side through a loader closure that
History can supply. The SwiftUI shell around the table holds the options
bar and the empty, binary, image and large states.

## Plan

1. ✅ Measure the SwiftUI renderer; build the table; measure again.
2. ✅ `FileDiff`: `-w`, `ignoresWhitespace`, `isLarge`, `byteCeiling` and
   `tooLarge`, `splitRows`, `partners`, `widestLine`. `Git.run(limit:)`.
   `WordDiff`, `DiffImages`, `Git.blob`.
3. ✅ The options bar, the split view, the large and too-large states, the
   image view. Tests: word highlights and their cap, split rows, hidden
   whitespace keeping the chosen lines, the thresholds, the ceiling, image
   sides for a modified, renamed, deleted and added file, a 10,000-line
   parse. Fixtures: `diff-words.patch`, `diff-whitespace.patch`,
   `diff-whitespace-w.patch`.
4. ✅ The History tab's diff is `DiffView` too, with `path` and an `images`
   loader reading `<parent>:<old path>` and `<commit>:<path>`; it honours
   Hide Whitespace and stops at the same ceiling. A right-click on a line,
   a hunk header or the selected rows offers Copy and, in Changes, Discard
   ([008](008_discard_ignore_and_conflicts.md)).

## Open questions

- **Thresholds.** 20,000 lines, 4 MB and the 16 MB ceiling are technical
  defaults; the owner may want them elsewhere.
- **Selecting text inside a line.** Rows copy whole. If users miss
  selecting part of a line, a read-only text field could be shown over the
  clicked row.
- **More image modes.** GitHub Desktop also has swipe, onion skin and
  difference. Side by side covers the requirement.
- **Long lines in the split view** are clipped at the half's edge. A
  shared horizontal offset for both halves would show them.
