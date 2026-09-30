# M1-024 Barrier Client Handshake Fixtures — Capture Plan

## Status

- The capture, the sanitization, the fixture pair, the repository validator and
  the evidence package have been completed under this plan. The fixture
  prepared for commit comes from accepted attempt 8. The independent review has
  not happened: `evidence/issues/M1-024/independent-review.md` is absent and is
  authored only by the isolated reviewer defined in Roles.
- This document is a capture plan. It is never a wire contract. It does not
  define, freeze or imply any Barrier field, message, length, endianness,
  ordering rule, state machine or compatibility property. The first-party client
  contract is not frozen until M1-025, and M1-025 may only use evidence that
  corrective Issue #249 has independently approved and registered.
- Windows is not executed in M1. No Windows result is claimed or implied.

## Purpose

Produce one sanitized, reproducible fixture of uninterpreted TCP application
payload bytes, in capture order with direction only, from a controlled
black-box observation of two lawfully installed external Barrier programs:

- client: external Barrier macOS client `barrierc` 2.4.0-release, protocol 1.6,
  on the locked macOS capture host;
- server: external Barrier Linux server `barriers` 2.4.0-release, protocol 1.6,
  on the locked Ubuntu 22.04 x86_64 test peer.

Barrier stays an external test peer only. No Barrier or Deskflow source is read,
copied, linked, bundled or vendored by any step of this plan, and no first-party
MacKVM code participates in the capture.

## Non-claims

- No field meaning, message code, message boundary, endianness, framing,
  version negotiation or semantic claim about any payload byte.
- No compatibility claim between Barrier and MacKVM, between Barrier versions,
  or between platforms.
- No security claim. Both external peers run with `--disable-crypto` solely so
  the application payload is observable for this one controlled observation.
  TLS is recorded as disabled for the observation. This does not change, test or
  weaken the MacKVM production requirement that TLS is default ON, and it proves
  nothing about TLS behavior.
- Observation boundaries in the fixture are direction-change boundaries of the
  captured byte stream only; they are not messages.
- No Windows result. No claim about input injection, clipboard, screen switching
  or any behavior beyond a bounded connection handshake window.

## Binding inputs

- Issue: `MacKVM_Implementation_Package_v2/issues/M1/M1-024-barrier-client-handshake-fixtures.md`
- Toolchain lock: `MacKVM_Implementation_Package_v2/toolchain.lock.json`
  (`M1-CAPTURE-TOOLCHAIN-001`, status `LOCKED`, scope
  `M1_CONTROLLED_BARRIER_BLACK_BOX_CAPTURE_ONLY`)
- ADR: `docs/adr/M1-CAPTURE-TOOLCHAIN-001-capture-readiness.md`
- Readiness contract test: `Tests/Contracts/test_m1_024_capture_readiness.py`
- Fixture metadata schema: `Tests/Fixtures/fixture-metadata.schema.json`
- Dependency: M1-023 complete.

## Roles

| Role | Who | Writes | Must not |
|---|---|---|---|
| Capture operator / producer, workflow reviewer | Root session | Private temp dirs only (raw pcap, peer config, logs, sanitized output); reviews the author-supplied temporary sanitizer against this plan, then executes it; hands sanitized bytes and their hash to the author | Author, edit or patch any sanitizer code; commit raw data or the sanitizer; write `independent-review.md` |
| Implementation author | Claude implementation-author session | The implementation files in the Exact Files list except `independent-review.md`; the temporary sanitizer, outside the repository only | Run SSH, capture or the sanitizer; commit the sanitizer; alter sanitized payload bytes; write `independent-review.md` |
| Independent reviewer | Fresh, isolated Claude reviewer session that is neither producer nor implementation author | `evidence/issues/M1-024/independent-review.md` only; it alone authors that file | Edit any other file; reuse producer or author context |

Root's workflow review of the sanitizer and of the capture steps is not the
independent review. The reviewer receives only the repository branch and this
plan. A review written by the producer or the implementation author does not
satisfy the gate.

## Safe environment placeholders

All real values are injected privately at run time into the producer's shell
environment and are never echoed, logged, committed or written into any
evidence file. Evidence records the placeholder names only.

| Placeholder | Meaning | Recorded in evidence |
|---|---|---|
| `M1_024_SSH_TARGET` | SSH destination alias for the Ubuntu peer | Never; name only |
| `M1_024_REMOTE_PORT` | Non-default server test port on the peer loopback, chosen at run time from 20000-60999 and not equal to Barrier's default 24800 | Never; name only |
| `M1_024_LOCAL_PORT` | Mac loopback port of the SSH local forward | Never; name only |
| `M1_024_MAC_PRIVATE_DIR` | `mktemp -d` directory on the Mac, outside the repository, mode 0700 | Never; name only |
| `M1_024_PEER_PRIVATE_DIR` | `mktemp -d` directory on the peer, mode 0700 | Never; name only |
| `M1_024_PRIVATE_DENYLIST` | File inside `M1_024_MAC_PRIVATE_DIR` listing real host names, user names, addresses and SSH target strings to scan for | Never; name only |

Synthetic Barrier screen names are fixed: server `m1-server`, client `m1-client`.
Shell tracing (`set -x`) is disabled for every step that expands a placeholder.

## Exact preflight (fail closed)

Every check must match the lock exactly. Any mismatch, missing tool, extra
output that cannot be matched, or failed command stops M1-024 before capture.
There is no fallback tool, no auto-install and no version substitution. Only a
new Product Owner approved ADR may change the lock.

Repository (Mac):

1. `python3 -m unittest discover -s Tests/Contracts -p 'test_m1_024_capture_readiness.py'` exits 0.
2. `python3 Tools/Backlog/validate_package.py` exits 0.
3. M1-023 is recorded complete in the package.
4. `git status --porcelain` shows no tracked changes outside the M1-024 Exact Files.
5. `M1_024_MAC_PRIVATE_DIR` resolves outside `git rev-parse --show-toplevel`.

Mac capture host (expected value from the lock):

| Command | Expected |
|---|---|
| `sw_vers -productVersion` | `26.6.2` |
| `sw_vers -buildVersion` | `25G83` |
| `uname -m` | `arm64` |
| `swift --version` | `Apple Swift 6.2.3`, the swift-driver version exactly as pinned in the lock, target `arm64-apple-macosx26.0` |
| `/usr/bin/python3 --version` | `3.9.6` |
| `barrierc --version` | `2.4.0-release`, protocol `1.6` |

Ubuntu peer, each run as `ssh -o BatchMode=yes "$M1_024_SSH_TARGET" '<command>'`:

| Command | Expected |
|---|---|
| `. /etc/os-release; echo "$NAME $VERSION_ID"` | `Ubuntu 22.04` |
| `uname -m` | `x86_64` |
| `barriers --version` | `2.4.0-release`, protocol `1.6` |
| `tcpdump --version` | `tcpdump version 4.99.1` |
| `dumpcap --version` | `3.6.2` |
| `dpkg-query -W -f='${Version}' wireshark-common` | `3.6.2-2` |
| `getcap /usr/bin/tcpdump` | `/usr/bin/tcpdump cap_net_admin,cap_net_raw=eip` |
| `getcap /usr/bin/dumpcap` | `/usr/bin/dumpcap cap_net_admin,cap_net_raw=eip` |
| `tcpdump -D` (unprivileged, no `sudo`) | exits 0 and lists `lo` as `Up` and `Running` |
| `ss -Htln "sport = :$M1_024_REMOTE_PORT"` | no listener |
| `pgrep -x barriers; pgrep -x tcpdump` | no process |

Also before capture: `pgrep -x barrierc` returns no process on the Mac, the Mac
has no listener on `M1_024_LOCAL_PORT`, and the Barrier SSL fingerprint trust
directories on both hosts are listed (names only, privately) so the post-run
comparison can prove no new trust state. Dumpcap/Wireshark is only
version-checked; it is not used to capture.

## Capture-time environment metadata, recorded before capture

Issue #17 requires the build, OS, hardware, network, keyboard layout, display
and peer metadata to be recorded before the test matrix runs. The producer
therefore queries and writes down all of the following before the client starts,
and only non-sensitive values are kept. A capture whose metadata was recorded
afterwards does not satisfy this plan, and the correct remedy is to record the
metadata first and repeat the identical procedure, not to claim the earlier run
retroactively.

| Fact | Capture host source | Peer source |
|---|---|---|
| Model and processor | `system_profiler SPHardwareDataType` model name, model identifier, chip, core split | `lscpu` model name and logical CPU count |
| Memory | Same hardware report | Reported total memory in bytes |
| CPU architecture | `uname -m` | `uname -m` |
| Keyboard layout | Active input source identifier | `setxkbmap -query` rules, model, layouts, variants |
| Display | Combined desktop coordinate bounds | `xdpyinfo` display name, pixel dimensions, physical dimensions, resolution |
| Network | Single encrypted local forward to the peer loopback; no address value is kept | Same single path |
| Peer product versions | `barrierc --version` | `barriers --version` |

Two limits are part of the rule, not commentary:

- An active input source identifier is a logical selection, so the physical
  keyboard layout is recorded as not captured rather than derived from it.
- Combined desktop bounds prove the combined coordinate layout only, so
  individual display models and resolutions stay unrecorded unless they were
  themselves reported before capture.

`evidence/issues/M1-024/environment.json` records these values together with
`preCaptureMetadata.recordedBeforeCapture`, the accepted attempt, and who
recorded them; the repository validator fails closed when that block is missing
or incomplete.

## Capture phases

All raw artifacts are written only to the private directories. The capture
window is bounded: at most 15 seconds from client start to client TERM.

1. Private dirs. Create `M1_024_MAC_PRIVATE_DIR` and
   `M1_024_PEER_PRIVATE_DIR` with `mktemp -d` and `chmod 700`.
2. Peer config. Write a Barrier server config in the peer private dir that
   declares exactly the screens `m1-server` and `m1-client` and no links, so no
   screen switch is possible.
3. Start tcpdump on the peer loopback, invoked directly and unprivileged through
   its file capabilities, never through `sudo` (background, pid file, stderr log
   in the private dir):
   `tcpdump -i lo -U -s 0 -n -w "$M1_024_PEER_PRIVATE_DIR/raw.pcap" "tcp port $M1_024_REMOTE_PORT"`
   Wait until its log shows it is listening on `lo`. Classic pcap output is
   required; pcapng is rejected later.
4. Start the server on the peer, loopback only:
   `barriers --no-daemon --disable-crypto --name m1-server --address "localhost:$M1_024_REMOTE_PORT" --config "$M1_024_PEER_PRIVATE_DIR/barrier.conf"`
   (background, pid file, log in the private dir). Verify with
   `ss -Htln "sport = :$M1_024_REMOTE_PORT"` that every listening address is
   loopback. If the server cannot start for any reason, including a missing
   display session, stop and report; do not add unlocked tools.
5. Open the tunnel on the Mac:
   `ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -L "localhost:$M1_024_LOCAL_PORT:localhost:$M1_024_REMOTE_PORT" "$M1_024_SSH_TARGET"`
   (background, pid recorded). Verify the Mac listener on
   `M1_024_LOCAL_PORT` is loopback only.
6. Start the client on the Mac:
   `barrierc --no-daemon --disable-crypto --name m1-client "localhost:$M1_024_LOCAL_PORT"`
   (background, pid recorded, log in the Mac private dir). Nobody types, moves
   the pointer, copies to a clipboard or triggers a screen switch on either host
   during the window.
7. Stop, in this order, each with TERM, then KILL if the process is still alive
   after 5 seconds: client `barrierc`, server `barriers`, `tcpdump`, SSH tunnel.
8. Transfer the raw pcap to `M1_024_MAC_PRIVATE_DIR` over SSH, compare SHA-256
   of both copies privately, and keep both until the deletion phase.

The SSH tunnel encrypts traffic between hosts; the observed plaintext exists
only on the peer loopback between the SSH daemon and `barriers`, which is why
the capture is on `lo`.

## Cleanup verification

All must hold before sanitization proceeds; any failure stops M1-024 and is
reported, never retried until success without root cause.

- Peer: `pgrep -x barriers` and `pgrep -x tcpdump` return nothing;
  `ss -Htln "sport = :$M1_024_REMOTE_PORT"` returns nothing.
- Mac: `pgrep -x barrierc` returns nothing; the recorded tunnel pid is gone;
  `lsof -nP -iTCP:"$M1_024_LOCAL_PORT" -sTCP:LISTEN` returns nothing.
- No stuck key or button and no suppressed local input on the Mac: keyboard and
  pointer respond normally, and no modifier is latched.
- No leaked trust state: the Barrier SSL fingerprint trust directories on both
  hosts match their preflight listing, and no new Accessibility or Input
  Monitoring grant was created for the capture.

## Sanitizer algorithm

The sanitizer is a temporary tool authored by the Claude implementation-author
session outside the repository, in `M1_024_MAC_PRIVATE_DIR`, for the locked
system Python 3.9.6. It is written from the public pcap, Ethernet, IPv4, IPv6
and TCP specifications only, not from Barrier source. Root authors none of its
code: root reviews it against this plan and then executes it; any required
change goes back to the implementation author. It is not an Exact File and is
never committed; its SHA-256 is recorded in `commands.json`. Before use, root
executes it against private synthetic inputs, and it must reject them for every
failure rule below, with results recorded in `manual.md`.

Input: the raw pcap and the server test port. Output: `handshake-capture.json`.

1. Read the classic pcap global header. Accept only magic `a1b2c3d4` or
   `d4c3b2a1` (microsecond), version 2.4, link type 1 (Ethernet). Reject pcapng,
   nanosecond, any other link type, a short header or trailing partial record.
2. For each record in file order: reject if `incl_len != orig_len`, if the
   record is truncated, or if the Ethernet type is not IPv4 or IPv6.
3. IPv4: reject bad version or header length, total length inconsistent with the
   record, any fragment (MF set or non-zero offset), or protocol other than TCP.
   IPv6: reject payload length inconsistent with the record or any next header
   other than TCP (extension headers are unsupported). Checksums are not
   validated because loopback checksum offload makes them unreliable.
4. TCP: reject a data offset below 5 or past the segment. Map direction by the
   server test port only: source port equal to it is `server-to-client`,
   destination port equal to it is `client-to-server`, neither or both is a
   rejection.
5. Exactly one TCP connection (one endpoint 4-tuple) may appear; any second
   connection, reconnect or unrelated flow is a rejection.
6. Both SYNs must be present to establish each direction's initial sequence
   number. For each payload-bearing segment, the sequence number must equal the
   next expected sequence number of its direction. Lower (retransmission or
   overlap), higher (gap), payload before SYN, payload after FIN or RST, or a
   payload-bearing RST is a rejection. Zero-length ACK, FIN and RST segments
   carry no payload and are skipped.
7. Keep only TCP payload bytes. Discard every timestamp, address, port, link,
   IP and TCP header field, option and flag. Append bytes in capture order;
   consecutive same-direction bytes join one observation, and a direction change
   starts the next observation. Bytes are never modified, redacted, decoded or
   interpreted.
8. Reject if there are no observations, if either direction is absent, if any
   observation exceeds 65536 bytes, or if the total exceeds 262144 bytes. An
   oversized run is rejected, never split.
9. Emit the closed JSON document below with standard RFC 4648 base64 including
   padding, no line breaks, in deterministic `json.dumps(..., indent=2)` form
   plus a trailing newline.
10. Privacy scan: search the decoded bytes, case-insensitively, for every entry
    in `M1_024_PRIVATE_DENYLIST`. Any hit rejects the fixture. The payload is
    never edited to remove a hit; the capture is discarded and investigated.

Any rejection produces no fixture. The sanitizer never guesses.

## Sanitized fixture format

`Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json` is
a closed object with exactly these keys:

```json
{
  "schemaVersion": 1,
  "captureId": "m1-024-linux-client-handshake",
  "encoding": "base64",
  "observations": [
    {
      "sequence": 1,
      "direction": "server-to-client",
      "applicationPayloadBase64": "<canonical base64>"
    }
  ]
}
```

Rules checked by the repository validator:

- no key beyond the four top-level keys; each observation has exactly
  `sequence`, `direction`, `applicationPayloadBase64`;
- `sequence` is an integer, contiguous and 1-based in array order;
- `direction` is `server-to-client` or `client-to-server`, and both appear;
- `applicationPayloadBase64` is canonical: it decodes strictly and re-encodes to
  the identical string;
- each decoded observation is 1..65536 bytes and the decoded total is at most
  262144 bytes;
- no timestamp, address, host name, port, TCP metadata, text decoding, field,
  message, endianness, semantic or compatibility content anywhere.

The example direction above is a placeholder, not a statement about which peer
sends first.

## Fixture metadata

`Tests/Fixtures/Barrier/m1-024-linux-client-handshake/metadata.json` must follow
`Tests/Fixtures/fixture-metadata.schema.json` exactly with no additional keys:

- `schemaVersion`: `1`
- `fixtureId`: `m1-024-linux-client-handshake`
- `protocol`: `barrier`
- `provenance.sourceKind`: `black-box-capture`
- `provenance.reference`: a single string naming this plan, the external
  `barrierc` 2.4.0-release to `barriers` 2.4.0-release protocol 1.6 observation,
  and that TLS was disabled for the observation only; no host, address, user or
  path containing a user name. `provenance.capturedAt` is omitted.
- `payload.path`: `handshake-capture.json`
- `payload.sha256`: lowercase SHA-256 of the exact bytes of
  `handshake-capture.json` as they stand in the tree
- `payload.byteLength`: exact byte length of that file
- `sanitization.status`: `sanitized`
- `sanitization.containsSensitiveData`: `false`
- `sanitization.removedCategories`: `["ip-address", "other-private-data"]`
  (addresses, ports, timestamps, link, IP and TCP metadata were removed; no
  typed text or clipboard data was generated)

## Repository validator and result generator

`Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh` is a
local-only validator and result generator written for bash 3.2, run by
`make e2e ISSUE=M1-024` through `Tools/Evidence/run_e2e.py`. It never invokes
`ssh`, `scp`, `tcpdump`, `dumpcap`, `barrierc`, `barriers` or any network or
capture operation, and it never reads the private directories.

It must:

1. validate `handshake-capture.json` against every rule in the fixture format;
2. validate `metadata.json` against the metadata schema rules and recompute the
   payload SHA-256 and byte length;
3. scan every Exact File present in the tree for the identifying patterns used
   by `Tests/Contracts/test_m1_024_capture_readiness.py` (IPv4, IPv6, user
   paths, email, local host names, certificate fingerprints, PEM material,
   tokens), allowing only the metadata `payload.sha256` value. The eleven
   implementation-author files are always required and a missing one fails
   closed; `independent-review.md` is the twelfth Exact File and is scanned by
   the same rules as soon as it exists, so the validator must not require it
   before the reviewer creates it;
4. fail if the repository tracks any `.pcap` or `.pcapng` file;
5. fail, and never report `not_executed`, when a fixture file is missing;
6. write `evidence/e2e/M1-024/result.json` at `$MACKVM_E2E_RESULT` in the form
   accepted by `Tools/Evidence/validate_evidence.py`, then exit 0 only when
   every check passed.

For negative testing only, an optional `M1_024_FIXTURE_ROOT` may point at a
private mutated copy of the fixture directory; when it is set the script writes
no result file and reports only through its exit code.

## Commit provenance

M1-024 lands in two commits: the implementation commit first, the review commit
afterwards. The author phase and the review phase are therefore recorded against
different commits, and the validator must encode that difference rather than
flatten it.

- `commands.json`, `environment.json` and `tests/e2e-validation.json` carry
  `repositoryHeadAtAuthorRun`: the repository head the implementation author ran
  every recorded check over, with the eleven implementation-author Exact Files
  still uncommitted. No author-phase record may call that value the
  implementation commit.
- The validator requires it to be a full lowercase commit id that is an ancestor
  of, or equal to, the current head, checked read-only with
  `git merge-base --is-ancestor`. A regex alone is not sufficient, and exact
  equality with the current head must not be required: committing the eleven
  implementation-author Exact Files necessarily moves the head, so an equality
  rule would leave the resulting PR and CI tree permanently unable to pass its
  own gate.
- Fail closed on anything else. A malformed value, a value git cannot resolve,
  an unavailable or failing git invocation, and a real commit outside the
  current history are each a rejection that writes no result.
- `evidence/e2e/M1-024/result.json` is generated, so it continues to carry the
  exact current head of the E2E execution that produced it.

After root commits the eleven implementation-author Exact Files, that commit is
the implementation commit, and it contains exactly those eleven files.
`independent-review.md` is the twelfth Exact File; it does not exist yet and is
therefore not in that commit. The fresh independent reviewer then runs against
the implementation commit, creates `independent-review.md` and records that
exact SHA in it; the reviewer's own E2E run regenerates `result.json` against
the implementation commit, before the separate review commit that carries the
twelfth file exists.

## RED commands

First red phase, on the tree before any M1-024 implementation file existed,
from `2026-09-29T23:19:10.755Z` to `2026-09-29T23:19:10.907Z`:

| Command | Observed |
|---|---|
| `make e2e ISSUE=M1-024` | prints `e2e error: script_root_missing`; runner prints `e2e disposition: error` and `e2e exit: 66`; Make itself exits 2 |
| `python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-024/result.json` | non-zero exit, because the result is absent |

The error is `script_root_missing`, not `script_missing`, because the directory
`Tests/SystemTests/Scripts` did not yet exist in the tree, so the runner stopped
before looking up the M1-024 script. The runner's own exit code is 66; Make
reports the failed recipe with its own exit status 2.

Second red phase, after the first incomplete system script existed and before
the fixture pair existed in the tree, from `2026-09-29T23:29:49.455Z` to
`2026-09-29T23:29:49.639Z`:

| Command | Observed |
|---|---|
| `make e2e ISSUE=M1-024` | script exits 1 because the fixture is absent; runner prints `e2e disposition: script_failed`; Make exits 2; no result is generated |

`bash -n` over the system script and `git diff --check` both exited 0 at that
incomplete-script stage, so the red phase was a missing input and not a syntax
or whitespace defect.

Mutation checks, each with `M1_024_FIXTURE_ROOT` pointing at a private mutated
copy of the fixture directory outside the repository, each expected to exit
non-zero and write no result:
`bash Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh`
against an unknown top-level key, an unknown observation key, a sequence gap, a
sequence starting at 0, an unknown direction, a single-direction fixture,
non-canonical padded base64, an empty observation, a 65537-byte observation, a
total above 262144 bytes, an embedded address literal in the decoded payload, a
metadata hash mismatch, a metadata length mismatch, an extra metadata key, and a
missing payload file. A control run against an unmutated private copy must be
accepted and must still write no result.

Provenance rules are only reachable in the normal repository mode, so three
further mutation checks run `make e2e ISSUE=M1-024` against a temporarily
mutated `repositoryHeadAtAuthorRun`, restoring the original bytes afterwards:
a value that is not a full commit id, a well-formed value git cannot resolve,
and a real repository commit that is not an ancestor of the current head. Each
must exit non-zero and leave no result file.

## GREEN commands

After the fixture and evidence are complete, all must exit 0:

```bash
bash -n Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh
make e2e ISSUE=M1-024
python3 Tools/Evidence/validate_evidence.py evidence/e2e/M1-024/result.json
python3 Tools/Backlog/validate_package.py
make architecture-check
make docs-check
python3 -m unittest discover -s Tests/Contracts -p 'test_m1_024_capture_readiness.py'
git diff --check
```

`make e2e ISSUE=M1-024` must print `e2e disposition: passed` and `e2e exit: 0`.
`git status --porcelain` must show changes only in the eleven
implementation-author Exact Files; `independent-review.md` does not exist during
the author phase.

## Evidence matrix (M1-024 Exact Files)

| # | File | Writer | Content | Gate |
|---|---|---|---|---|
| 1 | `Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md` | Implementation author | This plan | Reviewer confirms phases, sanitizer and non-claims were followed |
| 2 | `Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh` | Implementation author | Local-only validator and result generator | RED mutation checks fail; GREEN passes; no SSH or capture call |
| 3 | `evidence/e2e/M1-024/README.md` | Implementation author | How to rerun the validator; states no capture is rerun by it | Privacy scan clean |
| 4 | `evidence/e2e/M1-024/result.json` | Generated by the script | E2E result | `validate_evidence.py` exits 0 |
| 5 | `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/metadata.json` | Implementation author | Metadata per schema | Schema, hash and length verified by the script |
| 6 | `Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json` | Producer bytes, copied verbatim into the working tree by the author for root to commit | Sanitized observations | SHA-256 equals the producer's private value; closed-format rules pass |
| 7 | `evidence/issues/M1-024/summary.md` | Implementation author | Outcome, non-claims, TLS disabled for observation, Windows not executed, rollback | Privacy scan clean |
| 8 | `evidence/issues/M1-024/commands.json` | Implementation author | Every preflight, capture, cleanup, sanitizer and validation command with placeholder names and exit codes; sanitizer SHA-256 | No real values |
| 9 | `evidence/issues/M1-024/tests/e2e-validation.json` | Implementation author from tool output | RED and GREEN command outputs and exit codes | Values copied from actual tool output |
| 10 | `evidence/issues/M1-024/environment.json` | Implementation author | Observed locked versions, the capture-time host and peer metadata recorded before capture, the bounded window, TLS disabled for observation, Windows not executed | Matches the lock exactly; window arithmetic agrees with its own timestamps; no host identity |
| 11 | `evidence/issues/M1-024/manual.md` | Implementation author from producer report | Manual steps, sanitizer negative self-tests, cleanup verification, raw deletion confirmation | No path, host, user or port values |
| 12 | `evidence/issues/M1-024/independent-review.md` | Independent reviewer only, after the implementation commit, in a separate review commit | Review verdict against the privacy and review gates | Reviewer is neither producer nor author |

Rows 1-11 are the implementation-author Exact Files and are the entire content
of the implementation commit. Row 12 is created only later by the reviewer and
lands in the separate review commit.

## Privacy and review gates

Before the PR is opened:

- The script's identifying-pattern scan and the private denylist scan both pass
  over every Exact File present in the tree and the decoded payload. During the
  author phase that is the eleven implementation-author files;
  `independent-review.md` joins the same scan once the reviewer has created it.
- No raw pcap, peer config or log is in the repository or its history.
- No file contains a real host name, address, user name, path containing a user
  name, SSH target, port value, credential, key, token, certificate identity,
  certificate fingerprint, typed text or clipboard content.

The independent reviewer verifies and records in `independent-review.md`:

- roles were separated as defined in Roles;
- every locked version in `environment.json` equals the lock;
- the fixture and metadata pass the closed rules and the hash matches;
- no document claims field meaning, message code, endianness, semantics,
  compatibility, security or a Windows result;
- no Barrier or other GPL source is present or referenced as copied;
- cleanup verification and raw deletion are recorded;
- RED and GREEN outputs are real tool output.

Registration of the fixture as approved evidence is out of scope here and
belongs to corrective Issue #249.

## Raw artifact deletion

Raw pcap, peer config and logs stay in the private directories and are deleted
only after the sanitized fixture is verified: the repository validator passes
and the fixture SHA-256 in the tree equals the producer's private value. Then:

- delete `M1_024_PEER_PRIVATE_DIR` and `M1_024_MAC_PRIVATE_DIR` with `rm -rf`;
- confirm each with `test ! -e`;
- record only "deleted and confirmed" per host in `manual.md`.

If verification fails, the raw data is kept privately until root cause is found,
then deleted; it is never committed.

Deletion is performed by the capture producer, not by the implementation author.
Until the producer confirms it, `manual.md` records the raw artifacts as
retained privately and claims no deletion.

## Rollback

- Revert the M1-024 PR; this removes the fixture, metadata, script, result and
  evidence. No product code, lock, ADR or schema is changed by M1-024.
- Delete any remaining private directories and confirm deletion.
- Re-run cleanup verification on both hosts.
- Keep #249, M1-025 and every Barrier codec Issue blocked until a replacement
  fixture passes this plan.

## Limitations

- One capture of one external version pair on one locked host pair; it
  represents nothing beyond that observation.
- The observation ran with TLS disabled; payload under TLS was not observed.
- The window is bounded to the connection handshake; no input, clipboard or
  screen-switch traffic is captured.
- Checksums are not validated; captures needing IP fragments, IPv6 extension
  headers, pcapng or retransmission handling are rejected rather than supported.
- Direction-run observation boundaries depend on capture order and carry no
  message meaning.
- `barriers` may require a display session on the peer; if unavailable, capture
  stops rather than adding unlocked tools.
- Windows is unexecuted in M1.
