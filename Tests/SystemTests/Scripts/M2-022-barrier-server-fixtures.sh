#!/usr/bin/env bash
# M2-022: replay the Barrier server-side fixture capture on an approved Ubuntu
# test host and rebuild the sanitized fixtures.
#
# Usage: M2-022-barrier-server-fixtures.sh <ssh-host-alias> <work-dir>
#
# Everything runs on the host's loopback and on throwaway virtual displays (see
# Tests/SystemTests/Plans/M2-022-barrier-server-fixtures.md). The remote
# temporary directory is removed on every path. Raw streams stay in <work-dir>
# and are never committed; only make_fixtures.py output is.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <ssh-host-alias> <work-dir>" >&2
  exit 64
fi
host="$1"
work="$2"
root="$(cd "$(dirname "$0")/../../.." && pwd)"
tools="$root/evidence/e2e/M2-022/tools"

mkdir -p "$work/run1" "$work/run2"
remote="$(ssh -o BatchMode=yes "$host" 'mktemp -d /tmp/m2cap-XXXXXX')"
cleanup() { ssh -o BatchMode=yes "$host" "rm -rf -- '$remote'" || true; }
trap cleanup EXIT

scp -q -o BatchMode=yes \
  "$tools/capture_server_input.py" "$tools/capture_client_clipboard_keepalive.py" \
  "$host:$remote/"
ssh -o BatchMode=yes "$host" "cd '$remote' && python3 -I capture_server_input.py '$remote/run1'"
ssh -o BatchMode=yes "$host" \
  "cd '$remote' && python3 -I capture_client_clipboard_keepalive.py '$remote/run2'"
scp -q -o BatchMode=yes "$host:$remote/run1/stream.jsonl" "$work/run1/stream.jsonl"
scp -q -o BatchMode=yes "$host:$remote/run2/stream.jsonl" "$work/run2/stream.jsonl"

python3 -I "$tools/make_fixtures.py" "$work/run1" "$work/run2" "$root/Tests/Fixtures/Barrier"
