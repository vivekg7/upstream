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

cd "$WORK"
g init -q --bare origin.git
g clone -q origin.git repo 2>/dev/null
cd repo

printf 'a\nb\n' >keep.txt
echo x >'old name.txt'
echo d >gone.txt
echo s >staged.txt
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
g mv 'old name.txt' 'new name.txt'              # renamed, path with a space
rm gone.txt                                     # deleted, unstaged
echo s2 >>staged.txt && g add staged.txt && echo s3 >>staged.txt # staged and unstaged
echo new >added.txt && g add added.txt          # added
echo u >'ünïcode file.txt'                      # untracked, non-ASCII
printf '\x00\x09\x08' >image.bin                # binary
printf 'no newline, changed' >tail.txt          # no newline at end of file

mkdir -p "$OUT"
g status --porcelain=v2 --branch -z --untracked-files=all >"$OUT/status-v2.z"
g diff --no-ext-diff HEAD -- keep.txt >"$OUT/diff-modified.patch"
g diff --no-ext-diff HEAD -- image.bin >"$OUT/diff-binary.patch"
g diff --no-ext-diff HEAD -- tail.txt >"$OUT/diff-no-newline.patch"
g diff --no-ext-diff --no-index -- /dev/null 'ünïcode file.txt' >"$OUT/diff-untracked.patch" || true
echo "wrote $(ls "$OUT" | wc -l | tr -d ' ') fixtures to fixtures/git/ with $(git --version)"
