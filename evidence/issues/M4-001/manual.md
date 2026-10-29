# M4-001 Manual Verification

For a reviewer who is not the implementing agent. Docker must be able to run
`linux/amd64` images.

1. From the repository root, run `evidence/issues/M4-001/spikes/linux-shared-packages.sh`.
   Expected: Swift 6.2.3 on x86_64, then three `Test run with … passed` lines (64, 245
   and 172 tests).
2. Run `evidence/issues/M4-001/spikes/tls-pinning/run.sh`. The first run builds BoringSSL
   and takes several minutes. Expected: `Build complete!`, `tls handshake done; leaf
   sha256 hex length: 64`, and dynamic libraries limited to `libc`, `libm`, `libstdc++`,
   `libgcc_s` and the loader.
3. Compare the image digest and the dependency versions in
   `spikes/tls-pinning/Package.resolved` with `toolchain.m4.lock.json`.
4. Read the ADR's open questions and confirm each one has an owner and a blocking
   condition.

| Step | Actual (implementing agent, 2026-10-29) | Reviewer |
| --- | --- | --- |
| 1 | `tests/linux-shared-packages.txt` | pending |
| 2 | `tests/tls-pinning.txt` | pending |
| 3 | matches | pending |
| 4 | all six have both | pending |
