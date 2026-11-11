# 002 — Forges behind one interface, GitHub first

**Status:** `ACCEPTED` — no code yet; built after branches and remotes (001, step 6)
**Started:** 2026-11-11

## Problem

GitHub Desktop is a GitHub app: sign-in, cloning from your account, pull
requests and CI status. The owner wants those in Upstream, **in the app**,
and wants GitLab and Bitbucket to follow GitHub (owner, 2026-11-11). If the
first forge is written straight into the views and the git layer, the second
is a rewrite.

## Options

- **A. A small forge interface, GitHub its first implementation.** Chosen.
  The core defines what the app needs from any forge, in our own terms; each
  forge maps its API onto it. AGENTS.md otherwise says to add a seam only
  when the second consumer arrives; here the second and third are already
  decided, and the shape of a forge API is well enough known to draw the
  line correctly now.
- **B. GitHub only, generalise later.** Rejected. Cheaper for v1, but
  GitHub's vocabulary (pull requests, check runs, `owner/repo`) would leak
  into every view and become the model.
- **C. Drive each forge's CLI (`gh`, `glab`).** Rejected. Not installed for
  most users, a different CLI and output per forge, and nothing equivalent
  for Bitbucket.
- **D. Forge SDKs.** Rejected. A dependency per forge per platform, for a
  handful of HTTP calls we can make with `URLSession` and Rust's standard
  HTTP stack.

## Decision

### The interface

Roughly, per signed-in account:

- `matches(remoteURL) -> RepoRef?` — is this remote on this forge, and which
  repository (`github.com/owner/name`, a GitLab group path, a Bitbucket
  workspace). The git layer never parses forge URLs.
- `signIn()` / `signOut()`, and `credential(for host) -> (user, token)` for
  HTTPS git operations.
- `repositories()` — for the clone list.
- `changeRequests(repo)` — open PRs or MRs: number, title, author, source
  and target branch, draft, the ref to fetch to check it out, and a CI
  summary.
- `checks(repo, commit)` — each CI check: name, state, link.
- `createChangeRequestURL(repo, branch, base)` — the forge's own form.

Called **change requests** in the core, so neither "pull request" nor "merge
request" becomes the model; each forge's UI text uses its own word.

### GitHub (v1)

- **Sign-in:** the OAuth device flow (the app shows a code; the user approves
  it in the browser). No client secret is needed, so the app's OAuth client
  ID can be committed. GitHub Enterprise Server is the same flow on the
  user's host. A pasted personal access token is the fallback where an
  organisation blocks OAuth apps.
- **Token storage:** the Keychain on macOS, the Secret Service (libsecret)
  on Linux. Never in a file or `UserDefaults`.
- **PR list with CI state:** one GraphQL query returns the open PRs and the
  status rollup of each head commit. The REST equivalent is a call per PR.
- **Polling:** only while the window is in front, about once a minute for
  the current repository; nothing in the background except a pending check
  on the current branch, so the finished-checks notification can fire.
- **Checking out a PR:** fetch `refs/pull/<n>/head` into a local branch, so
  PRs from forks work without adding a remote.
- **HTTPS credentials for push:** the app acts as a git credential helper for
  the forge's host only, by running git with a host-scoped helper that calls
  the app's own binary (`upstream credential`), which reads the Keychain.
  Other hosts keep the user's own helpers. SSH remotes are never touched.

### GitLab and Bitbucket (after v1)

Each a new implementation of the same interface, with its own plan for its
sign-in (GitLab supports the device flow; Bitbucket uses OAuth or API
tokens) and its self-hosted variants.

## Plan

1. The interface and a fake implementation the views are built against.
2. GitHub: device-flow sign-in and the Keychain, then the clone list.
3. The credential helper mode, tested with a real push to a scratch
   repository.
4. PR list, check-out, CI state, notification.
5. Create PR (browser).

## Open questions

- **Registering the OAuth app.** Someone has to create the GitHub OAuth App
  (owner's account or an organisation for the project) with the device flow
  enabled. Its client ID goes in the source.
- **Helper precedence.** Verify that a host-scoped `credential.<url>.helper`
  passed with `-c` is consulted before a global `osxkeychain` helper that
  holds an old token for the same host; if not, an empty-string helper entry
  first resets the list for that host.
