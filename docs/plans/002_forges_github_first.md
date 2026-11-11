# 002 — Forges behind one interface, GitHub first

**Status:** `IN PROGRESS` — macOS: GitHub sign-in in the browser or by token, clone list, publish, pull requests, CI, notification, credential helper; GitLab, Bitbucket and Linux not started
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

### As built on macOS (2026-11-11)

Code: `UpstreamKit/ForgeAPI.swift` (the interface, the core types, remote
URL parsing, HTTP), `GitHub.swift`, `Credentials.swift` (Keychain, the
helper protocol), `Forge.swift` (`ForgeModel`: accounts, polling,
actions), and `Upstream/ForgeViews.swift`, `Upstream/Main.swift`.

- **The interface** is the `Forge` protocol, one value per signed-in
  account: `repositories()`, `owners()` and `createRepository(…)` for
  publishing, `changeRequests(in:)`, `checks(in:commit:)`, and
  `privacy(of:)` for the sidebar's lock icons
  ([009](009_repositories_and_settings.md#private-repositories)). What needs no
  account sits on `ForgeKind` and `RepoRef`: `repository(for: remoteURL)`
  (the `matches` above), the commit page and the new-change-request form.
  Sign-in is not in the protocol: each forge's sign-in differs (device
  flow, tokens, app passwords), so it is per forge, in the model and the
  settings view. The credential side is `TokenStore` plus
  `CredentialHelper`, which are forge-neutral.
- **Which remote is "the repository":** `origin` if it is on a known forge,
  else the first remote that is. A commit's web link needs no account and
  no network, so it works for any GitHub remote while signed out. An
  Enterprise host is recognised only once an account is on it. A
  branch's checks are read from its own remote (`branch.<name>.remote`),
  which may be a fork. Remotes are read with
  `git config -z --get-regexp '^remote\..*\.url$'`, not `git remote -v`.
- **One account per host**, as GitHub Desktop: one on github.com, one per
  Enterprise server. The credential helper then never has to choose
  between two accounts. Only `host` and `login` go in `UserDefaults`
  (`forgeAccounts`); the token is a generic password in the login keychain,
  service `Upstream: <host>`, account = login. The legacy file-based
  keychain, because the data protection keychain needs an entitlement an ad
  hoc signed app cannot have.
- **Sign-in.** The device flow on github.com only. An OAuth App is
  registered per server, so Enterprise hosts sign in with a token; a
  pasted personal access token works on every host. The token is checked
  with `GET /user`. A classic or OAuth token lists its scopes in
  `X-OAuth-Scopes`, and one without `repo` is refused at sign-in rather than at the first push. Fine-grained tokens send no
  scopes header and are taken on trust. Scopes asked for: `repo` (private
  repositories, HTTPS push, creating repositories), `workflow` (pushing
  `.github/workflows`, which `repo` alone cannot), `read:org` (organisations
  to publish to). Signing out deletes the Keychain item. The token stays
  valid on GitHub until revoked there, and the settings say so.
- **Credential helper.** For a remote (a name, so its `url` and `pushurl`,
  or a URL) whose scheme is `https` and whose host has an account, every
  network git command gets
  `-c credential.https://<host[:port]>.helper= -c credential.https://<host[:port]>.helper=!'<exe>' credential`.
  `<exe>` is the app's own executable, single-quoted for git's shell, and
  `Main.swift` answers `get` from the Keychain without starting the UI.
  `store` and `erase` do nothing: the token is the account's, and a failed
  push must not delete it. Because the reset empties the list for that
  host, git's `store` after a push reaches only us, so the token is never
  copied into `osxkeychain` either. SSH remotes and other hosts are never
  touched. The port has to be in the key: git matches credential URLs
  host _and_ port.
- **Pull requests:** one GraphQL query, the 50 most recently updated open
  ones, each with its head's `statusCheckRollup`. **Checking one out:**
  from the same repository, its real branch, created to track
  `<remote>/<branch>` (fetched with an explicit refspec, so a single-branch
  clone works too), so pushing to it works as for any branch. From a fork,
  `refs/pull/<n>/head` fetched into `pr/<n>`, **never forced**: if the
  author rewrote the branch and the local one has commits of its own, git
  refuses rather than drop them. Every fetch carries the credential
  arguments.
- **Create Pull Request** opens
  `https://<host>/<owner>/<repo>/compare/<base>...<branch>?expand=1`. The
  base is `refs/remotes/<remote>/HEAD` when the last fetch recorded it,
  else GitHub's default (`compare/<branch>`). The branch is the upstream's
  name (`branch.<name>.merge`), as `<fork-owner>:<branch>` when pushed to a
  fork. It needs no account. Branch → Create Pull Request, **⌥⌘R**: ⌘R,
  GitHub Desktop's shortcut, is Refresh here. Disabled with the reason
  until the branch has an upstream.
- **Publish** (Repository → Publish Repository…, or the toolbar while the
  repository has no remote): account, owner (the account or one of its
  organisations), name (the folder's, spaces as dashes), description,
  private by default as in GitHub Desktop. It creates the repository
  through the API, adds it as `origin` (the HTTPS clone URL) and runs
  `git push -u origin HEAD` with the credential arguments. Disabled before
  the first commit.
- **CI of the current branch:** its check runs and its commit statuses
  (GitHub keeps the two apart), for HEAD once it is pushed (an upstream and
  nothing ahead). Failure as soon as one check fails, pending while any
  runs. The popover lists failing ones first, each linked to its page.
- **Notification** when the checks on the current commit go from running
  to all finished. Permission is asked the first time a check is seen
  running, not at launch, so someone who never signs in is never asked.
  macOS shows it only while the app is in the background, which is where
  it is needed. Only from an app bundle: the bare debug executable and the
  test runner crash in `UNUserNotificationCenter`.

### Network budget

Written down because it will be audited, and because each line is a choice.

| When                                                                        | What is sent                                                                                                                                                                             |
| --------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Signed out                                                                  | Nothing. The commit link and the new-PR form are built from the remote URL.                                                                                                              |
| In front, signed in, current branch pushed                                  | Two conditional GETs a minute (check runs, statuses). A 304 does not count against GitHub's rate limit, so a settled commit costs two tiny round trips and no quota.                     |
| A repository is opened, the app comes to the front, or the PR popover opens | One GraphQL query for the open PRs, at most once per 30 s. Never on a timer: GraphQL has no conditional requests, and the list is only looked at in the popover.                         |
| Launch, or signing in to a host                                             | One GraphQL query per signed-in host, a hundred repositories each, for which repositories in the sidebar are private; again only for ones not answered yet, or after a failure.          |
| HEAD, the branch or its upstream moves                                      | The two check GETs at once, then back to the minute.                                                                                                                                     |
| In the background                                                           | Only while a check on the current branch is pending, once a minute, for the notification; stops when it settles. Otherwise nothing, until the app comes back.                            |
| A request fails                                                             | The interval doubles, up to 15 minutes, so an outage or a rate limit is not hammered. A 401 stops polling until the user signs in again. Failures go to a tooltip, not the error banner. |

Every request is to a host the user signed in to. `URLCache` is off (it
would answer 304s itself and hide them), so our own `ETag` copy is the
only cache, at most 64 answers in memory.

## Plan

1. ✅ The interface. No fake implementation: the views are built against
   `ForgeModel`, and the tests stub the network with `URLProtocol` instead.
2. ✅ GitHub: token sign-in and the Keychain, then the clone list. The
   device flow is tested against the stub, and runs against the
   registered OAuth App.
3. ✅ The credential helper mode. The precedence question is settled by a
   test against the installed git. ◻️ A real push to a scratch repository
   on GitHub, by hand, once an account is set up.
4. ✅ PR list, check-out, CI state, notification.
5. ✅ Create PR (browser).

## Open questions

- **The OAuth App: registered (2026-11-11)** under the owner's account, as
  `Upstream`, with the repository as homepage and callback URL (the form
  requires one; the device flow never uses it), **Enable Device Flow**
  ticked, and `docs/logo.png` as its logo. It has no client secret, and must
  not get one. The Client ID is in `GitHub.clientID`. It can move to a
  project organisation later with Transfer ownership. To register another
  (a fork shipping its own build): Settings → Developer settings → OAuth
  Apps → New OAuth App, the same fields, then the new Client ID in
  `GitHub.clientID`.
- **Helper precedence: answered (2026-11-11, git 2.54).** A host-scoped
  `credential.<url>.helper` passed with `-c` is **not** consulted first.
  git collects every matching helper in config order, system, global,
  local and then `-c`, and stops at the first that answers. A global
  `osxkeychain` with an old token therefore wins. The empty-value entry is
  needed, and it does reset the whole list for that host (the generic
  `credential.helper` included) while other hosts keep theirs. Pinned by
  `ourHelperWinsOverAGlobalOneOnlyBecauseOfTheReset` in `ForgeTests`, with
  stub helpers and `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM`.
- **Forks.** PRs are read from `origin`. For a clone of a fork whose PRs
  go to the parent (an `upstream` remote), GitHub Desktop asks how the
  fork is used. Not decided yet.
- **Keychain prompts after rebuilds.** The Keychain trusts the binary that
  saved the item by its signature. An ad hoc signature changes with every
  build, so after an update macOS asks once before handing out the token,
  and for the credential helper that dialog appears in the middle of a
  push. A Developer ID signature fixes it.
- **`url.<base>.insteadOf`.** The credential arguments are chosen from the
  remote's configured URL, not the rewritten one.
