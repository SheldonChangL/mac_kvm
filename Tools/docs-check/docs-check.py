#!/usr/bin/env python3

import argparse
import dataclasses
import json
import os
import re
import signal
import subprocess
import sys
from pathlib import Path
from typing import Iterable, List, Optional, Sequence


EXIT_FAILURE = 1
EXIT_USAGE = 64
EXIT_NOT_FOUND = 66
EXIT_CANCELLED = 130

TRACKED_SUFFIXES = (".json", ".md")
FENCE_PATTERN = re.compile(r"^\s{0,3}(`{3,}|~{3,})(.*)$")


class DocsCheckError(Exception):
    pass


class DuplicateJSONKeyError(ValueError):
    pass


@dataclasses.dataclass(frozen=True, order=True)
class Violation:
    path: str
    line: int
    rule: str
    detail: str


def handle_termination_signal(signum, frame) -> None:
    del signum, frame
    raise KeyboardInterrupt


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


def list_tracked_files(repository_root: Path, timeout_seconds: int):
    command = ("git", "ls-files", "-z", "--", "*.md", "*.json")
    try:
        process = subprocess.Popen(
            list(command),
            cwd=repository_root,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError as error:
        raise DocsCheckError("git-ls-files-start-failed") from error

    try:
        stdout, _ = process.communicate(timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        terminate_process_group(process)
        raise DocsCheckError("git-ls-files-timed-out") from error
    except BaseException:
        terminate_process_group(process)
        raise

    if process.returncode != 0:
        raise DocsCheckError("git-ls-files-failed")

    try:
        names = [item.decode("utf-8") for item in stdout.split(b"\0") if item]
    except UnicodeError as error:
        raise DocsCheckError("git-path-invalid-utf8") from error

    paths = []
    for name in names:
        path = Path(name)
        if path.is_absolute() or ".." in path.parts or path.suffix not in TRACKED_SUFFIXES:
            raise DocsCheckError("git-path-invalid")
        paths.append(path)
    return tuple(sorted(paths, key=lambda item: item.as_posix()))


def duplicate_key_rejector(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DuplicateJSONKeyError(key)
        result[key] = value
    return result


def markdown_violations(relative_path: Path, text: str, data: bytes):
    path_text = relative_path.as_posix()
    violations = []
    lines = text.splitlines()

    if b"\r" in data:
        violations.append(
            Violation(path_text, 0, "markdown-non-lf-newline", "carriage-return")
        )

    for line_number, line in enumerate(lines, start=1):
        if line.rstrip(" \t") != line:
            violations.append(
                Violation(
                    path_text,
                    line_number,
                    "markdown-trailing-whitespace",
                    "space-or-tab",
                )
            )

    if not data.endswith(b"\n") or data.endswith(b"\n\n"):
        violations.append(
            Violation(path_text, 0, "markdown-final-newline", "exactly-one")
        )

    open_fence = None
    for line_number, line in enumerate(lines, start=1):
        match = FENCE_PATTERN.match(line)
        if match is None:
            continue
        marker = match.group(1)
        if open_fence is None:
            open_fence = (marker[0], len(marker), line_number)
            continue
        marker_character, marker_length, _ = open_fence
        if (
            marker[0] == marker_character
            and len(marker) >= marker_length
            and match.group(2).strip() == ""
        ):
            open_fence = None

    if open_fence is not None:
        _, _, opening_line = open_fence
        violations.append(
            Violation(
                path_text,
                opening_line,
                "markdown-unbalanced-fence",
                "unterminated",
            )
        )

    return violations


def json_violations(relative_path: Path, text: str):
    try:
        json.loads(text, object_pairs_hook=duplicate_key_rejector)
    except DuplicateJSONKeyError:
        return [
            Violation(
                relative_path.as_posix(),
                0,
                "json-duplicate-key",
                "duplicate-object-key",
            )
        ]
    except json.JSONDecodeError:
        return [
            Violation(
                relative_path.as_posix(),
                0,
                "json-invalid",
                "parse-failed",
            )
        ]
    return []


def check_tracked_file(repository_root: Path, relative_path: Path):
    path_text = relative_path.as_posix()
    path = repository_root / relative_path
    if path.is_symlink():
        return [Violation(path_text, 0, "tracked-file-symlink", "not-followed")]
    if not path.is_file():
        return [Violation(path_text, 0, "tracked-file-missing", "not-readable-file")]

    try:
        data = path.read_bytes()
    except OSError:
        return [Violation(path_text, 0, "tracked-file-read-error", "unreadable")]
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        return [Violation(path_text, 0, "invalid-utf8", "decode-failed")]

    if relative_path.suffix == ".md":
        return markdown_violations(relative_path, text, data)
    if relative_path.suffix == ".json":
        return json_violations(relative_path, text)
    return [Violation(path_text, 0, "tracked-file-type", "unsupported")]


def scan_repository(
    repository_root: Path,
    tracked_paths: Optional[Iterable[Path]] = None,
    timeout_seconds: int = 10,
) -> List[Violation]:
    paths: Sequence[Path]
    if tracked_paths is None:
        paths = list_tracked_files(repository_root, timeout_seconds)
    else:
        paths = tuple(tracked_paths)

    violations = []
    for relative_path in paths:
        if relative_path.is_absolute() or ".." in relative_path.parts:
            violations.append(
                Violation(
                    relative_path.as_posix(),
                    0,
                    "tracked-path-invalid",
                    "outside-repository",
                )
            )
            continue
        violations.extend(check_tracked_file(repository_root, relative_path))
    return sorted(violations)


def format_violation(violation: Violation) -> str:
    return (
        f"{violation.path}:{violation.line}: {violation.rule}: "
        f"{violation.detail}"
    )


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description="Check tracked MacKVM docs and JSON")
    parser.add_argument(
        "--repository-root",
        default=str(Path(__file__).resolve().parents[2]),
    )
    parser.add_argument("--timeout-seconds", type=int, default=10)
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
        violations = scan_repository(
            repository_root,
            timeout_seconds=options.timeout_seconds,
        )
    except DocsCheckError as error:
        print(f"docs check failed: {error}", file=sys.stderr)
        return EXIT_FAILURE
    except KeyboardInterrupt:
        print("docs check cancelled", file=sys.stderr)
        return EXIT_CANCELLED
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)

    if violations:
        for violation in violations:
            print(format_violation(violation), file=sys.stderr)
        print(f"docs check failed: {len(violations)} violation(s)", file=sys.stderr)
        return EXIT_FAILURE

    print("docs check OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
