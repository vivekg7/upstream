# 009 — Repositories and settings

**Status:** `IN PROGRESS` — sidebar, clone, create, open in, Settings → General built; the Account tab waits on the forge's picker
**Started:** 2026-11-11

## Problem

The skeleton lists repositories by folder name and can add and remove
them. GitHub Desktop users also expect, from the
[REQUIREMENTS](../REQUIREMENTS.md#repositories): the list grouped by owner
and filterable, clone (by URL or from their account), create a repository
with a README, `.gitignore` and licence, open a repository in their editor,
terminal or Finder, and a Settings pane for their git identity, default
branch, editor, terminal and git. Each looks small; together they decide
what the app does at idle with fifty repositories in the list, how much
the binary grows, and whether the app ever talks to the network on its own.

## Options

### Who owns a repository

- **A. The host and owner path of a remote's URL.** Chosen. origin's URL,
  else the first other remote's by name; `github.com` + `octocat`,
  `gitlab.com` + `group/subgroup`. Every URL form git accepts is read:
  `https://`, `ssh://` and `git://` (with user and port dropped) and
  scp-like `git@host:owner/repo`, which git takes as scp-like only when no
  slash comes before the first colon. A local path, a `file://` URL or a
  URL with no owner goes under "Other". It is plain git, so it says
  nothing about which forge runs the host, and GitLab subgroups need no
  special case.
- **B. Ask the signed-in forge.** Rejected: it groups only repositories on
  a signed-in forge, needs the network, and puts a forge into the
  repository list.

### Reading the remotes

- **A. One `git config -z --get-regexp '^remote\..*\.url$'` per repository,
  when it is first seen, and again for the selected one.** Chosen. `-z`
  is git's machine format for config (`key\nvalue\0`). It runs once per
  repository per launch, in parallel, and the sidebar shows the plain list
  until all have answered, so it does not regroup in front of the user.
  The selected repository is read again on selection because the user may
  just have added its remote, and one process is nothing.
- **B. On every refresh.** Rejected: a process per repository each time the
  app comes to the front, to redraw headers that almost never change.
- **C. `git remote get-url`** per remote. Rejected for now: it applies
  `url.<base>.insteadOf`, which A does not, but costs a process per remote
  as well as one to list them. See Open questions.

### Change counts and ahead/behind on each row

GitHub Desktop shows both on every repository in its list.

- **A. None.** Chosen. Each would cost a `git status` per repository, on
  every refresh, for every repository the user ever added, and the owner
  audits idle CPU. The selected repository's counts are already in the
  toolbar. Written down as a departure in the REQUIREMENTS.
- **B. Live, as GitHub Desktop does.** Rejected for the cost above: fifty
  repositories is fifty `git status` runs each time the app comes to the
  front, most of them on large trees nobody is looking at.
- **C. The values from the last time each repository was selected.**
  Rejected: a count from yesterday is worse than none, because it looks
  current. If users ask, revisit with a watcher per repository, which
  costs no process until something changes.

### A missing folder

Shown in its group with a warning icon, dimmed; it cannot be selected,
since there is nothing to show, and its menu offers Locate… (choose the
folder where it went; it replaces the entry if it is a repository) and
Remove. If the selected repository goes missing, the selection moves to
the first one that is there. Folders are checked with a `stat` each time
the app comes to the front and whenever the list or selection changes,
which costs no process.

### Clone progress

- **A. Indeterminate, with "Cloning…".** Chosen. git's progress
  (`--progress`, `Receiving objects: 45%`) is human output on stderr, which
  changes with version and locale; there is no machine form of it.
- **B. Parse the progress lines**, as GitHub Desktop does. Rejected by the
  rule against parsing human output.

### Cancelling a clone

Cancel cancels the task, which terminates git (`Git.run`). git removes its
own half-made folder when it fails or is terminated (it registers a
handler for exactly this). We also remove the destination if the clone
threw and the folder did not exist before it started, which covers a
cancel that arrives before git has started; a folder that was there
before is never removed. The clone runs with `--recurse-submodules`, as
GitHub Desktop clones, and is prefixed with `AppModel.networkArguments`
so the signed-in forge answers HTTPS credentials.

### Create

`git init -b <default branch>` (the branch from `init.defaultBranch`, else
`main`), then the chosen files, then `git commit -m "Initial commit"`
through git, so the user's hooks and signing apply. In a folder that
already has files, a file is never overwritten, and only the files the app
wrote are committed: committing everything there unseen could commit a
secret, and the rest waits in Changes with its checkboxes. A failure after
`git init` (no identity, a hook) still adds the repository, with git's
message shown.

### Templates

- **A. Embed a small set.** Chosen. `.gitignore`: Go, Java, macOS, Node,
  Python, Rust, Swift and Xcode from
  [github/gitignore](https://github.com/github/gitignore) (CC0-1.0).
  Licences: MIT, Apache-2.0, GPL-3.0, BSD-2-Clause, BSD-3-Clause, ISC and
  the Unlicense from
  [choosealicense.com](https://github.com/github/choosealicense.com) (MIT,
  notice kept in `Templates.swift`), the texts GitHub puts in a new
  repository and GitHub Desktop bundles, with `[year]` and `[fullname]`
  filled from the clock and `user.name`. They are Swift string literals,
  byte for byte, in a file the formatter skips.
  **Cost: 64,576 bytes (63 KB) of the release binary** (measured by
  building with and without the texts, 2026-11-11), of which GPL-3.0 alone
  is 35 KB. Against the 15 MB budget that is 0.4%.
- **B. Fetch from the GitHub API** (`/gitignore/templates`, `/licenses`)
  when the sheet opens. Rejected: network the user did not ask for, to a
  forge they may not use, and creating a repository would stop working
  offline.
- **C. SwiftPM resources.** Rejected: the same bytes plus a resource bundle
  that `scripts/build-mac.sh` would have to copy and `Bundle.module` to
  find it, for no gain over a literal.
- **D. SPDX texts** (CC0, no notice). Rejected: one line per paragraph and
  placeholders that differ per licence (`<year> <owner>`,
  `<copyright holders>`), where choosealicense's are wrapped at 80 columns
  and uniform, and are what a GitHub user's other repositories already
  contain.

### Opening in an editor or terminal

- **A. Known apps by bundle ID, opened with `NSWorkspace`.** Chosen.
  `urlForApplication(withBundleIdentifier:)` finds an app wherever it is
  installed; `open(_:withApplicationAt:configuration:)` hands it the
  folder as a document, which every listed editor and terminal takes as
  "open this folder". Settings lists only the installed ones; "Automatic"
  means the first installed in our order (VS Code first, as GitHub
  Desktop), and Terminal for terminals. No editor at all opens the file
  in its default app. `openInEditor(_:)` takes a file too, for conflicts.
- **B. Run each app's command-line tool** (`code`, `zed`, `subl`).
  Rejected: they are often not installed or not on the GUI's `PATH`.
- **C. A free-form command in Settings.** Rejected for v1: a shell string
  to quote and run. A bundle ID list covers the apps people use; add to it.

Shortcuts are GitHub Desktop's: ⌘⇧A editor, `` ⌃` `` terminal, ⌘⇧F Finder, in
a Repository menu; ⌘N New Repository and ⌘⇧O Clone in File.

### Settings → General

- **Name, email, default branch** are read and written with
  `git config --global` (`--unset` when emptied), so git chooses the file
  (`~/.gitconfig`, the XDG one, or `GIT_CONFIG_GLOBAL`) and a terminal sees
  the same values. The email is checked for one `@`, a dotted domain, and
  no spaces or angle brackets; the branch with `git check-ref-format`.
- **Editor, terminal, clone folder, git path** are the app's own, in
  `UserDefaults`. The clone folder defaults to **`~/Developer`** rather
  than GitHub Desktop's `~/Documents/GitHub`: it names no forge, Finder
  gives it its own icon, and it is outside Documents, which iCloud may
  sync. It is created on first use.
- **The git to use** shows the path found and its version. An override
  path is passed to `Git.locate(preferred:)` when the app starts; changing
  git under a running app would mean rebuilding every feature's state, so
  it applies at the next launch, and the pane says so.
- **The git version** has no machine-readable form. `git --version` is
  read for the first word starting with a digit, compared number by number
  (2.9 is older than 2.38, which a string comparison gets wrong). It only
  decides a warning — once at launch above the window, and in Settings —
  so a version that cannot be read warns about nothing. Probing for
  `merge-tree --write-tree` instead was rejected: its usage error and an
  unknown option's look the same from outside.

## Decision

As chosen above: owners from one cached `git config -z` per repository, no
per-row status, git's own clone with indeterminate progress, embedded
templates (63 KB), apps by bundle ID, and the global git config through
git.

## Plan

1. ✅ `LibraryModel` (a feature of `AppModel`): owners, missing folders,
   clone, create, locate. `RemoteOwner`, `GlobalConfig`, `GitVersion`,
   `Templates`.
2. ✅ The sidebar: groups, filter, missing rows, an add menu; the clone and
   create sheets; `RepositoryCommands`; `Opening.swift`
   (`openInEditor(_:)`, `openInTerminal(_:)`, `showInFinder(_:)`);
   Settings → General.
3. ✅ Tests against real git: every URL form, origin first and no remote,
   a moved folder located again, create on the chosen branch, create in a
   folder with files, clone from a bare repository, a cancelled clone,
   settings in a scratch global config, an old git.
4. The Account tab lists repositories once the forge's
   `AccountRepositoryPicker` is built
   ([002](002_forges_github_first.md)).

## Open questions

- **`url.<base>.insteadOf`.** A remote written as `gh:owner/repo` groups
  under host `gh`. Applying the rewrite ourselves would reimplement git;
  `git remote get-url` would cost a process per remote. Wait until someone
  has it.
- **An editor that will not open a folder.** kitty and WezTerm take an
  opened folder on recent versions; older ones may not. If one does not,
  it needs its own launch arguments.
- **Cancelling a clone over SSH or HTTPS**: git's transport child (`ssh`,
  `git-remote-https`) inherits git's stderr and may hold the pipe for a
  moment after git is terminated, so the sheet can take that long to
  return. It exits once git's end of its stdin closes.
