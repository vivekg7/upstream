# 004 — Refreshing on file changes

**Status:** `IN PROGRESS` — FSEvents watcher, ignored-path filter, coalesced refresh, measured; not yet on `main`
**Started:** 2026-11-11

## Problem

The skeleton read the status when the app became active and on ⌘R. Edits
made while the app is in front (a save in an editor beside it, a `git
commit` in a terminal pane, a fetch the app itself ran) were not shown until
the user switched away and back. GitHub Desktop refreshes on its own
([REQUIREMENTS](../REQUIREMENTS.md#changes)).

Refreshing costs a `git status`: milliseconds in a small repository, a
second or more in a huge one. Whatever triggers it must not run it for
nothing. Builds write thousands of files into ignored folders, and every git
command touches `.git/objects` or a lock file. Nor may it run while nobody
is looking, which is what the idle budget is about.

## Options

- **A. FSEvents on the working tree and the git directories.** Chosen. The
  kernel batches the events (`latency` 0.3 s), costs nothing between them,
  and reports paths, so the noise can be filtered before any process runs.
- **B. Poll `git status` every few seconds.** Rejected. It costs a process
  and a tree walk on every tick, forever, whether anything changed or not.
- **C. Let git's `fsmonitor` daemon answer.** Rejected as the trigger. It
  makes `git status` itself faster where the user has turned it on, and our
  status benefits from that untouched, but it does not tell the app _when_
  to ask.
- **D. kqueue / `DispatchSource` per directory.** Rejected. One file
  descriptor per directory runs into the descriptor limit on a large tree,
  and the events say only that a directory changed.

## Decision

`Watcher` (FSEvents with file-level events) on the top level, plus the git
directory and the common directory when they lie outside it (a linked
worktree, `GIT_DIR` elsewhere). `AppModel` decides what an event is worth:

- **Inside the git directory**, only what changes what the app shows:
  `index`, `HEAD`, `refs/…`, `packed-refs`, and the merge, rebase,
  cherry-pick and revert markers. `objects/`, `logs/`, `*.lock`,
  `FETCH_HEAD` and the like are dropped. Our own `status` takes no optional
  locks and writes nothing, so a refresh never triggers another.
- **In the working tree**, the changed paths go to `git check-ignore -z
--stdin`, one process for the whole batch. If every one is ignored (a
  build writing into `.build/`, `node_modules/`, `target/`), there is no
  refresh. Tracked files are never reported as ignored, so an edit to one
  always counts.
- **FSEvents dropped events** (`MustScanSubDirs`): refresh.
- **The app in the background:** an event only marks the repository stale.
  Coming to the front refreshes if it is stale, and not otherwise. An app
  left open behind a long build runs no git at all.
- **Only the selected repository is watched.** Others are read when they
  are selected.

### Refreshes coalesce

`refresh()` runs at most one status at a time. A call made while one runs
asks for one more round and waits for it, so every caller still sees a
status read after it asked. A burst of any size costs one or two runs. The
tests count the runs.

### The stream holds its handler

The FSEvents context retains the box holding the handler, and releases it
when the stream is freed. FSEvents can still call back after `Invalidate`
(the WatchRoot check runs on its own queue); with an unretained box that
late call read freed memory, and the test suite crashed in about one run
in three, which the app would have done on switching repositories.

### Paths are real paths

FSEvents reports resolved paths (`/private/var/…`), while git may print the
path the user opened (`/var/…`). Both sides are compared after `realpath`.
`URL.resolvingSymlinksInPath` will not do, because it strips `/private` on
purpose. Found by the test, which fails without it.

## Plan

1. ✅ `Watcher` and `WatchFilter`, the coalesced `refresh()`, and the
   activity rule. Tests: the filter's choices, an edit picked up without
   asking, twenty files written into an ignored folder costing no status,
   and a burst of ten refreshes costing at most two.
2. ✅ Measure idle cost with the app open, in front and behind, on large
   repositories ([REQUIREMENTS](../REQUIREMENTS.md#lightweight-and-fast)),
   and fix what the measuring found (below).

## Measured

2026-11-11, release build, M-series Mac, git 2.54. Repositories: 50,000
tracked files, clean; 10,000 changes; 100,000 commits; a 9 MB diff of
100,000 lines; a 60 MB diff and a 50 MB binary. Method:
[`docs/memory/measuring-the-mac-app.md`](../memory/measuring-the-mac-app.md).

| What                                      | Measured                                                                                                        |
| ----------------------------------------- | --------------------------------------------------------------------------------------------------------------- |
| Behind other apps, 10 minutes             | no git, no network, 0.07 s of CPU                                                                               |
| In front, idle                            | no git and no wakeups between events; one fetch every 5 minutes (about 5 KB to GitHub when current)             |
| Coming to the front or going behind       | one `git config` (the sidebar's remotes for the selected repository) and a stat per folder                      |
| At launch                                 | 11 git processes before any fetch, one `git status` among them; the first status shown 0.37–0.52 s after launch |
| A refresh with 10,000 changes, beyond git | 6 ms (the parse was 11 ms; it now reads the records as bytes)                                                   |
| Memory                                    | 41–61 MB idle; 62–97 MB with a 10,000- to 100,000-line diff loaded; 79–87 MB at the 16 MB ceiling               |

Found and fixed by measuring:

- **Two status reads at every launch.** `selected = …` in `init` ran the
  property's didSet under `@Observable`, which refreshed, and the window
  asked again 180 ms later. `init` now sets the storage and starts the one
  read itself, before the window exists, which also shows it 0.2 s sooner.
- **The branch list read twice at launch**: the fetch loop's first check
  asked for another reload instead of waiting for the one running. The git
  version was asked twice the same way.
- **An app launched behind** (a login item, `open -g`) assumed it was in
  front, so its fetch loop ran. It now starts from `NSApp.isActive`.
- **The watcher's use after free** (above).

Not measured: a signed-in forge, which polls the current branch's checks
once a minute while in front (conditional requests; 304s cost no rate
limit) and keeps polling behind only while a check is pending
([002](002_forges_github_first.md)).

## Open questions

- **Huge working trees.** `git status` itself may take seconds (a monorepo
  without fsmonitor). A save every second would keep one running all the
  time. If it shows up, stretch the latency with the last status's
  duration.
