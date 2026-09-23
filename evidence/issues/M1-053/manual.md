# M1-053 Manual Verification

**Status: reviewer executed; passed.** The Codex root reviewer, who is not the
author, ran the opt-in Tier-H probe on real macOS at implementation commit
`5ca459acea932fd7324450d34224934ac12de22a`. The author, Claude Opus 5.5, ran
nothing and only transcribed the reviewer's report.

> **Scope of this manual evidence.** The probe exercised the real AppKit
> pasteboard path on a **uniquely named private pasteboard only**. It does
> **not** verify general-clipboard behavior, general-clipboard access prompts
> (`.default` / `.ask`), or a real `.alwaysDeny` state set in System Settings.
> No System Settings change was made and no denial was observed on a real
> pasteboard. The denial path is covered by deterministic seam tests and by
> compilation only.

Machine-readable result: `tests/tier-h-probe.json`. Sanitized output:
`manual-output.log`.

## Metadata

| Field | Value |
| --- | --- |
| Date | 2026-09-23 (Asia/Taipei); commands between `2026-09-23T05:53:56.086Z` and `2026-09-23T05:54:35.612Z` UTC wrapper time |
| Build commit | `5ca459acea932fd7324450d34224934ac12de22a` |
| Branch | `feat/m1-053-mac-pasteboard-adapter` |
| OS / build | macOS 26.6.2, build 25G83 |
| CPU architecture | arm64, Apple M4 Pro |
| Toolchain | Xcode SDK macOS 26.2; Swift 6.2.3; swift-format 6.2.3 |
| Display / layout | not collected; not required for pasteboard behavior |
| Keyboard layout | `com.apple.keylayout.ABC` (no keyboard behavior in this Issue) |
| Network / peer | not exercised; not applicable to this local adapter |
| Pasteboard | AppKit uniquely named private pasteboard only; general clipboard not read or modified |
| Reviewer | Codex root reviewer, distinct from the author |

No serial number, hardware UUID, device name, user name, home path, pasteboard
name, clipboard text, bytes or hash is recorded.

## Step — `unique-pasteboard-round-trip`

```sh
env MACKVM_M1_053_MANUAL_PROBE=unique-pasteboard-round-trip \
  swift test --package-path Packages/MacPlatform \
  --filter manualUniquePasteboardProbeRunsTheRealAdapterPath
```

What the probe does, in order, on a pasteboard from
`NSPasteboard.withUniqueName()` with `releaseGlobally()` in `defer`:

1. observe the count, then read the fresh empty pasteboard;
2. write a fixed synthetic marker at exactly its UTF-8 byte limit;
3. read it back and compare the read's count with the write's;
4. attempt the same write one byte under the limit, then compare the count and
   read again;
5. seed one fixed synthetic non-text byte under a private type, then read; and
6. clear directly, then read.

**Expected:** exit 0 and exactly the line below. **Actual (Codex root
reviewer):** exit 0; 1 test passed, 0 failures; reported test duration 0.014 s.

```text
M1-053 manual probe: action=unique-pasteboard-round-trip initialRead=clipboard.unsupportedType markerWrite=written writeCountVsInitial=different readBack=markerMatched readCountVsWrite=equal oversizedWrite=clipboard.oversized countAfterOversizedVsWrite=equal readAfterOversized=markerMatched nonTextRead=clipboard.unsupportedType clearedRead=clipboard.unsupportedType
```

**Verdict:** passed; matches the expected closed result exactly.

## What this proves

- The production `MacPasteboardEnvironment.backed` factory, the same one the
  shipped default uses, reads, clears and writes UTF-8 plain text on a real
  AppKit pasteboard.
- Empty and non-text real pasteboards report `clipboard.unsupportedType`.
- The real change count differs after a write, equals the next read's count,
  and is unchanged by an oversized write, which also leaves content intact.
- The private pasteboard is released on return.

## What this does not prove

- General-pasteboard behavior or its access prompts.
- A real `.alwaysDeny` → `permission.capabilityUnavailable` path.
- App-bundle permission identity.

## Screenshot / video

None. There is no UI, and the closed machine-readable line records the
observable path. Recording the screen could only add risk of capturing private
content.

## Cleanup / fail-safe

`releaseGlobally()` runs in `defer`. The user's clipboard was never read,
written or cleared. No sleep, poll, retry or timer is used.
