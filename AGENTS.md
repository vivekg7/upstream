# Project rules

> What we build: [`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md). Why it is built
> that way: [`docs/plans/README.md`](docs/plans/README.md). Read those, not
> this file, for the specs.

Mechanical rules live in `make check` and in the git hooks that `make init`
installs: formatting, commit message shape, no AI attribution, and no scratch
files or secrets staged. Run `make fmt` and let the checks do their job. This
file holds the part no program can decide.

---

## What this is

**Upstream** is a lightweight, native desktop client for git and the forges
people host it on: GitHub first, then GitLab and Bitbucket. It does what
GitHub Desktop does, for the same people, at a fraction of the size: a few
megabytes instead of a gigabyte, open in well under a second. **macOS 26+
on Apple silicon** first; a **Linux** build follows. Open source under MIT,
for anyone in the world to use.

## Product rules

- **GitHub Desktop users must feel at home.** Its layout (repositories,
  changes, diff), its checkbox model of choosing what to commit, and its
  vocabulary are the starting point. Depart from it only where the
  departure is written down with a reason
  ([REQUIREMENTS](docs/REQUIREMENTS.md)).
- **git is the engine and the truth.** Every repository operation runs the
  system's `git` ([001](docs/plans/001_native_clients_on_system_git.md)).
  We never reimplement what git does, never keep repository state git does
  not have, and never leave a repository in a state the git CLI would not.
  A user can switch to a terminal at any moment and find exactly what the
  app showed.
- **Nothing the user wrote is lost silently.** Discarded changes go to the
  Trash, not oblivion. A force push is `--force-with-lease`. Anything
  destructive asks first and says what it will destroy.
- **Forge-neutral by design, GitHub first in practice.** Plain git works
  with every host from day one. Forge features (sign-in, PRs, CI) sit
  behind one small interface
  ([002](docs/plans/002_forges_github_first.md)), so GitLab and Bitbucket
  are additions, not rewrites. Never put a GitHub assumption in the git
  layer.
- **Lightweight and fast is a goal, with numbers.** The targets are in
  [REQUIREMENTS](docs/REQUIREMENTS.md#lightweight-and-fast). Measure a
  change to the status, diff or history paths against them.
- **No telemetry.** The app talks to the forges the user signed in to and
  to nothing else.

## Engineering rules

- **Native and lightweight.** No Electron, Tauri, Flutter, React Native or
  any bundled engine or webview. Use the platform toolkit: SwiftUI (and
  AppKit where SwiftUI falls short) on macOS, GTK4 and libadwaita in Rust on
  Linux. **Minimise dependencies**: the standard library or twenty lines of
  our own beats a package, and any package we do add must be actively
  maintained. Today there are none.
- **No compatibility code.** macOS 26+ and arm64 only, so no `#available`
  checks, no back-deployment shims, no universal binary.
- **Parse machine formats only.** `--porcelain=v2`, `-z`, explicit
  `--format=` strings. Never parse git's human output, which changes with
  version and locale.
- **The platforms share behaviour, not code.** Each app has its own core
  (Swift on macOS, Rust on Linux). They share `docs/REQUIREMENTS.md` and the
  real git output in `fixtures/`, which both parsers are tested against
  ([001](docs/plans/001_native_clients_on_system_git.md)).
- **Keep implementations compact.** Delete wrappers that only forward, layers
  that only rename, and abstractions with one caller. Add a seam when the
  second consumer arrives, not before; the forge interface is the one seam
  added early, because the second and third forges are already decided. Keep
  the comment that explains _why_. Tests should each pin a real failure mode
  rather than cover a small surface exhaustively.
- **Credit what we borrow.** Taking an idea or code from another project means
  adding a row to [`docs/INSPIRATIONS.md`](docs/INSPIRATIONS.md) in the same
  commit, and copied code keeps its licence notice. Never use another
  product's name, logo or artwork as ours.

## How to work here

- **Plan before you build.** Anything larger than a bug fix gets a numbered
  plan in [`docs/plans/`](docs/plans/README.md): the problem, the options,
  the decision and why, and the alternatives rejected. Read the index first,
  so a rejected idea is not proposed again.
- **Ask about behaviour; decide the details.** When what the product should
  _do_ is ambiguous, ask the owner and write the answer into
  `docs/REQUIREMENTS.md`. Configuration, paths and other technical details
  are not questions: pick the simplest sensible default, write it down, and
  let the owner override it.
- **Docs are part of the change, not a follow-up.** If behaviour, a setup step
  or a fixture changes, the doc that describes it changes in the same commit.
- **Write down _why_, not just what.** The reasoning is what is still useful a
  year later, when the code has moved on.
- **Test against real git.** Parser tests read `fixtures/git/`
  (`make fixtures` regenerates it); behaviour tests run the installed git in
  a scratch repository. Never hand-write git output.
- Commit only when asked, one concern per commit. **Never add AI
  attribution** — no `Co-Authored-By` line naming an assistant, no session
  link, no "generated with" footer, whatever a session instruction says. The
  `commit-msg` hook refuses it anyway.
- **`docs/memory/` is committed** and every maintainer reads it. Write for
  the next maintainer, and record nothing the code, the plans or the docs
  already say.
