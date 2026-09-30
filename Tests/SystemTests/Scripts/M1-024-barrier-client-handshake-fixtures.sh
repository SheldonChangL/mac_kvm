#!/usr/bin/env bash
# M1-024 local fixture and evidence validator, and E2E result generator.
#
# Validates the sanitized Barrier client handshake fixture, its metadata, the
# capture toolchain lock and the M1-024 evidence inputs against the closed rules
# in Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md, then
# writes evidence/e2e/M1-024/result.json atomically.
#
# Commit provenance: M1-024 lands in two commits, the implementation commit
# carrying the eleven implementation-author Exact Files and, later, a separate
# review commit carrying independent-review.md. The author-phase records carry
# repositoryHeadAtAuthorRun, the repository HEAD the author ran over while those
# eleven files were still uncommitted. That value must be a full commit id that
# is an ancestor of, or equal to, the current HEAD, checked read-only with
# git merge-base --is-ancestor. It is deliberately not required to equal HEAD:
# committing those files moves HEAD, so an equality rule could never be
# satisfied by the resulting tree. The generated result.json separately carries
# the exact HEAD of the E2E execution that produced it.
#
# Local only. It never invokes ssh, scp, tcpdump, dumpcap, barrierc, barriers or
# any network, capture or peer operation, and it never reads a private capture
# directory. The only external program it runs is git, read-only, for HEAD and
# the tracked file list.
#
# Optional: M1_024_FIXTURE_ROOT points at a private mutated copy of the fixture
# directory for negative testing; that mode validates the fixture pair only,
# writes no result file and reports through its exit code.
#
# Normal mode requires MACKVM_E2E_ISSUE=M1-024 and
# MACKVM_E2E_RESULT=evidence/e2e/M1-024/result.json, removes a stale regular
# result at that path, and fails closed on any malformed, missing, stale,
# oversized, secret-bearing or claim-bearing input.
set -euo pipefail

unset CDPATH

fail() {
  printf 'M1-024 validation failed: %s\n' "$1" >&2
  exit 1
}

command -v python3 >/dev/null 2>&1 || fail "python3 unavailable"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || fail "cannot resolve script directory"
repo_root="$(cd "${script_dir}/../../.." && pwd -P)" || fail "cannot resolve repository root"

if [ "${M1_024_FIXTURE_ROOT+x}" = "x" ]; then
  [ -n "${M1_024_FIXTURE_ROOT}" ] || fail "M1_024_FIXTURE_ROOT is empty"
  fixture_root="${M1_024_FIXTURE_ROOT}"
  fixture_mode="override"
else
  fixture_root="${repo_root}/Tests/Fixtures/Barrier/m1-024-linux-client-handshake"
  fixture_mode="repository"
fi

# The validator source uses double quotes only so it can live in a
# single-quoted shell string (no heredoc temp file).
validator_src='
import base64
import datetime
import hashlib
import json
import math
import os
import platform
import re
import stat
import subprocess
import sys

MAX_JSON_BYTES = 1048576
MAX_EVIDENCE_BYTES = 262144
MAX_DEPTH = 8
MAX_INT_DIGITS = 19
MAX_OBSERVATION_BYTES = 65536
MAX_TOTAL_BYTES = 262144
MAX_REFERENCE_LENGTH = 512
MAX_RECORDS = 64
MAX_TEXT_FIELD = 300
GIT_TIMEOUT_SECONDS = 10

CAPTURE_ID = "m1-024-linux-client-handshake"
# Author-phase provenance key. The author ran every recorded check with the
# eleven implementation-author M1-024 files still uncommitted, on top of this
# repository HEAD, so the author-phase records cannot name the commit that will
# contain them. They name the HEAD they ran over, and the validator requires
# that value to be an ancestor of, or equal to, the current HEAD.
AUTHOR_HEAD_KEY = "repositoryHeadAtAuthorRun"
METADATA_NAME = "metadata.json"
PAYLOAD_NAME = "handshake-capture.json"
DIRECTIONS = ("client-to-server", "server-to-client")
REMOVED_CATEGORIES = ["ip-address", "other-private-data"]

ISSUE_ID = "M1-024"
RESULT_PATH = "evidence/e2e/M1-024/result.json"
FIXTURE_DIR = "Tests/Fixtures/Barrier/m1-024-linux-client-handshake"
LOCK_DIR = "MacKVM_Implementation_Package_v2"
LOCK_NAME = "toolchain.lock.json"
LOCK_PATH = LOCK_DIR + "/" + LOCK_NAME

PLAN_PATH = "Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md"
SCRIPT_PATH = "Tests/SystemTests/Scripts/M1-024-barrier-client-handshake-fixtures.sh"
E2E_README_PATH = "evidence/e2e/M1-024/README.md"
METADATA_PATH = FIXTURE_DIR + "/" + METADATA_NAME
PAYLOAD_PATH = FIXTURE_DIR + "/" + PAYLOAD_NAME
SUMMARY_PATH = "evidence/issues/M1-024/summary.md"
COMMANDS_PATH = "evidence/issues/M1-024/commands.json"
E2E_VALIDATION_PATH = "evidence/issues/M1-024/tests/e2e-validation.json"
ENVIRONMENT_PATH = "evidence/issues/M1-024/environment.json"
MANUAL_PATH = "evidence/issues/M1-024/manual.md"
REVIEW_PATH = "evidence/issues/M1-024/independent-review.md"

# Exact Files of the Issue, in Issue order. result.json is produced by this
# script. The eight text files below plus the fixture pair and result.json are
# the eleven implementation-author files and are always required. The twelfth
# Exact File, independent-review.md, is authored by the non-implementing
# reviewer only after the implementation commit exists, so it cannot be required
# here; it is scanned by the same rules as soon as it exists.
REQUIRED_TEXT_FILES = (
    PLAN_PATH,
    SCRIPT_PATH,
    E2E_README_PATH,
    SUMMARY_PATH,
    COMMANDS_PATH,
    E2E_VALIDATION_PATH,
    ENVIRONMENT_PATH,
    MANUAL_PATH,
)
DOCUMENT_FILES = (PLAN_PATH, E2E_README_PATH, SUMMARY_PATH, MANUAL_PATH)
RAW_CAPTURE_SUFFIXES = (".pcap", ".pcapng", ".cap", ".pcap.gz", ".pcapng.gz")

LOCK_EXPECTATIONS = (
    (("lock_id",), "M1-CAPTURE-TOOLCHAIN-001"),
    (("status",), "LOCKED"),
    (("scope",), "M1_CONTROLLED_BARRIER_BLACK_BOX_CAPTURE_ONLY"),
    (("scoped_issues",), ["M1-024"]),
    (("barrier", "role"), "EXTERNAL_TEST_PEER_ONLY"),
    (("barrier", "implementation_in_repository"), "NONE_COPIED_LINKED_OR_BUNDLED"),
    (("macos_capture_host", "os", "name"), "macOS"),
    (("macos_capture_host", "os", "version"), "26.6.2"),
    (("macos_capture_host", "os", "build"), "25G83"),
    (("macos_capture_host", "architecture"), "arm64"),
    (("macos_capture_host", "barrier_client", "executable"), "barrierc"),
    (("macos_capture_host", "barrier_client", "version"), "2.4.0-release"),
    (("macos_capture_host", "barrier_client", "protocol_version"), "1.6"),
    (("linux_peer", "os", "name"), "Ubuntu"),
    (("linux_peer", "os", "version"), "22.04"),
    (("linux_peer", "architecture"), "x86_64"),
    (("linux_peer", "barrier_server", "executable"), "barriers"),
    (("linux_peer", "barrier_server", "version"), "2.4.0-release"),
    (("linux_peer", "barrier_server", "protocol_version"), "1.6"),
    (("linux_peer", "capture_tools", "tcpdump", "version"), "4.99.1"),
    (("linux_peer", "capture_tools", "dumpcap_wireshark", "version"), "3.6.2"),
    (("capture", "raw_capture_location"), "OUTSIDE_REPOSITORY"),
    (
        ("capture", "retained_fixture_content"),
        "ORDERED_DIRECTION_AND_UNINTERPRETED_APPLICATION_PAYLOAD_BYTES_ONLY",
    ),
    (("capture", "wire_semantics_asserted"), False),
    (("capture", "windows_executed"), False),
    (("m4_first_party_production_toolchain", "status"), "UNRESOLVED_UNTIL_M4-001"),
    (("m4_first_party_production_toolchain", "windows"), "UNRESOLVED_UNTIL_M4-001"),
    (("m4_first_party_production_toolchain", "linux"), "UNRESOLVED_UNTIL_M4-001"),
    (("m4_first_party_production_toolchain", "selected_by_this_lock"), False),
)

BASE64_RE = re.compile(r"[A-Za-z0-9+/]+={0,2}")
SHA256_RE = re.compile(r"[a-f0-9]{64}")
COMMIT_RE = re.compile(r"[0-9a-f]{40}")
TIMESTAMP_RE = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?Z"
)
PRINTABLE_RE = re.compile(r"[ -~]{1,}")

# Identifying-content patterns kept behavior-identical to
# Tests/Contracts/test_m1_024_capture_readiness.py. Literal user-path prefixes
# are written with single-character classes so this file does not match itself.
IDENTIFYING_PATTERNS = (
    ("ipv4", re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")),
    ("ipv6", re.compile(r"(?i)\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}\b")),
    ("user path", re.compile(r"(?i)(?:/[u]sers/|/[h]ome/|c:[\\]{1,2}[u]sers[\\]{1,2})[^/\s\\]+")),
    ("email", re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+")),
    ("local hostname", re.compile(r"(?i)\b[\w-]+\.(?:local|lan|internal|corp|home)\b")),
    (
        "certificate fingerprint",
        re.compile(r"(?i)\b(?:[0-9a-f]{2}:){7,}[0-9a-f]{2}\b"),
    ),
    ("pem material", re.compile(r"-----BEGIN [A-Z ]+-----")),
    ("token", re.compile(r"\b(?:ghp_|gho_|github_pat_|sk-|xox[abp]-)[\w-]+")),
)
HEX_RUN_RE = re.compile(r"(?i)\b[0-9a-f]{32,}\b")
DIGEST_KEY_RE = re.compile(r"(?:Sha256|sha256|commit|Commit|HeadAtAuthorRun)$")

# Claim guards, kept behavior-identical to the readiness contract test.
NEGATION_RE = re.compile(r"(?i)不|未|\bnot\b|\bno\b")
WIRE_SEMANTIC_CLAIM_RE = re.compile(
    r"(?i)message code|endian|field (?:meaning|semantic)"
    r"|欄位(?:意義|語意)|相容|compatib"
)
WINDOWS_CLAIM_RE = re.compile(
    r"(?i)\bexecuted\b|\bpass(?:ed)?\b|compatib|已執行|通過|相容"
)
LOGICAL_LINE_START_RE = re.compile(r"\s*(?:[-*+]\s|\d+[.)]\s|#|\||>|```|~~~)")


class Invalid(Exception):
    pass


def fail(message):
    raise Invalid(message)


def read_regular(dir_fd, name, limit=MAX_JSON_BYTES):
    try:
        st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        fail(name + " missing")
    except OSError:
        fail(name + " unreadable")
    if stat.S_ISLNK(st.st_mode):
        fail(name + " is a symlink")
    if not stat.S_ISREG(st.st_mode):
        fail(name + " is not a regular file")
    if st.st_size > limit:
        fail(name + " exceeds the size limit")
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except OSError:
        fail(name + " cannot be opened safely")
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            fail(name + " is not a regular file")
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > limit:
                fail(name + " exceeds the size limit")
            chunks.append(chunk)
    finally:
        os.close(fd)
    return b"".join(chunks)


def check_depth(name, text):
    depth = 0
    in_string = False
    escaped = False
    for ch in text:
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == "\"":
                in_string = False
        elif ch == "\"":
            in_string = True
        elif ch == "[" or ch == "{":
            depth += 1
            if depth > MAX_DEPTH:
                fail(name + " nesting too deep")
        elif ch == "]" or ch == "}":
            depth -= 1


def check_strings(name, value):
    if isinstance(value, str):
        try:
            value.encode("utf-8")
        except UnicodeEncodeError:
            fail(name + " contains invalid unicode")
    elif isinstance(value, dict):
        for key, item in value.items():
            check_strings(name, key)
            check_strings(name, item)
    elif isinstance(value, list):
        for item in value:
            check_strings(name, item)


def parse_json(name, data):
    if data.startswith(b"\xef\xbb\xbf"):
        fail(name + " has a byte order mark")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        fail(name + " is not valid UTF-8")
    check_depth(name, text)

    def object_pairs(pairs):
        result = {}
        for key, item in pairs:
            if key in result:
                fail(name + " has a duplicate key")
            result[key] = item
        return result

    def reject_constant(token):
        fail(name + " has a nonfinite number")

    def parse_float(token):
        number = float(token)
        if not math.isfinite(number):
            fail(name + " has a nonfinite number")
        return number

    def parse_int(token):
        if len(token.lstrip("-")) > MAX_INT_DIGITS:
            fail(name + " has an oversized integer")
        return int(token)

    try:
        value = json.loads(
            text,
            object_pairs_hook=object_pairs,
            parse_constant=reject_constant,
            parse_float=parse_float,
            parse_int=parse_int,
        )
    except RecursionError:
        fail(name + " nesting too deep")
    except ValueError:
        fail(name + " is not valid JSON")
    check_strings(name, value)
    return value


def is_int(value):
    return type(value) is int


def require_object(context, value, keys):
    if not isinstance(value, dict):
        fail(context + " is not an object")
    present = set(value.keys())
    expected = set(keys)
    if present - expected:
        fail(context + " has an unknown key")
    if expected - present:
        fail(context + " is missing a required key")


def require_text(context, value, limit=MAX_TEXT_FIELD):
    if not isinstance(value, str) or not 1 <= len(value) <= limit:
        fail(context + " is not a bounded string")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        fail(context + " has a control character")
    return value


def require_possibly_empty_text(context, value, limit=MAX_TEXT_FIELD):
    """Like require_text, but an empty string is a recordable observation.

    A tool that reported no value must be recorded as reporting no value rather
    than as a filler string.
    """
    if not isinstance(value, str) or len(value) > limit:
        fail(context + " is not a bounded string")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        fail(context + " has a control character")
    return value


def require_positive_int(context, value):
    if not is_int(value) or value <= 0:
        fail(context + " is not a positive integer")
    return value


def require_const(context, value, expected):
    if type(value) is not type(expected) or value != expected:
        fail(context + " mismatch")


def require_timestamp(context, value):
    if not isinstance(value, str) or TIMESTAMP_RE.fullmatch(value) is None:
        fail(context + " is not a UTC timestamp")
    text = value[:-1]
    fmt = "%Y-%m-%dT%H:%M:%S.%f" if "." in text else "%Y-%m-%dT%H:%M:%S"
    try:
        return datetime.datetime.strptime(text, fmt)
    except ValueError:
        fail(context + " is not a UTC timestamp")


def require_exit_code(context, value):
    if not is_int(value) or not 0 <= value <= 255:
        fail(context + " is not an exit code")
    return value


def validate_capture(capture):
    require_object(
        PAYLOAD_NAME,
        capture,
        ("schemaVersion", "captureId", "encoding", "observations"),
    )
    if not is_int(capture["schemaVersion"]) or capture["schemaVersion"] != 1:
        fail(PAYLOAD_NAME + " schemaVersion is not 1")
    if capture["captureId"] != CAPTURE_ID:
        fail(PAYLOAD_NAME + " captureId mismatch")
    if capture["encoding"] != "base64":
        fail(PAYLOAD_NAME + " encoding is not base64")
    observations = capture["observations"]
    if not isinstance(observations, list) or not observations:
        fail(PAYLOAD_NAME + " observations must be a non-empty array")

    seen_directions = set()
    total = 0
    decoded_all = []
    for index, observation in enumerate(observations, start=1):
        context = PAYLOAD_NAME + " observation " + str(index)
        require_object(
            context,
            observation,
            ("sequence", "direction", "applicationPayloadBase64"),
        )
        sequence = observation["sequence"]
        if not is_int(sequence) or sequence != index:
            fail(context + " sequence is not contiguous and 1-based")
        direction = observation["direction"]
        if direction not in DIRECTIONS:
            fail(context + " direction is not allowed")
        seen_directions.add(direction)
        encoded = observation["applicationPayloadBase64"]
        if (
            not isinstance(encoded, str)
            or len(encoded) % 4 != 0
            or BASE64_RE.fullmatch(encoded) is None
        ):
            fail(context + " payload is not canonical base64")
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except ValueError:
            fail(context + " payload is not canonical base64")
        if base64.b64encode(decoded).decode("ascii") != encoded:
            fail(context + " payload is not canonical base64")
        if not 1 <= len(decoded) <= MAX_OBSERVATION_BYTES:
            fail(context + " payload size out of range")
        total += len(decoded)
        if total > MAX_TOTAL_BYTES:
            fail(PAYLOAD_NAME + " aggregate payload exceeds 262144 bytes")
        decoded_all.append(decoded)

    if seen_directions != set(DIRECTIONS):
        fail(PAYLOAD_NAME + " must contain both directions")
    return len(observations), total, b"".join(decoded_all)


def validate_metadata(metadata, payload_bytes):
    require_object(
        METADATA_NAME,
        metadata,
        ("schemaVersion", "fixtureId", "protocol", "provenance", "payload", "sanitization"),
    )
    if not is_int(metadata["schemaVersion"]) or metadata["schemaVersion"] != 1:
        fail(METADATA_NAME + " schemaVersion is not 1")
    if metadata["fixtureId"] != CAPTURE_ID:
        fail(METADATA_NAME + " fixtureId mismatch")
    if metadata["protocol"] != "barrier":
        fail(METADATA_NAME + " protocol is not barrier")

    provenance = metadata["provenance"]
    require_object(METADATA_NAME + " provenance", provenance, ("sourceKind", "reference"))
    if provenance["sourceKind"] != "black-box-capture":
        fail(METADATA_NAME + " provenance sourceKind is not black-box-capture")
    require_text(METADATA_NAME + " provenance reference", provenance["reference"], MAX_REFERENCE_LENGTH)

    payload = metadata["payload"]
    require_object(METADATA_NAME + " payload", payload, ("path", "sha256", "byteLength"))
    if payload["path"] != PAYLOAD_NAME:
        fail(METADATA_NAME + " payload path mismatch")
    digest = payload["sha256"]
    if not isinstance(digest, str) or SHA256_RE.fullmatch(digest) is None:
        fail(METADATA_NAME + " payload sha256 is malformed")
    if digest != hashlib.sha256(payload_bytes).hexdigest():
        fail(METADATA_NAME + " payload sha256 mismatch")
    byte_length = payload["byteLength"]
    if not is_int(byte_length) or byte_length < 0:
        fail(METADATA_NAME + " payload byteLength is malformed")
    if byte_length != len(payload_bytes):
        fail(METADATA_NAME + " payload byteLength mismatch")

    sanitization = metadata["sanitization"]
    require_object(
        METADATA_NAME + " sanitization",
        sanitization,
        ("status", "containsSensitiveData", "removedCategories"),
    )
    if sanitization["status"] != "sanitized":
        fail(METADATA_NAME + " sanitization status is not sanitized")
    if sanitization["containsSensitiveData"] is not False:
        fail(METADATA_NAME + " sanitization containsSensitiveData is not false")
    categories = sanitization["removedCategories"]
    if not isinstance(categories, list):
        fail(METADATA_NAME + " sanitization removedCategories is not an array")
    if (
        len(categories) != len(REMOVED_CATEGORIES)
        or any(type(category) is not str for category in categories)
        or categories != REMOVED_CATEGORIES
    ):
        fail(METADATA_NAME + " sanitization removedCategories mismatch")
    return digest


def open_repo(repo_root):
    try:
        return os.open(repo_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        fail("repository root cannot be opened safely")


def open_child_dir(parent_fd, name, context):
    # Returns None when the directory does not exist.
    try:
        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError:
        fail(context + " unreadable")
    if stat.S_ISLNK(st.st_mode):
        fail(context + " is a symlink")
    if not stat.S_ISDIR(st.st_mode):
        fail(context + " is not a directory")
    try:
        return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd)
    except OSError:
        fail(context + " cannot be opened safely")


def with_parent_dir(repo_fd, relative, action, missing_value=None):
    parts = relative.split("/")
    fds = []
    try:
        current = repo_fd
        for index, part in enumerate(parts[:-1]):
            child = open_child_dir(current, part, "/".join(parts[: index + 1]))
            if child is None:
                return missing_value
            fds.append(child)
            current = child
        return action(current, parts[-1])
    finally:
        for fd in reversed(fds):
            os.close(fd)


def read_repo_file(repo_fd, relative, required=True, limit=MAX_EVIDENCE_BYTES):
    def action(dir_fd, name):
        try:
            os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            if required:
                fail(relative + " missing")
            return None
        except OSError:
            fail(relative + " unreadable")
        return read_regular(dir_fd, name, limit)

    data = with_parent_dir(repo_fd, relative, action)
    if data is None and required:
        fail(relative + " missing")
    return data


def decode_text(relative, data):
    if data.startswith(b"\xef\xbb\xbf"):
        fail(relative + " has a byte order mark")
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        fail(relative + " is not valid UTF-8")


def remove_stale_result(repo_fd):
    def action(dir_fd, name):
        try:
            st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        except FileNotFoundError:
            return None
        except OSError:
            fail("stale result unreadable")
        if stat.S_ISLNK(st.st_mode):
            fail("stale result is a symlink")
        if not stat.S_ISREG(st.st_mode):
            fail("stale result is not a regular file")
        try:
            os.unlink(name, dir_fd=dir_fd)
        except OSError:
            fail("stale result cannot be removed")
        return None

    with_parent_dir(repo_fd, RESULT_PATH, action)


def lock_value(lock, path):
    value = lock
    for key in path:
        if not isinstance(value, dict) or key not in value:
            fail(LOCK_NAME + " " + ".".join(path) + " missing")
        value = value[key]
    return value


def validate_lock(repo_fd):
    lock_bytes = read_repo_file(repo_fd, LOCK_PATH, True, MAX_JSON_BYTES)
    lock = parse_json(LOCK_NAME, lock_bytes)
    if not isinstance(lock, dict):
        fail(LOCK_NAME + " is not an object")
    for path, expected in LOCK_EXPECTATIONS:
        context = LOCK_NAME + " " + ".".join(path)
        value = lock_value(lock, path)
        if isinstance(expected, list):
            matches = (
                isinstance(value, list)
                and all(type(item) is str for item in value)
                and value == expected
            )
        else:
            matches = type(value) is type(expected) and value == expected
        if not matches:
            fail(context + " mismatch")
    return lock


def git_output(repo_root, arguments, context):
    try:
        completed = subprocess.run(
            ["git"] + list(arguments),
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        fail(context + " unavailable")
    if completed.returncode != 0:
        fail(context + " failed")
    return completed.stdout


def git_status(repo_root, arguments, context):
    """Read-only git call that reports its exit status instead of failing on it."""
    try:
        completed = subprocess.run(
            ["git"] + list(arguments),
            cwd=repo_root,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        fail(context + " unavailable")
    return completed.returncode


def git_commit(repo_root):
    raw = git_output(repo_root, ["rev-parse", "--verify", "HEAD"], "git rev-parse")
    commit = raw.decode("ascii", errors="replace").strip()
    if COMMIT_RE.fullmatch(commit) is None:
        fail("git HEAD is not a commit id")
    return commit


def require_author_head(context, value, repo_root, commit):
    """Author-phase provenance.

    The value must be a full lowercase commit id that exists in this repository
    and is an ancestor of, or equal to, the current HEAD. Exact equality is not
    required and must not be required: once the eleven implementation-author
    M1-024 files are committed, HEAD moves past the HEAD the author ran over, and
    an equality rule would make the resulting tree permanently unsatisfiable.
    Anything malformed, unresolvable or outside the current history fails closed.
    """
    if not isinstance(value, str) or COMMIT_RE.fullmatch(value) is None:
        fail(context + " is not a full lowercase commit id")
    code = git_status(
        repo_root,
        ["merge-base", "--is-ancestor", value, commit],
        context + " ancestry check",
    )
    if code == 1:
        fail(context + " is not an ancestor of, or equal to, HEAD")
    if code != 0:
        fail(context + " cannot be resolved in this repository")
    return value


def check_no_tracked_raw_capture(repo_root):
    raw = git_output(repo_root, ["ls-files", "-z"], "git ls-files")
    count = 0
    for item in raw.split(b"\0"):
        if not item:
            continue
        count += 1
        try:
            name = item.decode("utf-8")
        except UnicodeDecodeError:
            fail("tracked path is not valid UTF-8")
        lowered = name.lower()
        for suffix in RAW_CAPTURE_SUFFIXES:
            if lowered.endswith(suffix):
                fail("repository tracks a raw capture file")
    if count == 0:
        fail("git ls-files returned no tracked file")
    return count


def check_fixture_directory(repo_fd):
    def action(dir_fd, name):
        child = open_child_dir(dir_fd, name, FIXTURE_DIR)
        if child is None:
            fail(FIXTURE_DIR + " missing")
        try:
            entries = sorted(os.listdir(child))
        except OSError:
            fail(FIXTURE_DIR + " unreadable")
        finally:
            os.close(child)
        return entries

    entries = with_parent_dir(repo_fd, FIXTURE_DIR, action)
    if entries is None:
        fail(FIXTURE_DIR + " missing")
    if entries != sorted([METADATA_NAME, PAYLOAD_NAME]):
        fail(FIXTURE_DIR + " contains an unexpected entry")


def logical_lines(text):
    """Join hard-wrapped markdown continuations so a negation is not split off."""
    lines = []
    current = None
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped:
            if current is not None:
                lines.append(current)
                current = None
            continue
        if current is None or LOGICAL_LINE_START_RE.match(line) is not None:
            if current is not None:
                lines.append(current)
            current = stripped
        else:
            current = current + " " + stripped
    if current is not None:
        lines.append(current)
    return lines


def string_values(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield key
            for text in string_values(item):
                yield text
    elif isinstance(value, list):
        for item in value:
            for text in string_values(item):
                yield text


def collect_digests(value, digests):
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, str) and DIGEST_KEY_RE.search(key) is not None:
                if SHA256_RE.fullmatch(item) is None and COMMIT_RE.fullmatch(item) is None:
                    fail("declared digest " + key + " is malformed")
                digests.add(item.lower())
            collect_digests(item, digests)
    elif isinstance(value, list):
        for item in value:
            collect_digests(item, digests)


def scan_identifying(relative, text, digests):
    for name, pattern in IDENTIFYING_PATTERNS:
        if pattern.search(text) is not None:
            fail(relative + " contains identifying content: " + name)
    for match in HEX_RUN_RE.finditer(text):
        token = match.group(0).lower()
        if token not in digests:
            fail(relative + " contains an undeclared hexadecimal digest")


def scan_claims(relative, lines):
    for line in lines:
        if NEGATION_RE.search(line) is not None:
            continue
        if WIRE_SEMANTIC_CLAIM_RE.search(line) is not None:
            fail(relative + " asserts wire semantics")
        if "windows" in line.lower() and WINDOWS_CLAIM_RE.search(line) is not None:
            fail(relative + " asserts a Windows result")


def validate_commands(document, payload_digest, payload_length, repo_root, commit):
    name = "commands.json"
    require_object(
        name,
        document,
        (
            "schemaVersion",
            "issue",
            "githubIssue",
            AUTHOR_HEAD_KEY,
            "status",
            "toolchain",
            "captureArtifacts",
            "producerReported",
            "rootReviewerVerification",
            "commands",
            "remediatedAttempts",
        ),
    )
    require_const(name + " schemaVersion", document["schemaVersion"], 1)
    require_const(name + " issue", document["issue"], ISSUE_ID)
    if not is_int(document["githubIssue"]) or document["githubIssue"] <= 0:
        fail(name + " githubIssue is not a positive integer")
    require_author_head(name + " " + AUTHOR_HEAD_KEY, document[AUTHOR_HEAD_KEY], repo_root, commit)
    require_const(name + " status", document["status"], "passed")

    toolchain = document["toolchain"]
    require_object(name + " toolchain", toolchain, ("machine", "platform", "pythonVersion", "swiftVersion"))
    for key in sorted(toolchain):
        require_text(name + " toolchain " + key, toolchain[key])

    artifacts = document["captureArtifacts"]
    require_object(
        name + " captureArtifacts",
        artifacts,
        (
            "fixtureSha256",
            "fixtureByteLength",
            "rawCaptureSha256",
            "rawCaptureByteLength",
            "rawCaptureCommitted",
            "sanitizerScriptSha256",
            "sanitizerSelfTestScriptSha256",
            "sanitizerSelfTestChecksPassed",
        ),
    )
    if artifacts["fixtureSha256"] != payload_digest:
        fail(name + " captureArtifacts fixtureSha256 is stale")
    require_const(name + " captureArtifacts fixtureByteLength", artifacts["fixtureByteLength"], payload_length)
    for key in ("rawCaptureSha256", "sanitizerScriptSha256", "sanitizerSelfTestScriptSha256"):
        value = artifacts[key]
        if not isinstance(value, str) or SHA256_RE.fullmatch(value) is None:
            fail(name + " captureArtifacts " + key + " is malformed")
    for key in ("rawCaptureByteLength", "sanitizerSelfTestChecksPassed"):
        if not is_int(artifacts[key]) or artifacts[key] <= 0:
            fail(name + " captureArtifacts " + key + " is not a positive integer")
    require_const(name + " captureArtifacts rawCaptureCommitted", artifacts["rawCaptureCommitted"], False)

    reported = document["producerReported"]
    require_object(
        name + " producerReported",
        reported,
        (
            "note",
            "observationCount",
            "aggregatePayloadBytes",
            "packetsCaptured",
            "packetsReceivedByFilter",
            "packetsDroppedByKernel",
            "denylistHits",
            "cleanupVerified",
            "rawTransferHashesMatched",
            "windowsExecuted",
            "tlsDisabledForObservationOnly",
        ),
    )
    require_text(name + " producerReported note", reported["note"])
    for key in ("observationCount", "aggregatePayloadBytes", "packetsCaptured", "packetsReceivedByFilter"):
        if not is_int(reported[key]) or reported[key] <= 0:
            fail(name + " producerReported " + key + " is not a positive integer")
    for key in ("packetsDroppedByKernel", "denylistHits"):
        require_const(name + " producerReported " + key, reported[key], 0)
    for key in ("cleanupVerified", "rawTransferHashesMatched", "tlsDisabledForObservationOnly"):
        require_const(name + " producerReported " + key, reported[key], True)
    require_const(name + " producerReported windowsExecuted", reported["windowsExecuted"], False)

    # A gate the author session could not complete, rerun by the root reviewer
    # outside the managed outer sandbox. It is recorded as a separate, attributed
    # record so it is never mistaken for an author-run command, and it does not
    # stand in for the independent review at the committed implementation head.
    root_run = document["rootReviewerVerification"]
    require_object(
        name + " rootReviewerVerification",
        root_run,
        ("command", "runBy", "startedAt", "endedAt", "exitCode", "steps", "treeState", "note"),
    )
    for key in ("command", "runBy", "steps", "treeState", "note"):
        require_text(name + " rootReviewerVerification " + key, root_run[key])
    root_started = require_timestamp(name + " rootReviewerVerification startedAt", root_run["startedAt"])
    root_ended = require_timestamp(name + " rootReviewerVerification endedAt", root_run["endedAt"])
    if root_started > root_ended:
        fail(name + " rootReviewerVerification timestamps are out of order")
    require_const(name + " rootReviewerVerification exitCode", root_run["exitCode"], 0)

    commands = document["commands"]
    if not isinstance(commands, list) or not 1 <= len(commands) <= MAX_RECORDS:
        fail(name + " commands must be a bounded non-empty array")
    for index, entry in enumerate(commands, start=1):
        context = name + " command " + str(index)
        require_object(context, entry, ("command", "startedAt", "endedAt", "exitCode", "result"))
        require_text(context + " command", entry["command"])
        started = require_timestamp(context + " startedAt", entry["startedAt"])
        ended = require_timestamp(context + " endedAt", entry["endedAt"])
        if started > ended:
            fail(context + " timestamps are out of order")
        require_exit_code(context + " exitCode", entry["exitCode"])
        require_text(context + " result", entry["result"])

    attempts = document["remediatedAttempts"]
    if not isinstance(attempts, list) or len(attempts) > MAX_RECORDS:
        fail(name + " remediatedAttempts must be a bounded array")
    for index, entry in enumerate(attempts, start=1):
        context = name + " remediatedAttempt " + str(index)
        require_object(context, entry, ("attempt", "outcome", "rootCause", "resolution"))
        for key in ("attempt", "outcome", "rootCause", "resolution"):
            require_text(context + " " + key, entry[key])
    if not attempts:
        fail(name + " remediatedAttempts must record the failed attempts")
    return reported


def validate_environment(document, lock, repo_root, commit):
    name = "environment.json"
    require_object(
        name,
        document,
        (
            "schemaVersion",
            "issue",
            AUTHOR_HEAD_KEY,
            "toolchainLock",
            "preCaptureMetadata",
            "observationWindow",
            "host",
            "peer",
            "captureTools",
            "network",
            "tls",
            "windows",
            "privacy",
        ),
    )
    require_const(name + " schemaVersion", document["schemaVersion"], 1)
    require_const(name + " issue", document["issue"], ISSUE_ID)
    require_author_head(name + " " + AUTHOR_HEAD_KEY, document[AUTHOR_HEAD_KEY], repo_root, commit)

    lock_reference = document["toolchainLock"]
    require_object(name + " toolchainLock", lock_reference, ("lockId", "status", "scope", "path"))
    require_const(name + " toolchainLock lockId", lock_reference["lockId"], lock_value(lock, ("lock_id",)))
    require_const(name + " toolchainLock status", lock_reference["status"], lock_value(lock, ("status",)))
    require_const(name + " toolchainLock scope", lock_reference["scope"], lock_value(lock, ("scope",)))
    require_const(name + " toolchainLock path", lock_reference["path"], LOCK_PATH)

    # Issue #17 requires the capture-time facts to be recorded before capture.
    # This block records that the recording happened first, for which attempt,
    # and by whom; it is not a claim about any value inside those facts.
    pre_capture = document["preCaptureMetadata"]
    require_object(
        name + " preCaptureMetadata",
        pre_capture,
        ("recordedBeforeCapture", "acceptedAttempt", "recordedBy", "note"),
    )
    require_const(
        name + " preCaptureMetadata recordedBeforeCapture", pre_capture["recordedBeforeCapture"], True
    )
    for key in ("acceptedAttempt", "recordedBy", "note"):
        require_text(name + " preCaptureMetadata " + key, pre_capture[key])

    window = document["observationWindow"]
    require_object(
        name + " observationWindow",
        window,
        (
            "timeBasis",
            "launcherStartedAt",
            "clientLogStartedAt",
            "serverAcceptedAt",
            "terminationRequestedAt",
            "serverDisconnectedAt",
            "observedSeconds",
            "clientLogToDisconnectSeconds",
            "maximumSeconds",
        ),
    )
    require_text(name + " observationWindow timeBasis", window["timeBasis"])
    ordered = (
        "launcherStartedAt",
        "clientLogStartedAt",
        "serverAcceptedAt",
        "terminationRequestedAt",
        "serverDisconnectedAt",
    )
    moments = []
    for key in ordered:
        moments.append(require_timestamp(name + " observationWindow " + key, window[key]))
    for index in range(1, len(moments)):
        if moments[index - 1] > moments[index]:
            fail(name + " observationWindow timestamps are out of order")
    for key in ("observedSeconds", "clientLogToDisconnectSeconds", "maximumSeconds"):
        if not is_int(window[key]) or window[key] <= 0:
            fail(name + " observationWindow " + key + " is not a positive integer")
    # The conservative window runs from the launcher, not from the client log.
    if window["observedSeconds"] != int((moments[4] - moments[0]).total_seconds()):
        fail(name + " observationWindow observedSeconds does not match its timestamps")
    if window["clientLogToDisconnectSeconds"] != int((moments[4] - moments[1]).total_seconds()):
        fail(name + " observationWindow clientLogToDisconnectSeconds does not match its timestamps")
    if window["clientLogToDisconnectSeconds"] > window["observedSeconds"]:
        fail(name + " observationWindow client-log window exceeds the conservative window")
    if window["observedSeconds"] > window["maximumSeconds"]:
        fail(name + " observationWindow exceeds the bounded capture window")

    host = document["host"]
    require_object(
        name + " host",
        host,
        ("os", "osVersion", "osBuild", "architecture", "hardware", "keyboard", "display", "barrierClient"),
    )
    require_const(name + " host os", host["os"], lock_value(lock, ("macos_capture_host", "os", "name")))
    require_const(name + " host osVersion", host["osVersion"], lock_value(lock, ("macos_capture_host", "os", "version")))
    require_const(name + " host osBuild", host["osBuild"], lock_value(lock, ("macos_capture_host", "os", "build")))
    require_const(
        name + " host architecture", host["architecture"], lock_value(lock, ("macos_capture_host", "architecture"))
    )
    hardware = host["hardware"]
    require_object(
        name + " host hardware",
        hardware,
        (
            "modelName",
            "modelIdentifier",
            "chip",
            "totalCores",
            "performanceCores",
            "efficiencyCores",
            "memory",
        ),
    )
    for key in ("modelName", "modelIdentifier", "chip", "memory"):
        require_text(name + " host hardware " + key, hardware[key])
    for key in ("totalCores", "performanceCores", "efficiencyCores"):
        require_positive_int(name + " host hardware " + key, hardware[key])
    if hardware["performanceCores"] + hardware["efficiencyCores"] != hardware["totalCores"]:
        fail(name + " host hardware core counts do not add up")

    keyboard = host["keyboard"]
    require_object(
        name + " host keyboard",
        keyboard,
        ("activeInputSourceId", "physicalLayoutRecorded", "physicalLayout", "note"),
    )
    require_text(name + " host keyboard activeInputSourceId", keyboard["activeInputSourceId"])
    # The active input source is a logical selection. It is not evidence of a
    # physical keyboard form factor, so the physical layout must stay unrecorded.
    require_const(
        name + " host keyboard physicalLayoutRecorded", keyboard["physicalLayoutRecorded"], False
    )
    require_const(name + " host keyboard physicalLayout", keyboard["physicalLayout"], "not captured")
    require_text(name + " host keyboard note", keyboard["note"])

    display = host["display"]
    require_object(
        name + " host display",
        display,
        ("combinedDesktopBounds", "individualDisplaysRecorded", "note"),
    )
    bounds = display["combinedDesktopBounds"]
    require_object(name + " host display combinedDesktopBounds", bounds, ("left", "top", "right", "bottom"))
    for key in ("left", "top", "right", "bottom"):
        if not is_int(bounds[key]):
            fail(name + " host display combinedDesktopBounds " + key + " is not an integer")
    if bounds["left"] >= bounds["right"] or bounds["top"] >= bounds["bottom"]:
        fail(name + " host display combinedDesktopBounds is not a positive rectangle")
    # Only the combined desktop rectangle was reported before capture. Per-display
    # models and resolutions were not, and must not be inferred from it.
    require_const(
        name + " host display individualDisplaysRecorded", display["individualDisplaysRecorded"], False
    )
    require_text(name + " host display note", display["note"])

    client = host["barrierClient"]
    require_object(name + " host barrierClient", client, ("executable", "version", "protocolVersion", "role"))
    require_const(
        name + " host barrierClient executable",
        client["executable"],
        lock_value(lock, ("macos_capture_host", "barrier_client", "executable")),
    )
    require_const(
        name + " host barrierClient version",
        client["version"],
        lock_value(lock, ("macos_capture_host", "barrier_client", "version")),
    )
    require_const(
        name + " host barrierClient protocolVersion",
        client["protocolVersion"],
        lock_value(lock, ("macos_capture_host", "barrier_client", "protocol_version")),
    )
    require_const(name + " host barrierClient role", client["role"], lock_value(lock, ("barrier", "role")))

    peer = document["peer"]
    require_object(
        name + " peer",
        peer,
        ("os", "osVersion", "architecture", "hardware", "display", "keyboard", "barrierServer"),
    )
    require_const(name + " peer os", peer["os"], lock_value(lock, ("linux_peer", "os", "name")))
    require_const(name + " peer osVersion", peer["osVersion"], lock_value(lock, ("linux_peer", "os", "version")))
    require_const(
        name + " peer architecture", peer["architecture"], lock_value(lock, ("linux_peer", "architecture"))
    )
    peer_hardware = peer["hardware"]
    require_object(
        name + " peer hardware", peer_hardware, ("cpuModel", "cpuArchitecture", "logicalCpus", "memoryBytes")
    )
    for key in ("cpuModel", "cpuArchitecture"):
        require_text(name + " peer hardware " + key, peer_hardware[key])
    require_const(
        name + " peer hardware cpuArchitecture",
        peer_hardware["cpuArchitecture"],
        lock_value(lock, ("linux_peer", "architecture")),
    )
    for key in ("logicalCpus", "memoryBytes"):
        require_positive_int(name + " peer hardware " + key, peer_hardware[key])

    peer_display = peer["display"]
    require_object(
        name + " peer display",
        peer_display,
        ("xDisplay", "widthPixels", "heightPixels", "widthMillimeters", "heightMillimeters", "resolutionDpi"),
    )
    require_text(name + " peer display xDisplay", peer_display["xDisplay"])
    require_text(name + " peer display resolutionDpi", peer_display["resolutionDpi"])
    for key in ("widthPixels", "heightPixels", "widthMillimeters", "heightMillimeters"):
        require_positive_int(name + " peer display " + key, peer_display[key])

    peer_keyboard = peer["keyboard"]
    require_object(name + " peer keyboard", peer_keyboard, ("rules", "model", "layouts", "variants"))
    for key in ("rules", "model", "layouts"):
        require_text(name + " peer keyboard " + key, peer_keyboard[key])
    # The peer reported no variant. That absence is recorded as an empty string
    # rather than filled in with a substitute value.
    require_possibly_empty_text(name + " peer keyboard variants", peer_keyboard["variants"])

    server = peer["barrierServer"]
    require_object(name + " peer barrierServer", server, ("executable", "version", "protocolVersion", "role"))
    require_const(
        name + " peer barrierServer executable",
        server["executable"],
        lock_value(lock, ("linux_peer", "barrier_server", "executable")),
    )
    require_const(
        name + " peer barrierServer version",
        server["version"],
        lock_value(lock, ("linux_peer", "barrier_server", "version")),
    )
    require_const(
        name + " peer barrierServer protocolVersion",
        server["protocolVersion"],
        lock_value(lock, ("linux_peer", "barrier_server", "protocol_version")),
    )
    require_const(name + " peer barrierServer role", server["role"], lock_value(lock, ("barrier", "role")))

    tools = document["captureTools"]
    require_object(name + " captureTools", tools, ("recorder", "availableNotUsed", "packets"))
    recorder = tools["recorder"]
    require_object(
        name + " captureTools recorder",
        recorder,
        ("name", "version", "interface", "linkType", "snapshotLength"),
    )
    require_const(name + " captureTools recorder name", recorder["name"], "tcpdump")
    require_const(
        name + " captureTools recorder version",
        recorder["version"],
        lock_value(lock, ("linux_peer", "capture_tools", "tcpdump", "version")),
    )
    require_text(name + " captureTools recorder interface", recorder["interface"])
    require_text(name + " captureTools recorder linkType", recorder["linkType"])
    if not is_int(recorder["snapshotLength"]) or recorder["snapshotLength"] <= 0:
        fail(name + " captureTools recorder snapshotLength is not a positive integer")
    available = tools["availableNotUsed"]
    require_object(name + " captureTools availableNotUsed", available, ("name", "version", "used"))
    require_const(
        name + " captureTools availableNotUsed version",
        available["version"],
        lock_value(lock, ("linux_peer", "capture_tools", "dumpcap_wireshark", "version")),
    )
    require_text(name + " captureTools availableNotUsed name", available["name"])
    require_const(name + " captureTools availableNotUsed used", available["used"], False)
    packets = tools["packets"]
    require_object(name + " captureTools packets", packets, ("captured", "receivedByFilter", "droppedByKernel"))
    for key in ("captured", "receivedByFilter"):
        if not is_int(packets[key]) or packets[key] <= 0:
            fail(name + " captureTools packets " + key + " is not a positive integer")
    require_const(name + " captureTools packets droppedByKernel", packets["droppedByKernel"], 0)

    network = document["network"]
    require_object(name + " network", network, ("scope", "identifyingAddressesRecorded"))
    require_text(name + " network scope", network["scope"])
    require_const(name + " network identifyingAddressesRecorded", network["identifyingAddressesRecorded"], False)

    tls = document["tls"]
    require_object(
        name + " tls",
        tls,
        ("observationTlsEnabled", "productDefaultTlsEnabled", "productTlsValidatedByThisObservation", "note"),
    )
    require_const(name + " tls observationTlsEnabled", tls["observationTlsEnabled"], False)
    require_const(name + " tls productDefaultTlsEnabled", tls["productDefaultTlsEnabled"], True)
    require_const(
        name + " tls productTlsValidatedByThisObservation", tls["productTlsValidatedByThisObservation"], False
    )
    require_text(name + " tls note", tls["note"])

    windows = document["windows"]
    require_object(name + " windows", windows, ("executed", "resultClaimed", "decisionRef"))
    require_const(name + " windows executed", windows["executed"], lock_value(lock, ("capture", "windows_executed")))
    require_const(name + " windows resultClaimed", windows["resultClaimed"], False)
    require_text(name + " windows decisionRef", windows["decisionRef"])

    privacy = document["privacy"]
    require_object(
        name + " privacy",
        privacy,
        (
            "typedTextRecorded",
            "clipboardPayloadRecorded",
            "credentialOrKeyMaterialRecorded",
            "hostnameOrAddressRecorded",
            "rawCaptureCommitted",
            "sanitizationReviewed",
        ),
    )
    for key in (
        "typedTextRecorded",
        "clipboardPayloadRecorded",
        "credentialOrKeyMaterialRecorded",
        "hostnameOrAddressRecorded",
        "rawCaptureCommitted",
    ):
        require_const(name + " privacy " + key, privacy[key], False)
    require_const(name + " privacy sanitizationReviewed", privacy["sanitizationReviewed"], True)
    return document


def validate_e2e_validation(document, repo_root, commit):
    name = "tests/e2e-validation.json"
    require_object(
        name,
        document,
        ("schemaVersion", "issue", AUTHOR_HEAD_KEY, "redPhase", "mutationChecks", "greenPhase"),
    )
    require_const(name + " schemaVersion", document["schemaVersion"], 1)
    require_const(name + " issue", document["issue"], ISSUE_ID)
    require_author_head(name + " " + AUTHOR_HEAD_KEY, document[AUTHOR_HEAD_KEY], repo_root, commit)

    red = document["redPhase"]
    if not isinstance(red, list) or not 1 <= len(red) <= MAX_RECORDS:
        fail(name + " redPhase must be a bounded non-empty array")
    for index, entry in enumerate(red, start=1):
        context = name + " redPhase " + str(index)
        require_object(context, entry, ("phase", "command", "startedAt", "endedAt", "exitCode", "observed"))
        require_text(context + " phase", entry["phase"])
        require_text(context + " command", entry["command"])
        started = require_timestamp(context + " startedAt", entry["startedAt"])
        ended = require_timestamp(context + " endedAt", entry["endedAt"])
        if started > ended:
            fail(context + " timestamps are out of order")
        if require_exit_code(context + " exitCode", entry["exitCode"]) == 0:
            fail(context + " records a red phase that did not fail")
        require_text(context + " observed", entry["observed"])

    mutations = document["mutationChecks"]
    if not isinstance(mutations, list) or not 1 <= len(mutations) <= MAX_RECORDS:
        fail(name + " mutationChecks must be a bounded non-empty array")
    seen = set()
    for index, entry in enumerate(mutations, start=1):
        context = name + " mutationCheck " + str(index)
        require_object(context, entry, ("case", "mutation", "exitCode", "observed", "resultWritten"))
        case_id = require_text(context + " case", entry["case"])
        if case_id in seen:
            fail(context + " duplicates a mutation case")
        seen.add(case_id)
        require_text(context + " mutation", entry["mutation"])
        if require_exit_code(context + " exitCode", entry["exitCode"]) == 0:
            fail(context + " records a mutation that did not fail")
        require_text(context + " observed", entry["observed"])
        require_const(context + " resultWritten", entry["resultWritten"], False)

    green = document["greenPhase"]
    if not isinstance(green, list) or not 1 <= len(green) <= MAX_RECORDS:
        fail(name + " greenPhase must be a bounded non-empty array")
    for index, entry in enumerate(green, start=1):
        context = name + " greenPhase " + str(index)
        require_object(context, entry, ("command", "startedAt", "endedAt", "exitCode", "observed"))
        require_text(context + " command", entry["command"])
        started = require_timestamp(context + " startedAt", entry["startedAt"])
        ended = require_timestamp(context + " endedAt", entry["endedAt"])
        if started > ended:
            fail(context + " timestamps are out of order")
        require_const(context + " exitCode", entry["exitCode"], 0)
        require_text(context + " observed", entry["observed"])
    return len(red), len(mutations), len(green)


def build_result(commit, lock, started_at, ended_at, payload_digest, payload_length,
                 metadata_digest, metadata_length, observation_count, payload_bytes,
                 tracked_count, red_count, mutation_count, green_count, review_present):
    environment = {
        "localOS": "{0} {1} build {2} {3}".format(
            lock_value(lock, ("macos_capture_host", "os", "name")),
            lock_value(lock, ("macos_capture_host", "os", "version")),
            lock_value(lock, ("macos_capture_host", "os", "build")),
            lock_value(lock, ("macos_capture_host", "architecture")),
        ),
        "peerProduct": "Barrier {0} external test peer".format(
            lock_value(lock, ("linux_peer", "barrier_server", "executable"))
        ),
        "peerVersion": "{0} protocol {1}".format(
            lock_value(lock, ("linux_peer", "barrier_server", "version")),
            lock_value(lock, ("linux_peer", "barrier_server", "protocol_version")),
        ),
        "peerRole": lock_value(lock, ("barrier", "role")),
        "peerOS": "{0} {1} {2}".format(
            lock_value(lock, ("linux_peer", "os", "name")),
            lock_value(lock, ("linux_peer", "os", "version")),
            lock_value(lock, ("linux_peer", "architecture")),
        ),
        "networkScope": "peer loopback only through an encrypted local forward; no wider exposure",
        "tls": "disabled for that observation only; product default stays enabled and unvalidated here",
    }
    cases = [
        {
            "id": "fixture-format",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "{0} ordered observations, both directions present, 1-based contiguous sequence".format(
                    observation_count
                ),
                "canonical base64 round-trips exactly; {0} aggregate payload bytes within bounds".format(
                    payload_bytes
                ),
                "no timestamp, address, port or transport metadata key exists in the fixture",
            ],
        },
        {
            "id": "fixture-metadata",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "metadata.json matches the repository fixture metadata schema with no extra key",
                "recomputed payload digest and byte length {0} match the recorded values".format(payload_length),
                "sanitization is recorded as sanitized with no sensitive data",
            ],
        },
        {
            "id": "toolchain-lock",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "capture toolchain lock is LOCKED and scoped to this Issue only",
                "locked host, peer, Barrier and recorder versions match the lock exactly",
                "lock records no wire semantics and no Windows execution",
            ],
        },
        {
            "id": "evidence-inputs",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "plan, script, e2e readme, summary, commands, environment, tests and manual are present",
                "each author-phase record names a repository head that is an ancestor of, or equal to,"
                " the current head, and commands carries the current fixture digest",
                "red phase {0}, mutation {1} and green phase {2} records are complete and consistent".format(
                    red_count, mutation_count, green_count
                ),
                "independent review file is written by the non-implementing reviewer: present={0}".format(
                    "yes" if review_present else "not yet"
                ),
            ],
        },
        {
            "id": "privacy-scan",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "identifying-pattern scan is clean over every present Exact File and the decoded payload",
                "each hexadecimal digest in the files is a declared and verified digest value",
                "the fixture pair is {0} metadata bytes plus the recomputed payload digest".format(
                    metadata_length
                ),
            ],
        },
        {
            "id": "nonclaim-scan",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "no document line asserts field meaning, message code, endianness or compatibility",
                "no document line asserts a Windows execution or pass result",
                "observation boundaries are recorded as direction runs and not as messages",
            ],
        },
        {
            "id": "raw-capture-exclusion",
            "status": "passed",
            "exitCode": 0,
            "evidence": [
                "no tracked repository path ends with a raw capture suffix",
                "checked {0} tracked repository paths".format(tracked_count),
                "the fixture directory holds only the metadata and the sanitized payload",
            ],
        },
    ]
    artifacts = [
        {
            "path": PAYLOAD_PATH,
            "sha256": payload_digest,
            "byteLength": payload_length,
            "kind": "sanitized-fixture",
            "reviewStatus": "reviewed",
        },
        {
            "path": METADATA_PATH,
            "sha256": metadata_digest,
            "byteLength": metadata_length,
            "kind": "sanitized-fixture",
            "reviewStatus": "reviewed",
        },
    ]
    return {
        "schemaVersion": 1,
        "issueId": ISSUE_ID,
        "status": "passed",
        "startedAt": started_at,
        "endedAt": ended_at,
        "commit": commit,
        "toolchain": {
            "pythonVersion": platform.python_version(),
            "platform": platform.system() + " " + platform.release(),
            "machine": platform.machine(),
        },
        "environment": environment,
        "cases": cases,
        "artifacts": artifacts,
        "privacy": {
            "containsSensitiveData": False,
            "containsTypedText": False,
            "containsClipboardPayload": False,
            "containsCredentials": False,
            "containsKeyMaterial": False,
            "containsHostnames": False,
            "containsIPAddresses": False,
            "rawCaptureCommitted": False,
            "sanitizationReviewed": True,
        },
        "approvedDecisionRef": None,
    }


def write_result(repo_fd, payload):
    def action(dir_fd, name):
        temporary = name + ".tmp"
        try:
            fd = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW,
                0o644,
                dir_fd=dir_fd,
            )
        except OSError:
            fail("result file cannot be created")
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError:
            try:
                os.unlink(temporary, dir_fd=dir_fd)
            except OSError:
                pass
            fail("result file cannot be written")
        try:
            os.rename(temporary, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        except OSError:
            try:
                os.unlink(temporary, dir_fd=dir_fd)
            except OSError:
                pass
            fail("result file cannot be replaced")
        return True

    if with_parent_dir(repo_fd, RESULT_PATH, action) is not True:
        fail("result directory missing")


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    if len(sys.argv) != 4 or sys.argv[2] not in ("override", "repository"):
        fail("internal usage error")
    root = sys.argv[1]
    fixture_mode = sys.argv[2]
    repo_root = sys.argv[3]
    started_at = utc_now()

    try:
        st = os.lstat(root)
    except FileNotFoundError:
        fail("fixture directory missing")
    except OSError:
        fail("fixture directory unreadable")
    if stat.S_ISLNK(st.st_mode):
        fail("fixture directory is a symlink")
    if not stat.S_ISDIR(st.st_mode):
        fail("fixture directory is not a directory")
    try:
        dir_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    except OSError:
        fail("fixture directory cannot be opened safely")
    try:
        metadata_bytes = read_regular(dir_fd, METADATA_NAME)
        payload_bytes = read_regular(dir_fd, PAYLOAD_NAME)
    finally:
        os.close(dir_fd)

    capture = parse_json(PAYLOAD_NAME, payload_bytes)
    metadata = parse_json(METADATA_NAME, metadata_bytes)
    observation_count, decoded_total, decoded = validate_capture(capture)
    payload_digest = validate_metadata(metadata, payload_bytes)

    fixture_digests = set([payload_digest])
    collect_digests(metadata, fixture_digests)
    scan_identifying(METADATA_NAME, decode_text(METADATA_NAME, metadata_bytes), fixture_digests)
    scan_identifying(PAYLOAD_NAME, decode_text(PAYLOAD_NAME, payload_bytes), fixture_digests)
    scan_identifying("decoded application payload", decoded.decode("latin-1"), fixture_digests)

    if fixture_mode == "override":
        # Negative-testing mode: fixture pair only, no result, no repository state.
        sys.stdout.write("M1-024 fixture validation passed\n")
        return

    if os.environ.get("MACKVM_E2E_ISSUE") != ISSUE_ID:
        fail("MACKVM_E2E_ISSUE must be " + ISSUE_ID)
    if os.environ.get("MACKVM_E2E_RESULT") != RESULT_PATH:
        fail("MACKVM_E2E_RESULT must be " + RESULT_PATH)

    repo_fd = open_repo(repo_root)
    try:
        remove_stale_result(repo_fd)
        lock = validate_lock(repo_fd)
        check_fixture_directory(repo_fd)
        commit = git_commit(repo_root)
        tracked_count = check_no_tracked_raw_capture(repo_root)

        texts = {}
        for relative in REQUIRED_TEXT_FILES:
            texts[relative] = decode_text(relative, read_repo_file(repo_fd, relative))
        review_bytes = read_repo_file(repo_fd, REVIEW_PATH, False)
        review_present = review_bytes is not None
        if review_present:
            texts[REVIEW_PATH] = decode_text(REVIEW_PATH, review_bytes)
        texts[METADATA_PATH] = decode_text(METADATA_PATH, metadata_bytes)
        texts[PAYLOAD_PATH] = decode_text(PAYLOAD_PATH, payload_bytes)

        commands = parse_json("commands.json", texts[COMMANDS_PATH].encode("utf-8"))
        environment = parse_json("environment.json", texts[ENVIRONMENT_PATH].encode("utf-8"))
        validation = parse_json("e2e-validation.json", texts[E2E_VALIDATION_PATH].encode("utf-8"))

        validate_commands(commands, payload_digest, len(payload_bytes), repo_root, commit)
        validate_environment(environment, lock, repo_root, commit)
        red_count, mutation_count, green_count = validate_e2e_validation(validation, repo_root, commit)

        digests = set([payload_digest, commit])
        for document in (metadata, commands, environment, validation):
            collect_digests(document, digests)

        for relative in sorted(texts):
            scan_identifying(relative, texts[relative], digests)
        scan_identifying("decoded application payload", decoded.decode("latin-1"), digests)

        for relative in DOCUMENT_FILES:
            scan_claims(relative, logical_lines(texts[relative]))
        if review_present:
            scan_claims(REVIEW_PATH, logical_lines(texts[REVIEW_PATH]))
        for relative, document in (
            (METADATA_PATH, metadata),
            (COMMANDS_PATH, commands),
            (ENVIRONMENT_PATH, environment),
            (E2E_VALIDATION_PATH, validation),
        ):
            scan_claims(relative, list(string_values(document)))

        result = build_result(
            commit,
            lock,
            started_at,
            utc_now(),
            payload_digest,
            len(payload_bytes),
            hashlib.sha256(metadata_bytes).hexdigest(),
            len(metadata_bytes),
            observation_count,
            decoded_total,
            tracked_count,
            red_count,
            mutation_count,
            green_count,
            review_present,
        )
        serialized = (json.dumps(result, indent=2, sort_keys=False) + "\n").encode("utf-8")
        result_digests = set(digests)
        collect_digests(result, result_digests)
        scan_identifying(RESULT_PATH, serialized.decode("utf-8"), result_digests)
        scan_claims(RESULT_PATH, list(string_values(result)))
        write_result(repo_fd, serialized)
    finally:
        os.close(repo_fd)

    sys.stdout.write("M1-024 fixture and evidence validation passed\n")


try:
    main()
except Invalid as error:
    sys.stderr.write("M1-024 validation failed: " + str(error) + "\n")
    sys.exit(1)
except Exception:
    sys.stderr.write("M1-024 validation failed: internal validator error\n")
    sys.exit(1)
'

exec python3 -I -c "${validator_src}" "${fixture_root}" "${fixture_mode}" "${repo_root}"
