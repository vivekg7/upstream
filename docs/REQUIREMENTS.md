# Requirements

What Upstream does. Why each part is built the way it is lives in the
[plans](plans/README.md). When what the product should _do_ is unclear, ask
the owner and write the answer here.

## Who it is for

Anyone who uses GitHub Desktop, or would like to, and finds it too heavy:
**1.1 GB installed** on the owner's Mac (2026-11-11), slow to open, an
Electron app with its own copy of git. Upstream does the same job natively,
for anyone in the world, under MIT. The owner's answers (2026-11-11):

| Question       | Answer                                                                                                                       |
| -------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| Name           | **Upstream** — forge-neutral, since GitLab and Bitbucket follow GitHub; no "Git" prefix (the Git trademark policy asks not). |
| Forge features | **PRs and CI in the app**, not only sign-in and clone.                                                                       |
| Forges         | **GitHub in v1**, then GitLab, then Bitbucket, behind one interface from the start.                                          |
| Licence        | **MIT**, as GitHub Desktop.                                                                                                  |

## Platforms

- **macOS 26 or later, Apple silicon only.** No Intel build, no universal
  binary, no back-deployment. One architecture and one OS generation means
  no compatibility code, the newest SwiftUI throughout, and half the binary.
- **Linux later**, as a native GTK4 and libadwaita app
  ([001](plans/001_native_clients_on_system_git.md)). Same features, wherever
  Linux allows.
- **Not Windows.**
- **git 2.38 or later, the user's own.** Upstream never bundles git.

## Lightweight and fast

GitHub Desktop is the baseline. Targets, on an M-series Mac:

| Measure                                    | Target                                              | Now (2026-11-11, v1 build)                          | GitHub Desktop (2026-11-11)   |
| ------------------------------------------ | --------------------------------------------------- | --------------------------------------------------- | ----------------------------- |
| App on disk                                | ≤ 15 MB                                             | 2.5 MB (1.0 MB zipped)                              | 1.1 GB                        |
| Launch to the first status shown           | ≤ 0.5 s                                             | 0.37–0.52 s, median 0.43 s                          | —                             |
| Memory, one repository open                | ≤ 100 MB footprint                                  | 41–61 MB; 62–97 MB with a 10k–100k-line diff loaded | 183 MB (four processes, idle) |
| Status refresh, beyond `git status` itself | ≤ 30 ms for 10,000 changes                          | 6 ms                                                | —                             |
| A 10,000-line diff                         | opens and scrolls smoothly                          | < 0.1 s, 3 ms a frame                               | —                             |
| History                                    | first page ≤ 200 ms on 100k commits, the rest paged | 10 ms; later pages 16 ms                            | —                             |
| Idle                                       | behind: nothing; in front: the 5-minute fetch only  | behind: 0 git, 0 bytes, 0.07 s CPU in 10 min        | —                             |

How each was measured, and on what, is in
[004](plans/004_refreshing_on_file_changes.md#measured) and
[`docs/memory/measuring-the-mac-app.md`](memory/measuring-the-mac-app.md).

GitHub Desktop's memory is the sum of its four processes' footprints, idle
behind other apps with the owner's repositories open. Fill in the rest of its
column before the first release, measured the same way, so the comparison is
honest.

## v1: what GitHub Desktop users rely on

Status: ✅ built, ◻️ to build.

### Repositories

- ✅ A list of repositories in the sidebar, grouped by owner (host and
  owner path of origin's URL, else another remote's; "Other" without one),
  filterable. A folder that has moved or gone is shown as missing, with
  Locate… and Remove. A private repository's folder has a lock on it
  (asked of the signed-in forge, so signed out every folder is plain).
  ✅ Add a local folder (its top-level working tree is what is added).
  ✅ Remove from the list (the folder is untouched).
- Unlike GitHub Desktop, the rows show no change counts or ahead/behind:
  each would cost a `git status` per repository, on every refresh, for
  every repository the user ever added. The selected one's are in the
  toolbar ([009](plans/009_repositories_and_settings.md)).
- ✅ Clone by URL, or from the signed-in account's repositories, into a
  folder that defaults to `~/Developer` (Settings). Cancel stops git and
  leaves no folder behind.
- ✅ Create a repository: `git init`, with optional README, `.gitignore`
  template and licence, committed as "Initial commit". In a folder that
  already has files, none is overwritten and only the new files are
  committed; the rest wait in Changes.
- ✅ Publish a local repository to the signed-in forge.
- ✅ Open in the editor (⌘⇧A), the terminal (`` ⌃` ``), or Finder (⌘⇧F); the
  editor and terminal are chosen in Settings from the ones installed.

### Changes

GitHub Desktop's **checkbox model**: every changed file has a checkbox, and
the commit records exactly the checked files (and checked lines). Users
never need to know the index exists. Changes the user staged from a terminal
show as checked.

The owner's answer (2026-11-11): **the app holds the checkboxes until
Commit**, as GitHub Desktop does, rather than staging on every click. New
changes start checked. If anything is already staged, what is staged starts
checked and nothing else. Whatever is staged for a file left unchecked
stays staged after the commit (unlike GitHub Desktop, which unstages it).
How: [003](plans/003_the_checkbox_commit.md).

- ✅ The changed files, with one status each (new, modified, deleted,
  renamed, conflicted) and the diff of the selected one against `HEAD`.
- ✅ Checkboxes per file, and one for all; click a line's gutter or a hunk
  header in the diff to commit part of a file. A binary, a deletion or a
  submodule commits whole.
- ✅ Commit: summary, description, amend the last commit (warns when it is
  already pushed). Signing and hooks come from the user's git config,
  untouched. ✅ Co-authors (`Co-authored-by:` trailers); the summary
  prefilled from `commit.template`.
- ✅ Discard changes to a file or to selected lines, after confirming. The
  discarded content goes to the **Trash**
  ([008](plans/008_discard_ignore_and_conflicts.md)).
- ✅ Stash: offered when switching branches with changes; restore or discard
  the stash. Only the stashes Upstream (or GitHub Desktop) left on the
  current branch are offered; one made in a terminal stays the user's
  ([005](plans/005_branches_and_remotes.md)).
- ✅ Ignore an untracked file or its extension (adds to the top-level
  `.gitignore`). A tracked file is not offered: git goes on tracking it
  whatever `.gitignore` says.
- ✅ Refresh on its own when files change (FSEvents), not only on focus and
  ⌘R ([004](plans/004_refreshing_on_file_changes.md)).

### Diff

- ✅ Unified diff with line numbers.
- ✅ Split view, hide whitespace, word-level highlights within changed lines.
  Lines can be checked in the split view too. While whitespace is hidden
  they cannot, as in GitHub Desktop: the diff shown is not the one
  committed.
- ✅ Image diff (side by side) for common image types.
- ✅ A large diff (over 20,000 lines or 4 MB) asks before it is drawn, as
  in GitHub Desktop. Past 16 MB it is not read at all, and the file
  commits whole ([007](plans/007_the_diff_view.md)).
- ◻️ Syntax highlighting. Later than the rest: no dependency is allowed for
  it, so it waits for a small highlighter of our own.

### History

- ✅ Commits of the current branch, paged; the files and diff of each.
  Commits not pushed yet are marked, tags and branches are shown on the
  commit they point at. A merge shows what it brought in: its files
  against the first parent.
- ✅ Create a branch or tag from a commit, cherry-pick, revert, reset to a
  commit (after confirming), copy the SHA, open on the forge. Undo the last
  commit while it is not pushed: its changes go back, staged, and its
  message back into the commit fields; a message the user has already
  started typing there is kept rather than replaced (it is their writing;
  the undone message is still in `git reflog`). Reset keeps
  the changes in the working tree (`--mixed`), never `--hard`.
- ◻️ Squash, reorder and edit messages of unpushed commits (interactive
  rebase run for the user). After the first release.

### Branches

- ✅ The current branch with ahead/behind counts in the toolbar.
- ✅ Switch, create, rename, delete (local and remote, after confirming).
- ✅ Merge another branch into this one, rebase this one onto another,
  squash-merge; preview whether it will conflict before starting
  (`git merge-tree`, hence git 2.38).
- ✅ Compare with another branch: in History, its commits this branch
  lacks (behind) and this branch's commits it lacks (ahead), in GitHub
  Desktop's words. Cherry-pick is offered there, on the commits this
  branch lacks.

### Remotes

- ✅ Fetch (and every few minutes in the background), pull (the user's
  `pull.rebase` setting decides how), push, publish a branch. The
  background fetch runs every 5 minutes, only while the app is in front and
  only for the selected repository
  ([005](plans/005_branches_and_remotes.md)).
- ✅ After a rebase or amend: force push only as
  `--force-with-lease --force-if-includes`, after confirming.
- ✅ SSH and HTTPS remotes on any host work through the user's own keys and
  credential helpers. A signed-in forge also answers HTTPS credentials for
  its own host ([002](plans/002_forges_github_first.md)).

### Conflicts

- ✅ During a merge, rebase, cherry-pick or revert: the conflicted files, open
  each in the editor, take ours or theirs (named by branch), then continue
  or abort ([008](plans/008_discard_ignore_and_conflicts.md)). What is
  staged is what continues; other changes stay in the working tree.

### Pull requests and CI (GitHub in v1)

- ✅ Sign in to GitHub (and GitHub Enterprise Server by host); the token is
  kept in the Keychain.
- ✅ The repository's open pull requests, each with its CI state; check one
  out (including from forks).
- ✅ CI state of the current branch in the toolbar, with the failing checks
  listed and a link to each.
- ✅ Create a pull request: opens the forge's own form in the browser with
  the branch filled in. The forge's form already has templates, reviewers
  and labels; repeating it in the app is after v1.
- ✅ A notification when the current branch's checks finish.

### Settings

- ✅ Name and email (`user.name`, `user.email` in the global config), the
  default branch name, the editor and terminal, the git to use (found
  automatically, overridable; a change applies at the next launch). A git
  older than 2.38 is named in a warning at launch and in Settings.
- Appearance follows the system. There is no separate theme setting.

### Keyboard and help

The owner's ask (2026-11-11): simple keyboard navigation that feels
obvious, a help page and a keyboard shortcuts page
([010](plans/010_keyboard_and_help.md)).

- ✅ GitHub Desktop's shortcuts in the menus. ⌘1 and ⌘2 show Changes and
  History with the keyboard in the list; ⌘T goes to the sidebar's filter,
  and ↓ from there opens the first match.
- ✅ ← and → move between the columns' lists (repositories, changes or
  history, a commit's files), as between Finder's columns; ↑ and ↓ move
  within one. Arriving in a list with nothing selected selects its first
  row.
- ✅ Space checks or unchecks the selected files.
- ✅ Help → Upstream Help: a window of short topics, drawn by the app and
  offline. Help → Keyboard Shortcuts (⌘/) opens it on the full list,
  which is read from the same table as the menus.

## Not in v1

- GitLab and Bitbucket forge features (plain git with them works in v1).
- Submodule management beyond showing their changes.
- Git LFS management (LFS works through git; there is no LFS UI).
- Auto-update. Releases are on GitHub; an update check may come later.

## Never

- Bundled git, a bundled browser engine or webview, telemetry.
- Intel Macs, macOS before 26, Windows.
