"""M4-020 mutation runner.

Usage:
  python3 -I evidence/issues/M4-020/mutations/run_mutations.py <repository> --group swift
      [--scratch-path <dir>] [--out <json>]
  python3 -I evidence/issues/M4-020/mutations/run_mutations.py <repository> --group checker
      [--out <json>]

The swift group edits LinuxSkeleton.swift and runs `swift test --filter LinuxPlatformTests`.
In the root package LinuxPlatform builds only on Linux. LinuxSkeleton.swift and its tests use
only Foundation and Testing, so the group also runs on macOS against a mirror: a directory with
the same relative paths for the two files and the LOCK file, and a small manifest that declares
the two targets and whose trailing comment holds the root manifest's text (the manifest-pin
test reads it). The <repository> argument is then that mirror. The checker group edits the architecture checker and runs its
unittest suite; it runs anywhere.

Each mutant is an exact text replacement whose searched text must occur exactly once. A mutant
is killed when the run exits non-zero, the build succeeded and every test in its `killers` list
failed. After each mutant the file is restored from a backup and compared byte for byte. A
baseline run on the unmodified tree must pass first. Exit 0 only when the baseline passes,
every mutant is killed and every restore is clean. The JSON holds repository-relative paths.
"""

import argparse
import datetime
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys

SKELETON = "Packages/LinuxPlatform/Sources/LinuxPlatform/LinuxSkeleton.swift"
CHECKER = "Tools/architecture-check/architecture-check.py"
TIMEOUT_SECONDS = 1800

MUTANTS = {
    "swift": [
        {
            "id": "M1",
            "mutation": "detection ignores WAYLAND_DISPLAY and XDG_SESSION_TYPE=wayland",
            "file": SKELETON,
            "find": (
                "    if value(waylandDisplayVariable, in: environment) != nil"
                " || sessionType == \"wayland\" {\n"
            ),
            "replace": "    if false && sessionType == \"wayland\" {\n",
            "killers": [
                "WAYLAND_DISPLAY makes the session wayland, even with an XWayland DISPLAY",
                "XDG_SESSION_TYPE=wayland makes the session wayland, whatever its case",
            ],
        },
        {
            "id": "M2",
            "mutation": "detection returns x11 when nothing is set",
            "file": SKELETON,
            "find": "    return .headless\n  }\n",
            "replace": "    return .x11\n  }\n",
            "killers": [
                "nothing set is headless",
                "empty and blank values count as unset",
                "XDG_SESSION_TYPE=x11 without DISPLAY is headless: there is nothing to connect to",
                "unrelated variables do not change the answer",
            ],
        },
        {
            "id": "M3",
            "mutation": "a toolchain lock constant drifts from LOCK (swift-nio 2.104.0 -> 2.105.0)",
            "file": SKELETON,
            "find": "      \"swift-nio\": \"2.104.0\",\n",
            "replace": "      \"swift-nio\": \"2.105.0\",\n",
            "killers": [
                "the constants mirror the LOCK file exactly",
                "the root manifest pins every LOCK dependency with exact:",
            ],
        },
    ],
    "checker": [
        {
            "id": "M4",
            "mutation": "the checker no longer forbids CX11 in KVMCore",
            "file": CHECKER,
            "find": "FORBIDDEN_KVMCORE_IMPORTS = (\n    \"CX11\",\n",
            "replace": "FORBIDDEN_KVMCORE_IMPORTS = (\n",
            "killers": ["test_kvmcore_rejects_linux_platform_imports"],
        },
        {
            "id": "M5",
            "mutation": (
                "the checker no longer forbids NIOCore in contracts (name dropped and, since the"
                " NIO prefix rule would still catch it, the contracts prefix rule dropped too)"
            ),
            "file": CHECKER,
            "find": "imported_module, FORBIDDEN_CONTRACT_IMPORTS, LINUX_CORE_FORBIDDEN_PREFIXES\n",
            "replace": (
                "imported_module,\n"
                "                    tuple(m for m in FORBIDDEN_CONTRACT_IMPORTS if m != \"NIOCore\"),\n"
                "                    (),\n"
            ),
            "killers": ["test_contracts_reject_linux_platform_imports"],
        },
        {
            "id": "M6",
            "mutation": "XEvent is not flagged as a contract platform type",
            "file": CHECKER,
            "find": "    \"XButtonEvent\",\n    \"XEvent\",\n",
            "replace": "    \"XButtonEvent\",\n",
            "killers": ["test_contracts_reject_x11_event_types"],
        },
        {
            "id": "R1",
            "mutation": "review: NIO*/Crypto*/_Crypto* families no longer forbidden by prefix in Core",
            "file": CHECKER,
            "find": 'LINUX_CORE_FORBIDDEN_PREFIXES = ("NIO", "Crypto", "_Crypto")\n',
            "replace": "LINUX_CORE_FORBIDDEN_PREFIXES = ()\n",
            "killers": [
                "test_kvmcore_rejects_linux_module_families",
                "test_contracts_reject_linux_module_families",
            ],
        },
        {
            "id": "R2",
            "mutation": "review: NIO* family no longer concrete networking in protocol roots",
            "file": CHECKER,
            "find": 'CONCRETE_NETWORK_PREFIXES = ("NIO",)\n',
            "replace": "CONCRETE_NETWORK_PREFIXES = ()\n",
            "killers": ["test_protocol_modules_reject_nio_family"],
        },
        {
            "id": "R3",
            "mutation": "review: Musl no longer forbidden in KVMCore",
            "file": CHECKER,
            "find": (
                "FORBIDDEN_KVMCORE_IMPORTS = (\n    \"CX11\",\n    \"CXFixes\",\n"
                "    \"CXRandR\",\n    \"CXTest\",\n    \"Crypto\",\n    \"Glibc\",\n"
                "    \"Musl\",\n"
            ),
            "replace": (
                "FORBIDDEN_KVMCORE_IMPORTS = (\n    \"CX11\",\n    \"CXFixes\",\n"
                "    \"CXRandR\",\n    \"CXTest\",\n    \"Crypto\",\n    \"Glibc\",\n"
            ),
            "killers": ["test_kvmcore_rejects_linux_module_families"],
        },
    ],
}

SWIFT_FAILED = re.compile(r'Test "(.+?)" (?:failed|recorded an issue)')
SWIFT_SUMMARY = re.compile(r"Test run with \d+ tests? in \d+ suites? (passed|failed)")
SWIFT_COMPILE_ERROR = re.compile(r"\.swift:\d+:\d+: error:")
PY_FAILED = re.compile(r"^(?:FAIL|ERROR): (test_\w+)", re.MULTILINE)
PY_SUMMARY = re.compile(r"^Ran \d+ tests?", re.MULTILINE)


def command_for(group, repository, scratch):
    if group == "swift":
        command = ["swift", "test", "--filter", "LinuxPlatformTests"]
        if scratch:
            command += ["--scratch-path", scratch]
        return command
    return [
        sys.executable, "-m", "unittest", "discover",
        "-s", "Tools/architecture-check/tests", "-p", "test_*.py",
    ]


def run(command, repository):
    completed = subprocess.run(
        command, cwd=repository, capture_output=True, text=True, timeout=TIMEOUT_SECONDS
    )
    return completed.returncode, completed.stdout + completed.stderr


def failed_tests(group, output):
    if group == "swift":
        return sorted(set(SWIFT_FAILED.findall(output)))
    return sorted(set(PY_FAILED.findall(output)))


def built(group, output):
    if group == "swift":
        return bool(SWIFT_SUMMARY.search(output)) and not SWIFT_COMPILE_ERROR.search(output)
    return bool(PY_SUMMARY.search(output))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("--group", choices=sorted(MUTANTS), required=True)
    parser.add_argument("--scratch-path")
    parser.add_argument("--out")
    options = parser.parse_args()
    repository = pathlib.Path(options.repository).resolve()
    group = options.group
    command = command_for(group, repository, options.scratch_path)
    out = pathlib.Path(options.out) if options.out else (
        repository / f"evidence/issues/M4-020/mutations/mutations-{group}.json"
    )

    report = {
        "schemaVersion": 1,
        "issue": "M4-020",
        "group": group,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "command": " ".join(
            "<scratch>" if part == options.scratch_path else
            ("python3" if part == sys.executable else part)
            for part in command
        ),
        "files": {},
        "mutants": [],
    }
    for path in sorted({mutant["file"] for mutant in MUTANTS[group]}):
        data = (repository / path).read_bytes()
        report["files"][path] = hashlib.sha256(data).hexdigest()

    code, output = run(command, repository)
    report["baseline"] = {
        "exitCode": code,
        "built": built(group, output),
        "failedTests": failed_tests(group, output),
    }
    ok = code == 0
    if not ok:
        print(output[-4000:], file=sys.stderr)

    for mutant in MUTANTS[group]:
        path = repository / mutant["file"]
        original = path.read_bytes()
        text = original.decode("utf-8")
        count = text.count(mutant["find"])
        entry = {key: mutant[key] for key in ("id", "mutation", "file", "killers")}
        if count != 1:
            entry.update(applied=False, occurrences=count, killed=False)
            report["mutants"].append(entry)
            ok = False
            continue
        backup = path.with_name(path.name + ".m4-020-backup")
        shutil.copy2(path, backup)
        try:
            path.write_text(text.replace(mutant["find"], mutant["replace"], 1), encoding="utf-8")
            code, output = run(command, repository)
        finally:
            shutil.copy2(backup, path)
            backup.unlink()
        failures = failed_tests(group, output)
        killed = code != 0 and built(group, output) and all(
            killer in failures for killer in mutant["killers"]
        )
        restored = path.read_bytes() == original
        entry.update(
            applied=True,
            exitCode=code,
            built=built(group, output),
            failedTests=failures,
            killed=killed,
            restoredByteForByte=restored,
        )
        report["mutants"].append(entry)
        ok = ok and killed and restored
        print(f"{mutant['id']}: killed={killed} restored={restored} failed={failures}")

    report["allKilled"] = ok
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
