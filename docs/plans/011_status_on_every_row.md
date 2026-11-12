# 011 — Status on every row, and Pull All

**Status:** `IN PROGRESS` — row indicators, fetching the others, Pull All and the setting built; idle cost not yet measured
**Started:** 2026-11-12

## Problem

The owner asked (2026-11-12) for what GitHub Desktop shows on every row of
its repository list: an arrow up when there are commits to push, an arrow
down when there are commits to pull, and a dot when there are uncommitted
changes. GitHub Desktop also fetches the other repositories now and then,
so the down arrow means something. They also asked for one thing GitHub
Desktop does not have: a command that pulls every repository that can be
pulled without a conflict with local commits or changes.

[009](009_repositories_and_settings.md) turned the indicators down: a
`git status` per repository, on every refresh, for every repository ever
added. It said to revisit with a watcher per repository if users asked,
and now one has.

### What GitHub Desktop does

Read from its source (`repository-indicator-updater.ts`,
`background-fetcher.ts`, `app-store.ts`, 2026-11-12):

- Every 15 minutes, starting 2 minutes after launch and paused while the
  app is behind, it runs a status in each repository but the selected one,
  one at a time. The arrows come from the status's ahead/behind and the
  dot from its changed files.
- In the same pass it fetches a repository whose last fetch is more than
  30 minutes old and, for a GitHub repository, only if the API says it
  was pushed to since.
- The selected repository has its own fetch timer, an hour by default.
- A setting turns the indicators off; it is on by default.
- It has no pull-all command.

## What it costs

The owner's 61 repositories (2026-11-12, M-series Mac, git 2.54): one
`git status --porcelain=v2 --branch` in each took 1.35 s in all, one after
the other; median 16 ms, the slowest 63 ms. What made 009 say no was
running that on _every_ refresh. Read only when something changed, it is
cheap.

## Options

### When the rows are read

- **A. At launch, then only what changed: one FSEvents stream over every
  repository.** Chosen. The stream costs nothing between events, and its
  events go through the same filter as the selected repository's
  ([004](004_refreshing_on_file_changes.md)): objects, logs and locks in
  `.git` are dropped, and a batch of only ignored paths (a build) costs a
  `check-ignore` and no status. A repository with something worth reading
  is read; in the background it is only marked, and read on coming to the
  front. A rescan event reads them all.
- **B. Every 15 minutes, as GitHub Desktop does.** Rejected: up to 15
  minutes stale, which is the "count from yesterday" 009 warned about, and
  61 statuses each time whether anything changed or not.
- **C. Every repository each time the app comes to the front.** Rejected:
  what 009 rejected.

The selected repository is never read for its row: its row copies the
status the app has just read for the window, so it costs nothing.

Each read is `git status --porcelain=v2 --branch -z
--untracked-files=normal`, four at a time. `normal` rather than the
window's `all`: the dot needs to know there is a new file, not to list
every file in a new folder. Like every call it takes no optional locks
(`GIT_OPTIONAL_LOCKS=0`), so it never writes the index and never holds a
lock a terminal's git would trip over. The dot counts untracked files,
as GitHub Desktop's does: a new file is uncommitted work.

### Fetching the others

- **A. GitHub Desktop's rule.** Chosen. While the app is in front, every
  15 minutes (the first 2 minutes after launch, so launch stays quiet),
  each repository but the selected one whose `FETCH_HEAD` is more than 30
  minutes old is fetched, one at a time. Signed in to GitHub, one GraphQL
  query per hundred repositories asks for `pushedAt` (with `isPrivate`,
  the same query the lock icons use), and a repository nobody pushed to
  since its last fetch is skipped. Most cycles fetch nothing.
- **B. Fetch them all on a timer.** Rejected: 61 fetches every cycle, most
  for nothing.
- **C. Never fetch the others.** Rejected: ↓ would only say what the last
  fetch in a terminal saw.

The fetch is the selected repository's background fetch
([005](005_branches_and_remotes.md)), with the same guards: no prompts
(`BatchMode=yes`, `credential.interactive=false`), quiet failures, and
"last fetched" read from git's own `FETCH_HEAD`. It names no remote, so
git picks the current branch's remote, else origin, as `git fetch` does
by itself. Every remote's URL gets the signed-in forge's credential helper.
Behind other apps nothing is fetched; the selected repository keeps its
own 5-minute fetch.

### Pull All

- **A. Fast-forward only; anything else is skipped and listed.** Chosen by
  the owner (2026-11-12). Every repository is fetched (four at a time),
  then a repository whose branch is behind and not ahead gets `git merge
--ff-only @{upstream}`. git refuses when an uncommitted change touches
  an incoming file, or when a merge is in progress, so "no conflict with
  local changes" is git's decision, not ours. A branch that is ahead too
  is skipped as "has local commits": pulling it means a merge or a rebase,
  which a batch command should not do in a dozen repositories at once. A
  fast-forward loses nothing and rewrites nothing.
- **B. Also pull diverged branches when `merge-tree` predicts no
  conflict.** Rejected by the owner: it rebases local commits or makes
  merge commits without the user looking at either.

Only the checked-out branch is pulled; other local branches are left as
they are. The fetch is the background one, without prompts: a passphrase
asked once per repository would be sixty dialogs. A failure is listed with
git's own words. A summary lists what was pulled and what was skipped, and
why; an up-to-date repository is not listed. Stop finishes the
repositories already started, since a fast-forward killed halfway could
leave an index lock behind, and starts no more.

⌥⇧⌘P: Pull is ⇧⌘P, and ⌥ is the Mac's "all" (⌥⌘W closes all windows).

### The setting

Settings → General → "Show status in the repository list", on by default,
as GitHub Desktop has it. Off, nothing of this plan runs: no reads of the
others, no stream, no fetches of the others. Pull All still works.

## Decision

As chosen above: rows read at launch and when FSEvents says so, the
selected row copied from the window's status, GitHub Desktop's 15/30-minute
fetch rule gated by `pushedAt`, fast-forward-only Pull All, and a setting.

What the rows show: ↓ and ↑ without numbers, as GitHub Desktop's list does
(the counts are in the tooltip), then a dot in the accent colour, white on
a selected row.

## Plan

1. ✅ `OverviewModel`: the rows, the stream, the fetch cycle and Pull All;
   `ForgeModel.lastPushes(of:)` from the privacy query. Tests against real
   git: ahead, behind and changes read for a repository not selected; a
   change in an ignored folder costs no read; a repository fetched only
   when its last fetch is old enough; Pull All fast-forwards a clean one,
   and skips one with local commits and one whose change an incoming
   commit touches, leaving both as they were.
2. ✅ The rows, the menu item and its summary sheet, the setting, Help;
   the rows checked in the app on 2026-11-12, behind other apps.
3. Measure idle cost again with the owner's 61 repositories, in front and
   behind.

## Open questions

- **A linked worktree's git directory** lies outside its folder and is not
  watched for the rows, so a commit made in it shows on its row at the next
  launch or rescan. Watching every repository's git directories would cost
  a `rev-parse` per repository at launch; wait until someone has one in
  the list.
