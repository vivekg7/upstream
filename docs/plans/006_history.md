# 006 — History

**Status:** `IN PROGRESS` — macOS: paged history, a commit's files and diffs, the commit actions, compare; Linux not started
**Started:** 2026-11-11

## Problem

GitHub Desktop's History tab lists the current branch's commits, shows the
files and diff of the selected one, and offers the things people do with a
commit: branch or tag from it, cherry-pick, revert, reset to it, undo the
last one, copy its SHA, open it on the forge. Its compare view lists what
another branch has that this one lacks, and the reverse
([REQUIREMENTS](../REQUIREMENTS.md#history)).

The target is a first page in **200 ms on a 100,000-commit branch**, with
the rest paged. Three questions decide whether it is met and stays correct:
how a page is read, how the next page continues from the last, and what is
read per commit (a body, a file list, a diff) versus only for the selected
one.

## Options

### Reading a page

- **A. `git log -z` with an explicit `--format`, in git's default order.**
  Chosen. Fields end in `%x1f`, records in NUL. The subject, the only free
  text, comes last, so a stray 0x1F in it stays in it. The body is never
  read for the list. The default order prints as it walks, so the first
  page costs the same on 100 commits as on 100,000.
- **B. `--topo-order` or `--graph`.** Rejected. Both walk the whole history
  before printing anything: 290 ms on the benchmark repository before the
  first line, and it grows with the history. A graph column is not in
  GitHub Desktop either.
- **C. `git rev-list` of everything, then `log --no-walk` per page.**
  Rejected. The full list costs 280 ms and grows with the history, which
  is what paging exists to avoid.
- **D. `%D` in the format for branch and tag names.** Rejected. Its shape
  follows `log.excludeDecoration` and the decoration settings, and it does
  not say which name is a tag. One `git for-each-ref` call per reload
  gives every label with its kind, and `%(*objectname)` puts an annotated
  tag on its commit rather than on the tag object.

### Continuing to the next page

- **A. `--skip=N`.** Rejected. git walks the N skipped commits again on
  every page: 280 ms for the page at commit 99,000 without a commit-graph
  file. With one it is 28 ms, but `git fast-import`, fresh clones and many
  repositories have none, and we do not write files into the user's
  repository to make our paging fast.
- **B. Continue from the last commit's parent (`<sha>^`, `--max-count`).**
  Rejected. Correct only for a line of commits: after a merge, the
  commits on the other parent's line that were still queued are lost.
- **C. Continue from the frontier.** Chosen. Keep the commits listed and
  the parents of listed commits that are not listed yet. The next page is
  `git log` from those parents (on stdin, since there can be many), which
  is the walk one longer `git log` would have made next: git pops commits
  by date from the same queue. Every unlisted ancestor is reachable from
  the frontier, so nothing is skipped. One case repeats: a commit dated
  before its own parent (clock skew) lets git show that parent first, and
  a walk restarted from the skewed commit reaches the parent again. It is
  listed once (a test builds exactly that history). A page costs the same
  wherever it starts: 10 to 16 ms at commit 99,000.

### Marking commits not pushed

- **A. The upstream's `..HEAD`, read once per reload.** Chosen, as GitHub
  Desktop marks them. Skipped entirely when status says ahead 0. A branch
  with no upstream, or a detached HEAD, counts commits on no remote
  (`HEAD --not --remotes`). A repository with no remote marks nothing:
  there is nowhere to push to, and marking every commit says nothing.
- **B. Ask per page.** Rejected. A page would need its own exclusion walk;
  the set is usually a handful of commits, read alongside the first page.

### A commit's files and diff

- **Files:** `git diff-tree -r -z --name-status -M --root --no-commit-id`.
  A merge against its first parent, as GitHub Desktop shows it: what the
  merge brought in. A combined diff (`-c`, `--cc`) was rejected; it is
  empty for a clean merge, which tells the user nothing. The list is lazy,
  and only the selected file's diff is read, so a commit of thousands of
  files costs one `diff-tree` and one file's diff.
- **Diff:** `git diff` with the options every parsed diff gets
  (`FileDiff.base`), from the first parent to the commit, for that file's
  paths (both, for a rename). A first commit is compared with the empty
  tree, whose name is asked of git (`hash-object -t tree`), since it
  differs between SHA-1 and SHA-256 repositories.

## Decision

`git log -z --format=…` pages of 200 in the default order, each continued
from the frontier; one `for-each-ref` for labels and the compare branch
list; one `rev-list` for the unpushed marks; the message, files and diff
only for the selected commit. `HistoryModel` reads nothing until the
History tab is first shown, then reloads the first page whenever status
says HEAD, the branch or its upstream moved. Reloads coalesce as
`AppModel.refresh` does, and a read for a state already replaced is
dropped.

### The actions

All run through `AppModel.perform`, so they show activity, report git's own
message on failure, and refresh after.

- **Create branch from commit:** `git switch -c <name> <sha>`, as GitHub
  Desktop creates and switches. Uncommitted changes come along unless they
  conflict, and then git refuses. The name is checked by `git
check-ref-format --branch`, and must come back unchanged, so `@{-1}` is
  not taken for a name.
- **Create tag:** lightweight, `git -c tag.gpgSign=false tag <name> <sha>`,
  checked by `git check-ref-format refs/tags/<name>`. `tag.gpgSign`
  would force an annotated, signed tag and open an editor nobody can see;
  a lightweight tag cannot carry a signature anyway.
- **Cherry-pick:** offered only on the compare view's commits this branch
  lacks: picking a commit HEAD already has would be empty, which leaves
  git mid-cherry-pick. A merge is picked against its first parent
  (`-m 1`).
- **Revert:** `git revert --no-edit`, a merge against its first parent.
- **Reset to commit:** `git reset --mixed`, after a confirmation that says
  the later commits leave the branch, their changes stay in the working
  tree and nothing stays staged, and warns when some are already pushed.
  Never `--hard`.
- **Undo:** the newest commit, while not pushed, not a merge (a soft reset
  would drop the merge silently), and not the first commit of a detached
  HEAD. `reset --soft <parent>`; for a first commit `update-ref -d HEAD
<sha>`, which leaves the branch unborn with the files staged. The message
  goes back into the commit fields, unless the user has started typing
  one there: then theirs is kept (still recoverable from `git reflog`).
- **Copy SHA, copy a tag's name, view on the web** (the forge's commit
  page; hidden when the forge knows no page for this repository).
- A conflict from a cherry-pick or revert leaves the repository
  conflicted, as the git CLI does; resolving it is the conflicts work.

### Compare

A "Compare…" menu of the local and remote branches (from the same
`for-each-ref`) switches the list to one side of the comparison, in GitHub
Desktop's words: **behind**, the other branch's commits this one lacks
(`HEAD..other`), and **ahead**, this one's that it lacks (`other..HEAD`),
with both counts from `rev-list --left-right --count`. Paging works the
same, with the excluded side passed on every page.

### Measurements

A 100,000-commit linear branch made by `git fast-import` (one file changed
per commit, 5,000 lightweight tags, no commit-graph file), M-series Mac,
git 2.54, release build, 2026-11-11. In-process times include starting git.
Other builds were running at the time; the occasional slower run (up to
80 ms for a first page) is that.

| What                                                    | Time        |
| ------------------------------------------------------- | ----------- |
| First page of 200 (`git log` and parse)                 | 9–10 ms     |
| Reload: first page, labels, unpushed marks, in parallel | 33 ms       |
| A page at commit 99,000, from the frontier              | 10–16 ms    |
| The same page with `--skip=99000` (CLI)                 | 280 ms      |
| The same, `--skip` with a commit-graph file (CLI)       | 28 ms       |
| `--topo-order`, first page (CLI)                        | 290 ms      |
| Parsing 200 commits / 10,000 commits                    | 0.4 / 18 ms |
| `for-each-ref` of 5,000 tags, with parsing              | 32–35 ms    |
| Pages 2 to 51 one after another (10,000 commits)        | 18 ms each  |
| App footprint with the first page and a commit shown    | 44 MB       |

## Plan

1. ✅ Paged log, labels, unpushed marks; a commit's detail, files and diff.
2. ✅ The actions, compare, and tests against real git: messages with
   newlines, unicode, a literal `%x1f` and an empty body; paging over a
   merge with clock skew; a first commit's files; a merge's files against
   its first parent; a rename; revert, cherry-pick, reset keeping changes;
   undo restoring the message, and keeping a typed one; the unpushed
   marks; names refused by git. Fixtures of each format in `fixtures/git/`.
3. The Linux app's history, against the same fixtures.

## Open questions

- **Tags made in a terminal** show at the next reload: when HEAD or the
  upstream moves, or the repository is selected again. The watcher sees
  ref changes, but status (what triggers a reload) does not change for a
  new tag. Wait and see whether anyone notices.
- **Compare with hundreds of branches** is a plain menu. GitHub Desktop
  has a filterable list; add one when a menu gets in the way.
- **Search** in history (`--grep`, `--author`, run by git, never a filter
  over the pages already read) is not built. GitHub Desktop has none.
- **An empty cherry-pick** (the change is already on the branch under
  another SHA) leaves git mid-cherry-pick with git's message shown.
  `--empty=drop` needs git 2.45; we require 2.38.
