# M1-058 Manual Verification

**Verdict: PASS.** The **human Product Owner** executed a development-signed,
provisioned probe app against the real local macOS data-protection Keychain.
The **Codex root reviewer** — non-author and non-executing for this step —
reviewed the exact output, exit status, artifact hashes and signature facts.
Claude Opus authored the temporary probe source and this document using file
tools only and ran nothing.

## Metadata

| Field | Value |
| --- | --- |
| Date | 2026-10-27 (Asia/Taipei) |
| Observed launch time | `2026-10-27T14:19:50+08:00` (`2026-10-27T06:19:50Z`) — from a launch-adjacent kernel event; observed, not a user-supplied start time |
| Implementation commit | `5c87ba53a45d3312c282b41702138522b36e3c57` |
| Evidence commit | pending |
| Operator | human Product Owner, in Terminal |
| Reviewer | Codex root reviewer (non-author, non-executing) |
| OS / build | macOS 26.6.2, build 25G83 |
| CPU architecture | arm64, Apple M4 Pro (MacBook Pro, Mac16,7) |
| Toolchain | Xcode 26.2 (17C52); Swift 6.2.3 |
| Platform under test | local data-protection Keychain; device unlocked |
| Display / keyboard layout | not applicable to Keychain validation |
| Network / peer | not exercised; the component and probe perform no network I/O |

## Command

```sh
/private/tmp/m1-058-signed-probe.HGUZ1S/M1058KeychainProbe.app/Contents/MacOS/m1-058-keychain-probe
echo "exit=$?"
```

The probe performs a first-use round trip against the real data-protection
Keychain on one fixed synthetic record: initial cleanup, evaluate with no
record, explicit owner reject, re-evaluate, explicit owner trust, evaluate
the same fingerprint, evaluate a changed fingerprint, final cleanup, and a
final absence check. Output is a closed vocabulary only.

## Exact output

```text
M1-058 manual probe: action=keychain-first-use-round-trip initialCleanup=removed absent=prompt explicitReject=reject.trustRejected afterReject=prompt explicitTrust=allow same=allow changed=reject.identityChanged finalCleanup=removed afterCleanup=absent
exit=0
```

## Expected vs actual

| Field | Expected | Actual | Result |
| --- | --- | --- | --- |
| `action` | `keychain-first-use-round-trip` | `keychain-first-use-round-trip` | match |
| `initialCleanup` | `removed` | `removed` | match |
| `absent` | `prompt` (no write) | `prompt` | match |
| `explicitReject` | `reject.trustRejected` | `reject.trustRejected` | match |
| `afterReject` | `prompt` (reject wrote nothing) | `prompt` | match |
| `explicitTrust` | `allow` | `allow` | match |
| `same` | `allow` | `allow` | match |
| `changed` | `reject.identityChanged` | `reject.identityChanged` | match |
| `finalCleanup` | `removed` | `removed` | match |
| `afterCleanup` | `absent` | `absent` | match |
| exit status | `0` | `0` | match |

**Cleanup / fail-safe:** final cleanup removed the fixed synthetic record and
`afterCleanup=absent` verified its absence. No trust record remains.

## Artifacts and signed environment

| Item | Value |
| --- | --- |
| Final executable SHA-256 | `24da7eb60eef795e3cb59934de7a32975dbc945200edf5f79aaca0d353b11029` |
| Temporary probe source SHA-256 | `05f5c0f4ddc88a3d78923d0d2323451e84d80f398fe9028a01f067002547dd4c` |
| Embedded provisioning profile SHA-256 | `e66f31721f63818100dfff1babab8b22767079b3619a8193eb74309ba780eecf` |
| Signature | Apple Development; TeamIdentifier `4V223Y472D`; bundle identifier `com.sheldonchang.mackvm.m1-058-probe`; hardened runtime |
| Entitlements | exactly `application-identifier`, `team-identifier`, `get-task-allow`, `keychain-access-groups` |
| codesign | deep/strict verification passed |
| Profile | `Mac Team Provisioning Profile: *`; platform OSX; Team `4V223Y472D`; wildcard application identifier and keychain group; expires 2027-10-27; contains the current Mac |

Build provenance (not a test result): the final signed probe executable was
built outside the repository by linking the temporary probe main source
(SHA-256 above) with the production MacPlatform object files for
`KeychainTrustStore`, `TrustPolicy`, `CertificateFingerprint`, `CoreErrors`
and `DomainIdentifiers` produced at implementation commit
`5c87ba53a45d3312c282b41702138522b36e3c57`.

Authorization: the human explicitly authorized use of the signing identity,
creation of temporary macOS App ID/profile resources, and registration of the
current Mac. Xcode automatic provisioning then built successfully. The
temporary signing work happened outside the repository and never modified
it.

## Diagnostic attempts (failed; not acceptance passes)

These earlier attempts are negative/diagnostic evidence. They show the store
fails closed on an unsigned or unprovisioned host and explain why a signed,
provisioned app host was required.

| # | Host | Outcome |
| --- | --- | --- |
| D-1 | Opt-in Swift test run by the human from an ad-hoc SwiftPM xctest bundle (ad-hoc/linker signature; no TeamIdentifier or entitlements) | Failed immediately at initial cleanup with `secureStorageUnavailable`; final cleanup also failed; `afterCleanup=absent`; nonzero exit (exact value not recorded) |
| D-2 | Development-signed standalone executable with restricted entitlements, no matching provisioning profile | Killed before `main`, exit 137. macOS logs: `No matching profile found`; AMFI rejected the restricted entitlements. Keychain not touched |
| D-3 | Development-signed standalone executable without restricted entitlements | Ran; initial and final cleanup failed `secureStorageUnavailable`; `afterCleanup=absent`; exit 1. securityd reason: OSStatus `-34018`, client had neither `application-identifier`, `application-groups` nor `keychain-access-groups` entitlement |
| D-4 | Xcode automatic provisioning | First failed because the login was rejected; the human reauthenticated. The next attempt required Mac registration, which the human explicitly authorized; registration and the profiled build then succeeded |

## Privacy

The probe output is a closed one-line vocabulary plus exit status; together
with the artifact and signature hashes it is sufficient, so no screenshot or
video was captured. This document contains no Apple ID, certificate private
data, device UDID, profile UUID, serial number, hardware UUID, synthetic
DeviceID, Keychain account value or fingerprint bytes. No secret, private key,
certificate or password is stored or logged by the component.

## What this proves

- The production data-protection Keychain path stores, reads and removes a
  trust record when hosted by a correctly signed and provisioned app.
- Missing → `prompt` without writing; explicit reject writes nothing; explicit
  trust inserts; same → `allow`; changed → `identityChanged`.
- Cleanup removes the record and absence is verified.
- Unsigned or entitlement-less hosts fail closed (D-1, D-3).

## What this does not prove

- Deployment signing of the shipping app (L-1).
- Prompt UI, TLS wiring, re-pair or revocation workflows (L-3).
- Network or peer behavior.
