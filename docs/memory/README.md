# Memory

Things an agent learned about this project by getting something wrong. They
are kept in the repo, not on one laptop.

A plan records a decision taken deliberately; a memory records something that
had to be discovered. Both are worth keeping only because the reasoning
outlives the code.

**These files are committed, so every maintainer reads them and they show up
in review.** That decides what belongs here.

## What belongs

- A fact about this project that the code, the docs and `git log` do not
  already record. Examples: a git version that prints something
  differently, a macOS quirk, a measurement that took effort to get.
- Written for the next maintainer, not as a note to yourself.

## What does not

- **Anything the repo already says.** A second copy drifts from the first.
- **Personal working preferences.** Those belong in the person's user-level
  memory. The exception is a preference that has become how this project is
  built: that is a rule, and it goes in [`AGENTS.md`](../../AGENTS.md).
- **Decisions.** A decision with options and alternatives gets a plan in
  [`docs/plans/`](../plans/README.md).

## How it is wired

`autoMemoryDirectory` in `.claude/settings.local.json` points Claude Code
here. The setting needs an absolute path, so it cannot be committed;
`make init` writes it.

`MEMORY.md` is the index, loaded every session. It has one line per memory
and no content of its own.
