# M1-057 Trust Policy State Machine

## Outcome

`MacPlatform` provides `TrustPolicy.decide(state:presentedFingerprint:)`, the
C-009 trust decision as a pure, synchronous function. An unknown identity
prompts, a trusted identity presenting the same fingerprint is allowed, and a
changed or revoked identity is rejected. Nothing is accepted automatically,
and a fingerprint of the wrong length fails closed.

No frozen contract, ADR, or wire format is changed, and `KVMContracts` is not
edited. Changes are limited to the three Exact Files:

- `Packages/MacPlatform/Sources/MacPlatform/TrustPolicy.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/TrustPolicyTests.swift`
- `docs/components/M1-057-trust-policy.md`

## API

| Declaration | Purpose |
| --- | --- |
| `enum TrustPolicyState: Equatable, Sendable` | `unknown`, `trusted(fingerprint: Data)`, `revoked` |
| `enum TrustPolicyDecision: Equatable, Sendable` | `prompt`, `allow`, `reject(SecurityErrorCode)` |
| `enum TrustPolicy` | caseless namespace; no instances, no stored state |
| `static func decide(state:presentedFingerprint:) -> TrustPolicyDecision` | the decision |
| `private static func isSHA256Digest(_:)` | exact-length check against `CertificateFingerprint.sha256DigestLength` |

`SecurityErrorCode` is the frozen M1-015 type from `KVMContracts`; no case is
added. The three types and `decide` carry no access modifier, so they are
`internal` by default: an internal seam within the `MacPlatform` target, not
a public API. This matches M1-055 and M1-056, which use `package` and
`internal`, and is enough for M1-058, which is in the same target. The tests
reach the seam through `@testable import`.

## Contract

C-009 in `CONTRACT_CATALOG.md`: unknown→prompt; trusted+same
fingerprint→allow; changed/revoked→reject; no auto-accept. Frozen Decision 6:
TLS/security fails closed, and an unknown or changed identity is never
accepted automatically.

A fingerprint is the raw SHA-256 digest of a certificate's DER, as produced by
M1-056 `CertificateFingerprint.sha256Digest(ofCertificateDER:)`: exactly
`CertificateFingerprint.sha256DigestLength` (32) bytes. Display text is never
a fingerprint.

## Precedence

Highest first:

1. **Presented length.** A presented fingerprint that is not exactly 32 bytes
   returns `.reject(.trustRejected)`, whatever the state. An unknown identity
   is not prompted for, a revoked one is not reported as revoked, and a
   trusted one is not reported as changed.
2. **Stored length.** A `.trusted` state whose stored fingerprint is not
   exactly 32 bytes returns `.reject(.trustRejected)`, even when the bytes
   compare equal. Two empty values are equal but not valid.
3. **State.**

| State | Presented (valid length) | Decision |
| --- | --- | --- |
| `.unknown` | any | `.prompt` |
| `.trusted(fingerprint: f)` | equal to `f`, byte for byte | `.allow` |
| `.trusted(fingerprint: f)` | different from `f` | `.reject(.identityChanged)` |
| `.revoked` | any | `.reject(.identityRevoked)` |

Equality is `Data` content equality over the whole value: the same count and
the same bytes in the same order. It does not depend on storage or on slice
start indices, and there is no prefix, suffix, or truncated comparison.

Only `.identityChanged`, `.identityRevoked`, and `.trustRejected` are ever
returned. An unknown identity prompts rather than rejecting with
`.identityUnknown`, and nothing claims `.secureStorageUnavailable`.

## Boundaries

- **Decides only.** The policy does not store, load, or update trust state;
  it does not show a prompt or record the person's answer; it does not log,
  emit diagnostics, or format a fingerprint.
- **Caller-owned inputs.** The caller supplies the state and the presented
  digest. Which certificate in a chain to fingerprint is the caller's choice
  from a verified source; M1-055 assigns no leaf meaning to element zero.
- **No platform work.** No network, TLS, Keychain, UI, file, clock, or
  protocol message. No Barrier token or type appears in the API or its
  results, so the policy is usable unchanged by the Native protocol.
- **No memory.** Earlier calls never affect later ones. Prompting is not
  trust-on-first-use, and allowing is not learning.

## Security and fail-safe behavior

- **Never auto-accepts.** `.allow` is reachable only from `.trusted` with a
  valid stored fingerprint equal to a valid presented one. `.prompt` is
  reachable only from `.unknown` with a valid presented fingerprint.
- **Fail closed on malformed input.** A wrong-length digest is rejected, not
  truncated, padded, rehashed, or parsed. Display text in any case, with or
  without colons, is the wrong length and rejected, as are concatenated
  digests.
- **Revocation is final.** No presented fingerprint, including the one once
  trusted, revives a `.revoked` state.
- **No payload in decisions.** `TrustPolicyDecision` carries no fingerprint,
  so decisions for different fingerprints are equal and a rendered decision
  exposes no digest bytes.
- **No secrets, no retention.** Fingerprints are public material. Nothing is
  retained after a call or written to UserDefaults, a plist, JSON, the
  Keychain, or a log.
- **Closed sets.** Both enums are exhaustively switched in the tests, so a
  new case breaks compilation instead of silently defaulting.

## Determinism, concurrency, cancel, and cleanup

`decide` is pure: its result depends only on its two arguments, with no
clock, randomness, global mutable state, or I/O. Inputs are value types and
are not mutated. Calls are safe from any thread without synchronization.

Cancellation and cleanup are not applicable by design. The function is
synchronous over in-memory values and owns no task, stream, socket, file,
timer, lock, or stored state, so there is nothing to cancel and nothing to
release. Idempotency is covered by the determinism and non-poisoning tests.

## Tests

`TrustPolicyTests.swift` declares 28 `@Test` functions; two are parameterized
over 10 lengths (0, 1, 16, 20, 31, 33, 48, 64, 95, 4096). Valid fingerprints
are the FIPS 180-2 B.1 and B.2 SHA-256 vectors, transcribed byte by byte.

- **Table:** the full state/decision table, including wrong-length rows.
- **Happy path:** unknown prompts; trusted with the same fingerprint allows;
  an independent copy matches; `Data` slices with non-zero start indices.
- **Boundary:** 32 bytes is the only accepted length; 31 and 33 reject.
- **Invalid input and fail closed:** wrong presented length in every state
  shape; wrong stored length against identical, copied, prefix-sharing, and
  unrelated values; empty against empty; concatenated digests; display text.
- **Identity changed:** every single-bit flip of the presented and of the
  stored fingerprint; first and last bytes; reversed and rotated bytes.
- **No auto-accept:** `.allow` and `.prompt` only through their own rows;
  only the three table codes; revocation not bypassable.
- **Types:** closed case sets; `Equatable` and `Sendable`.
- **Determinism and recovery:** repeated calls; earlier calls do not change
  later ones; rejections do not poison later calls; inputs not mutated;
  concurrent calls agree with serial calls.
- **Privacy:** decisions for different fingerprints are indistinguishable.

## Integration guidance

- **`.prompt` is not accept.** Map it to a rejection of the current
  connection, for example `MacTLSTrustDecision.reject`, until a person
  explicitly confirms the fingerprint. Never map `.prompt` to
  `MacTLSTrustDecision.accept`.
- **Persist only after confirmation.** Only an explicit user confirmation may
  turn `.unknown` into `.trusted(fingerprint:)`, and storing it belongs to the
  secure storage layer (Keychain), not to this policy.
- **Pass raw digests.** Compute the presented value with
  `CertificateFingerprint.sha256Digest(ofCertificateDER:)` and store the same
  raw bytes. Use `canonicalDisplay` only to show the value to a person.
- **Treat every rejection as terminal** for the connection attempt. Do not
  retry with a different state, and do not downgrade to an unauthenticated or
  plaintext path.
- **Unreadable stored trust.** If stored trust cannot be read, do not invent
  `.unknown` to get a prompt; report the storage failure in the caller.

## Verification status

The reviewer ran the Required Commands on 2026-10-23:

```bash
swift test --package-path Packages/MacPlatform
xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build
python3 Tools/Backlog/validate_package.py
make architecture-check
```

| Command | Exit | Result |
| --- | --- | --- |
| `swift test --package-path Packages/MacPlatform` | 0 | Build complete; Swift Testing run passed 172 tests. Only the existing opt-in manual Tier-H probes were skipped. |
| `xcodebuild -workspace MacKVM.xcworkspace -scheme MacKVM -destination 'platform=macOS' build` | 0 | `BUILD SUCCEEDED` |
| `python3 Tools/Backlog/validate_package.py` | 0 | `PACKAGE OK: 217 issues, 5 milestones, 17 epics` |
| `make architecture-check` | 0 | `architecture check OK` |

M1-057 has no mandatory manual step. Security review is required (risk:
critical, tier C/S).

## Known limitations

- **Not constant time.** Comparison uses `Data` equality. Fingerprints are
  public values, so timing reveals no secret.
- **SHA-256 only.** Another digest algorithm or length needs a new decision.
- **No chain selection or certificate validation.** See Boundaries.

## Out of scope

- Prompt UI, trust store, Keychain persistence, and revocation management.
- Wiring the policy into `MacTLSTransport` or any session.
- Protocol messages, diagnostics, and logging.
- Any change to `SecurityErrorCode`, C-009, or other frozen contracts.

## Rollback

Remove or revert the three M1-057 Exact Files. No other file depends on them,
and there is no persisted state, trust data, migration, wire format, or
runtime resource to clean up.
