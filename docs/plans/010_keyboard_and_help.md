# 010 — Keyboard and help

**Status:** `MERGED` — the shortcut table, moving between the columns, Space, the Help window with a shortcuts page
**Started:** 2026-11-11

## Problem

The owner asked (2026-11-11) for simple keyboard navigation that feels
obvious, a help page and a keyboard shortcuts page. The Help menu said
"Help isn't available for Upstream." The menus already had GitHub Desktop's
shortcuts, but nothing moved the keyboard between the sidebar, the changes
or history, and a commit's files. Space did nothing to a checkbox, and the
only list of shortcuts was the menus themselves.

## Options

### Moving between the columns

- **A. ← and → between the lists, as between Finder's columns.** Chosen.
  The window is laid out in columns, so → goes one column right (sidebar →
  Changes or History → a commit's files) and ← goes back. Nothing else uses
  those keys in these lists. Arriving in a list with nothing selected
  selects its first row, so its diff shows at once. That happens only when
  the keyboard arrives: SwiftUI gives the Changes list focus at launch, and
  selecting a file then would read a diff nobody asked for.
- **B. Tab alone.** Not enough on its own, though it works (the lists and
  fields are in the window's key loop; Tab from the changes reaches the
  Summary). It stops at every field and button on the way, so getting from
  the sidebar to a commit's files takes many presses.
- **C. A shortcut for each pane (⌃1, ⌃2, …).** Rejected: more keys to
  learn for what two arrows already do.

The diff stays out of the arrow keys: there ↑ and ↓ select lines for
copying, and its columns are not lists. Tab reaches it.

### Jumping to a tab or a repository

- **⌘1 Show Changes and ⌘2 Show History** switch the tab and put the
  keyboard in its list, as in GitHub Desktop's View menu.
- **⌘T Filter Repositories** puts the keyboard in the sidebar's filter, at
  GitHub Desktop's "Show Repository List" key. Its list is always on
  screen here, so the key goes to the filter, and opens the sidebar if it
  was hidden. ↓ in the filter goes into the matches and opens the first:
  that is the search field's own behaviour. Return was meant to open the
  first match, but `onSubmit(of: .search)` never runs for a field placed in
  the sidebar (macOS 27.2), and the field's Return reaches no other
  handler. Rather than replace the native field, ↓ is the documented way
  in.

### Checking files from the keyboard

- **Space checks or unchecks the selected files**, as in GitHub Desktop.
  With several selected it checks them all, unless every one is checked
  already, and then it unchecks them all. Flipping each file on its own
  would leave a mixed selection mixed. A partly checked file counts as
  unchecked, as a click on its box does. Conflicted files are skipped;
  during an operation Space does nothing, as the boxes do.

### Where help lives

- **A. A Help window drawn by the app.** Chosen. Topics in a sidebar, each a
  page of short paragraphs, the last page the keyboard shortcuts. It is
  plain SwiftUI, opens at once, works offline, and adds a few kilobytes.
  The text is in Swift, so the shortcuts it names come from the same
  table as the menus.
- **B. An Apple Help book.** Rejected: HTML pages and an index built with
  `hiutil` into the bundle, opened in Help Viewer, which is slow to start.
  Its one gain, the Help menu's search finding pages, does not pay for
  the HTML and the build step. The menu's search still finds every menu
  item.
- **C. Pages on the web.** Rejected: help would need the network, would
  describe the latest version rather than the one installed, and would
  send the user to a browser for a paragraph.

### Keeping the shortcuts page true

- **One table, `Shortcut.all`** (`Shortcuts.swift`). Every menu item binds
  its key from the table, and the shortcuts page and the help text list
  the table. A key changed in one place changes everywhere. Keys the lists
  handle themselves (arrows, Space, Tab) are rows in the table that no menu
  binds. Settings' ⌘, is listed as SwiftUI binds it.
- Help is ⌘? and Keyboard Shortcuts ⌘/. macOS takes ⇧⌘/ first to open the
  Help menu's search, where Upstream Help is the top item. Apple's apps
  show their Help item as ⌘? all the same, so this one does too.

## Plan

1. ✅ `Shortcut` table; the File, Repository, Branch and View menus bind
   from it.
2. ✅ View → Show Changes ⌘1, Show History ⌘2, Filter Repositories ⌘T,
   through a focused scene value, so they apply to the main window only.
3. ✅ ← and → between the lists; the first row selected on arrival.
   History's first page arrives after ⌘2 has moved the keyboard there, so
   it selects its first commit when the page comes in.
4. ✅ Space on the selected changes (`AppModel.toggleChecked`, tested
   against real git).
5. ✅ The Help window and Help menu; the topics take the keyboard when it
   opens.

Checked on 2026-11-11 by driving a release build with keys (see
[measuring](../memory/measuring-the-mac-app.md)): every step above, Tab
into the Summary and back, and ↓ from the filter. Not yet checked: ⌘T
opening a hidden sidebar.

## Open questions

- Return in the filter, if a later macOS runs `onSubmit(of: .search)` for
  a sidebar field.
- Keys inside the diff (move between hunks, Space to check a line) if
  users ask: GitHub Desktop has none.
