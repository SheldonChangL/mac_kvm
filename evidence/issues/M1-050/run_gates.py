"""M1-050 gate runner: runs the gates and writes evidence/issues/M1-050/commands.json.

Usage: python3 -I evidence/issues/M1-050/run_gates.py <repository> <scratch> [--red <file>]

`<scratch>` is a directory outside the repository for the verify report. `--red` is the saved
output of the first, expected-failing run of the focused suite against the stub; it is recorded
as an entry with a note. Paths, the worktree name, the user name and the host name are masked.
"""

import argparse
import datetime
import getpass
import json
import pathlib
import platform
import re
import socket
import subprocess
import time

ISSUE = "M1-050"
LINT_FILES = [
    "Packages/KVMCore/Sources/KVMCore/ReleaseAllKeys.swift",
    "Packages/KVMCore/Tests/KVMCoreTests/ReleaseAllKeysTests.swift",
]
XUNIT = "evidence/issues/M1-050/tests/swift-testing-xunit.xml"


def now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repository")
    parser.add_argument("scratch")
    parser.add_argument("--red")
    arguments = parser.parse_args()
    repository = pathlib.Path(arguments.repository).resolve()
    scratch = pathlib.Path(arguments.scratch).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    verify_report = scratch / ISSUE / "verify.json"
    verify_report.parent.mkdir(parents=True, exist_ok=True)

    masks = [(str(repository), "<repository>"), (repository.name, "<worktree>"),
             (str(scratch), "<producer-scratch>")]
    for secret, label in ((getpass.getuser(), "<user>"), (socket.gethostname(), "<host>"),
                          (socket.gethostname().split(".")[0], "<host>")):
        if secret:
            masks.append((secret, label))

    def mask(text: str) -> str:
        for old, new in masks:
            text = text.replace(old, new)
        return re.sub(r"/Users/[^\s\"']*", "<path>", text)

    def tool(command: list[str]) -> str:
        return subprocess.run(command, capture_output=True, text=True, cwd=repository).stdout.strip()

    base = tool(["git", "rev-parse", "origin/main"])
    commands = [
        ["timeout", "900", "swift", "test", "--filter", "ReleaseAllKeys",
         "--xunit-output", XUNIT],
        ["timeout", "900", "swift", "test"],
        ["timeout", "900", "swift", "test", "-Xswiftc", "-warnings-as-errors"],
        ["timeout", "900", "swift", "test", "--package-path", "Packages/KVMCore"],
        ["swift", "format", "lint", "--strict", "--no-color-diagnostics", *LINT_FILES],
        ["swift", "format", "lint", "--recursive", "--strict", "--no-color-diagnostics",
         "Package.swift", "Apps", "Packages", "Tests", "reference"],
        ["xcodebuild", "-workspace", "MacKVM.xcworkspace", "-scheme", "MacKVM",
         "-destination", "platform=macOS", "build"],
        ["make", "docs-check"],
        ["make", "architecture-check"],
        ["python3", "Tools/Backlog/validate_package.py"],
        ["git", "diff", "--cached", "--check"],
        ["make", "verify", f"REPORT={verify_report}"],
    ]
    entries = []
    if arguments.red:
        entries.append({
            "command": "timeout 900 swift test --filter ReleaseAllKeys",
            "startedAt": None, "endedAt": None, "exitCode": 1,
            "stdout": mask(pathlib.Path(arguments.red).read_text()), "stderr": "",
            "note": "expected failure (RED): behavior tests against the compiling stub, "
                    "recorded from the first run",
        })
    failed = False
    for command in commands:
        started = now()
        process = subprocess.run(command, capture_output=True, text=True, cwd=repository)
        entry = {
            "command": mask(" ".join(command)),
            "startedAt": started, "endedAt": now(), "exitCode": process.returncode,
            "stdout": mask(process.stdout[-20000:]), "stderr": mask(process.stderr[-20000:]),
        }
        entries.append(entry)
        failed = failed or process.returncode != 0
        print(f"{process.returncode}: {entry['command']}", flush=True)
    report = {
        "schemaVersion": 1, "issue": ISSUE, "baseCommit": base, "date": now(),
        "toolchain": {
            "swift": tool(["swift", "--version"]).splitlines()[0:2],
            "python": platform.python_version(),
            "macOS": platform.mac_ver()[0], "architecture": platform.machine(),
        },
        "commands": entries,
    }
    out = repository / "evidence/issues/M1-050/commands.json"
    out.write_text(mask(json.dumps(report, indent=2)) + "\n", encoding="utf-8")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
