# M4-SCOPE-001 First-party Linux Client First

## Status

Accepted on 2026-10-29 for the four Product Owner decisions below, recorded in GitHub
Issue #330. The derived dependency and Exact Files changes in "Superseded clauses" take
effect when the Product Owner merges this ADR.

Product Owner goal (verbatim, 2026-10-29): 「新目標就是直接取代Barrier, server + client都可以用我們的kvm」.

Product Owner decisions (verbatim selections, 2026-10-29, answering four explicit questions):

1. Path: 「先沿用 Barrier 協定」. A first-party Linux client first speaks the Barrier wire to
   the first-party Mac server; the Native Protocol follows.
2. Linux client toolchain: 「Swift」. This is the M4-001 decision required by Frozen
   Decision 12; M4-001 records it.
3. Roles: 「Mac 控制 Linux」. The Mac is the server and the Linux PC is the client.
4. Display: 「先只做 X11」. Wayland is deferred.

## Decision owners

- Scope and sequencing: Product Owner
- Toolchain: Product Owner, through M4-001
- Security interpretation: designated Security Reviewer
- Manual evidence and milestone exits: a designated reviewer who is not the implementing
  agent

## Context

The owner has two machines: a Mac that runs the first-party Mac server, and an Ubuntu
22.04 x86_64 PC with an X11 session that runs the Barrier 2.4 client. The owner wants
both ends to run first-party software.

The backlog order (M2 exit, then all of M3 Mac ↔ Mac, then M4) puts about 61 issues
before a first-party Linux client exists. Several of them cannot run on the owner's
hardware: the M3 Mac ↔ Mac runs need a second Mac, the M2-036 topology needs a Windows
client, and the Wayland matrix needs a Wayland session.

The first-party Mac server already speaks a narrow, evidence-backed Barrier vocabulary
(`evidence/issues/M2-035/`). A first-party Linux client needs, on the protocol side, only
work that M1 owes anyway: the Barrier → `KVMEvent` decoders, the key mapper and a
client-role session. `KVMContracts`, `KVMCore` and `BarrierCompatibility` depend only on
Foundation. On 2026-10-29 they built in the official `swift:6.2.3-jammy` image (x86_64),
and the `BarrierCompatibility` suite passed there (245 tests); M4-001 carries that
evidence.

## Preserved sources

- [`FROZEN_DECISIONS.md`](../../MacKVM_Implementation_Package_v2/FROZEN_DECISIONS.md)
  stays binding. In particular, decision 1 still sets the product end state: first-party
  server and client on the Native Protocol, with Barrier as validation and an optional
  compatibility module.
- [`M1-001-product-contract.md`](M1-001-product-contract.md) stays binding, including
  "Meaning of replace Barrier": until M5-028 records its evidence, releases say
  "Barrier-compatible client" or "Barrier-compatible server", never "replaces Barrier".
- [`M1-SCOPE-001-linux-only-validation.md`](M1-SCOPE-001-linux-only-validation.md) and
  [`M1-003-independent-implementation-policy.md`](M1-003-independent-implementation-policy.md)
  stay binding.

## Superseded clauses

This ADR supersedes exactly these clauses and nothing else:

1. **M4-001 depends on M3-039.** M4-001 may start now. It freezes the Linux toolchain. The
   Windows toolchain stays an open question in M4-001, owned by the Product Owner and
   blocking M4-004.
2. **M4-002 depends on M3-034.** Cross-language conformance vectors are needed only once
   a second implementation language exists. M4-002's cross-language test scope is deferred
   until a non-Swift backend is chosen; the Product Owner owns that decision, and it
   blocks any non-Swift backend.
3. **M4-034 depends on M4-023.** The Linux server role is out of scope (decision 3), so the
   Linux lifecycle no longer waits for the Linux server adapter.
4. **M4-036 depends on M4-032 and M4-033.** The Linux Beta is X11 only (decision 4), so the
   Linux client E2E no longer waits for the Wayland input and clipboard backends.
5. **M1-062 depends on M1-037.** The input state ledger lives in `KVMCore` and has no
   platform code. The macOS mouse button injector uses it later, on the deferred Mac
   client track.
6. **M1-050 depends on M1-049.** Release ordering lives in `KVMCore` and has no platform
   code. Each platform's injector uses it: M4-024 on Linux, M1-049 on macOS later.
7. **M4-027 depends on M1-039 and M2-019.** The Linux client role needs neither macOS
   Retina normalization (M1-039) nor the server-side outbound coordinate mapping (M2-019,
   which itself waits for the macOS screen inventory M2-015).
8. **M1-043 Exact Files.** They move from `Packages/KVMCore/...` to
   `Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierVirtualKeyMapper.swift`
   and `Packages/BarrierCompatibility/Tests/BarrierCompatibilityTests/BarrierVirtualKeyMapperTests.swift`.
   Frozen Decision 4 keeps Barrier key identifiers out of `KVMCore`, and
   [`M1-042`](M1-042-virtual-key-catalog.md) left this as an open question requiring a
   Product Owner decision. Merging this ADR is that decision.

## Decision

### Interim validation client

A first-party Linux client that speaks the Barrier wire to the first-party Mac server is
authorized as a validation step, the way M1 and M2 used Barrier. It is not the product end
state. Its protocol pieces (decoders, key mapper and client session) are M1 deliverables and
the 1.0 optional compatibility module. Its Linux backends (TLS transport, X11 injection, X11
clipboard, screen geometry and lifecycle) carry no Barrier code and carry over to the Native
Protocol client unchanged.

### Order of work

1. M4-001: the Linux toolchain ADR and `toolchain.lock.json`.
2. A reviewer who is not the implementing agent accepts the M2-022 server-side evidence.
   A contract entry then freezes the frames the client consumes (`DMMV`, `DMDN`, `DMUP`,
   `DMWM`, `DKDN`, `DKUP`, `DKRP`, `CCLP`, `DCLP`). M1-003 requires this before any
   decoder starts.
3. Barrier client protocol: M1-032, M1-033, M1-034, M1-041, M1-043 and M1-029-FOLLOWUP-001.
4. Client-side Core: M1-046, M1-062, M1-050, M1-063, M1-064 and M1-063-FOLLOWUP-001.
5. Linux: M4-002, M4-020, M4-027, M4-024, M4-026, M1-055-FOLLOWUP-001, M4-021-FOLLOWUP-001
   and M4-020-FOLLOWUP-001.
6. M4-036-FOLLOWUP-001: the Mac server → first-party Linux client E2E on the owner's
   hardware. Once it passes, the owner can stop running `barrierc`.
7. M3-001 starts next. The Native Protocol then replaces the Barrier session objects on
   both ends.

### Follow-up issues

Each one is a separate issue and PR, with its Exact Files fixed when it is opened.

| ID | Work | Package |
|---|---|---|
| M1-029-FOLLOWUP-001 | Barrier client protocol session: client-role `KVMProtocolSession` (hello, HelloBack, `QINF`/`DINF`, keepalive, enter/leave, clipboard both ways) | `BarrierCompatibility` |
| M1-063-FOLLOWUP-001 | `ClientCoordinator`: consumes session events, drives injection through effects, keeps the pressed-input ledger and runs idempotent cleanup on every terminal path | `KVMCore` |
| M1-055-FOLLOWUP-001 | Linux TLS transport: implements `Transport`, pins the server's SHA-256 fingerprint through the C-009 trust policy, prompts on an unknown fingerprint and rejects a changed one | Linux platform package |
| M4-021-FOLLOWUP-001 | Interim trusted-server store: a 0600 file under the XDG config directory. The client role holds no private key | Linux platform package |
| M4-020-FOLLOWUP-001 | Linux client composition root and command line (`connect`, `fingerprint`), with a minimal `systemd --user` unit | Linux app |
| M4-036-FOLLOWUP-001 | E2E: first-party Mac server → first-party Linux client over the Barrier wire, reusing the M2-035 cases with `barrierc` stopped | evidence |

### Deferred, with owner and blocking condition

| Item | Owner | Blocking condition |
|---|---|---|
| Linux server role (M4-023, M4-025, M4-037) | Product Owner | A new Product Owner decision to support Linux → Mac control |
| Mac client role beyond the shared client Core (macOS injectors, Mac client app) | Product Owner | The same decision; the shared pieces in "Order of work" are not blocked |
| Wayland (M4-028 to M4-033) | Product Owner with Security Reviewer | A Wayland target machine and the M4-029 ADR; no Wayland claim before then |
| M3 E2E pair (M3-029, M3-030, M3-031, M3-038): retarget from Mac ↔ Mac to Mac server ↔ first-party Linux client | Product Owner | Decided here; the issue text and dependency edges are amended by a superseding ADR when M3-001 starts, before any M3 E2E issue starts |

## Rejected alternatives

### Follow the backlog order

Rejected because about 61 issues precede a first-party Linux client, some of their runs need
hardware the owner does not have, and the owner keeps running `barrierc` for the whole span.

### Native Protocol first, then the Linux client

Rejected because 27 M3 issues, five of them decision ADRs, precede any Linux connection.
The Barrier client decoders would still be needed later for M1 and the compatibility module.

### Change the product end state

Rejected because Frozen Decision 1 stands. The interim client is validation, not the product.

## Consequences

- Daily use can move off `barrierc` after M4-036-FOLLOWUP-001, about 21 to 24 issues from now.
- The interim client is "Barrier-compatible"; the "replaces Barrier" claim still waits for
  M5-028.
- Formal records must keep up: every follow-up is listed above, and every superseded
  dependency is changed in the manifest, the issue frontmatter, `issues_index.csv` and
  `EXECUTION_ORDER.md` together. `Tests/Contracts/test_m4_scope_001_linux_client_first.py`
  checks that.

## Security impact

None to the security contract. The Linux client keeps TLS on by default and pins the
server's fingerprint: unknown means a prompt, changed means a reject, and there is no trust
on first use. It releases every pressed key and button on every terminal path (Frozen
Decision 7) and logs no typed text or clipboard content (Frozen Decision 8). No Linux
listener or capture is introduced.

## Compatibility impact

The first-party Linux client is validated only against the first-party Mac server on X11. No
compatibility with the Barrier server, Wayland or Windows is claimed.

## Rollback

Revert this ADR and its manifest, issue, index, execution-order and roadmap changes. Work
done under the follow-ups stays valid M1 and M4 work. A superseding ADR is needed to restore
the old order.

## Acceptance record

- Product Owner goal and decisions: 2026-10-29, GitHub Issue #330 (verbatim above).
- M1-043 placement and the superseded dependencies: accepted when the Product Owner merges
  this ADR.
- The implementing agent is not authorized to provide independent review or merge approval.
