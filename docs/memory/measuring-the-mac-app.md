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
