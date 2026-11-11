# Plans — index

One file per piece of work larger than a bug fix. Each records the problem, the
options, the decision and **why**, and the alternatives that were rejected.

Read the index (newest first) before starting anything. The project spans
two native apps and several forges, built over months, mostly by agents. This record is
what stops a rejected idea from being proposed again, and what explains why a
part is shaped the way it is.

## Filenames

```
docs/plans/NNN_short_slug.md      e.g. 001_own_backend_in_go.md
```

- **`NNN` is a zero-padded sequence number.** Take the next unused one
  (`ls docs/plans/`). A number is never reused or renumbered, not even for an
  abandoned plan. A gap in the sequence tells you something; a reused number
  breaks every citation of it.
- The slug may be renamed if every reference to it changes in the same commit.
  The number never changes.
- Code comments and docs cite a plan by its full path
  (`docs/plans/001_own_backend_in_go.md`).

## Status vocabulary

| Status        | Means                                                             |
| ------------- | ----------------------------------------------------------------- |
| `PROPOSED`    | Options and trade-offs written up. No decision yet, no code.      |
| `ACCEPTED`    | Decided, but nobody is building it yet.                           |
| `IN PROGRESS` | Being built. Not yet on `main`.                                   |
| `MERGED`      | On `main`, but not yet in anyone's hands.                         |
| `RELEASED`    | Running for real: the app is in a GitHub release.                 |
| `ABANDONED`   | Deliberately dropped. Kept for the reasoning; say why at the top. |

**The vocabulary is closed.** A made-up status (`DONE`, `READY`) forces the
reader to open the plan to learn whether the thing is actually running. If none
of the six words fits, write the nuance after the em dash on the status line.

`MERGED` and `RELEASED` are different facts. Code on `main` does nothing until
a release is cut and installed.

## Writing a plan

A plan is a decision record, not a task list. It should still be worth reading
a year from now, when the code has moved on and only the reasoning still
matters.

```markdown
# NNN — Title

**Status:** `PROPOSED` — one line on where it actually stands
**Started:** YYYY-MM-DD

## Problem

What is missing or broken, and what that costs us.

## Options

Each one with its trade-offs. Include the options we reject; writing them down
is what stops them coming back.

## Decision

What we are doing, and why this option rather than the others.

## Plan

The steps in order, with the parts that can fail called out.

## Open questions

Anything unresolved. Better found here than mid-build.
```

Update a plan's status line the moment it changes, and update this index in
the same commit. A stale index is worse than none, because it is confidently
wrong.

## Index

| Plan                                                                            | Status                                                                      |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| [003 — The checkbox commit](003_the_checkbox_commit.md)                         | `MERGED` — files, lines, amend; co-authors and templates not yet            |
| [002 — Forges behind one interface, GitHub first](002_forges_github_first.md)   | `ACCEPTED` — no code yet                                                    |
| [001 — Native clients on the system's git](001_native_clients_on_system_git.md) | `IN PROGRESS` — macOS: status, diff, the checkbox commit; Linux not started |
