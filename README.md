# Upstream

A lightweight, native desktop client for git, GitHub, GitLab and Bitbucket —
what GitHub Desktop does, in a few megabytes instead of a gigabyte. SwiftUI
on macOS, GTK on Linux, the system's own `git` underneath. No Electron, no
bundled git, no telemetry.

**Status:** early. The macOS skeleton opens repositories and shows their
changes and diffs. The plan for everything else is in
[`docs/REQUIREMENTS.md`](docs/REQUIREMENTS.md).

| Platform                      | State       | Folder   |
| ----------------------------- | ----------- | -------- |
| macOS 26+, Apple silicon      | building    | `macos/` |
| Linux (GTK4 and libadwaita)   | planned     | `linux/` |
| Windows, Intel Macs, macOS 15 | not planned | —        |

## Requirements

- **macOS 26 or later on Apple silicon.**
- **git 2.38 or later.** The Command Line Tools provide it
  (`xcode-select --install`), or Homebrew's `git`. Upstream does not ship
  its own: it uses yours, so your config, hooks, SSH keys, credential
  helpers, signing and LFS all work as they do in a terminal.

## Build

Xcode 26 or later (for Swift 6 and `swift-format`).

```sh
make init     # once: git hooks, agent settings
make check    # format check and tests
make mac      # local/upstream-mac-v<version>.zip; scripts/build-mac.sh --install puts it in /Applications
```

The build is signed ad hoc. On another Mac, allow the first launch once
under System Settings → Privacy & Security.

## Layout

```
macos/        the Mac app: a Swift package (UpstreamKit = git and parsing, Upstream = the UI)
linux/        the Linux app, when it starts: a Cargo workspace (core/, app/, data/)
fixtures/     real git output both apps' parsers are tested against
scripts/      build and fixture scripts
docs/         requirements, numbered plans, inspirations, maintainer memory
```

Why it is shaped this way:
[plan 001](docs/plans/001_native_clients_on_system_git.md).

## Licence

MIT. See [`LICENSE`](LICENSE). Not affiliated with GitHub, GitLab or
Atlassian.
