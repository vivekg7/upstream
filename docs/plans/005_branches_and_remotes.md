# 005 — Branches, remotes and the stash

**Status:** `IN PROGRESS` — macOS: branch menu, switch (carry or stash), create, rename, delete, merge/squash/rebase with a preview, fetch/pull/push/publish/force push, background fetch, the stash row
**Started:** 2026-11-11

## Problem

After committing, a GitHub Desktop user's next moves are all about
branches: switch to one (taking their changes along or leaving them
behind), start one, merge one in, and get it to and from the remote with
one button. Plan [001](001_native_clients_on_system_git.md) step 4 builds
these ([REQUIREMENTS](../REQUIREMENTS.md#branches)). The parts that need a
decision are how the branch list is read, how a merge is previewed, what
the remote button does in each state, how a force push stays safe, how
often to fetch in the background, and which stash entries the Changes list
offers.

## Options

### Reading the branches

- **A. One `git for-each-ref` with an explicit `--format`.** Chosen. Every
  field is a `%(…)` atom followed by `%00`; git ends each record with a
  newline, which a refname cannot contain. `%(upstream:trackshort)` gives
  `=`, `>`, `<` or `<>` per branch, and nothing when the upstream is gone.
  Measured (2026-11-11, M-series): 27 ms for the 1,764 refs of a Zed clone,
  22 ms for Flutter's 919, both with a branch hundreds of commits behind.
- **B. `%(upstream:track)` for the counts.** Rejected: "ahead 2, behind 1"
  and "gone" are translated (`_()` in `ref-filter.c`), so they are human
  output. The exact counts for the current branch come from `status`
  anyway.
- **C. `git branch -vv`.** Rejected: human output.
- **D. `%(ahead-behind:…)`.** Rejected: git 2.41, above our 2.38 floor, and
  it counts against one fixed commit, not each branch's own upstream.

The list is read when the selected repository's status shows a different
branch, upstream, ahead/behind or stash count, after each of our
operations, and when the popover opens. Nothing polls it.

### Previewing a merge

- **A. `git merge-tree --write-tree --name-only -z --no-messages HEAD
<branch>`.** Chosen. It merges in memory (git 2.38), exits 0 when clean
  and 1 on conflicts, and prints the tree followed by each conflicted path
  once, all NUL-terminated. The messages section is human text, so it is
  turned off. `rev-list --count` gives the commits each side lacks, so the
  sheet says "up to date" without merging at all. This is GitHub Desktop's
  "N conflicted files" / "can be merged cleanly".
- **B. A trial merge in a temporary worktree.** Rejected: slow, writes to
  disk, and is what `merge-tree` replaced.
- **Rebase** is not previewed for conflicts: it replays commit by commit,
  and one `merge-tree` of the two tips does not say which step would stop.
  The sheet says how many commits are rewritten, or that it fast-forwards.

On a conflict the repository is left exactly as `git merge` or `git rebase`
leaves it; the conflicts work (plan 001 step 5) resolves it. A squash merge
stages the result and the user commits it through the Changes list, where
staged files start checked.

### The remote button

One button, as GitHub Desktop's, whose job follows the branch:

| State                                             | Button         | Runs                                                              |
| ------------------------------------------------- | -------------- | ----------------------------------------------------------------- |
| No upstream, or the upstream is gone              | Publish branch | `push --set-upstream <remote> HEAD:refs/heads/<branch>`           |
| Behind, and the upstream's tip was rewritten here | Force push…    | `push --force-with-lease --force-if-includes <remote> HEAD:<ref>` |
| Behind                                            | Pull           | `pull`, nothing added                                             |
| Ahead                                             | Push           | `push <remote> HEAD:<upstream's ref>`                             |
| Otherwise, or a detached HEAD                     | Fetch          | `fetch --prune <remote>`                                          |

Its menu offers each of them explicitly and says when the repository last
fetched. Decisions inside the table:

- **Pull passes nothing.** The user's `pull.rebase` (or `pull.ff`) decides.
  With neither set and the branches diverged, git ≥ 2.33 refuses and says
  which setting to choose; that message is shown as it is. GitHub Desktop
  merges in that case instead. See open questions.
- **Push names its destination**: the remote and ref of the upstream, so
  what is pushed is exactly what the button counted ahead of, whatever
  `push.default` says. Triangular setups (`branch.<name>.pushRemote`) are
  not modelled, as in GitHub Desktop.
- **Publish goes to origin, or the only remote; with several and no
  origin, the user picks.** With no remote at all there is no button:
  publishing a repository to a forge is the forge's feature.
- **When is a force push offered first?** Only when the upstream's tip is
  reachable from one of the branch's reflog entries, that is, the remote's
  commits were once this branch's and an amend or rebase replaced them. It
  is the same test `--force-if-includes` makes, run with `log -g` and
  `rev-list --stdin`, and only when the branch has diverged. Otherwise a
  diverged branch offers Pull, because the remote has work that was never
  here; the menu still lists Force push.
- **Force push is always `--force-with-lease --force-if-includes`**, after
  a sheet that names the upstream and lists the commits it removes from
  it. The lease alone is not enough once the app fetches in the
  background: the fetch moves `origin/<branch>`, the lease then matches,
  and someone's new commit would be overwritten unseen. `--force-if-includes`
  refuses that, and a test pins both refusals.
- **Created branches track nothing** (`switch --no-track -c`), even when
  started from a remote branch, so the button offers Publish, as GitHub
  Desktop does. With git's default `branch.autoSetupMerge`, a branch made
  from `origin/main` would track it, and Push would go into `main`.
- **Every command that reaches a remote** puts the forge's credential
  arguments (`AppModel.networkArguments`, plan
  [002](002_forges_github_first.md)) before the subcommand.

### Fetching in the background

GitHub Desktop fetches every few minutes. The owner audits idle CPU and
network, so the rule is frugal:

- **Every 5 minutes, only while the app is in front, only for the selected
  repository.** On coming to the front or selecting a repository, it
  fetches at once if the last fetch is older than 5 minutes. Between
  fetches the loop sleeps; nothing else runs. An app left behind a build
  overnight fetches nothing.
- **"Last fetched" is the modification time of `FETCH_HEAD`**, git's own
  record, so a fetch or pull in a terminal counts and resets the timer. We
  keep no fetch state of our own.
- **One remote**: the current branch's, else origin, else the only (or
  first) one. Fetching every remote of a fork setup multiplies the network
  for refs the button does not show.
- **`--prune`**, as GitHub Desktop does. A remote-tracking ref is a cache
  of the remote; pruning loses nothing the user wrote, and without it
  branches deleted on the forge after a merge stay in the list forever and
  "upstream gone" is never seen.
- **It cannot prompt.** `GIT_TERMINAL_PROMPT=0` is already on every call.
  The background fetch adds `-o BatchMode=yes` to the user's own ssh
  command (`GIT_SSH_COMMAND`, else `core.sshCommand`, else `ssh`), so a
  passphrase or an unknown host key fails the fetch instead of waiting on a
  question nobody can see; a `GIT_SSH` program is left alone, as it takes
  no ssh options. `-c credential.interactive=false` keeps Git Credential
  Manager from opening a sign-in window every 5 minutes. An explicit Fetch
  runs without either, so the user's own prompts still work when they ask.
- **Failures are quiet**: offline every 5 minutes is not news. The button's
  tooltip says the last background fetch failed and why; an explicit Fetch
  shows the error banner as any operation does.

### Which stash entries count

- **A. Only entries Upstream made, tagged per branch, as GitHub Desktop
  does.** Chosen. Stashing on switch uses the message `!!Upstream<branch>`,
  and the Changes list shows "Stashed Changes" only for the current
  branch's. An entry made in a terminal is the user's to manage; offering
  `stash@{0}` on whatever branch is current would restore someone's
  unrelated work into the wrong branch. Entries tagged
  `!!GitHub_Desktop<branch>` count too, so a GitHub Desktop user finds the
  changes they left behind.
- **B. Every stash entry.** Rejected for the reason above; the full stash
  list is a history-like view, not the Changes list's job.
- **One entry per branch, as GitHub Desktop insists?** No: GitHub Desktop
  drops the older stash when you stash again on the same branch. We never
  drop without asking. A second entry is kept, the row shows a count, and
  Restore pops the newest.

Restore is `stash pop` of that entry, found again by its object ID right
before (pushing another stash renumbers `stash@{n}`). On a conflict git
keeps the entry and the banner says so; Discard is `stash drop` after a
sheet saying the changes are deleted. The status read adds `--show-stash`,
whose `# stash <n>` header tells the model to reread the stash list without
a call of its own (no measurable cost: 88 ms either way on a Zed clone's
status).

### Switching with changes

GitHub Desktop asks: "Leave my changes on <current>" or "Bring my changes
to <new>". Both are built:

- **Leave**: `stash push --include-untracked` with the tag, then `switch`.
  If the switch fails, the stash is popped again, so the changes are where
  they were; it is popped only if the push created an entry.
- **Bring**: plain `switch`. If the changes would be overwritten, git
  refuses, nothing changes, and git's message is shown.

A remote branch with no local one is checked out as
`switch -c <name> --track <remote ref>`; one that already has a local
branch (tracking it, or of the same name) switches to that.

### Deleting

`branch -d` refuses a branch whose commits are not in its upstream (or in
HEAD without one). The sheet counts them first (`rev-list --count`), names
the number and where they are missing from, and only then uses `-D`. A
branch with an upstream can delete it on the remote in the same step;
remote branches are deleted with `push <remote> --delete refs/heads/<name>`
after a sheet saying it is for everyone who uses the remote.

## Decision

All of the above. The model is `BranchesModel` in `UpstreamKit/Branches.swift`;
the toolbar button, popover, remote button and every sheet are in
`Upstream/BranchToolbar.swift`, the stash row in `StashView.swift`, the
Branch menu in `BranchCommands.swift`. Shortcuts follow GitHub Desktop:
⌘B branches, ⌘⇧N new, ⌘⇧R rename, ⌘⇧S stash all, ⌘⇧M merge, ⌥⌘⇧M squash
merge, ⌘⇧E rebase, ⌘⇧T fetch, ⌘⇧P pull, ⌘P push (or publish).

## Plan

1. ✅ Parsers for `for-each-ref`, `merge-tree` and `stash list`, against
   new fixtures (`branches.z`, `merge-tree-*.z`, `stash-list.z`,
   `status-v2-stash.z`).
2. ✅ Behaviour tests against bare remotes on disk: carrying vs stashing on
   switch, a refused switch, a conflicting restore, checking out a remote
   branch, created branches publish rather than push, deleting unmerged
   and on the remote, both previews, a conflicted merge and a squash,
   fetch/pull/push, both force-push refusals, and the background fetch on
   opening a repository never fetched.
3. ✅ The views, sheets and menu.
4. The forge's credential helper behind `networkArguments` (plan 002).

## Open questions

- **Pull with diverged branches and no `pull.rebase`.** git refuses and
  says to choose; GitHub Desktop merges. Should Upstream merge too
  (`--no-rebase` only when neither `pull.rebase` nor `pull.ff` is set), or
  keep git's refusal? Owner to decide; today it is git's refusal.
- **Recognising GitHub Desktop's stash tag** is an interoperability choice
  the owner may veto.
- **Fetching all remotes** for fork workflows (origin and upstream), as
  GitHub Desktop does for forks it created. Waits until the forge knows
  which remote is the fork's parent.
- **Renaming a published branch** leaves its upstream pointing at the old
  name, as `git branch -m` does; Push then pushes to the old name. GitHub
  Desktop warns and does the same. Unsetting the upstream instead would
  make Publish create the new name; worth doing if users trip on it.
