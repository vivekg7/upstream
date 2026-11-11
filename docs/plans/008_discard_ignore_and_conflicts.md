# 008 — Discard, ignore and conflicts

**Status:** `IN PROGRESS` — macOS: discard files and lines to the Trash, ignore, the conflict banner, ours/theirs, continue and abort, discarding from the diff's context menu
**Started:** 2026-11-11

## Problem

The Changes tab commits ([003](003_the_checkbox_commit.md)) but cannot take
anything back, ignore a file, or get through a conflict
([REQUIREMENTS](../REQUIREMENTS.md#changes),
[Conflicts](../REQUIREMENTS.md#conflicts)). Each of them destroys or rewrites
something, so each has to answer the product rule that nothing the user wrote
is lost silently. The conflict work also has a trap: the checkbox commit
builds its tree in a temporary index from HEAD, so run during a merge it
would make a commit that drops the merge's parent or the files it brought in.

## Options

### Where discarded content goes

- **A. Copy the files into one folder and move the folder to the Trash,
  then restore.** Chosen. What GitHub Desktop does. One folder per discard,
  named "Upstream discarded changes <repo> <date>", is easy to find in the
  Trash and holds every file at its path in the repository. If the copy or
  the move fails, nothing has been touched yet.
- **B. Move each file to the Trash on its own.** Rejected. A discard of
  thirty files would leave thirty loose entries with no sign of which
  repository or which discard they came from, and a tracked file's slot in
  the working tree would have to be restored afterwards anyway.
- **C. `git stash` the discarded changes.** Rejected. Stashes are easy to
  drop by accident, invisible outside git, and an untracked file needs
  `--include-untracked`; the Trash is where a Mac user looks for something
  thrown away.

### Restoring files

- **A. `git restore --source=HEAD --staged --worktree`.** Chosen for tracked
  paths, with `--literal-pathspecs`. One command puts index and working tree
  back to HEAD: a modified file is restored, a deleted one returns, an added
  one leaves both index and working tree, and a rename is undone by naming
  both its paths. Untracked files are removed by the app once their copies
  are in the Trash. Before the first commit there is no HEAD, so tracked
  files are `rm --cached` and removed.
- **B. `git checkout HEAD --` plus `git clean`.** Rejected. Two commands
  with different pathspec rules, and `checkout` does not remove a file that
  is new in the index.

### Discarding lines

- **A. Reverse-apply a patch to the working tree.** Chosen. The patch's new
  side is the working tree, and its old side the working tree without the
  chosen changes: an unchosen addition stays as context (it is in the
  working tree), an unchosen removal is left out (it is not). `git apply
--reverse` then undoes exactly the chosen lines. The header names only
  the one path, taken byte for byte from git's `+++` line, so a rename or a
  new file's mode is not reversed with it. The whole file goes to the Trash
  first, and the diff is read again so lines chosen in an older one are
  refused.
- **B. Reverse-apply `patch(selecting:)`, the commit's patch.** Rejected.
  It is cut against HEAD: an unchosen removal becomes context that the
  working tree no longer has, so it fails to apply whenever chosen and
  unchosen changes share a hunk. A test pins the difference.
- **C. Write the file ourselves without the chosen lines.** Rejected: it is
  applying a diff in our own code, which is git's job (plan 001).

Only the working tree changes. A line staged in a terminal and then
discarded here stays staged, where a terminal would show it.

### Ignore

- **Untracked files only.** As GitHub Desktop. Adding a tracked file to
  `.gitignore` changes nothing (git goes on tracking it), and "stop
  tracking" (`git rm --cached`) deletes the file for everyone who pulls,
  which deserves its own, explicit command if anyone asks.
- **One line appended to the top-level `.gitignore`**, created if missing,
  after ending an unterminated last line, and not added twice. A single
  file is anchored (`/path/to/file`), so it does not also ignore a file of
  the same name elsewhere; an extension is `*.ext`, anywhere. `*`, `?`, `[`
  and `\` are escaped, and trailing spaces, which git would drop, are
  escaped one by one. A leading `#` or `!` never needs escaping, since
  every pattern starts with `/` or `*`. Rejected: `.git/info/exclude`,
  which would ignore the file for this clone only, unlike GitHub Desktop.

### Detecting an operation in progress

- **A. Stat the files git keeps for it.** Chosen. `MERGE_HEAD`,
  `CHERRY_PICK_HEAD`, `REVERT_HEAD`, and `rebase-merge/` or `rebase-apply/`
  with an `onto` file (`git am` also uses `rebase-apply/`, without one).
  `git rev-parse --git-path` resolves them once per repository, so a linked
  worktree's own are found; after that each refresh costs a few stats and
  no git process. Branch names for the banner (`for-each-ref --points-at`)
  and a merge's message are read only when the operation or its commit
  changes. The watcher already refreshes when these files appear.
- **B. Parse `git status`'s human output** ("You are currently
  rebasing"). Rejected: human output changes with version and locale.

### Committing during an operation

- **A. Replace the commit button.** Chosen. During a merge the form keeps
  its summary and description, prefilled from `MERGE_MSG` (comments
  stripped by `git stripspace`), and **Commit Merge** runs `git commit
--file=-` on the real index, which records both parents. During a rebase,
  cherry-pick or revert the fields give way to **Continue Rebase** (and so
  on), which runs `--continue` with `GIT_EDITOR=true`: git keeps the
  original commit's message and no editor opens behind the app. Both are
  enabled once nothing is conflicted. The checkbox commit refuses, in the
  model and again in `Git.commit` itself, while any operation is in
  progress.
- **B. Let the checkboxes choose what goes into the merge.** Rejected. An
  unchecked file the merge brought in would be left out of the merge
  commit: an "evil merge" that loses the other branch's change without a
  trace. During an operation the checkboxes show what is staged, and are
  disabled.

What is staged is what continues. Files git merged are staged by git;
conflicted ones are staged by taking a side or by Mark as Resolved. Any
other working-tree change stays out of the operation's commit and in the
working tree, as with `git commit` in a terminal. GitHub Desktop commits
every change during a merge; the owner should confirm this departure.

Discarding is disabled during an operation: discarding a file the merge
brought in would quietly drop it from the merge. Abort is the way to throw
an operation away, and it asks first, saying what goes.

### Resolving a file

- **Take a side**: `checkout --ours` or `--theirs`, then `add`. The stages
  present (`ls-files -u`) tell whether that side deleted the file; if so,
  taking it means `rm`. That covers modify/delete conflicts: the menu
  offers "Use the Version from …" for the side that kept it and "Delete
  the File, as on …" for the side that deleted it. The working-tree file,
  possibly half resolved by hand, goes to the Trash first.
- **Names, not ours and theirs.** During a rebase git's `--ours` is the
  branch being rebased onto and `--theirs` the commit being replayed, the
  reverse of what the words suggest to most people. The menu names
  branches: `head-name` and `onto` for a rebase, the current branch and
  the merged one otherwise.
- **Mark as Resolved** is `add --all` (which records a deletion too), and
  refuses while a line still starts with `<<<<<<<` or `>>>>>>>`. A lone
  `=======` is not counted: a Markdown heading's underline looks the same.
- **Open in Editor** opens the file with its default app for now; the
  configurable editor from the repositories work replaces it.

### Co-authors and the template

These finish plan [003](003_the_checkbox_commit.md) step 4, decided there:
co-authors go through `git commit --trailer`, so git formats them, and
`commit.template` fills an empty draft. Details decided here:

- A co-author is "Name <email>", checked when it is added; suggestions are
  the authors of the last 500 commits, read once per repository when the
  field is first shown. Co-authors are cleared with the message after a
  commit, so nobody is credited on the next one by surprise.
- The template is read once per repository: `git config --path
commit.template` (a relative path is taken from the top level), then
  `git stripspace --strip-comments`, which knows `core.commentChar`. It
  fills the fields only while they are untouched since the app last filled
  them, so fields the user cleared stay clear. A change to the setting is
  seen after a relaunch.

## Decision

Discard copies to one Trash folder, then restores with `git restore` or
reverse-applies a working-tree patch. Ignore appends an escaped, anchored
line for untracked files. An operation in progress is read from files in
the git directory, shown as a banner, and finished with Commit Merge or
Continue on the real index; the checkbox commit refuses while one is in
progress.

## Plan

1. ✅ Discard files and lines to the Trash, with an injected Trash for
   tests; ignore; co-authors and the template; the operation banner, sides
   named by branch, Mark as Resolved, continue and abort; tests against
   real git for each.
2. ✅ A context menu on the diff ([007](007_the_diff_view.md)): Discard
   Line…, Discard Hunk… on a hunk header, Discard Selected Lines… on the
   selected rows, each calling `requestDiscardLines`. The stand-in bar
   above the diff that discarded the unchecked lines is gone with it.
3. ✅ Open in Editor on a conflicted file uses the editor chosen in
   Settings.

## Open questions

- **Committing every change during a merge**, as GitHub Desktop does,
  rather than what is staged. Owner to confirm.
- **Detecting resolution by hand.** GitHub Desktop notices a conflicted
  file whose markers are gone and stages it on Continue. Here the user
  marks it resolved. Worth adding if people forget the step.
- **Taking a side copies to the Trash every time**, even when the file
  holds only git's markers. Cheap and safe; revisit if the Trash fills
  with such folders.
