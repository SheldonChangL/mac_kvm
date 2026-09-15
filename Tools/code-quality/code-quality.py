#!/usr/bin/env python3

import argparse
import dataclasses
import hashlib
import os
import signal
import subprocess
import sys
from pathlib import Path
from typing import Callable, List, Sequence


PINNED_SWIFT_FORMAT_VERSION = "6.2.3"

EXIT_FAILURE = 1
EXIT_USAGE = 64
EXIT_NOT_FOUND = 66
EXIT_TIMEOUT = 124
EXIT_CANCELLED = 130
EXIT_COMMAND_NOT_FOUND = 127


@dataclasses.dataclass(frozen=True)
class CommandResult:
    command: List[str]
    exit_code: int
    stdout: str
    stderr: str


def handle_termination_signal(signum, frame) -> None:
    del signum, frame
    raise KeyboardInterrupt


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


def execute_command(
    command: Sequence[str], repository_root: Path, timeout_seconds: int
) -> CommandResult:
    try:
        process = subprocess.Popen(
            list(command),
            cwd=repository_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
    except OSError as error:
        return CommandResult(
            command=list(command),
            exit_code=EXIT_COMMAND_NOT_FOUND,
            stdout="",
            stderr=f"{type(error).__name__}: command could not be started",
        )

    try:
        stdout, stderr = process.communicate(timeout=timeout_seconds)
        return CommandResult(
            command=list(command),
            exit_code=process.returncode,
            stdout=stdout,
            stderr=stderr,
        )
    except subprocess.TimeoutExpired:
        terminate_process_group(process)
        stdout, stderr = process.communicate()
        return CommandResult(
            command=list(command),
            exit_code=EXIT_TIMEOUT,
            stdout=stdout,
            stderr=stderr,
        )
    except BaseException:
        terminate_process_group(process)
        raise


def quality_commands():
    return [
        ("swift", "format", "--version"),
        (
            "swift",
            "format",
            "lint",
            "--recursive",
            "--strict",
            "--no-color-diagnostics",
            "Package.swift",
            "Apps",
            "Packages",
            "Tests",
            "reference",
        ),
        ("swift", "test", "-Xswiftc", "-warnings-as-errors"),
    ]


def print_result(name: str, result: CommandResult) -> None:
    stdout_sha256, stdout_line_count = output_metadata(result.stdout)
    stderr_sha256, stderr_line_count = output_metadata(result.stderr)
    print(
        f"[{name}] exit={result.exit_code} "
        f"stdoutLines={stdout_line_count} stdoutSha256={stdout_sha256} "
        f"stderrLines={stderr_line_count} stderrSha256={stderr_sha256}"
    )


def run_quality_checks(
    repository_root: Path,
    timeout_seconds: int,
    execute: Callable[[Sequence[str], Path, int], CommandResult] = execute_command,
) -> int:
    version_command, lint_command, build_command = quality_commands()

    version_result = execute(version_command, repository_root, timeout_seconds)
    print_result("swift-format-version", version_result)
    if version_result.exit_code != 0:
        return EXIT_FAILURE
    actual_version = version_result.stdout.strip()
    if actual_version != PINNED_SWIFT_FORMAT_VERSION:
        print(
            "swift format version mismatch: "
            f"expected={PINNED_SWIFT_FORMAT_VERSION} actual={actual_version}",
            file=sys.stderr,
        )
        return EXIT_FAILURE

    lint_result = execute(lint_command, repository_root, timeout_seconds)
    print_result("swift-format-lint", lint_result)
    if lint_result.exit_code != 0:
        return EXIT_FAILURE

    build_result = execute(build_command, repository_root, timeout_seconds)
    print_result("swift-test-warnings-as-errors", build_result)
    if build_result.exit_code != 0:
        return EXIT_FAILURE

    return 0


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description="Run pinned MacKVM code-quality gates")
    parser.add_argument(
        "--repository-root",
        default=str(Path(__file__).resolve().parents[2]),
    )
    parser.add_argument("--timeout-seconds", type=int, default=600)
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

    previous_sigterm_handler = signal.signal(
        signal.SIGTERM, handle_termination_signal
    )
    try:
        return run_quality_checks(
            repository_root,
            timeout_seconds=options.timeout_seconds,
        )
    except KeyboardInterrupt:
        print("code-quality gate cancelled", file=sys.stderr)
        return EXIT_CANCELLED
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)


if __name__ == "__main__":
    raise SystemExit(main())
