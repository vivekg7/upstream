# 003 — The checkbox commit

**Status:** `MERGED` — files, lines, hunks, summary, description, amend; co-authors and commit templates not yet
**Started:** 2026-11-11

## Problem

GitHub Desktop users commit by checking boxes: every changed file has one,
lines can be checked in the diff, and the commit records exactly what is
checked. They never meet the index ([REQUIREMENTS](../REQUIREMENTS.md#changes)).
Plan [001](001_native_clients_on_system_git.md) step 2 builds it. Three
things have to be decided: where the checkbox state lives, how a commit is
built from it without disturbing anything the user did in a terminal, and
how part of a file is committed. Partial staging of renamed and new files
is the part most likely to go wrong.

## Options

### Where the checkboxes live

- **A. The app holds them, as GitHub Desktop does.** Chosen by the owner
  (2026-11-11). New changes start checked; press Commit and everything is
  committed, which is what GitHub Desktop users expect. A terminal sees an
  uncheck only once the commit is made.
- **B. The checkboxes are the index.** Rejected by the owner. Each click
  would stage or unstage at once, so `git status` would always match the app
  and the app would hold nothing. But new changes would start unchecked, and
  the one diff cannot show a staged line that is in neither HEAD nor the
  working tree (staged, then edited again).

### Building the commit

- **A. Reset the real index, stage the checked parts, commit.** What GitHub
  Desktop does. Rejected: it throws away whatever the user staged for any
  file they left unchecked.
- **B. A temporary index, as `git commit --only` uses.** Chosen. Copy the
  real index (so its stat data spares the commit a rehash of every file),
  `read-tree --reset HEAD` into it, stage the checked files and lines into
  it, and run `git commit` with `GIT_INDEX_FILE` pointing at it. Hooks,
  signing and templates run as they would in a terminal; a hook that runs
  `git add` adds to the temporary index, exactly as under `--only`. Then the
  real index takes the committed paths from the new HEAD (`git reset -q --
<paths>`), and only those. A rejected commit leaves the real index as it
  was, with nothing to undo.
- **C. `git commit --only <paths>` itself.** Rejected: it commits whole
  files only, and part of a file needs an index to stage into.

### Committing part of a file

- **A. Cut a patch from the diff on screen and `git apply --cached` it.**
  Chosen. An unchecked addition is left out, an unchecked removal becomes
  context, and the hunk counts are recomputed. The patch applies to HEAD's
  version, which is what the temporary index holds, so it always applies.
  It is cut from git's bytes, not decoded text, so a file in Latin-1 or
  Shift-JIS is committed as it is. One case needs care: keeping the old
  file's last line when it has no newline, but adding lines after it. In
  the new file that line needs a newline, which a patch can only say by
  removing it and adding it back.
- **B. Write the chosen version of the file ourselves and `git update-index
--cacheinfo` it.** Rejected: it means applying the diff in our own code,
  and carrying modes, renames and filters by hand. That is reimplementing
  git.

## Decision

The app holds the checkboxes, per repository, until Commit. The commit is
built in a temporary index, the way `git commit --only` builds one.
Partial files are staged into it with patches cut from the diff the user
checked lines in.

### Rules

- **Which files start checked.** A file seen for the first time is checked,
  unless something is already staged. Then what is staged starts checked and
  nothing else, so a commit prepared in a terminal is the one the app
  offers. For a file with both staged and unstaged changes, the staged lines
  start checked. They are found from the staged diff (HEAD to the index) and
  the unstaged one (the index to the working tree): an addition is staged
  unless the unstaged diff adds it, a removal is staged if the staged diff
  removes it. That is exact only when the picked lines are the staged diff's
  own changes. Otherwise the file starts unchecked, so whatever is staged
  for it stays out of the commit and untouched.
- **Which files can be committed in part.** One text file's diff with
  hunks: a modified, added, untracked or renamed file. A binary, a deletion,
  a submodule, a mode change alone, or a diff that git splits in two (a type
  change, a rename too edited to be found) commits whole.
- **Lines chosen in a diff that has changed** would point at other lines.
  When the shown diff reloads differently, its file is unchecked. At commit
  every partly checked file's diff is read again, and the commit stops with
  a message if it differs.
- **Paths are literal.** `--literal-pathspecs` on `add`, `reset` and every
  diff, so a file named `*.txt` is that file. It is not passed to `commit`:
  git exports it to hooks, whose own pathspecs would stop working.
- **Diff options** are fixed whatever the user's config says: `--no-color`,
  `--no-ext-diff`, and the `a/` and `b/` prefixes that `git apply` expects.
  `apply` gets `--whitespace=nowarn`, so `apply.whitespace=fix` cannot change
  the lines the user chose.
- **After a commit**, unchecked files stay unchecked. Whatever is left of a
  committed file is a new change and gets the defaults again. The message
  is cleared.
- **The draft is kept per repository**, checkboxes and message together.
  Switching to another repository and back loses neither: the message is
  the user's writing, and a file quietly checked again would be committed
  by surprise.
- **Amend** puts the last commit's message in the fields (`git log -1
--no-show-signature --format=%B`) and builds the temporary index from that
  commit. With nothing checked, it rewrites the message alone. It warns
  when the commit is already on the upstream branch (status says ahead 0).
  Turning it off brings back what was typed before.
- **No commit with conflicted files.** Committing a merge belongs to the
  conflicts work (plan 001 step 5).

### Cost

The parse keeps git's bytes and a range per line beside the decoded text.
A 10,000-line diff parses in 2 ms and a patch is cut from it in under 1 ms
(release build, M-series, 2026-11-11).

## Plan

1. ✅ `FileDiff` from bytes, `canSelectLines`, `patch(selecting:)`, the
   staged-lines reading; fixtures for a staged rename with an edit, an added
   file, and one file's diff three ways.
2. ✅ `Git.commit` through the temporary index; tests against real git for
   checked files with a glob in a name, checked lines, a new file, a renamed
   file, a last line without a newline, amend, a hook that refuses, and a
   stale line selection.
3. ✅ Checkboxes (mixed state included), check all, the gutter and hunk
   headers in the diff, summary, description, amend, ⌘↩ to commit.
4. Co-authors (`git commit --trailer "Co-authored-by: …"`, so git formats
   them) and the summary prefilled from `commit.template`, with the
   [REQUIREMENTS](../REQUIREMENTS.md#changes) items they finish.

## Open questions

- **Dragging across lines** to check several at once, as GitHub Desktop
  allows. Clicking one line or a hunk header covers it for now.
- **Line selection on a deletion.** Committing part of a deletion would need
  the patch's `deleted file mode` header rewritten. Wait until someone asks.
