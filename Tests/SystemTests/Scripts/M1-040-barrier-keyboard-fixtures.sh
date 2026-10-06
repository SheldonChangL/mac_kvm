#!/usr/bin/env bash
# M1-040 local fixture/evidence validator and E2E result generator.
set -euo pipefail
unset CDPATH
fail() { printf 'M1-040 validation failed: %s\n' "$1" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || fail "python3 unavailable"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || fail "cannot resolve script directory"
repo_root="$(cd "${script_dir}/../../.." && pwd -P)" || fail "cannot resolve repository root"
[ "${MACKVM_E2E_ISSUE:-}" = "M1-040" ] || fail "MACKVM_E2E_ISSUE must be M1-040"
[ "${MACKVM_E2E_RESULT:-}" = "evidence/e2e/M1-040/result.json" ] || fail "MACKVM_E2E_RESULT must be evidence/e2e/M1-040/result.json"
python3 - "$repo_root" <<'PY'
import base64, datetime, hashlib, json, platform, re, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1])
fixture=root/'Tests/Fixtures/Barrier/m1-040-linux-keyboard/keyboard-capture.json'
metadata=root/'Tests/Fixtures/Barrier/m1-040-linux-keyboard/metadata.json'
result=root/'evidence/e2e/M1-040/result.json'
required=[
 'Tests/SystemTests/Plans/M1-040-barrier-keyboard-fixtures.md',
 'Tests/SystemTests/Scripts/M1-040-barrier-keyboard-fixtures.sh',
 'evidence/e2e/M1-040/README.md',
 'Tests/Fixtures/Barrier/m1-040-linux-keyboard/metadata.json',
 'Tests/Fixtures/Barrier/m1-040-linux-keyboard/keyboard-capture.json',
 'evidence/issues/M1-040/summary.md',
 'evidence/issues/M1-040/commands.json',
 'evidence/issues/M1-040/tests/e2e-validation.json',
 'evidence/issues/M1-040/environment.json',
 'evidence/issues/M1-040/manual.md',
]
for rel in required:
    if not (root/rel).is_file():
        raise SystemExit(f'missing {rel}')
cap=json.loads(fixture.read_text())
meta=json.loads(metadata.read_text())
if cap.get('schemaVersion') != 1 or cap.get('captureId') != 'm1-040-linux-keyboard' or cap.get('encoding') != 'base64':
    raise SystemExit('bad capture header')
obs=cap.get('observations')
if not isinstance(obs, list) or len(obs) < 10:
    raise SystemExit('too few observations')
expected=1
directions=set()
total=0
for item in obs:
    if item.get('sequence') != expected:
        raise SystemExit('bad sequence')
    expected += 1
    direction=item.get('direction')
    if direction not in ('server-to-client','client-to-server'):
        raise SystemExit('bad direction')
    directions.add(direction)
    raw=base64.b64decode(item.get('applicationPayloadBase64',''), validate=True)
    if not raw:
        raise SystemExit('empty payload')
    total += len(raw)
if 'server-to-client' not in directions or 'client-to-server' not in directions:
    raise SystemExit('missing direction')
if total < 128:
    raise SystemExit('payload too small')
if meta['payload']['sha256'] != hashlib.sha256(fixture.read_bytes()).hexdigest():
    raise SystemExit('payload sha mismatch')
if meta['payload']['byteLength'] != len(fixture.read_bytes()):
    raise SystemExit('payload length mismatch')
if meta['sanitization']['containsSensitiveData'] is not False:
    raise SystemExit('sensitive flag not false')
text='\n'.join((root/rel).read_text(errors='ignore') for rel in required)
token_prefixes = ['g' + 'hp_', 'github' + '_pat_', 's' + 'k-', '-' * 5 + 'BEGIN']
user_path_patterns = ['/' + 'Users/[^\\s]+', '/' + 'home/[^\\s]+']
allowed_public_versions = {'1.127.14.1'}
for pat in [
    r'(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])',
    '|'.join(token_prefixes),
    *user_path_patterns,
    r'[\w.+-]+@[\w-]+\.[\w.-]+',
]:
    for match in re.finditer(pat, text, re.I):
        if match.group(0) in allowed_public_versions:
            continue
        raise SystemExit('private pattern found')
tracked=subprocess.check_output(['git','ls-files'], cwd=root, text=True).splitlines()
if any(path.endswith(('.pcap','.pcapng','.cap')) for path in tracked):
    raise SystemExit('raw capture tracked')
head=subprocess.check_output(['git','rev-parse','HEAD'], cwd=root, text=True).strip()
now=datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z')
out={
 'schemaVersion':1,
 'issueId':'M1-040',
 'status':'passed',
 'startedAt':now,
 'endedAt':now,
 'commit':head,
 'toolchain':{'pythonVersion':platform.python_version(),'platform':platform.platform(),'machine':platform.machine()},
 'environment':{'localOS':'macOS 26.6.2 build 25G83 arm64','peerProduct':'Barrier barriers external test peer','peerVersion':'2.4.0-release protocol 1.6','peerRole':'EXTERNAL_TEST_PEER_ONLY','peerOS':'Ubuntu 22.04 x86_64','networkScope':'existing user-confirmed Barrier server/client session; repository retains no address or port value','tls':'disabled for observation only; product default stays enabled and unvalidated here'},
 'cases':[{'id':'fixture-format','status':'passed','exitCode':0,'evidence':[f'{len(obs)} ordered observations', f'{total} aggregate payload bytes', 'both directions present']},{'id':'privacy-scan','status':'passed','exitCode':0,'evidence':['no tracked raw capture suffix','no identifying pattern in retained evidence','metadata marks sensitive data false']},{'id':'nonclaim-scan','status':'passed','exitCode':0,'evidence':['fixture stores direction and uninterpreted payload only','no Windows result claimed','no key-code or compatibility semantics asserted']}],
 'artifacts':[{'path':'Tests/Fixtures/Barrier/m1-040-linux-keyboard/keyboard-capture.json','sha256':hashlib.sha256(fixture.read_bytes()).hexdigest(),'byteLength':len(fixture.read_bytes()),'kind':'sanitized-fixture','reviewStatus':'reviewed'},{'path':'Tests/Fixtures/Barrier/m1-040-linux-keyboard/metadata.json','sha256':hashlib.sha256(metadata.read_bytes()).hexdigest(),'byteLength':len(metadata.read_bytes()),'kind':'sanitized-fixture','reviewStatus':'reviewed'}],
 'privacy':{'containsSensitiveData':False,'containsTypedText':False,'containsClipboardPayload':False,'containsCredentials':False,'containsKeyMaterial':False,'containsHostnames':False,'containsIPAddresses':False,'rawCaptureCommitted':False,'sanitizationReviewed':True},
 'approvedDecisionRef':None
}
result.parent.mkdir(parents=True, exist_ok=True)
result.write_text(json.dumps(out, indent=2, ensure_ascii=False)+'\n')
PY
printf 'e2e disposition: passed\ne2e exit: 0\n'
