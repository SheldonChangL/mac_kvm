#!/usr/bin/env bash
# M2-035 automated smoke: the MacKVM server (DEBUG build, stdin smoke driver, no
# event tap, local input untouched) against a real Barrier 2.4 client on a Linux
# host reachable over SSH. The client runs on a private Xvfb display with its own
# profile directory, so the host's own barrierc, display and trust list are never
# touched. The server listens on loopback only and is reached through `ssh -R`.
# A disposable server identity is created in the login Keychain and removed again.
# The server's clipboard is the smoke driver's in-memory stand-in, never the Mac
# pasteboard; the client's is the Xvfb display's, read and set with xclip. The
# clipboard probes are the fixed strings below.
#
#   MACKVM_SMOKE_HOST=<ssh-alias> Tests/SystemTests/Scripts/M2-035-linux-smoke.sh
#
# Output is closed vocabulary only: one `M2-035 smoke: <case>=pass|fail` line per
# case and a final `M2-035 smoke: result=pass|fail`. Exit 0 only when all pass.
# Nothing written here contains addresses, host names, typed text or clipboard text.
set -uo pipefail

host=${MACKVM_SMOKE_HOST:?set MACKVM_SMOKE_HOST to the SSH alias of the Linux host}
port=${MACKVM_SMOKE_PORT:-24810}
display=${MACKVM_SMOKE_DISPLAY:-:93}
name=m2-smoke
root=$(cd "$(dirname "$0")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/m2-035-smoke.XXXXXX")
label="MacKVM M2-035 smoke $(uuidgen)"
binary="$root/.build/debug/MacKVM"
remote=""
failures=0
to_client="mackvm smoke to-client ✓ café 中文"
from_client="mackvm smoke from-client ✓ naïve 日本"

rssh() { timeout 40 ssh -o BatchMode=yes "$host" "$@"; }
say() { printf 'M2-035 smoke: %s\n' "$1"; }
check() {
  if [ "$2" = "$3" ]; then say "$1=pass"; else say "$1=fail"; failures=$((failures + 1)); fi
}
send() { printf '%s\n' "$1" >"$work/cmd"; sleep 0.3; }
pointer() { rssh "DISPLAY=$display xdotool getmouselocation --shell" | tr '\n' ' ' | awk '{print $1 $2}'; }
count() { grep -c "$1" "$work/server.log"; }

cleanup() {
  [ -n "$remote" ] && rssh "for f in barrierc wrong xclip xinput xvfb; do [ -f $remote/\$f.pid ] && kill \$(cat $remote/\$f.pid) 2>/dev/null; done; rm -rf $remote" >/dev/null 2>&1
  for f in server tunnel holder; do [ -f "$work/$f.pid" ] && kill "$(cat "$work/$f.pid")" 2>/dev/null; done
  [ -x "$binary" ] && "$binary" forget-identity --identity-label "$label" >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

swift build --package-path "$root" >/dev/null 2>&1 || { say "build=fail"; exit 1; }
hex=$("$binary" fingerprint --identity-label "$label" | grep -o 'v2:sha256:[0-9a-f]*' | cut -d: -f3)
check identity "${#hex}" 64

mkfifo "$work/cmd"
(sleep 3600 >"$work/cmd" & echo $! >"$work/holder.pid")
("$binary" smoke --client "$name" --port "$port" --loopback-only --identity-label "$label" \
  <"$work/cmd" >"$work/server.log" 2>&1 & echo $! >"$work/server.pid")
sleep 2
(ssh -o BatchMode=yes -o ExitOnForwardFailure=yes -N -R "127.0.0.1:$port:127.0.0.1:$port" "$host" \
  >/dev/null 2>&1 & echo $! >"$work/tunnel.pid")
sleep 3

remote=$(rssh 'mktemp -d /tmp/m2-035-smoke.XXXXXX')
rssh "set -e; cd $remote; mkdir -p profile/SSL/Fingerprints
  openssl req -x509 -nodes -days 1 -subj /CN=m2-smoke-client -newkey rsa:2048 \
    -keyout profile/SSL/Barrier.pem -out profile/SSL/Barrier.pem >/dev/null 2>&1
  printf 'v2:sha256:%s\n' $hex > profile/SSL/Fingerprints/TrustedServers.txt
  Xvfb $display -screen 0 1600x900x24 -nolisten tcp >/dev/null 2>&1 & echo \$! > xvfb.pid
  sleep 1; DISPLAY=$display xdotool mousemove 800 450
  DISPLAY=$display xinput test-xi2 --root > xi2.log 2>&1 & echo \$! > xinput.pid
  barrierc -f --no-tray --debug INFO --name $name --profile-dir $remote/profile \
    --display $display 127.0.0.1:$port > barrierc.log 2>&1 & echo \$! > barrierc.pid"
sleep 5
check handshake "$(grep -c "client ready (1600x900)" "$work/server.log")" 1
check fingerprint-pinned "$(rssh "grep -c 'Fingerprint matches trusted fingerprint' $remote/barrierc.log")" 1

send "copy $to_client"
send edge; sleep 0.5
check enter "$(pointer)" "X=1Y=450"
check clipboard-to-client "$(rssh "DISPLAY=$display xclip -selection clipboard -o")" "$to_client"
send "move 100 50"; check move-1 "$(pointer)" "X=101Y=500"
send "move 300 -200"; check move-2 "$(pointer)" "X=401Y=300"

for c in "key a down" "key a up" "key shift down" "key b down" "key b up" "key shift up" \
  "key return down" "key return up" "key 1 down" "key 1 up" "key f5 down" "key f5 up" \
  "button left down" "button left up" "button right down" "button right up" \
  "button middle down" "button middle up" "scroll 0 1" "scroll 0 -2"; do
  send "$c"
done
for k in minus equal bracketleft bracketright backslash semicolon apostrophe grave comma \
  period slash; do
  send "key $k down"; send "key $k up"
done
for c in "key shift down" "key slash down" "key slash up" "key shift up"; do send "$c"; done
rssh "cd $remote; (printf '%s' '$from_client' | DISPLAY=$display xclip -quiet -selection clipboard -i \
  >/dev/null 2>&1 & echo \$! > xclip.pid)"
sleep 1
send "key a down"; send "move -500 0"; sleep 0.5
check held-key-locks "$(grep -c 'input is local again' "$work/server.log")" 0
send "key a up"; send "key shift down"; send "move -500 0"; sleep 0.5
check return "$(grep -c 'input is local again' "$work/server.log")" 1
send "key shift up"
sleep 0.5; send "clipboard-is $from_client"
check clipboard-from-client "$(count 'clipboard received from the client') $(count 'smoke: clipboard matches')" "1 1"

send edge; sleep 0.3; send "key control down"; send escape; sleep 0.5; send "key control up"
check escape "$(grep -c 'local recovery: completed' "$work/server.log")" 1
check clipboard-not-echoed "$(count 'clipboard sent to the client')" 1

send edge; sleep 0.3; send "key shift down"
rssh "kill \$(cat $remote/barrierc.pid)"; sleep 2; send "key shift up"
check client-loss "$(grep -c 'client disconnected' "$work/server.log")" 1

rssh "barrierc -f --no-tray --debug INFO --name wrong-name --profile-dir $remote/profile \
  --display $display 127.0.0.1:$port > $remote/wrong.log 2>&1 & echo \$! > $remote/wrong.pid"
sleep 4; rssh "kill \$(cat $remote/wrong.pid)"
check wrong-name-rejected "$(grep -c 'trustRejected' "$work/server.log" | awk '{print ($1 > 0)}')" 1

rssh "barrierc -f --no-tray --debug INFO --name $name --profile-dir $remote/profile \
  --display $display 127.0.0.1:$port > $remote/barrierc.log 2>&1 & echo \$! > $remote/barrierc.pid"
sleep 5; send edge; sleep 0.3; send "move 20 20"
check reconnect "$(pointer)" "X=21Y=470"
check clipboard-on-reconnect "$(count 'clipboard sent to the client')" 2
sleep 13; send "move 30 0"
check keepalive "$(pointer)" "X=51Y=470"
send "key shift down"; send quit; sleep 2
check quit-while-remote "$(grep -c '^\[.*\] stopped$' "$work/server.log")" 1

expected="KeyPress38 KeyRelease38 KeyPress50 KeyPress56 KeyRelease56 KeyRelease50 KeyPress36 \
KeyRelease36 KeyPress10 KeyRelease10 KeyPress71 KeyRelease71 ButtonPress1 ButtonRelease1 \
ButtonPress3 ButtonRelease3 ButtonPress2 ButtonRelease2 ButtonPress4 ButtonRelease4 ButtonPress5 \
ButtonRelease5 ButtonPress5 ButtonRelease5 KeyPress20 KeyRelease20 KeyPress21 KeyRelease21 \
KeyPress34 KeyRelease34 KeyPress35 KeyRelease35 KeyPress51 KeyRelease51 KeyPress47 KeyRelease47 \
KeyPress48 KeyRelease48 KeyPress49 KeyRelease49 KeyPress59 KeyRelease59 KeyPress60 KeyRelease60 \
KeyPress61 KeyRelease61 KeyPress50 KeyPress61 KeyRelease61 KeyRelease50 \
KeyPress38 KeyRelease38 KeyPress50 KeyRelease50 \
KeyPress37 KeyRelease37 KeyPress50 KeyRelease50 KeyPress50 KeyRelease50"
actual=$(rssh "awk '/^EVENT type/{t=\$4} /^ +detail:/{if (t ~ /Raw(Key|Button)(Press|Release)/) {gsub(/[()]/,\"\",t); sub(/^Raw/,\"\",t); printf \"%s%s \", t, \$2}; t=\"\"}' $remote/xi2.log" | sed 's/ $//')
check x-events "$actual" "$expected"

if [ "$failures" -eq 0 ]; then say "result=pass"; exit 0; fi
say "result=fail"
exit 1
