"""M1-TOOLING-002 gate runner.

Usage: python3 -I evidence/issues/M1-TOOLING-002/run_gates.py <repository> <scratch-dir>

Runs the RED check (new tests against the base-commit tools, in a scratch copy), then the gates
in the repository, and writes commands.json with the repository path masked as <repository>,
the worktree basename as <worktree> and the scratch directory as <producer-scratch>.
"""

import datetime
import json
import pathlib
import platform
import shutil
import subprocess
import sys

ISSUE = "M1-TOOLING-002"
PRODUCTION = (
    "Tools/Evidence/run_e2e.py",
    "Tools/Evidence/validate_evidence.py",
    "MacKVM_Implementation_Package_v2/schemas/e2e-result.schema.json",
)
UNITTEST = ["python3", "-I", "-m", "unittest", "discover", "-s", "Tools/Evidence/tests"]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def run(args, cwd, timeout=1800):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=timeout)


def tail(text, limit=4000):
    return text if len(text) <= limit else "...[truncated]...\n" + text[-limit:]


def main():
    root = pathlib.Path(sys.argv[1]).resolve()
    scratch = pathlib.Path(sys.argv[2]).resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    base = run(["git", "rev-parse", "origin/main"], root).stdout.strip()

    def mask(text):
        return (
            text.replace(str(root), "<repository>")
            .replace(root.name, "<worktree>")
            .replace(str(scratch), "<producer-scratch>")
        )

    entries = []

    def record(label, command, cwd, note=None, timeout=1800):
        started = now()
        try:
            result = run(command, cwd, timeout)
            code, out, err = result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            code, out, err = 124, "", "timeout"
        entry = {
            "command": mask(" ".join(command)),
            "startedAt": started,
            "endedAt": now(),
            "exitCode": code,
            "stdout": mask(tail(out)),
            "stderr": mask(tail(err)),
        }
        if note:
            entry["note"] = note
        entries.append(entry)
        print(label, code, flush=True)

    # RED: the new tests against the base commit's production files.
    red = scratch / "red"
    if red.exists():
        shutil.rmtree(red)
    (red / "Tools/Evidence").mkdir(parents=True)
    shutil.copytree(root / "Tools/Evidence/tests", red / "Tools/Evidence/tests")
    for rel in PRODUCTION:
        target = red / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(subprocess.run(["git", "show", "origin/main:" + rel], cwd=root,
                                          capture_output=True, check=True).stdout)
    record("red", UNITTEST, red, note="expected failure (RED): new tests against the base-commit tools")

    record("green", UNITTEST, root)
    record("validate_package", ["python3", "Tools/Backlog/validate_package.py"], root)
    record("swift-test", ["timeout", "900", "swift", "test"], root, timeout=1000)
    record("swift-test-werror", ["timeout", "900", "swift", "test", "-Xswiftc", "-warnings-as-errors"],
           root, timeout=1000)
    record("swift-format", ["swift", "format", "lint", "--recursive", "--strict",
                            "--no-color-diagnostics", "Package.swift", "Apps", "Packages", "Tests",
                            "reference"], root)
    record("docs-check", ["make", "docs-check"], root)
    record("architecture-check", ["make", "architecture-check"], root)
    record("diff-check", ["git", "diff", "--cached", "--check"], root)
    record("verify", ["make", "verify", "REPORT=" + str(scratch / "verify.json")], root, timeout=1800)

    def version(args):
        return run(args, root).stdout.strip()

    document = {
        "schemaVersion": 1,
        "issue": ISSUE,
        "baseCommit": base,
        "date": now()[:10],
        "toolchain": {
            "swift": version(["swift", "--version"]).replace(str(root), "<repository>"),
            "python": platform.python_version(),
            "macOS": platform.mac_ver()[0],
            "architecture": platform.machine(),
        },
        "commands": entries,
    }
    (root / "evidence/issues" / ISSUE / "commands.json").write_text(json.dumps(document, indent=2) + "\n")


if __name__ == "__main__":
    main()
