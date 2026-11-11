# Fixtures

Real output of real git, which both apps' parsers are tested against: the
Swift tests in `macos/Tests/` today, the Rust tests in `linux/core/` later.
One set of bytes, so the two parsers cannot drift apart
([plan 001](../docs/plans/001_native_clients_on_system_git.md)).

`scripts/make-fixtures.sh` (`make fixtures`) builds a scratch repository with
every kind of change we parse — modified, staged and unstaged, added,
deleted, renamed with spaces and edited after, untracked with non-ASCII,
binary, no final newline, a merge conflict, ahead and behind its upstream —
and writes what git prints for it, with the diff options the app uses. A
second repository holds a short history: a first commit with a body and a
literal `%x1f`, an annotated and a lightweight tag, a rename and a merge. A
third holds the diff view's cases (word highlights, hidden whitespace). Each
new scenario got a repository of its own, so the first stayed as it was.
Dates and identities are fixed, so object IDs are stable.

**Never edit these by hand.** To cover a new case, add it to the script and
regenerate. `.gitattributes` keeps git from converting their line endings.

| File                         | Command                                                                                                                                              |
| ---------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status-v2.z`                | `git status --porcelain=v2 --branch -z --untracked-files=all`                                                                                        |
| `diff-modified.patch`        | `git diff HEAD -- keep.txt`                                                                                                                          |
| `diff-no-newline.patch`      | `git diff HEAD -- tail.txt`                                                                                                                          |
| `diff-binary.patch`          | `git diff HEAD -- image.bin`                                                                                                                         |
| `diff-untracked.patch`       | `git diff --no-index -- /dev/null 'ünïcode file.txt'`                                                                                                |
| `diff-added.patch`           | `git diff HEAD -- added.txt`                                                                                                                         |
| `diff-renamed.patch`         | `git diff --find-renames HEAD -- 'old name.txt' 'new name.txt'`                                                                                      |
| `diff-staged-head.patch`     | `git diff HEAD -- staged.txt`: what the checkbox commits                                                                                             |
| `diff-staged-cached.patch`   | `git diff --cached -- staged.txt`: the staged half                                                                                                   |
| `diff-staged-worktree.patch` | `git diff -- staged.txt`: the unstaged half                                                                                                          |
| `diff-words.patch`           | `git diff HEAD -- words.txt`: a block of edited lines, for word highlights                                                                           |
| `diff-whitespace.patch`      | `git diff HEAD -- indent.txt`: a re-indent beside a real edit                                                                                        |
| `diff-whitespace-w.patch`    | `git diff -w HEAD -- indent.txt`: the same, whitespace hidden                                                                                        |
| `log.z`                      | `git log -z --format=%H%x1f%P%x1f%aN%x1f%aE%x1f%at%x1f%s HEAD`                                                                                       |
| `log-detail.z`               | `git log -1 --format=%H%x00…%x00%B` of the first commit                                                                                              |
| `diff-tree-root.z`           | `git diff-tree -r -z --name-status -M --root` of the first                                                                                           |
| `diff-tree-rename.z`         | the same, of the rename against its parent                                                                                                           |
| `diff-tree-merge.z`          | the same, of the merge against its first parent                                                                                                      |
| `for-each-ref.z`             | `git for-each-ref --format=%(objectname)%00%(*objectname)%00…`                                                                                       |
| `branches.z`                 | `git for-each-ref --format=… refs/heads refs/remotes` (`Branch.format`), after adding a symref, a branch with a slash and one whose upstream is gone |
| `merge-tree-conflict.z`      | `git merge-tree --write-tree --name-only -z --no-messages main theirs`                                                                               |
| `merge-tree-clean.z`         | the same, `main origin/main`                                                                                                                         |
| `stash-list.z`               | `git stash list -z --format=%H%x1f%ct%x1f%gs`, in a second clone with a terminal stash and an Upstream one                                           |
| `status-v2-stash.z`          | `git status --porcelain=v2 --branch --show-stash -z --untracked-files=all` there                                                                     |
