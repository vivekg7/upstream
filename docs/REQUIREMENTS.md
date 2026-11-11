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

| Measure                                    | Target                                              | Now (2026-11-11, skeleton) | GitHub Desktop |
| ------------------------------------------ | --------------------------------------------------- | -------------------------- | -------------- |
| App on disk                                | ≤ 15 MB                                             | 380 KB                     | 1.1 GB         |
| Launch to a usable window                  | ≤ 0.5 s                                             | not measured               | —              |
| Memory, one repository open                | ≤ 100 MB footprint                                  | 51 MB                      | —              |
| Status refresh, beyond `git status` itself | ≤ 30 ms for 10,000 changes                          | not measured               | —              |
| A 10,000-line diff                         | opens and scrolls smoothly                          | not measured               | —              |
| History                                    | first page ≤ 200 ms on 100k commits, the rest paged | not measured               | —              |

Fill in the GitHub Desktop column before the first release, measured the same
way, so the comparison is honest.

## v1: what GitHub Desktop users rely on

Status: ✅ built, ◻️ to build.

### Repositories

- ◻️ A list of repositories in the sidebar, grouped by owner, filterable.
  ✅ Add a local folder (its top-level working tree is what is added).
  ✅ Remove from the list (the folder is untouched).
- ◻️ Clone by URL, or from the signed-in account's repositories.
- ◻️ Create a repository: `git init`, with optional README, `.gitignore`
  template and licence.
- ◻️ Publish a local repository to the signed-in forge.
- ◻️ Open in the editor, the terminal, or Finder; each configurable.

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
  untouched. ◻️ Co-authors (`Co-authored-by:` trailers); the summary
  prefilled from `commit.template`.
- ◻️ Discard changes to a file or to selected lines, after confirming. The
  discarded content goes to the **Trash**.
- ◻️ Stash: offered when switching branches with changes; restore or discard
  the stash.
- ◻️ Ignore a file or extension (adds to `.gitignore`).
- ◻️ Refresh on its own when files change (FSEvents), not only on focus and
  ⌘R.

### Diff

- ✅ Unified diff with line numbers.
- ◻️ Split view, hide whitespace, word-level highlights within changed lines.
- ◻️ Image diff (side by side) for common image types.
- ◻️ Syntax highlighting. Later than the rest: no dependency is allowed for
  it, so it waits for a small highlighter of our own.

### History

- ◻️ Commits of the current branch, paged; the files and diff of each.
- ◻️ Create a branch or tag from a commit, cherry-pick, revert, reset to a
  commit (after confirming), copy the SHA, open on the forge.
- ◻️ Squash, reorder and edit messages of unpushed commits (interactive
  rebase run for the user). After the first release.

### Branches

- ✅ The current branch with ahead/behind counts in the toolbar.
- ◻️ Switch, create, rename, delete (local and remote, after confirming).
- ◻️ Merge another branch into this one, rebase this one onto another,
  squash-merge; preview whether it will conflict before starting
  (`git merge-tree`, hence git 2.38).
- ◻️ Compare with another branch.

### Remotes

- ◻️ Fetch (and every few minutes in the background), pull (the user's
  `pull.rebase` setting decides how), push, publish a branch.
- ◻️ After a rebase or amend: force push only as
  `--force-with-lease --force-if-includes`, after confirming.
- ◻️ SSH and HTTPS remotes on any host work through the user's own keys and
  credential helpers. A signed-in forge also answers HTTPS credentials for
  its own host ([002](plans/002_forges_github_first.md)).

### Conflicts

- ◻️ During a merge, rebase, cherry-pick or revert: the conflicted files, open
  each in the editor, take ours or theirs, then continue or abort.

### Pull requests and CI (GitHub in v1)

- ◻️ Sign in to GitHub (and GitHub Enterprise Server by host); the token is
  kept in the Keychain.
- ◻️ The repository's open pull requests, each with its CI state; check one
  out (including from forks).
- ◻️ CI state of the current branch in the toolbar, with the failing checks
  listed and a link to each.
- ◻️ Create a pull request: opens the forge's own form in the browser with
  the branch filled in. The forge's form already has templates, reviewers
  and labels; repeating it in the app is after v1.
- ◻️ A notification when the current branch's checks finish.

### Settings

- ◻️ Name and email (`user.name`, `user.email` in the global config), the
  default branch name, the editor and terminal, the git to use (found
  automatically, overridable).
- Appearance follows the system. There is no separate theme setting.

## Not in v1

- GitLab and Bitbucket forge features (plain git with them works in v1).
- Submodule management beyond showing their changes.
- Git LFS management (LFS works through git; there is no LFS UI).
- Auto-update. Releases are on GitHub; an update check may come later.

## Never

- Bundled git, a bundled browser engine or webview, telemetry.
- Intel Macs, macOS before 26, Windows.
