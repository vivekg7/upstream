---
name: measuring-the-mac-app
description: "Measure memory with `footprint`, not ps RSS; screenshot the window with screencapture -l, since osascript has no assistive access"
metadata:
  node_type: memory
  type: reference
  originSessionId: 41a21d34-7a58-45a4-89b4-1e82f295dae0
  modified: 2026-11-11T07:16:47.250Z
---

How the "Now" numbers in [REQUIREMENTS](../REQUIREMENTS.md#lightweight-and-fast)
were taken (2026-11-11), so later measurements are comparable.

- **Memory is the physical footprint**, `footprint -p $(pgrep -x Upstream)`
  (the `phys_footprint` line). `ps -o rss` reported 120 MB for the same
  process at 51 MB footprint, because RSS counts the shared system
  frameworks every app maps. Measure GitHub Desktop the same way, adding up
  all its helper processes.
- **App size** is `du -sh macos/.build/Upstream.app`, which
  `scripts/build-mac.sh` prints.
- **Screenshots of the window without the Accessibility permission:**
  `osascript` → System Events fails with "not allowed assistive access"
  (-1719). Instead, get the window number from `CGWindowListCopyWindowInfo`
  (the entry whose owner is "Upstream" and layer is 0, in a few lines of
  `swift`) and run `screencapture -o -l<number> shot.png`.
- **The repository list** lives in the app's defaults:
  `defaults write io.github.vivekg7.upstream repositories -array <path>…`
  seeds it for a test run; `defaults delete io.github.vivekg7.upstream`
  clears it. That is the owner's real list, so read it first and put it
  back. To look at a scratch repository without touching it, run the bare
  `macos/.build/debug/Upstream` (after `swift build`): with no bundle, its
  defaults domain is `Upstream`, so seed `defaults write Upstream
repositories -array <path>` and `defaults delete Upstream` afterwards.
- **Without touching any defaults domain**, pass the list on the command
  line: `macos/.build/release/Upstream -repositories '("/path/to/repo")'`
  (the argument domain overrides the stored one and is never written). Use
  this when several people or agents may be running the bare binary at
  once, since they all share the `Upstream` domain.
- **Driving the app without clicking** (selecting a file, scrolling the
  diff) takes a temporary hook in the app; plan
  [007](../plans/007_the_diff_view.md) describes the one used for the diff
  numbers. Keep a direct reference to the view you want to drive. Finding
  it by walking SwiftUI's view tree from inside a `Task` made one run in
  ten crash inside SwiftUI (`swift_task_isMainExecutor`), which looked
  like a bug in the app.
- **A bundle of its own for measuring.** Copy `macos/.build/Upstream.app`,
  set `CFBundleIdentifier` to `io.github.vivekg7.upstream.bench` with
  PlistBuddy, re-sign ad hoc, and launch it with `open -n -a Bench.app
--env … --args -repositories '("/path")' -gitPath /path/gitlog.sh`. It
  runs the real bundle without touching the owner's domain; `defaults
delete io.github.vivekg7.upstream.bench` afterwards.
- **Counting git processes:** point `-gitPath` at a two-line wrapper that
  appends `date +%s.%N` and `$*` to a log, then `exec /usr/bin/git "$@"`.
  Every command the app runs, with its start time, is in the log; that is
  how the launch's duplicate reads were found.
- **Idle CPU:** take the process's CPU time (`ps -o time=`) before and
  after a quiet minute. `top`'s IDLEW column is a running total, not a
  rate, and its date lines start with digits, so parse rows by PID.
- **A locked Mac** (the display asleep, `lsappinfo front` says
  `loginwindow`) never makes the app active and never puts its window on
  screen. Front and behind then have to be simulated by calling
  `setActive` from a temporary hook, and launch time is measured from
  `NSRunningApplication.current.launchDate` to the first status, not to a
  visible window.
- **Network:** git's traffic is in git's processes (`git-remote-https`),
  not the app's. `nettop -P -L 0 -s 1 -n -x -J bytes_in,bytes_out`
  catches them while they live; the app's own URLSession traffic is
  under its PID.
