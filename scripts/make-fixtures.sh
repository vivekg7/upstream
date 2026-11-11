#!/usr/bin/env bash
#
# Rebuild fixtures/git/: what real git prints for a working tree with every
# kind of change we parse. The macOS and Linux parsers are both tested
# against these same bytes (fixtures/README.md), so regenerate them here,
# never by hand.
#
#   ./scripts/make-fixtures.sh
#
# Dates and identities are fixed so the object IDs, and so the fixtures,
# are the same on every machine with the same git.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT="$ROOT/fixtures/git"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -c init.defaultBranch=main -c color.ui=false -c core.quotepath=false "$@"; }
# The options the app gives every diff (FileDiff.base in macos/).
d() { g diff --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$@"; }

cd "$WORK"
g init -q --bare origin.git
g clone -q origin.git repo 2>/dev/null
cd repo

printf 'a\nb\n' >keep.txt
printf 'x\ny\nz\n' >'old name.txt'
echo d >gone.txt
printf 's\nt\n' >staged.txt
printf 'line\n' >conflict.txt
printf '\x00\x01\x02' >image.bin
printf 'no newline' >tail.txt
g add . && g commit -qm base && g push -q origin main

# One commit on origin that this clone has not pulled: behind 1.
g clone -q ../origin.git ../other 2>/dev/null
(cd ../other && echo upstream >upstream.txt && g add . && g commit -qm upstream && g push -q origin main)
g fetch -q

# Two branches that edit the same line, merged into a conflict.
g switch -qc theirs && echo theirs >conflict.txt && g commit -qam theirs
g switch -q main && echo ours >conflict.txt && g commit -qam ours # ahead 1
g merge -q theirs >/dev/null 2>&1 || true

# Every other kind of change.
printf 'a\nB\nc\n' >keep.txt                     # modified, unstaged
g mv 'old name.txt' 'new name.txt'              # renamed, path with a space,
echo w >>'new name.txt'                         # and edited after
rm gone.txt                                     # deleted, unstaged
printf 's\ns2\n' >staged.txt && g add staged.txt # staged: -t +s2,
echo s3 >>staged.txt                            # and unstaged: +s3
echo new >added.txt && g add added.txt          # added
echo u >'ünïcode file.txt'                      # untracked, non-ASCII
printf '\x00\x09\x08' >image.bin                # binary
printf 'no newline, changed' >tail.txt          # no newline at end of file

mkdir -p "$OUT"
g status --porcelain=v2 --branch -z --untracked-files=all >"$OUT/status-v2.z"
d HEAD -- keep.txt >"$OUT/diff-modified.patch"
d HEAD -- image.bin >"$OUT/diff-binary.patch"
d HEAD -- tail.txt >"$OUT/diff-no-newline.patch"
d HEAD -- added.txt >"$OUT/diff-added.patch"
d --find-renames HEAD -- 'old name.txt' 'new name.txt' >"$OUT/diff-renamed.patch"
d --no-index -- /dev/null 'ünïcode file.txt' >"$OUT/diff-untracked.patch" || true
# One file, three ways: what the checkbox shows, and the halves that tell
# which of its lines a terminal staged.
d HEAD -- staged.txt >"$OUT/diff-staged-head.patch"
d --cached -- staged.txt >"$OUT/diff-staged-cached.patch"
d -- staged.txt >"$OUT/diff-staged-worktree.patch"
# Branches, merge previews and the stash (docs/plans/005_branches_and_remotes.md),
# after everything above is written, so none of those files change. The
# format is Branch.format in macos/: fields end in NUL, records in newline.
g remote set-head origin main                             # a symref, never listed
g branch -q --track feature/slash origin/main            # a slash, level with its upstream
g branch -q gone && g config branch.gone.remote origin && # an upstream that is gone
  g config branch.gone.merge refs/heads/gone
g for-each-ref --format='%(HEAD)%00%(refname)%00%(symref)%00%(upstream)%00%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream:trackshort)%00%(committerdate:unix)%00' \
  refs/heads refs/remotes >"$OUT/branches.z"
p() { g merge-tree --write-tree --name-only -z --no-messages "$@"; }
p main theirs >"$OUT/merge-tree-conflict.z" || true # exits 1 on a conflict
p main origin/main >"$OUT/merge-tree-clean.z"
# A stash left by a terminal, then one Upstream left when switching away.
cd "$WORK" && g clone -q origin.git stashes 2>/dev/null && cd stashes
echo mine >>keep.txt && g stash push -q -m plain
echo more >>keep.txt && echo new >new.txt && g stash push -q --include-untracked -m '!!Upstream<main>'
g stash list -z --no-show-signature --format=%H%x1f%ct%x1f%gs >"$OUT/stash-list.z"
g status --porcelain=v2 --branch --show-stash -z --untracked-files=all >"$OUT/status-v2-stash.z"

# History (docs/plans/006_history.md), in a second repository so the
# scenario above stays as it is: a first commit with a body and a literal
# "%x1f", an annotated and a lightweight tag, a rename, and a merge.
cd "$WORK" && g init -q hist && cd hist
printf 'one\ntwo\n' >a.txt && echo b >'old name.txt'
g add . && printf 'Ünïcode subject, a literal %%x1f\n\nBody line one\nbody line two\n' | g commit -q -F -
g tag -a -m 'Release 1' v1
g mv 'old name.txt' 'new name.txt' && g commit -qm 'Rename, no body'
g switch -qc side && echo s >side.txt && g add side.txt && g commit -qm Side
g switch -q main && echo m >main.txt && g add main.txt && g commit -qm Main
g merge -q --no-ff -m 'Merge side' side
g tag light
# The formats HistoryModel reads (macos/Sources/UpstreamKit/History.swift).
g log --no-show-signature -z '--format=%H%x1f%P%x1f%aN%x1f%aE%x1f%at%x1f%s' HEAD >"$OUT/log.z"
g log -1 --no-show-signature '--format=%H%x00%P%x00%aN%x00%aE%x00%at%x00%cN%x00%cE%x00%ct%x00%B' HEAD~3 \
  >"$OUT/log-detail.z"
t() { g diff-tree -r -z --name-status -M --root --no-commit-id "$@"; }
t HEAD~3 >"$OUT/diff-tree-root.z"
t HEAD~3 HEAD~2 >"$OUT/diff-tree-rename.z"
t HEAD^1 HEAD >"$OUT/diff-tree-merge.z"
g for-each-ref '--format=%(objectname)%00%(*objectname)%00%(refname)' refs/heads refs/remotes refs/tags \
  >"$OUT/for-each-ref.z"

# The diff view (docs/plans/007_the_diff_view.md), in a repository of its
# own so the scenario above stays as it is: a block of edited lines for the
# word highlights, and a re-indent beside a real edit, with and without -w.
cd "$WORK"
g init -q view && cd view
printf 'let total = price * count\nreturn total\nkeep\n' >words.txt
printf 'if ok {\nrun()\n}\n' >indent.txt
g add . && g commit -qm base
printf 'let total = price * quantity\nreturn total + tax\nkeep\n' >words.txt
printf 'if ok {\n    run()\n    stop()\n}\n' >indent.txt
d HEAD -- words.txt >"$OUT/diff-words.patch"
d HEAD -- indent.txt >"$OUT/diff-whitespace.patch"
d -w HEAD -- indent.txt >"$OUT/diff-whitespace-w.patch"
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') fixtures to fixtures/git/ with $(git --version)"
