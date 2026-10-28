# M1-059 Manual Verification

**Verdict: PENDING — not performed.** No manual result exists, and none is
claimed. The executing author (Claude Opus) did not run the Tier-H probe, did
not touch the real Keychain, and must not be the reviewer of record for this
step. Every automated result in this package uses an in-memory fake Keychain
and is not a substitute for this verification.

## Why Tier H applies

M1-059 is risk critical, tier `B/S/H`. Its Manual Verification requires the
fingerprint change flow to run on real macOS secure storage, not a mock, and
to be checked by a reviewer who is not the executing agent. The flow has no UI
in scope; the real-platform surface is the data-protection Keychain path that
the re-pair transition (check, remove, insert, verify) drives.

## Command

The probe is the opt-in test `manualFingerprintChangeProbeRunsTheRealRepairRoundTrip`
in `Packages/MacPlatform/Tests/MacPlatformTests/FingerprintChangeFlowTests.swift`.
It is skipped unless the reviewer selects it:

```sh
MACKVM_M1_059_MANUAL_PROBE=fingerprint-change-repair-round-trip \
  swift test --package-path Packages/MacPlatform \
  --filter manualFingerprintChangeProbeRunsTheRealRepairRoundTrip
echo "exit=$?"
```

It touches one fixed synthetic record only, removes it first and again at the
end, and prints exactly one closed-vocabulary line. Sequence: initial cleanup;
first-use trust of vector A; evaluate vector B (identity changed, warning must
show exactly A and B for the synthetic device); owner declines; evaluate B
again; owner re-pairs; evaluate B (allow) and A (identity changed); re-pair
again (allow, no write); final cleanup; absence check.

## Expected output

```text
M1-059 manual probe: action=fingerprint-change-repair-round-trip initialCleanup=removed seedTrust=allow changed=identityChanged warning=match declined=reject.trustRejected afterDecline=identityChanged repair=allow presented=allow previous=identityChanged repeatRepair=allow finalCleanup=removed afterCleanup=absent
```

The test also records an issue, and the run exits non-zero, if any field
differs. Expected equals actual must be checked field by field.

## Host requirement

M1-058 established that the data-protection Keychain refuses an ad-hoc-signed
SwiftPM test host without a Keychain entitlement, and that a pass needed a
development-signed, provisioned host (`evidence/issues/M1-058/manual.md`,
diagnostic attempts D-1 to D-4). If the command above runs in such an
unsigned host, the line reports `failed.security.secureStorageUnavailable.*`
fields. That is the fail-closed outcome, not a pass; record it as a diagnostic
attempt and rerun the same sequence in a signed, provisioned host, as was done
for M1-058. The synthetic record and the expected line are the same in either
host.

## To be recorded by the reviewer

| Field | Value |
| --- | --- |
| Date / time zone | pending |
| Build commit | pending |
| Operator | pending |
| Reviewer (non-author, non-executing) | pending |
| OS / build | pending |
| CPU architecture / model | pending |
| Toolchain | pending |
| Host signing (identity kind, team, entitlement keys) | pending |
| Exact output line and exit status | pending |
| Expected vs actual, field by field | pending |
| Cleanup verified (`afterCleanup=absent`) | pending |
| Display / keyboard layout | not applicable to Keychain validation |
| Network / peer | not exercised; the flow performs no network I/O |

## Privacy

Record only the closed output line, exit status, OS/build/hardware facts and
artifact hashes. Do not record fingerprint bytes or display text, the synthetic
device identifier, a Keychain account value, an Apple ID, a device UDID, a
profile UUID, a serial number, or any certificate private data.
