# M4-036-FOLLOWUP-001 First-Party Mac Server → First-Party Linux Client E2E Plan

## Status

Two halves (docs/adr/M4-SCOPE-001-linux-client-first.md, step 6; issue #351):

- **Automated half**: `Tests/SystemTests/Scripts/M4-036-FOLLOWUP-001-linux-client-e2-e.sh`,
  run through `make e2e ISSUE=M4-036-FOLLOWUP-001`. It writes
  `evidence/e2e/M4-036-FOLLOWUP-001/result.json` and the sanitized logs beside it.
- **Owner-hardware half**: `evidence/issues/M4-036-FOLLOWUP-001/manual.md`, run by the
  owner at both machines and verified by a reviewer who is not the agent.

The script always records the hardware half as a pending case, so `result.json` is
never `passed` from the script alone. `result.json` becomes `passed` only when every
automated case passed, the owner completed `manual.md` and the reviewer signed it;
then the owner stops running `barrierc` (issue exit rule). The exact steps are in
"Sign-off" below.

## Automated half

### Topology

- Server: the MacKVM DEBUG build, `MacKVM smoke` (stdin smoke driver: no event tap, the
  Mac's input, cursor and pasteboard are never touched), `--loopback-only` on a test
  port (default 24811; 24800 is refused by the script), with a disposable identity in
  the login Keychain that the script removes.
- Client: the first-party `mackvm-client` (Apps/Linux/MacKVMClient), DEBUG, built by the
  script from the same tree inside a native arm64 `swift:6.2.3-jammy` container that has
  Xvfb, xdotool, xinput and xclip, the headers the client links against (`libx11-dev`,
  `libxtst-dev`, `libxrandr-dev`, `libxfixes-dev`, as in `make dist-linux`) and a
  non-root user `tester` (the client refuses root).
  It runs on a private Xvfb display `:93` (1600x900) and reaches the Mac loopback
  listener through the Docker Desktop host gateway; the server sees a loopback peer.
- The client's trust store is the container user's; it pins the disposable identity.
- No owner display, no owner `barrierc` and no LAN address is involved.

### Cases

Every probe is a fixed string or a fixed key list in the script. Output is one
closed-vocabulary `M4-036 e2e: <case>=pass|fail` line per case.

| Case id | Issue bullet | Pass condition |
| --- | --- | --- |
| `fingerprint-changed-exit-78` | changed fingerprint | a different trusted record → the client exits 78 |
| `fingerprint-changed-no-bytes` | changed fingerprint | server `connection refused before the handshake` once; no ready session, nothing remote |
| `handshake` | identity line, handshake | server `client ready (1600x900)`; client `connected` |
| `enter` | enter point | pointer at (1, 450); client `input is on this screen` |
| `clipboard-to-client` | clipboard in | fixed probe read back with xclip |
| `move-1`, `move-2` | moves | +(100, 50) → (101, 500); +(300, −200) → (401, 300) |
| `held-key-locks` | held-key lock | a held letter keeps input on the client past the return edge |
| `return` | held-key lock | a held Shift is released on return; no key down |
| `clipboard-from-client` | clipboard out | client probe matched exactly on the server |
| `escape` | escape | Control held, escape → server `local recovery: completed`; no key down |
| `clipboard-not-echoed` | clipboard | an unchanged clipboard is not sent again |
| `clipboard-large-from-client` | 100 KB in (client → server) | 100 KB client copy matched exactly |
| `kill-client-no-stuck-key` | kill with key held | SIGTERM with Shift+a held → no key down, exit 0, server saw the disconnect |
| `reconnect` | reconnect | a new client process gets a new session; enter + (20, 20) → (21, 470) |
| `clipboard-on-reconnect` | clipboard | the server clipboard is sent once to the new session |
| `keepalive-13s` | 13 s idle keepalive | after 13 s idle, +(30, 0) → (51, 470); no connection end |
| `clipboard-large-to-client` | 600 KB out (server → client) | SHA-256 match on the client display; no `connection ended` on the client and no `client disconnected` on the server during the case |
| `clipboard-later-to-client` | clipboard (#376) | a later small server clipboard is read back exactly with xclip, on the same session |
| `quit-while-remote` | quit while remote | Shift held, server quits → server `stopped`, no key down, client saw the end |
| `auto-reconnect` | reconnect | the running client reconnects by itself to the restarted server |
| `client-sigterm-exit-0` | — | SIGTERM ends the client with exit 0 |
| `x-events` | moves, key list, buttons, vertical and horizontal scroll | XI2 raw events equal the list below |

Expected raw events, in order: a; Shift+b; Return; 1; F5; buttons 1, 3, 2; wheel up
once (button 4), down twice (button 5); **horizontal**: `scroll 1 0` (positive deltaX =
left, M1-PROTOCOL-003) once as button 6, `scroll -2 0` twice as button 7; the eleven
punctuation keys; Shift+slash; then the held-key, escape, kill and quit probes. A
release of a key that is already up changes no X state; the check drops such
redundant releases and reports their count separately.

Counts after the first session are deltas, so one failed case does not mask the next.
The 600 KB case runs late because a failure there ends the session.

### Running

```sh
MACKVM_E2E_CONTAINER=<running arm64 swift:6.2.3-jammy container> make e2e ISSUE=M4-036-FOLLOWUP-001
```

`run_e2e.py` exits 1 (make reports 2) while the hardware half is pending, by design (fail
closed). The smoke driver's FIFO write gives up after 5 s and prints
`smoke-driver-write=timeout` if the server has died, so the run cannot hang.

## Owner-hardware half

`evidence/issues/M4-036-FOLLOWUP-001/manual.md` is the checklist: `barrierc` stopped and
disabled; trust from the fingerprint the Mac displays; M2-035 C1–C11; shifted
punctuation; Shift held at enter; Linux copy → Mac paste and Mac copy → Linux paste;
Linux suspend and resume with the pointer local; Mac sleep and wake; the
unknown-fingerprint prompt on first run; `systemd --user` start and stop; automatic
reconnect after a Linux reboot. Each case is bounded to 2 minutes. **The run stops at
the first safety failure** (stuck key or button, Mac input not restored, input going
to the wrong machine).

## Sign-off: how `result.json` becomes `passed`

The script never writes `passed`. After the owner run, the reviewer (not the agent)
promotes the committed `result.json` by hand, in this order, and only if all hold:

1. Every automated case in the committed `result.json` is `passed`, from a run at the
   commit recorded in `manual.md` or an ancestor of it with no change under
   `Apps/Linux`, `Packages` or this script since.
2. `manual.md` is complete: every P row `y`, every C and X row `pass`, operator and
   reviewer signature rows filled, verdict `accept`.
3. The reviewer has read the three sanitized logs listed under `artifacts`.

The edit changes only these fields (`validate_evidence.py` requires each of them for
`passed`):

- the `owner-hardware-half` case: `"status": "passed"`, `"exitCode": 0`, `"evidence":`
  `["owner run P1-P4, C1-C11 and X1-X10 pass; reviewer sign-off in evidence/issues/M4-036-FOLLOWUP-001/manual.md"]`
  (printable ASCII, at most 200 characters, no names);
- every entry in `artifacts`: `"reviewStatus": "reviewed"` (the `sha256` and
  `byteLength` stay as they are; the validator rehashes the files);
- the top level: `"status": "passed"`. `approvedDecisionRef` stays `null`.

```sh
python3 - <<'PY'
import json
p = "evidence/e2e/M4-036-FOLLOWUP-001/result.json"
d = json.load(open(p))
assert all(c["status"] == "passed" for c in d["cases"] if c["id"] != "owner-hardware-half")
for c in d["cases"]:
    if c["id"] == "owner-hardware-half":
        c.update(status="passed", exitCode=0, evidence=[
            "owner run P1-P4, C1-C11 and X1-X10 pass; reviewer sign-off in "
            "evidence/issues/M4-036-FOLLOWUP-001/manual.md"])
for a in d["artifacts"]:
    a["reviewStatus"] = "reviewed"
d["status"] = "passed"
open(p, "w").write(json.dumps(d, indent=2) + "\n")
PY
python3 Tools/Evidence/validate_evidence.py evidence/e2e/M4-036-FOLLOWUP-001/result.json \
  --expected-issue M4-036-FOLLOWUP-001 --require-passed
```

The validator must print `evidence valid: issue=M4-036-FOLLOWUP-001 status=passed`.
Commit the promoted `result.json` with the signed `manual.md` and record the
validator command and its output in `commands.json`. If any manual case is `fail` or
`not run`, nothing is promoted and `result.json` stays `failed`.

## Evidence rules

No typed text, clipboard content, addresses, host names or user names in any committed
file. Fingerprints of the disposable identity are masked in the logs. The owner run
records only pass/fail and closed-vocabulary notes.
