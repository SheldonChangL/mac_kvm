# M1-056 SHA-256 Certificate Fingerprint Formatter

## Outcome

`MacPlatform` provides `CertificateFingerprint`, which computes the SHA-256
digest of a certificate's DER bytes and, as a separate step, renders a 32-byte
digest in the canonical display form: uppercase two-digit hex groups joined by
single colons. Empty DER and a digest of the wrong length fail closed with a
typed, payload-free reason. Nothing here decides trust.

No public or package contract is added, and no frozen contract, ADR, or wire
format is changed. Changes are limited to the three Exact Files:

- `Packages/MacPlatform/Sources/MacPlatform/CertificateFingerprint.swift`
- `Packages/MacPlatform/Tests/MacPlatformTests/CertificateFingerprintTests.swift`
- `docs/components/M1-056-certificate-fingerprint.md`

## API

Every declaration is `internal` (the default access level, written without a
modifier like the other `MacPlatform` internals):

| Declaration | Purpose |
| --- | --- |
| `enum CertificateFingerprint` | caseless namespace; no instances, no stored state |
| `static let sha256DigestLength = 32` | the only accepted digest length |
| `static func sha256Digest(ofCertificateDER:) -> Result<Data, CertificateFingerprintFailure>` | raw 32-byte SHA-256 digest of non-empty DER |
| `static func canonicalDisplay(ofSHA256Digest:) -> Result<String, CertificateFingerprintFailure>` | display string for an exactly 32-byte digest |
| `enum CertificateFingerprintFailure: String, Error, Equatable, Sendable, CaseIterable` | `emptyCertificate`, `invalidDigestLength` |

No caller in the repository uses these yet. The later trust policy (M1-057)
and its store are the intended consumers; widening access for them is their
decision, not this issue's.

## Contract

- **Hash.** `sha256Digest` returns `.failure(.emptyCertificate)` for empty
  input. Otherwise it returns the 32 bytes of Apple CryptoKit
  `SHA256.hash(data:)` over exactly the input bytes, as a new `Data`. The DER
  is never parsed or validated as a certificate; any non-empty bytes are
  hashed.
- **Format.** `canonicalDisplay` returns `.failure(.invalidDigestLength)`
  unless the input is exactly 32 bytes. Otherwise it returns 95 characters:
  each byte, in order, as two uppercase hex digits from a fixed
  `0123456789ABCDEF` table, with a single `:` between groups and nothing
  before or after. It never hashes its input.
- **Separation.** The raw digest is the value a trust store compares; the
  display string is only for people. Neither function calls the other, so a
  caller cannot get a display string without first holding the raw digest,
  and a display string fed back as a digest is the wrong length and rejected.
- **Slices.** Both functions read only the bytes of the `Data` they receive,
  so a slice with a non-zero `startIndex` is handled like a fresh copy, and an
  empty slice of a non-empty buffer is still `emptyCertificate`.
- **Result, not throws.** Both return `Result`, so a caller must handle the
  failure case explicitly; there is no default, fallback digest, or empty
  string on failure.

## Boundaries

- No trust decision, comparison, pinning, trust-on-first-use, or
  identity-change policy. Accepting, prompting for, or rejecting a peer
  belongs to the C-009 trust policy.
- No choice of which certificate in a chain to fingerprint. M1-055 forwards
  the chain in platform callback order and assigns no leaf meaning to element
  zero; the caller of this unit must make that choice from a verified source.
- No storage, persistence, logging, diagnostics, network, UI, or protocol
  message.
- No other algorithm, no lowercase or unseparated form, and no parser for the
  display string.

## Security and privacy

- **Fail closed.** Empty DER would otherwise hash to the well-known empty-input
  digest `E3B0C442...B855`, a valid-looking value that identifies no
  certificate. It is refused, and a test asserts that value is never produced.
  A wrong-length digest is refused rather than truncated, padded, or rehashed.
- **No payload in failures.** `CertificateFingerprintFailure` cases carry no
  associated value, so no rendering of a failure can contain certificate
  bytes, digest bytes, or their length. A test renders failures through
  `String(describing:)` and `String(reflecting:)` and checks for a distinctive
  input byte in hex and decimal and for its length.
- **No secrets.** Certificate DER and its digest are public material. No
  private key, identity, password, or other secret is handled, and nothing is
  written to UserDefaults, a plist, JSON, the Keychain, or a log.
- **No retention.** Neither the input nor the output is retained after a call
  returns.
- **Primitive.** SHA-256 comes from the system CryptoKit framework; no hash is
  implemented here.

## Determinism, concurrency, cancel, and cleanup

Both functions are pure: the output depends only on the input bytes, with no
clock, randomness, locale, global mutable state, or I/O. The hex table is a
`private static let` constant, and formatting does not use `String(format:)`
or any locale-sensitive API. Tests assert that the same input, including an
independent copy, always yields the same digest and display string, and that
failures do not affect later calls.

Cancellation and cleanup are not applicable by design. Both operations are
synchronous over in-memory `Data` and own no task, stream, socket, file,
timer, lock, or stored state, so there is nothing to cancel, nothing to
release, and no teardown entry point. `CertificateFingerprint` is a caseless
enum with a memory size of zero, which a test asserts. Calls are safe from any
thread without synchronization.

## Tests

`CertificateFingerprintTests.swift` declares 26 `@Test` functions; one is
parameterized over 9 lengths. Expected digests are published SHA-256 vectors
transcribed byte by byte, not computed by the code under test:

| Input | SHA-256 |
| --- | --- |
| `"abc"` (FIPS 180-2 B.1) | `ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad` |
| single byte `0x00` | `6e340b9cffb37a989ca544e6bb780a2c78901d3fb33738768511a30617afa01d` |
| 56-byte `"abcdbcde...nopq"` (FIPS 180-2 B.2) | `248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1` |

Coverage:

- **Happy path:** digest length constant; the `abc` digest and its display
  string; hash-then-format end to end.
- **Formatting:** bytes `0x00...0x1F` against an explicit string; all `0xFF`;
  every byte value `0x00...0xFF` rendered in canonical uppercase shape.
- **Separation:** the digest is 32 raw bytes, not hex text; formatting does not
  hash; hashing a 32-byte input does not pass it through.
- **Boundaries:** the single-byte input; the two-block FIPS vector; a 256 KiB
  input; `Data` slices with non-zero start indices for both functions.
- **Invalid input and fail closed:** empty DER; never the empty-input digest;
  an empty slice of a non-empty buffer; digest lengths 0, 1, 16, 20, 31, 33,
  48, 64, and 95; a display string offered as a digest; the closed,
  distinct failure set and raw values.
- **Fingerprint changed:** different certificates; every single-bit flip of a
  certificate; an appended or truncated certificate.
- **Determinism:** repeated and copied inputs; failures not poisoning later
  calls.
- **Privacy:** failure renderings carry no input bytes or length.
- **No state:** the caseless enum has zero size.

The tests were written first; a RED run against the missing implementation
was verified by the reviewer before this implementation was added.

## Verification status

The author session had no command execution, so none of the Required
Commands have been run by the author. The implementation was checked only by
static review against the tests. Reviewer validation must run the Required
Commands, `swift build --package-path Packages/MacPlatform -c release`,
`make code-quality-check`, and `make docs-check`.

M1-056 has no mandatory manual step.

## Known limitations

- **No certificate validation.** Any non-empty bytes are hashed; malformed DER
  yields a valid-looking fingerprint of those bytes.
- **No chain selection.** Which certificate to fingerprint is unresolved here;
  see Boundaries.
- **Not constant time.** The display string and any future comparison are not
  constant-time. Fingerprints are public values, so this is not a secrecy
  concern; comparison belongs to the trust policy.
- **Whole-input hashing.** Input size is not capped here. M1-055 already caps a
  peer chain at 256 KiB, and the hash itself returns 32 bytes for any size.
- **Display form is fixed.** SHA-256, uppercase, colon-separated only. A
  different presentation or algorithm needs a new decision.

## Rollback

Remove or revert the three M1-056 Exact Files. No other file depends on them,
and there is no persisted state, trust data, migration, wire format, or
runtime resource to clean up.
