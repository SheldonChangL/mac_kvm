# M1-011 Privacy-safe Logging and Error Taxonomy

## Status

Proposed for acceptance through GitHub Issue #5. This ADR refines frozen contract C-010 and Frozen Decision 8; it does not replace or weaken either source. It becomes accepted only after the required repository gates and PR review pass.

## Decision owners and review

- Product contract and privacy boundary: Product Owner
- Security interpretation and allowlist review: designated Security Reviewer
- Diagnostic operability and evidence: diagnostics owner and PR reviewer

The Product Owner standing authorization permits this M1 Issue to proceed through protected PR review and merge without a separate per-step approval. The PR must record a privacy/security review with Critical and High findings resolved before merge.

## Binding sources

1. `CONTRACT_CATALOG.md` C-010: a `DiagnosticEvent` contains only allowlisted event id, category, correlation, and metadata; arbitrary string payloads are prohibited.
2. `FROZEN_DECISIONS.md` Decision 8: logs do not contain typed text, clipboard payload, passwords, private keys, or reconstructable content.
3. `ARCHITECTURE_GUARDRAILS.md`: logs and diagnostics use allowlisted metadata only.
4. M1-002 architecture boundary: protocol, Core, and platform modules remain separate; diagnostics do not become a dependency escape hatch.
5. `DEFINITION_OF_DONE.md`: diagnostic output must exclude user content and secret/key material.

If a later implementation cannot satisfy all five inputs, it must stop and seek a superseding Product Owner decision rather than broaden the log payload.

## Context and threat model

MacKVM needs enough telemetry to diagnose connection, protocol, permission, input-safety, clipboard, and lifecycle failures. KVM software also handles unusually sensitive data: physical keystrokes, clipboard contents, peer identity material, host and network identifiers, and timing that may reveal user behavior.

Logs can outlive the process, enter a support bundle, be indexed by the operating system, or be shared outside the original trust boundary. Development builds, error paths, and third-party error descriptions are not safer channels. The logging contract therefore treats every value as prohibited until its field and representation are explicitly allowlisted.

## Selected decision

### Diagnostic event envelope

A diagnostic record is a structured envelope with exactly four conceptual fields:

| Field | Rule |
|---|---|
| category | One value from the fixed category allowlist below |
| event id | Stable, reviewed identifier from a source-controlled event catalog; never caller-supplied text |
| correlation id | Opaque, random, process-local operation identifier with the lifecycle rules below |
| metadata | Zero or more typed entries whose keys and representations are individually allowlisted |

An event has no free-form message, interpolation array, arbitrary dictionary, dump, payload, or generic `Error` description field. Human-readable presentation is derived locally from the event id and typed metadata catalog; it is not stored as user-provided text.

### Category allowlist

The initial categories are:

- `lifecycle`: application and subsystem start, stop, sleep, wake, cancellation, and cleanup outcomes
- `connectivity`: connection state and bounded retry/timeout outcomes, without address or peer-name data
- `protocol`: handshake/codec state and typed validation outcomes, without raw frames, message bytes, or vendor payloads
- `security`: trust-policy decisions and credential-store outcomes, without certificate bytes, fingerprints, keys, tokens, or account identifiers
- `inputSafety`: permission, injection, state-ledger, and cleanup outcomes, without key codes, characters, button sequences, coordinates, or timing sequences that reconstruct activity
- `clipboard`: type/size-limit/encoding and routing outcomes, without clipboard bytes, text, hashes, previews, transaction content, or source application names
- `system`: supported platform capability and resource outcomes, without paths, usernames, device names, serials, or persistent hardware identifiers
- `diagnostics`: diagnostic collection and redaction outcomes, without collected content

Adding or broadening a category requires a reviewed change to this ADR or a superseding ADR. A category name alone does not authorize any metadata.

### Event id rules

- Event ids are stable identifiers selected from a source-controlled allowlist owned by the component that emits them.
- Each id maps to one category, one severity, an optional typed error code, and a fixed metadata schema.
- An unknown event id is rejected by the diagnostic boundary; it is not emitted under a generic fallback.
- Event ids describe state transitions or outcomes, not user content. They must not embed hostnames, paths, peer ids, protocol bytes, key names, clipboard types supplied by a peer, or exception text.
- Renaming or deleting an id requires compatibility review for tests, support tooling, and diagnostic bundles. Reusing an id with new semantics is prohibited.

The concrete code representation and first event catalog belong to their implementing Issues. This ADR does not add a public Swift API.

### Correlation id rules

- A correlation id is generated from a cryptographically secure random source at the start of one bounded operation or session.
- It is opaque and contains no timestamp, device/account/network identifier, certificate material, sequence of user actions, or reversible source data.
- It is scoped to one process launch and is not persisted as product identity or reused across launches.
- Child operations may inherit the parent id only when they are part of the same diagnostic operation; unrelated work receives a new id.
- It is not an authentication token, protocol session id, trust identity, analytics identifier, or stable device id.
- Missing correlation is represented by absence, never by a caller-supplied placeholder string.

### Metadata allowlist

Metadata is permitted only when an event-catalog entry fixes its key, type, bounds, and representation. Initially permitted representations are:

- booleans
- bounded integer counts that do not encode user actions
- bounded durations rounded to a reviewed diagnostic resolution
- byte-size buckets such as empty, small, medium, large, or rejected; never content hashes or exact sensitive payload sizes
- closed enums for state, stage, reason, retry disposition, permission status, and cleanup outcome
- application, schema, protocol, or operating-system version values only when they come from the local build/runtime and cannot identify a user or peer

Prohibited metadata includes typed text, key sequences, key codes tied to activity, clipboard content or hashes, passwords, secrets, tokens, private/public key material, certificate or trust fingerprints, raw protocol frames, memory dumps, stack values containing arguments, file paths, usernames, hostnames, IP/MAC addresses, device names/serials, peer-provided identifiers, precise cursor trails, and arbitrary strings.

Values outside their declared enum or bounds fail closed at the diagnostic boundary. They are not truncated into an allowed-looking string and are not replaced with a hash that could still identify or correlate content.

### Error taxonomy

Diagnostic errors use a typed taxonomy rather than localized descriptions or arbitrary exception text. Every error has a domain, code, stage, severity, retry disposition, and cleanup disposition selected from closed allowlists.

Domains and minimum codes are:

| Domain | Codes covered by this policy |
|---|---|
| cancellation | requested, superseded, shutdown |
| timeout | connect, handshake, read, write, keepalive, cleanup |
| transport | unavailable, disconnected, refused, reset, resourceExhausted |
| protocol | malformed, oversized, unsupportedVersion, unsupportedMessage, invariantViolation |
| security | identityUnknown, identityChanged, identityRevoked, trustRejected, secureStorageUnavailable |
| permission | accessibilityDenied, capabilityUnavailable |
| inputSafety | cleanupRequired, cleanupPartial, cleanupFailed, localStateRestoreFailed |
| clipboard | unsupportedType, invalidUTF8, oversized, loopRejected |
| lifecycle | sleep, wake, termination, subsystemUnavailable |
| internal | preconditionFailed, stateInvariantViolation |

Severity is `debug`, `info`, `notice`, `warning`, or `error`; it does not authorize more metadata. Retry disposition is `never`, `userActionRequired`, `backoff`, or `immediateAfterStateChange`. Cleanup disposition is `notRequired`, `completed`, `partial`, or `failed`.

Underlying operating-system or library errors may be mapped to a reviewed code and bounded numeric status only when the event catalog explicitly permits that numeric field. `localizedDescription`, reflection output, debug dumps, stack arguments, and raw error strings are never emitted. An unmapped error becomes `internal.preconditionFailed` or the narrowest safe domain code with no source text; it is not silently treated as success.

### Emission, sinks, and failure behavior

- All modules emit through one diagnostic boundary that validates event id, category, correlation, metadata schema, and bounds before a sink receives the event.
- Production and development builds use the same content prohibitions. Debug mode may increase event frequency, not payload sensitivity.
- Sink failures never block input cleanup, cancellation, disconnect, or trust rejection. They return a bounded diagnostic failure signal to their caller without recursively logging arbitrary errors.
- Diagnostics are best effort and must not become protocol frames, Core events, UI state authority, or a networking dependency.
- Redaction happens before serialization or sink submission. A sink is not trusted to repair an unsafe event.
- No event may assert success when the underlying operation failed or when required cleanup is partial/failed.

## Selected and rejected alternatives

### Selected: typed allowlisted diagnostic envelope

Selected because it satisfies C-010, supports deterministic tests and support tooling, and rejects unsafe values before persistence.

### Rejected: free-form strings with best-effort redaction

Rejected because redaction cannot reliably recognize arbitrary user content, localized errors, future payload formats, or secrets embedded in strings.

### Rejected: log content hashes instead of content

Rejected because low-entropy typed text, clipboard contents, peer identifiers, and fingerprints can be correlated or recovered by guessing. Hashing does not make prohibited content allowable.

### Rejected: permit sensitive fields only in debug builds

Rejected because debug logs are routinely persisted and shared, and development environments still contain real user content and credentials.

### Rejected: rely on sink privacy annotations alone

Rejected because sinks differ, exports may discard annotations, and unsafe data has already crossed the diagnostic boundary before the sink can redact it.

### Rejected: silently drop unknown errors and events

Rejected because it hides operational failures. Unknown values must produce a bounded typed diagnostic-boundary failure without exposing the original payload.

## Consequences

### Positive

- Logs remain useful for lifecycle, failure-stage, retry, and cleanup diagnosis without reconstructing user content.
- Event schemas are deterministic and testable.
- Support bundles can filter and summarize stable event ids without parsing prose.
- Protocol, Core, platform, and UI boundaries remain intact.

### Costs and constraints

- Every new event and metadata field requires catalog review.
- Some third-party and OS error detail is intentionally unavailable in persisted logs.
- Components must map errors deliberately and test rejected metadata.
- Diagnostic correlation ends at process restart unless a separately reviewed, privacy-safe support workflow is approved.

## Security and privacy impact

- The policy minimizes persisted data and rejects content before serialization.
- Trust material, identity fingerprints, tokens, typed input, and clipboard contents remain prohibited even when an error occurs.
- Correlation ids cannot become cross-launch tracking identifiers.
- Exact sensitive sizes, timings, coordinates, and action sequences are either bucketed or prohibited to prevent reconstruction.
- A logging-validation failure cannot weaken TLS, trust, input cleanup, cancellation, or local-state restoration.

## Compatibility impact

- Event ids are compatibility identifiers for tests and diagnostic tooling, not wire-protocol or public product APIs.
- Stable meaning and fixed metadata schemas permit later macOS, Windows, and Linux implementations to produce comparable diagnostic outcomes.
- Platform-specific numeric codes remain optional allowlisted metadata and never replace the cross-platform error taxonomy.
- Existing protocol and KVMEvent contracts are unchanged.

## Validation and acceptance evidence

Implementing Issues must test:

- one valid event for each introduced category and error domain
- rejection of unknown event ids, categories, metadata keys, enum values, and out-of-bound numbers
- rejection of arbitrary strings and every prohibited content class relevant to that component
- correlation-id creation, scope, non-persistence, and cancellation cleanup
- error mapping, retry disposition, cleanup disposition, and sink-failure non-interference
- diagnostic export without typed text, clipboard content, secrets, key material, fingerprints, paths, network addresses, or peer identifiers

The M1-011 PR is accepted only when docs/schema checks, backlog validation, architecture checks, full CI, and privacy/security review pass.

## Deferred decisions with owners and blockers

| Decision | Owner | Blocking Issue |
|---|---|---|
| Concrete Swift `DiagnosticEvent` and typed error representation | Core diagnostics owner | M1-015 before public code is introduced |
| First source-controlled event-id and metadata catalog | Diagnostics owner plus Security Reviewer | The first Issue that emits production diagnostics |
| Local retention duration, rotation, size cap, and OSLog integration | Diagnostics owner plus Security Reviewer | M1-012 diagnostic bundle/export implementation |
| Diagnostic bundle schema and user-consent/export UX | Diagnostics owner plus Product Owner | M1-012 |
| Cross-platform sink parity and platform numeric-code allowlists | Platform owners plus Security Reviewer | The first Windows/Linux diagnostic implementation |

These decisions are not authorized by this ADR. Their blocking Issues must preserve C-010 and this privacy boundary.

## Rollback

If an implementation emits prohibited or unreviewed data:

1. Disable the affected event or sink without weakening product security, cleanup, or error reporting.
2. Quarantine unsafe diagnostic artifacts and identify their storage/export paths without copying their content into new logs.
3. Replace the event with the last reviewed schema and rerun privacy-negative tests.
4. Notify the Product Owner and Security Reviewer when content may have left the local trust boundary.
5. Do not restore emission until the field, representation, retention, and evidence are explicitly approved.

If this policy itself must change, use a superseding ADR and explicit Product Owner decision. Never redefine C-010 through an implementation shortcut.

## Acceptance record

- M1-002 dependency: merged through PR #219; formal independent backfill completed through PR #236.
- C-010: present and frozen in `CONTRACT_CATALOG.md`.
- Frozen Decision 8 and architecture guardrails: reviewed as binding inputs.
- Product Owner authorization: standing M1 execution and protected-merge authorization applies; no per-step approval is required when all gates and review conditions pass.
- Security/privacy disposition: must be recorded in the M1-011 PR review before merge.
