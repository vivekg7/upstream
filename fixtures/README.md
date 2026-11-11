# Fixtures

Real output of real git, which both apps' parsers are tested against: the
Swift tests in `macos/Tests/` today, the Rust tests in `linux/core/` later.
One set of bytes, so the two parsers cannot drift apart
([plan 001](../docs/plans/001_native_clients_on_system_git.md)).

`scripts/make-fixtures.sh` (`make fixtures`) builds a scratch repository with
every kind of change we parse — modified, staged and unstaged, added,
deleted, renamed with spaces, untracked with non-ASCII, binary, no final
newline, a merge conflict, ahead and behind its upstream — and writes what
git prints for it. Dates and identities are fixed, so object IDs are stable.

**Never edit these by hand.** To cover a new case, add it to the script and
regenerate. `.gitattributes` keeps git from converting their line endings.

| File                    | Command                                                       |
| ----------------------- | ------------------------------------------------------------- |
| `status-v2.z`           | `git status --porcelain=v2 --branch -z --untracked-files=all` |
| `diff-modified.patch`   | `git diff HEAD -- keep.txt`                                   |
| `diff-no-newline.patch` | `git diff HEAD -- tail.txt`                                   |
| `diff-binary.patch`     | `git diff HEAD -- image.bin`                                  |
| `diff-untracked.patch`  | `git diff --no-index -- /dev/null 'ünïcode file.txt'`         |
