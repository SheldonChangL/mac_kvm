# M1-044 Evidence Summary

## Status

M1-044 implementation is complete on branch
`codex/m1-044-mac-key-code-mapper`; all required local gates passed.

## Dependencies

- M1-042: merged by PR #307 and follow-up PR #309; the VirtualKey catalog ADR
  is accepted.
- M1-035: closed with evidence present under `evidence/issues/M1-035/`.

## Deliverables

- `Packages/MacPlatform/Sources/MacPlatform/MacKeyCodeMapper.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/MacKeyCodeMapperTests.swift`
- `docs/components/M1-044-mac-key-code-mapper.md`
- `evidence/issues/M1-044/commands.json`
- `evidence/issues/M1-044/summary.md`
- `evidence/issues/M1-044/tests/results.json`

## Acceptance criteria mapping

| Criterion | Evidence |
|---|---|
| Focus items located | `MacKeyCodeMapper` maps C-005 catalog v1 `VirtualKey` values to macOS US ANSI baseline `CGKeyCode`; docs describe table source and failure policy. |
| Happy path, boundary, invalid input, error/cancel/cleanup tests pass | `MacKeyCodeMapperTests.swift` covers representative mappings, full letter/digit/fixed-member tables, F1-F20, F21-F24 gaps, out-of-domain payloads, unknown raw values, no raw-code rendering, determinism, concurrency and cancellation/no-cleanup applicability. |
| Public behavior matches frozen catalog and adds no implicit API | Mapper and failure enum are `internal` to `MacPlatform`; no `KVMContracts`, wire, Core or package manifest change. |
| Architecture checker, docs/package validation, build and unit tests pass | See `commands.json`; all required commands exited `0`. |
| Production logs contain no typed text, clipboard payload, secret/private key or reconstructable content | Mapper emits no logs or diagnostics; failure reasons are payload-free and tested not to render rejected raw codes. |

## Known limitations

- Catalog v1 does not support punctuation/OEM, keypad, Insert, Fn/Globe, media
  transport, IME/language keys or side-specific modifiers.
- F21-F24 are catalog v1 members, but the macOS SDK exposes no `kVK_F21` to
  `kVK_F24`; they fail as `noMacOSBaseline`.
- The table is a US ANSI positional baseline. Layout and IME behavior belong
  to M1-045.
- Whether `kVK_VolumeUp`, `kVK_VolumeDown` and `kVK_Mute` create the desired
  system volume behavior when posted is injector behavior and is not verified
  by this mapper-only Issue.

## Rollback

Revert the M1-044 PR. No runtime state, permission state, ledger state or
migration cleanup is required because no caller uses the mapper yet and the
mapper stores no state.
