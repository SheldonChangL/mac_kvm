# M1-042 VirtualKey Catalog and Unknown-key Policy

## Status

Proposed. This ADR freezes the C-005 `VirtualKey` catalog version 1 and the
unknown-key policy once the signoffs listed under "Signoff record" are
recorded. Until then, dependent Issues M1-043, M1-044 and M1-046 must not
merge.

## Binding sources

1. `CONTRACT_CATALOG.md` C-005: a platform-neutral physical, function,
   navigation, media and modifier key catalog that includes `.unknown(rawCode)`.
2. `FROZEN_DECISIONS.md` decisions 3, 4, 7 and 8: `KVMEvent` is the only Core
   event language, Barrier tokens stay out of Core, fail-safe outranks feature
   completeness, and logs never contain reconstructable typed content.
3. `ARCHITECTURE_GUARDRAILS.md`: `CGKeyCode`, Windows VK and Linux evdev/X11
   codes never enter `KVMEvent` or Native wire schema; Barrier message codes
   live only in `BarrierCompatibility`.
4. [`M1-002-architecture-boundary.md`](M1-002-architecture-boundary.md):
   unknown values become an explicit platform-neutral representation at their
   owning adapter boundary; one universal platform key-code field is rejected.
5. [`M1-013-kvmevent.md`](../components/M1-013-kvmevent.md): the merged
   `VirtualKey` enum shape in
   `Packages/KVMContracts/Sources/KVMContracts/KVMEvent.swift`, which defers
   the exact catalog and mapping rules to C-005.
6. [`M1-011-logging-policy.md`](M1-011-logging-policy.md): diagnostics carry
   allowlisted metadata only.

M1-040 is a dependency only as evidence that a Barrier keyboard capture exists.
Its fixture makes no key-code, message-code, endianness or field-semantics
claim, and this ADR derives nothing from its bytes.

## Context

M1-013 merged a `VirtualKey` enum with a fixed set of cases and an
`unknown(UInt32)` escape value, but left payload domains, catalog identity and
unknown handling undefined. Barrier decoding (M1-041/M1-043), macOS key mapping
(M1-044), modifier tracking (M1-046) and later Native Protocol encoding all need
one shared meaning for each case. Without it, each adapter would invent its
own interpretation of `letter(UInt8)` or `unknown(UInt32)`, and an opaque raw
code could reach `CGEvent` and inject an unintended key.

This Issue changes no Swift source. The catalog below is defined against the
enum exactly as merged; any case addition or removal is a separate contract
change.

## Decision

### Catalog identity

- Name: `C-005 VirtualKey catalog v1`.
- Source shape: the `VirtualKey` cases in
  `Packages/KVMContracts/Sources/KVMContracts/KVMEvent.swift` at repository
  commit `a25e591b1e86359909e3837b0cf7eb0b4efb6965` (file SHA-256
  `efa25c68aa5da8596278de742e608c55a86dc7a7cd5d26f44596a24117447c4c`),
  unchanged since M1-013.
- Semantics: the payload domains and meanings in this ADR.

A `VirtualKey` value identifies a physical key position or a dedicated
function/media key. It never identifies a produced character, text, IME
composition or keyboard layout; M1-045 owns physical-versus-text semantics and
non-US layout scope.

### Catalog v1 members

| Group | Case | Domain and meaning |
|---|---|---|
| Letters | `letter(UInt8)` | `0...25`. Index `n` is the key at the US ANSI reference position labelled with the `n`-th Latin letter (`0` = A, `25` = Z). Positional, not textual. |
| Digits | `digit(UInt8)` | `0...9`. The main-row digit key labelled `n` on the US ANSI reference layout. Keypad digits are not members. |
| Function | `function(UInt8)` | `1...24`. Function key F`n`. `0` and values above `24` are invalid. |
| Navigation | `left`, `right`, `up`, `down`, `home`, `end`, `pageUp`, `pageDown` | Dedicated arrow and page navigation keys. |
| Editing and whitespace | `enter`, `escape`, `tab`, `space`, `backspace`, `delete` | `backspace` deletes backwards; `delete` is forward delete. Keypad Enter is not a member. |
| Modifiers | `shift`, `control`, `option`, `command`, `capsLock` | Side-agnostic. Left and right variants of a modifier map to the same case. `option` covers Alt/Option; `command` covers Command/Super/Windows. |
| Media | `volumeUp`, `volumeDown`, `mute` | Dedicated system volume keys. |
| Unknown | `unknown(UInt32)` | Any source key that has no v1 member, or a v1-shaped payload outside its domain. See the unknown-key policy. |

Every member above is a C-005 v1 catalog member. A value of `letter`, `digit`
or `function` whose payload is outside the listed domain is invalid: it is
not a catalog member and must be treated like `unknown` at every boundary.

Keys that are not v1 members, including punctuation/OEM keys, keypad keys,
Insert, Fn/Globe, side-specific modifiers, media transport (play/pause, next,
previous), brightness and IME/language keys, are represented as
`unknown(rawCode)` in v1.

### Adapter rules (inbound to KVMEvent)

- A protocol or platform adapter maps a source key to a v1 member only from an
  evidence-backed, table-driven mapping owned by that adapter's Issue. No
  adapter may guess a mapping.
- A source key without a v1 mapping becomes `unknown(rawCode)`, where
  `rawCode` is the unmodified source key identifier zero-extended to `UInt32`.
  It is neither discarded silently nor coerced into the nearest member.
- A source identifier wider than 32 bits, or otherwise not representable, is
  rejected by the adapter as a typed decode error before it enters Core.
- Adapters never emit a `letter`, `digit` or `function` payload outside its
  v1 domain.
- Barrier key identifiers and their tables exist only in
  `BarrierCompatibility`; macOS `CGKeyCode` tables exist only in
  `MacPlatform`. Neither enters `KVMContracts`, `KVMCore` or a Native wire
  schema.

### Unknown-key policy

1. `unknown(rawCode)` preserves the original source code for routing,
   counting and future catalog work. In v1 it carries no source namespace,
   so the raw value is opaque: no consumer may interpret it as a code in its
   own key space.
2. KVM Core may route an `unknown` key event like any other key event, but it
   must not translate, normalize or synthesize a member from it.
3. A platform mapper must handle `unknown` explicitly. In catalog v1 the only
   permitted handling is an explicit, typed "unsupported key" rejection. The
   raw value is never passed to `CGEvent`, `SendInput`, uinput or any other
   platform input API, and is never reused as a platform key code.
4. An invalid payload (out-of-domain `letter`, `digit` or `function`) is
   rejected by platform mappers with the same typed unsupported result.
5. A rejected key is not recorded as pressed in any injected-key or
   modifier ledger, so release-all and terminal cleanup never need to inject a
   release for it.
6. Platform mappers switch exhaustively over `VirtualKey` without a `default`
   branch, so a later catalog member fails compilation until it is handled or
   explicitly rejected.
7. Diagnostics may record only an allowlisted event id and counts for
   unknown or rejected keys. Raw codes, key sequences and timing that could
   reconstruct typed content are never logged, per Frozen Decision 8 and
   M1-011.
8. Allowing a platform mapper to inject any `unknown` value requires a
   superseding catalog version that adds a source namespace. It cannot be
   introduced by a mapper Issue alone.

### Catalog versioning

- The catalog version is an integer. This ADR defines version `1`.
- Additive change (new member, wider payload domain): increment the version
  through a contract-change Issue that updates `KVMContracts`, this catalog
  record and every exhaustive mapper in the same change set.
- Breaking change (removed member, changed meaning or narrowed domain):
  requires a superseding ADR with Product Owner approval and a migration plan
  for persisted or wire representations.
- A raw code that was `unknown` in version `n` may become a named member in
  version `n + 1`. A member never reverts to `unknown` without a breaking
  change.
- Mapper component documents and tests (M1-043, M1-044 and later platforms)
  state the catalog version they cover.
- The synthesized Swift `Codable` form of `VirtualKey` is not a wire format.
  Any persisted or Native Protocol representation of `VirtualKey` must carry
  the catalog version; its encoding is owned by M3-004.

## Selected versus rejected alternatives

### Selected: positional catalog v1 bound to the merged M1-013 enum

Selected because it satisfies C-005 without changing `KVMContracts`, keeps
platform and protocol codes out of the domain model, and gives every mapper
one closed meaning per case.

### Selected: reject-only unknown handling in v1

Selected because `unknown(UInt32)` has no source namespace. Any injection of
an opaque raw code would be a guess about another key space and could press
an unintended key. Rejection is fail-safe.

### Rejected: text or character semantics for `letter` and `digit`

Rejected because layout and IME behavior belong to M1-045, and textual
meaning would make the same physical key mean different things per layout.

### Rejected: ASCII payloads for `letter` (for example `0x41...0x5A`)

Rejected because ASCII invites textual interpretation and case confusion.
A `0...25` index is positional and has a single valid range.

### Rejected: embedding platform or Barrier key codes in `VirtualKey`

Rejected by `ARCHITECTURE_GUARDRAILS.md` and M1-002. It would couple Core and
the Native wire schema to one platform's key space.

### Rejected: passing `unknown` raw codes through to platform APIs

Rejected because the raw value's key space is not recorded, so injection
could produce an arbitrary key on the target host.

### Rejected: dropping unknown keys silently at the adapter

Rejected by M1-002. Silent drops hide compatibility gaps and remove the data
needed to extend the catalog.

### Rejected: side-specific modifier cases in v1

Rejected for v1 because the merged enum and C-006 `ModifierState` are
side-agnostic. Adding side-specific members is an additive catalog change.

### Rejected: adding punctuation, keypad and media transport keys now

Rejected in this Issue because it requires a `KVMContracts` change outside the
Exact Files. It is tracked as an open question below.

## Consequences

### Positive

- Every mapper shares one closed, testable meaning per case.
- Opaque raw codes cannot reach a platform input API.
- Exhaustive switching turns catalog growth into a compile-time obligation.
- Catalog gaps remain visible as counted `unknown` events.

### Costs and limitations

- In v1, punctuation/OEM, keypad, Insert, Fn/Globe, media transport and IME
  keys cannot be forwarded; they are rejected at the platform mapper. M1 must
  not claim full typing support until the catalog is extended.
- Left/right modifier distinction is lost. When both sides of the same
  modifier are held, the first release on either side may release the
  injected modifier early. This favors release over stuck input; M1-046 and
  M1-049 must keep that direction and never leave a modifier held after its
  last source release.
- Payload domains are not yet enforced by `KVMContracts` decoding; mappers
  must enforce them until a contract change adds validation.

## Security impact

- Unknown and out-of-domain values are rejected before any platform input
  API, preventing injection of unintended keys from untrusted network input.
- Rejected keys never enter pressed-key ledgers, so they cannot create stuck
  input or require cleanup injection.
- Raw key codes are excluded from diagnostics, preserving Frozen Decision 8.
- No TLS, trust, permission or wire-format behavior changes.

## Compatibility impact

- No source, API, test or wire change. The merged `VirtualKey` enum and its
  Codable behavior are unchanged.
- Barrier interoperability for keys outside v1 is intentionally incomplete;
  those keys are counted and rejected, not mis-injected.
- Windows, Linux and Native Protocol mappers must adopt the same catalog
  version and rejection rules.

## Open questions

| Question | Owner | Blocking condition |
|---|---|---|
| Add punctuation/OEM, keypad, Insert, Fn/Globe, media transport and side-specific modifier members (catalog v2) | Contracts owner with Product Owner approval, through a new contract-change Issue | Blocks any M1 or M2 claim of punctuation, keypad or media-transport forwarding. Does not block M1-043, M1-044 or M1-046 for v1 members. |
| Add catalog-version constant and payload-domain validation to `KVMContracts` | Contracts owner, through a new contract-change Issue | Must be resolved before the first persisted or Native wire representation of `VirtualKey` (M3-004). Until then M1-043 and M1-044 tests enforce domains. |
| Decide whether a Native keyboard wire representation may carry `unknown(rawCode)`, must reject it, or must first add a source namespace | M3-004/M3-017 owners with Security Reviewer | Must be resolved before the first Native keyboard encoder represents `VirtualKey.unknown`. This does not block M1's Barrier-to-macOS v1 mapper, where `unknown` stays reject-only at the platform boundary. |
| Source namespace for `unknown`, enabling explicit platform handling | Contracts owner and Security Reviewer, through a superseding catalog ADR | Blocks any mapper that would inject an `unknown` value. Reject-only handling stays in force until resolved. |
| M1-043 Exact Files place `BarrierVirtualKeyMapper` in `KVMCore`, while M1-002 and Frozen Decision 4 keep Barrier key tables in `BarrierCompatibility` | M1-043 implementer with Architecture Reviewer | Must be resolved by Product Owner decision before M1-043 starts. This ADR does not authorize Barrier key identifiers in `KVMCore`. |

No other open question remains.

## Rollback

This Issue changes documentation only. Revert the M1-042 PR and keep M1-043,
M1-044 and M1-046 blocked until a replacement C-005 catalog decision is
signed off. If a later mapper violates this ADR (injects an `unknown` or
out-of-domain value, or records a rejected key as pressed), disable that
mapper's injection path, run release-all cleanup, and restore the previous
reviewed mapping table before re-enabling. Rollback must not weaken TLS,
decoder bounds, privacy-safe logging or fail-safe cleanup.

## Signoff record

| Role | Required for | Status |
|---|---|---|
| Product Owner | Catalog v1 scope and the v1 forwarding limitation | Approved by Product Owner Sheldon Chang on 2026-10-13. |
| Security Reviewer | Unknown-key reject-only policy and diagnostic exclusions | Approved by Claude Code Opus reviewer on 2026-10-13; no Critical or High findings after the Native-wire unknown handling follow-up was added above. |
| Human / independent reviewer (tier B) | Full review of this ADR against C-005 and M1-002 | Approved by Claude Code Opus reviewer on 2026-10-13; no Critical or High findings after the Native-wire unknown handling follow-up was added above. |

This ADR is accepted for M1-042 because all three required rows record an
approval with reviewer identity and date.
