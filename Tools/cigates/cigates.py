#!/usr/bin/env python3

import argparse
import dataclasses
import datetime
import hashlib
import json
import os
import platform
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple


EXIT_FAILURE = 1
EXIT_USAGE = 64
EXIT_NOT_FOUND = 66
EXIT_CANCELLED = 130


def handle_termination_signal(signum, frame) -> None:
    del signum, frame
    raise KeyboardInterrupt


def utc_now() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds")


@dataclasses.dataclass(frozen=True)
class GateSpec:
    name: str
    command: Tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class GateResult:
    name: str
    command: List[str]
    status: str
    exit_code: Optional[int]
    started_at: Optional[str]
    ended_at: Optional[str]
    duration_ms: int
    stdout_sha256: str
    stderr_sha256: str
    stdout_line_count: int
    stderr_line_count: int

    def as_dict(self):
        return {
            "name": self.name,
            "command": self.command,
            "status": self.status,
            "exitCode": self.exit_code,
            "startedAt": self.started_at,
            "endedAt": self.ended_at,
            "durationMs": self.duration_ms,
            "stdoutSha256": self.stdout_sha256,
            "stderrSha256": self.stderr_sha256,
            "stdoutLineCount": self.stdout_line_count,
            "stderrLineCount": self.stderr_line_count,
        }


@dataclasses.dataclass(frozen=True)
class TestDiscovery:
    relative_paths: Tuple[Path, ...]
    errors: Tuple[str, ...]


def output_metadata(output: str):
    encoded = output.encode("utf-8", errors="replace")
    return hashlib.sha256(encoded).hexdigest(), len(output.splitlines())


def terminate_process_group(process) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return

    try:
        process.wait(timeout=2)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()


def run_gate(
    gate: GateSpec, repository_root: Path, timeout_seconds: int
) -> GateResult:
    started_at = utc_now()
    started_monotonic = time.monotonic()
    stdout = ""
    stderr = ""

    try:
        process = subprocess.Popen(
            list(gate.command),
            cwd=repository_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
    except OSError as error:
        stderr = f"{type(error).__name__}: command could not be started"
        stderr_sha256, stderr_line_count = output_metadata(stderr)
        return GateResult(
            name=gate.name,
            command=list(gate.command),
            status="failed-to-start",
            exit_code=None,
            started_at=started_at,
            ended_at=utc_now(),
            duration_ms=round((time.monotonic() - started_monotonic) * 1000),
            stdout_sha256=output_metadata("")[0],
            stderr_sha256=stderr_sha256,
            stdout_line_count=0,
            stderr_line_count=stderr_line_count,
        )

    status = "failed"
    exit_code = None
    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
        exit_code = process.returncode
        status = "passed" if exit_code == 0 else "failed"
    except subprocess.TimeoutExpired:
        terminate_process_group(process)
        stdout, stderr = process.communicate()
        status = "timed-out"
    except BaseException:
        terminate_process_group(process)
        raise

    stdout_sha256, stdout_line_count = output_metadata(stdout)
    stderr_sha256, stderr_line_count = output_metadata(stderr)
    return GateResult(
        name=gate.name,
        command=list(gate.command),
        status=status,
        exit_code=exit_code,
        started_at=started_at,
        ended_at=utc_now(),
        duration_ms=round((time.monotonic() - started_monotonic) * 1000),
        stdout_sha256=stdout_sha256,
        stderr_sha256=stderr_sha256,
        stdout_line_count=stdout_line_count,
        stderr_line_count=stderr_line_count,
    )


def discover_tool_test_files(repository_root: Path) -> TestDiscovery:
    tools_root = repository_root / "Tools"
    if not tools_root.is_dir() or tools_root.is_symlink():
        return TestDiscovery((), ("tools-root-missing",))

    relative_paths = []
    errors = []
    try:
        tool_roots = sorted(tools_root.iterdir(), key=lambda path: path.name)
        for tool_root in tool_roots:
            if tool_root.is_symlink():
                errors.append("tool-root-symlink")
                continue
            if not tool_root.is_dir():
                continue
            tests_root = tool_root / "tests"
            if tests_root.is_symlink():
                errors.append("tool-test-symlink")
                continue
            if not tests_root.is_dir():
                continue
            for candidate in sorted(
                tests_root.rglob("*"),
                key=lambda path: path.relative_to(repository_root).as_posix(),
            ):
                if candidate.is_symlink():
                    errors.append("tool-test-symlink")
                    continue
                if (
                    candidate.is_file()
                    and candidate.name.startswith("test_")
                    and candidate.suffix == ".py"
                ):
                    relative_paths.append(candidate.relative_to(repository_root))
    except OSError:
        errors.append("tool-test-discovery-io-failure")

    unique_paths = tuple(
        sorted(set(relative_paths), key=lambda path: path.as_posix())
    )
    return TestDiscovery(unique_paths, tuple(sorted(set(errors))))


def discover_evidence_test_files(repository_root: Path) -> TestDiscovery:
    evidence_root = repository_root / "evidence"
    if evidence_root.is_symlink():
        return TestDiscovery((), ("evidence-root-symlink",))
    if not evidence_root.is_dir():
        return TestDiscovery((), ("evidence-root-missing",))

    issues_root = evidence_root / "issues"
    if issues_root.is_symlink():
        return TestDiscovery((), ("evidence-issues-root-symlink",))
    if not issues_root.is_dir():
        return TestDiscovery((), ("evidence-issues-root-missing",))

    relative_paths = []
    errors = []
    try:
        issue_roots = sorted(issues_root.iterdir(), key=lambda path: path.name)
        for issue_root in issue_roots:
            if issue_root.is_symlink():
                errors.append("evidence-issue-root-symlink")
                continue
            if not issue_root.is_dir():
                continue
            tests_root = issue_root / "tests"
            if tests_root.is_symlink():
                errors.append("evidence-test-symlink")
                continue
            if not tests_root.is_dir():
                continue
            for candidate in sorted(
                tests_root.rglob("*"),
                key=lambda path: path.relative_to(repository_root).as_posix(),
            ):
                if candidate.is_symlink():
                    errors.append("evidence-test-symlink")
                    continue
                if (
                    candidate.is_file()
                    and candidate.name.startswith("test_")
                    and candidate.suffix == ".py"
                ):
                    relative_paths.append(candidate.relative_to(repository_root))
    except OSError:
        errors.append("evidence-test-discovery-io-failure")

    unique_paths = tuple(
        sorted(set(relative_paths), key=lambda path: path.as_posix())
    )
    return TestDiscovery(unique_paths, tuple(sorted(set(errors))))


def build_tool_test_gate_specs(discovery: TestDiscovery) -> List[GateSpec]:
    gates = []
    for relative_path in discovery.relative_paths:
        tool_relative_path = Path(*relative_path.parts[1:])
        gates.append(
            GateSpec(
                "tool-test:{0}".format(tool_relative_path.as_posix()),
                (
                    "python3",
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    relative_path.parent.as_posix(),
                    "-p",
                    relative_path.name,
                    "-v",
                ),
            )
        )
    return gates


def build_evidence_test_gate_specs(discovery: TestDiscovery) -> List[GateSpec]:
    gates = []
    for relative_path in discovery.relative_paths:
        evidence_relative_path = Path(*relative_path.parts[2:])
        gates.append(
            GateSpec(
                "evidence-test:{0}".format(evidence_relative_path.as_posix()),
                (
                    "python3",
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    relative_path.parent.as_posix(),
                    "-p",
                    relative_path.name,
                    "-v",
                ),
            )
        )
    return gates


def build_gate_specs(repository_root: Path) -> List[GateSpec]:
    tool_discovery = discover_tool_test_files(repository_root)
    evidence_discovery = discover_evidence_test_files(repository_root)
    gates = [
        GateSpec(
            "manifest-validation",
            ("python3", "Tools/Backlog/validate_package.py"),
        ),
        GateSpec(
            "docs-check",
            ("python3", "Tools/docs-check/docs-check.py"),
        ),
        GateSpec(
            "architecture-check",
            ("python3", "Tools/architecture-check/architecture-check.py"),
        ),
        GateSpec(
            "code-quality",
            ("python3", "Tools/code-quality/code-quality.py"),
        ),
        GateSpec(
            "tool-test-discovery",
            (
                "python3",
                "Tools/cigates/cigates.py",
                "--repository-root",
                ".",
                "--check-tool-tests",
                "--expected-tool-test-count",
                str(len(tool_discovery.relative_paths)),
            ),
        ),
        GateSpec(
            "evidence-test-discovery",
            (
                "python3",
                "Tools/cigates/cigates.py",
                "--repository-root",
                ".",
                "--check-evidence-tests",
                "--expected-evidence-test-count",
                str(len(evidence_discovery.relative_paths)),
            ),
        ),
    ]
    gates.extend(build_tool_test_gate_specs(tool_discovery))
    gates.extend(build_evidence_test_gate_specs(evidence_discovery))
    gates.extend(
        [
            GateSpec(
                "swift-package-test:KVMContracts",
                (
                    "swift",
                    "test",
                    "--package-path",
                    "Packages/KVMContracts",
                    "-Xswiftc",
                    "-warnings-as-errors",
                ),
            ),
            GateSpec(
                "swift-package-test:MacPlatform",
                (
                    "swift",
                    "test",
                    "--package-path",
                    "Packages/MacPlatform",
                ),
            ),
            GateSpec(
                "repository-contract-tests",
                (
                    "python3",
                    "-m",
                    "unittest",
                    "discover",
                    "-s",
                    "Tests/Contracts",
                    "-p",
                    "test_*.py",
                    "-v",
                ),
            ),
            GateSpec(
                "swift-test-targets",
                ("./Tools/verify/M1-007-test-targets.sh",),
            ),
            GateSpec(
                "native-arm64-build",
                ("./Tools/verify/M1-005-mac-arm64-build.sh",),
            ),
        ]
    )
    return gates


def command_first_line(command: Sequence[str], repository_root: Path) -> str:
    try:
        result = subprocess.run(
            list(command),
            cwd=repository_root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"
    output = result.stdout.strip() or result.stderr.strip()
    return output.splitlines()[0] if result.returncode == 0 and output else "unavailable"


def collect_context(repository_root: Path):
    return {
        "commit": command_first_line(("git", "rev-parse", "HEAD"), repository_root),
        "pythonVersion": platform.python_version(),
        "swiftVersion": command_first_line(("swift", "--version"), repository_root),
        "platform": platform.platform(),
        "machine": platform.machine(),
    }


def not_run_result(gate: GateSpec) -> GateResult:
    empty_sha256 = output_metadata("")[0]
    return GateResult(
        name=gate.name,
        command=list(gate.command),
        status="not-run",
        exit_code=None,
        started_at=None,
        ended_at=None,
        duration_ms=0,
        stdout_sha256=empty_sha256,
        stderr_sha256=empty_sha256,
        stdout_line_count=0,
        stderr_line_count=0,
    )


def write_report(report_path: Path, payload) -> None:
    report_path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=report_path.parent,
            prefix=f".{report_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)
            json.dump(payload, temporary_file, indent=2, sort_keys=True)
            temporary_file.write("\n")
        os.replace(temporary_path, report_path)
    finally:
        if temporary_path is not None and temporary_path.exists():
            temporary_path.unlink()


def run_pipeline(
    repository_root: Path,
    report_path: Path,
    timeout_seconds: int,
    execute_gate: Callable[[GateSpec, Path, int], GateResult] = run_gate,
    context_provider=None,
) -> int:
    started_at = utc_now()
    context = (
        context_provider()
        if context_provider is not None
        else collect_context(repository_root)
    )
    print(
        "CI context: "
        f"commit={context['commit']} "
        f"machine={context['machine']} "
        f"python={context['pythonVersion']} "
        f"swift={context['swiftVersion']}"
    )

    gates = build_gate_specs(repository_root)
    results = []
    pipeline_exit_code = 0

    for index, gate in enumerate(gates):
        try:
            result = execute_gate(gate, repository_root, timeout_seconds)
        except KeyboardInterrupt:
            result = not_run_result(gate)
            result = dataclasses.replace(
                result,
                status="cancelled",
                started_at=utc_now(),
                ended_at=utc_now(),
            )
            pipeline_exit_code = EXIT_CANCELLED
        results.append(result)
        print(
            f"[{result.status.upper()}] {result.name} "
            f"exit={result.exit_code} durationMs={result.duration_ms}"
        )
        if result.status != "passed":
            if pipeline_exit_code == 0:
                pipeline_exit_code = EXIT_FAILURE
            results.extend(not_run_result(item) for item in gates[index + 1 :])
            break

    payload = {
        "schemaVersion": 1,
        "status": "passed" if pipeline_exit_code == 0 else "failed",
        "startedAt": started_at,
        "endedAt": utc_now(),
        "commit": context["commit"],
        "toolchain": {
            "pythonVersion": context["pythonVersion"],
            "swiftVersion": context["swiftVersion"],
            "platform": context["platform"],
            "machine": context["machine"],
        },
        "gates": [result.as_dict() for result in results],
    }
    write_report(report_path, payload)
    print(f"CI report: {report_path}")
    return pipeline_exit_code


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description="Run MacKVM PR build/test gates")
    parser.add_argument(
        "--repository-root",
        default=str(Path(__file__).resolve().parents[2]),
    )
    parser.add_argument(
        "--report",
        default="artifacts/ci/m1-008-report.json",
    )
    parser.add_argument("--timeout-seconds", type=int, default=600)
    parser.add_argument("--check-tool-tests", action="store_true")
    parser.add_argument("--expected-tool-test-count", type=int)
    parser.add_argument("--check-evidence-tests", action="store_true")
    parser.add_argument("--expected-evidence-test-count", type=int)
    return parser.parse_args(arguments)


def main(arguments=None) -> int:
    options = parse_arguments(arguments)
    repository_root = Path(options.repository_root).resolve()
    if not repository_root.is_dir():
        print(f"repository root does not exist: {repository_root}", file=sys.stderr)
        return EXIT_NOT_FOUND
    if options.timeout_seconds <= 0:
        print("timeout seconds must be positive", file=sys.stderr)
        return EXIT_USAGE
    if options.check_tool_tests:
        discovery = discover_tool_test_files(repository_root)
        if discovery.errors:
            print(
                "tool test discovery failed: {0}".format(
                    ",".join(discovery.errors)
                ),
                file=sys.stderr,
            )
            return EXIT_FAILURE
        if (
            options.expected_tool_test_count is not None
            and options.expected_tool_test_count != len(discovery.relative_paths)
        ):
            print("tool test discovery failed: count-mismatch", file=sys.stderr)
            return EXIT_FAILURE
        print(
            "tool test discovery OK: {0} files".format(
                len(discovery.relative_paths)
            )
        )
        return 0
    if options.check_evidence_tests:
        discovery = discover_evidence_test_files(repository_root)
        if discovery.errors:
            print(
                "evidence test discovery failed: {0}".format(
                    ",".join(discovery.errors)
                ),
                file=sys.stderr,
            )
            return EXIT_FAILURE
        if (
            options.expected_evidence_test_count is not None
            and options.expected_evidence_test_count != len(discovery.relative_paths)
        ):
            print("evidence test discovery failed: count-mismatch", file=sys.stderr)
            return EXIT_FAILURE
        print(
            "evidence test discovery OK: {0} files".format(
                len(discovery.relative_paths)
            )
        )
        return 0

    report_path = Path(options.report)
    if not report_path.is_absolute():
        report_path = repository_root / report_path
    previous_sigterm_handler = signal.signal(
        signal.SIGTERM, handle_termination_signal
    )
    try:
        return run_pipeline(
            repository_root,
            report_path,
            timeout_seconds=options.timeout_seconds,
        )
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)


if __name__ == "__main__":
    raise SystemExit(main())
