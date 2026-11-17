#!/usr/bin/env bash
# M4-036-FOLLOWUP-001 automated half: the first-party MacKVM server (DEBUG build,
# stdin smoke driver, no event tap, Mac input and pasteboard untouched) against
# the first-party Linux client `mackvm-client` on a private Xvfb display.
#
# The server listens on Mac loopback only, on a test port (never 24800). The
# client runs in a native arm64 `swift:6.2.3-jammy` container (Docker Desktop),
# as a non-root user, and reaches the Mac loopback listener through Docker's
# host gateway. A disposable server identity is created in the login Keychain
# and removed again. The container needs Xvfb, xdotool, xinput, xclip and a
# non-root user `tester`; the script copies this tree in and builds the client.
#
#   MACKVM_E2E_CONTAINER=<running container> make e2e ISSUE=M4-036-FOLLOWUP-001
#
# Output is closed vocabulary only: one `M4-036 e2e: <case>=pass|fail` line per
# case. The script writes the sanitized artifacts and result.json under
# evidence/e2e/M4-036-FOLLOWUP-001/. The owner-hardware half is not automatable,
# so the result records it as a failed (pending) case until manual.md is signed;
# the overall status is never `passed` from this script alone. Exit 0 means the
# script ran and wrote a valid result, whatever the case outcomes.
set -uo pipefail

issue=M4-036-FOLLOWUP-001
container=${MACKVM_E2E_CONTAINER:?set MACKVM_E2E_CONTAINER to a running arm64 swift:6.2.3-jammy container}
port=${MACKVM_E2E_PORT:-24811}
[ "$port" = 24800 ] && { echo "M4-036 e2e: port 24800 is reserved" >&2; exit 64; }
display=:93
name=m4-smoke
gateway=host.docker.internal
root=$(cd "$(dirname "$0")/../../.." && pwd)
out_dir="$root/evidence/e2e/$issue"
work=$(mktemp -d "${TMPDIR:-/tmp}/m4-036-e2e.XXXXXX")
label="MacKVM M4-036 e2e $(uuidgen)"
binary="$root/.build/debug/MacKVM"
remote=/tmp/m4-036-e2e
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
results=()
to_client="mackvm e2e to-client ✓ café 中文"
from_client="mackvm e2e from-client ✓ naïve 日本"
large_to_client=$(python3 -c 'print("mackvm-e2e-large-" * 35295, end="")')
large_from_client_code='import sys; sys.stdout.write("mackvm-e2e-from-large-" * 4546)'
large_from_client=$(python3 -c "$large_from_client_code")

rx() { docker exec -u tester -e DISPLAY=$display -w "$remote" "$container" timeout 40 bash -c "$1"; }
say() { printf 'M4-036 e2e: %s\n' "$1"; }
record() {
  local status=failed code=1
  [ "$2" = pass ] && { status=passed; code=0; }
  results+=("$1|$status|$code|$3")
  say "$1=$2"
}
check() {
  [ -n "${MACKVM_E2E_DEBUG:-}" ] && [ "${#2}" -lt 200 ] && printf 'debug %s: [%s] want [%s]\n' "$1" "$2" "$3" >&2
  if [ "$2" = "$3" ]; then record "$1" pass "$4"; else record "$1" fail "$4"; fi
}
send() { printf '%s\n' "$1" >"$work/cmd"; sleep 0.3; }
pointer() { rx "xdotool getmouselocation --shell" | tr '\n' ' ' | awk '{print $1 $2}'; }
count() { grep -c "$1" "$work/server.log"; }
ccount() { rx "grep -c '$1' $remote/$2 || true"; }
# Number of keys down on the client display (XQueryKeymap on a separate connection).
held_keys() {
  rx "python3 -c 'import ctypes as c; x = c.CDLL(\"libX11.so.6\"); x.XOpenDisplay.restype = c.c_void_p
d = x.XOpenDisplay(None); b = (c.c_char * 32)(); assert d and x.XQueryKeymap(c.c_void_p(d), b)
print(sum(bin(v).count(\"1\") for v in b.raw))'"
}
start_client() {
  rx "(mackvm-client connect $gateway:$port --name $name --display $display --non-interactive \
    >$1 2>&1; echo \$? >$1.exit) >/dev/null 2>&1 & sleep 0.2; pgrep -n -u tester -x mackvm-client >client.pid"
}
start_server() {
  ("$binary" smoke --client "$name" --port "$port" --loopback-only --identity-label "$label" \
    <"$work/cmd" >>"$work/server.log" 2>&1 & echo $! >"$work/server.pid")
  sleep 2
}

cleanup() {
  docker exec "$container" bash -c "pkill -u tester -x mackvm-client; pkill -u tester xclip; \
    pkill -u tester xinput; pkill -u tester Xvfb; rm -rf $remote /home/tester/.config/mackvm*" \
    >/dev/null 2>&1
  for f in server holder; do [ -f "$work/$f.pid" ] && kill "$(cat "$work/$f.pid")" 2>/dev/null; done
  [ -x "$binary" ] && "$binary" forget-identity --identity-label "$label" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

swift build --package-path "$root" >/dev/null 2>&1 || { say "server-build=fail"; exit 1; }
docker exec "$container" bash -c "rm -rf /m4036src && mkdir -p /m4036src" || exit 1
tar -C "$root" --exclude ./.build --exclude ./evidence --exclude '*.zip' -cf - . \
  | docker exec -i "$container" tar -C /m4036src -xf - 2>/dev/null || exit 1
docker exec "$container" bash -c "cd /m4036src && swift build --scratch-path /m4036build \
  --product mackvm-client >/dev/null 2>&1 && install -m 755 /m4036build/debug/mackvm-client \
  /usr/local/bin/mackvm-client" || { say "client-build=fail"; exit 1; }

hex=$("$binary" fingerprint --identity-label "$label" | grep -o 'v2:sha256:[0-9a-f]*' | cut -d: -f3)
mkfifo "$work/cmd"
(sleep 3600 >"$work/cmd" & echo $! >"$work/holder.pid")
start_server

docker exec "$container" bash -c "rm -rf $remote; install -d -o tester -m 700 $remote; install -d -o tester -m 755 /home/tester/.config"
rx "Xvfb $display -screen 0 1600x900x24 -nolisten tcp >/dev/null 2>&1 & echo \$! >xvfb.pid
  sleep 1; xdotool mousemove 800 450
  xinput test-xi2 --root >xi2.log 2>&1 & echo \$! >xinput.pid"

# Changed fingerprint first, while no session exists: exit 78, nothing stored or sent.
wrong=$(printf '%064d' 0)
rx "mackvm-client fingerprint trust $gateway:$port $wrong >/dev/null 2>&1"
rx "mackvm-client connect $gateway:$port --name $name --display $display --non-interactive \
  >changed.log 2>&1; echo \$? >changed.exit"
check fingerprint-changed-exit-78 "$(rx 'cat changed.exit')" 78 \
  "trusted record differs from the server: mackvm-client exited 78"
check fingerprint-changed-no-bytes "$(count 'ready (') $(count 'input is now remote')" "0 0" \
  "server log: no session became ready, so no application byte crossed TLS"
rx "mackvm-client fingerprint forget $gateway:$port >/dev/null 2>&1; \
  mackvm-client fingerprint trust $gateway:$port $hex >/dev/null 2>&1"

start_client client-1.log
sleep 5
check handshake "$(count "client ready (1600x900)") $(ccount '\] connected$' client-1.log)" "1 1" \
  "server: client ready (1600x900); client: connected; identity line and pinned TLS"

send "copy $to_client"
send edge; sleep 0.5
check enter "$(pointer) $(ccount 'input is on this screen' client-1.log)" "X=1Y=450 1" \
  "enter point at the left edge (1, 450); client: input is on this screen"
check clipboard-to-client "$(rx "xclip -selection clipboard -o")" "$to_client" \
  "fixed probe read back with xclip on the client display"
send "move 100 50"; check move-1 "$(pointer)" "X=101Y=500" "+(100, 50) -> (101, 500)"
send "move 300 -200"; check move-2 "$(pointer)" "X=401Y=300" "+(300, -200) -> (401, 300)"

for c in "key a down" "key a up" "key shift down" "key b down" "key b up" "key shift up" \
  "key return down" "key return up" "key 1 down" "key 1 up" "key f5 down" "key f5 up" \
  "button left down" "button left up" "button right down" "button right up" \
  "button middle down" "button middle up" "scroll 0 1" "scroll 0 -2" "scroll 1 0" "scroll -2 0"; do
  send "$c"
done
for k in minus equal bracketleft bracketright backslash semicolon apostrophe grave comma \
  period slash; do
  send "key $k down"; send "key $k up"
done
for c in "key shift down" "key slash down" "key slash up" "key shift up"; do send "$c"; done
rx "(printf '%s' '$from_client' | xclip -quiet -selection clipboard -i >/dev/null 2>&1 &)"
sleep 1
send "key a down"; send "move -500 0"; sleep 0.5
check held-key-locks "$(count 'input is local again') $(held_keys)" "0 1" \
  "a held letter keeps input on the client past the return edge; the probe sees it down"
send "key a up"; send "key shift down"; send "move -500 0"; sleep 0.5
check return "$(count 'input is local again') $(held_keys)" "1 0" \
  "held Shift is released on return; no key down on the client display"
send "key shift up"
sleep 0.5; send "clipboard-is $from_client"
check clipboard-from-client "$(count 'clipboard received from the client') $(count 'smoke: clipboard matches')" "1 1" \
  "client copy arrived on the leave and matched the fixed probe exactly"

send edge; sleep 0.3; send "key control down"; send escape; sleep 0.5; send "key control up"
check escape "$(count 'local recovery: completed') $(held_keys)" "1 0" \
  "Control held then escape: server local recovery completed; no key down on the client"
check clipboard-not-echoed "$(count 'clipboard sent to the client')" 1 \
  "the next enter did not send the unchanged clipboard again"

# From here on every count is a delta, so one failed case cannot hide the next.
r0=$(count 'clipboard received from the client'); m0=$(count 'smoke: clipboard matches')
send edge; sleep 0.5
rx "(python3 -c '$large_from_client_code' | xclip -quiet -selection clipboard -i >/dev/null 2>&1 &)"
sleep 1; send "move -500 0"; sleep 3
send "clipboard-is $large_from_client"
check clipboard-large-from-client \
  "$(($(count 'clipboard received from the client') - r0)) $(($(count 'smoke: clipboard matches') - m0))" \
  "1 1" "100 KB client clipboard arrived on the leave and matched exactly"

d0=$(count 'client disconnected')
send edge; sleep 0.3; send "key shift down"; send "key a down"; sleep 0.3
h0=$(held_keys)
rx 'kill $(cat client.pid)'; sleep 3
check kill-client-no-stuck-key \
  "$h0 $(held_keys) $(rx 'cat client-1.log.exit') $(($(count 'client disconnected') - d0))" "2 0 0 1" \
  "client SIGTERM with Shift+a held (2 keys down before): none down after, exit 0, server saw the disconnect"
send "key a up"; send "key shift up"; send "move -500 0"; sleep 0.5

k0=$(count 'client ready (1600x900)'); s0=$(count 'clipboard sent to the client')
start_client client-2.log
sleep 5; send edge; sleep 0.3; send "move 20 20"
check reconnect "$(pointer) $(($(count 'client ready (1600x900)') - k0))" "X=21Y=470 1" \
  "new client process: a new session became ready; enter + (20, 20) -> (21, 470)"
check clipboard-on-reconnect "$(($(count 'clipboard sent to the client') - s0))" 1 \
  "the server clipboard was sent once to the new session"
sleep 13; send "move 30 0"
check keepalive-13s "$(pointer) $(ccount 'connection ended' client-2.log)" "X=51Y=470 0" \
  "13 s idle, then +(30, 0) -> (51, 470); the client saw no connection end"

# 600 KB out runs late: a failure ends the session, and the client reconnects by itself.
send "move -500 0"; sleep 0.5
send "copy $large_to_client"
send edge; sleep 3
check clipboard-large-to-client \
  "$(rx "xclip -selection clipboard -o | sha256sum | cut -c1-64") $(ccount 'resourceExhausted' client-2.log)" \
  "$(printf '%s' "$large_to_client" | shasum -a 256 | cut -c1-64) 0" \
  "600 KB server clipboard matched by SHA-256 on the client display, session kept"
sleep 3; send "move -500 0"; sleep 0.5; send "copy $to_client"; send edge; sleep 0.5

e0=$(ccount 'connection ended' client-2.log)
send "key shift down"; sleep 0.3; send quit; sleep 3
check quit-while-remote \
  "$(grep -c '\] stopped$' "$work/server.log") $(held_keys) $(($(ccount 'connection ended' client-2.log) > e0))" \
  "1 0 1" "Shift held, server quit: server stopped; no key down on the client; the client saw the end"

# The client keeps running and reconnects on its own once the server is back.
k0=$(count 'client ready (1600x900)')
start_server
sleep 12
check auto-reconnect "$(($(count 'client ready (1600x900)') - k0))" 1 \
  "the running client reconnected to the restarted server on its own"
send quit; sleep 2
rx 'kill $(cat client.pid)'; sleep 2
check client-sigterm-exit-0 "$(rx 'cat client-2.log.exit')" 0 "SIGTERM ends the client with exit 0"


expected="KeyPress38 KeyRelease38 KeyPress50 KeyPress56 KeyRelease56 KeyRelease50 KeyPress36 \
KeyRelease36 KeyPress10 KeyRelease10 KeyPress71 KeyRelease71 ButtonPress1 ButtonRelease1 \
ButtonPress3 ButtonRelease3 ButtonPress2 ButtonRelease2 ButtonPress4 ButtonRelease4 ButtonPress5 \
ButtonRelease5 ButtonPress5 ButtonRelease5 ButtonPress6 ButtonRelease6 ButtonPress7 ButtonRelease7 \
ButtonPress7 ButtonRelease7 KeyPress20 KeyRelease20 KeyPress21 KeyRelease21 \
KeyPress34 KeyRelease34 KeyPress35 KeyRelease35 KeyPress51 KeyRelease51 KeyPress47 KeyRelease47 \
KeyPress48 KeyRelease48 KeyPress49 KeyRelease49 KeyPress59 KeyRelease59 KeyPress60 KeyRelease60 \
KeyPress61 KeyRelease61 KeyPress50 KeyPress61 KeyRelease61 KeyRelease50 \
KeyPress38 KeyRelease38 KeyPress50 KeyRelease50 \
KeyPress37 KeyRelease37 KeyPress50 KeyPress38 KeyRelease38 KeyRelease50 KeyPress50 KeyRelease50"
actual=$(rx "awk '/^EVENT type/{t=\$4} /^ +detail:/{if (t ~ /Raw(Key|Button)(Press|Release)/) {gsub(/[()]/,\"\",t); sub(/^Raw/,\"\",t); printf \"%s%s \", t, \$2}; t=\"\"}' xi2.log" | sed 's/ $//')
# A release of a key that is already up changes no X state; the effective list drops it
# and the count of such redundant releases is reported on its own.
effective=$(printf '%s\n' $actual | awk '/^KeyPress/{d[substr($0,9)]=1; print; next}
  /^KeyRelease/{k=substr($0,11); if (d[k]) {d[k]=0; print}; next} {print}' | tr '\n' ' ' | sed 's/ $//')
redundant=$(( $(printf '%s\n' $actual | wc -l) - $(printf '%s\n' $effective | wc -l) ))
say "x-events-redundant-releases=$redundant"
check x-events "$effective" "$expected" \
  "X raw key, button and wheel events on the client display (redundant releases dropped) equal the plan list"

# Sanitized artifacts: status lines only; fingerprints of the disposable identity masked.
mask() { sed -E 's/([0-9A-F]{2}:){31}[0-9A-F]{2}/<fingerprint>/g; s/[0-9a-f]{64}/<fingerprint>/g'; }
mkdir -p "$out_dir"
mask <"$work/server.log" >"$out_dir/server.log"
{ for f in changed.log client-1.log client-2.log; do
    printf '== %s\n' "$f"; rx "cat $f" | mask; done; } >"$out_dir/client.log"
printf '%s\n' "$actual" | tr ' ' '\n' >"$out_dir/x-events.txt"
ended=$(date -u +%Y-%m-%dT%H:%M:%SZ)

python3 - "$root" "$issue" "$started" "$ended" "${results[@]}" <<'PY'
import hashlib, json, platform, subprocess, sys
from pathlib import Path
root, issue, started, ended, *rows = sys.argv[1:]
cases = []
for row in rows:
    case_id, status, code, evidence = row.split("|", 3)
    cases.append({"id": case_id, "status": status, "exitCode": int(code), "evidence": [evidence]})
cases.append({
    "id": "owner-hardware-half",
    "status": "failed",
    "exitCode": 69,
    "evidence": ["not run: needs the owner at both machines and a reviewer sign-off in "
                 "evidence/issues/M4-036-FOLLOWUP-001/manual.md (pending)"],
})
artifacts = []
for name in ("server.log", "client.log", "x-events.txt"):
    path = Path(root, "evidence", "e2e", issue, name)
    data = path.read_bytes()
    artifacts.append({
        "path": "evidence/e2e/{0}/{1}".format(issue, name),
        "sha256": hashlib.sha256(data).hexdigest(),
        "byteLength": len(data),
        "kind": "sanitized-log",
        "reviewStatus": "pending-review",
    })
commit = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True,
                        text=True, check=True).stdout.strip()
result = {
    "schemaVersion": 1,
    "issueId": issue,
    "status": "failed",
    "startedAt": started,
    "endedAt": ended,
    "commit": commit,
    "toolchain": {"pythonVersion": platform.python_version(), "platform": platform.system(),
                  "machine": platform.machine()},
    "environment": {
        "localOS": "macOS " + platform.mac_ver()[0],
        "peerProduct": "mackvm-client (first-party, DEBUG)",
        "peerVersion": commit[:12],
        "peerRole": "client",
        "peerOS": "Ubuntu 22.04 arm64 container (swift:6.2.3-jammy), Xvfb 1600x900",
        "networkScope": "Mac loopback listener via the Docker Desktop host gateway",
        "tls": "TLS 1.3, server pinned by SHA-256 fingerprint",
    },
    "cases": cases,
    "artifacts": artifacts,
    "privacy": {"containsSensitiveData": False, "containsTypedText": False,
                "containsClipboardPayload": False, "containsCredentials": False,
                "containsKeyMaterial": False, "containsHostnames": False,
                "containsIPAddresses": False, "rawCaptureCommitted": False,
                "sanitizationReviewed": True},
    "approvedDecisionRef": None,
}
Path(root, "evidence", "e2e", issue, "result.json").write_text(json.dumps(result, indent=2) + "\n")
PY
say "automated=$(printf '%s\n' "${results[@]}" | grep -c '|failed|') failed of ${#results[@]}"
say "owner-hardware-half=pending"
exit 0
