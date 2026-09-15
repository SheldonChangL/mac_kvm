#!/usr/bin/env python3

import argparse
import dataclasses
import re
import signal
import sys
from pathlib import Path
from typing import List


EXIT_FAILURE = 1
EXIT_NOT_FOUND = 66
EXIT_CANCELLED = 130

SOURCE_SCAN_ROOTS = ("Apps", "Packages", "reference")
KVMCORE_ROOT = "Packages/KVMCore"
KVMCONTRACTS_ROOT = "Packages/KVMContracts"
PROTOCOL_ROOTS = ("Packages/BarrierCompatibility", "Packages/NativeProtocol")
PLATFORM_ROOTS = ("Packages/MacPlatform",)
BARRIER_TOKEN_ALLOWED_ROOTS = ("Packages/BarrierCompatibility",)

FORBIDDEN_KVMCORE_IMPORTS = (
    "ApplicationServices",
    "AppKit",
    "BarrierCompatibility",
    "CFNetwork",
    "CoreGraphics",
    "IOKit",
    "NativeProtocol",
    "Network",
    "NetworkExtension",
    "WinSDK",
)
FORBIDDEN_CONTRACT_IMPORTS = (
    "ApplicationServices",
    "AppKit",
    "BarrierCompatibility",
    "CFNetwork",
    "CoreGraphics",
    "IOKit",
    "MacPlatform",
    "NativeProtocol",
    "Network",
    "NetworkExtension",
    "WinSDK",
)
PROTOCOL_PLATFORM_IMPORTS = (
    "ApplicationServices",
    "AppKit",
    "CoreGraphics",
    "IOKit",
    "MacPlatform",
    "WinSDK",
)
CONCRETE_NETWORK_IMPORTS = (
    "CFNetwork",
    "Network",
    "NetworkExtension",
)
PLATFORM_PROTOCOL_IMPORTS = (
    "BarrierCompatibility",
    "NativeProtocol",
)
CONTRACT_PLATFORM_TYPES = (
    "CGEvent",
    "CGKeyCode",
    "KEYBDINPUT",
    "KeySym",
    "NSEvent",
    "input_event",
    "wl_keyboard",
    "xkb_keycode_t",
)
CONCRETE_TRANSPORT_TYPES = (
    "CFReadStream",
    "CFSocket",
    "CFStreamCreatePairWithSocket",
    "CFStreamCreatePairWithSocketToHost",
    "CFWriteStream",
    "InputStream",
    "NWConnection",
    "NWConnectionGroup",
    "NWListener",
    "NWTCPConnection",
    "OutputStream",
    "URLSession",
    "URLSessionDataTask",
    "URLSessionDownloadTask",
    "URLSessionStreamTask",
    "URLSessionTask",
    "URLSessionUploadTask",
    "URLSessionWebSocketTask",
)
BARRIER_TOKENS = ("CINN", "COUT", "DKDN", "DMMV")

IMPORT_PATTERN = re.compile(
    r"^\s*(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"(?:(?:private|fileprivate|internal|package|public|open)\s+)?"
    r"import\s+(?:(?:typealias|struct|class|enum|protocol|let|var|func)\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)\b"
)
TOKEN_PATTERN = re.compile(
    r"\b(" + "|".join(map(re.escape, BARRIER_TOKENS)) + r")\b"
)
CONTRACT_PLATFORM_TYPE_PATTERN = re.compile(
    r"\b(" + "|".join(map(re.escape, CONTRACT_PLATFORM_TYPES)) + r")\b"
)
CONTRACT_PLATFORM_CODE_PATTERN = re.compile(
    r"\b((?:XF86XK|kVK|VK|KEY|BTN|XK)_[A-Za-z0-9_]+)\b"
)
CONCRETE_TRANSPORT_PATTERN = re.compile(
    r"\b(" + "|".join(map(re.escape, CONCRETE_TRANSPORT_TYPES)) + r")\b"
    r"|\b(socket)\s*\("
)


@dataclasses.dataclass(frozen=True, order=True)
class Violation:
    path: str
    line: int
    rule: str
    detail: str


def handle_termination_signal(signum, frame) -> None:
    del signum, frame
    raise KeyboardInterrupt


def is_within(relative_path: str, root: str) -> bool:
    return relative_path == root or relative_path.startswith(f"{root}/")


def swift_source_paths(repository_root: Path):
    paths = []
    for root_name in SOURCE_SCAN_ROOTS:
        source_root = repository_root / root_name
        if source_root.is_dir():
            paths.extend(
                path for path in source_root.rglob("*.swift") if not path.is_symlink()
            )
    return sorted(paths, key=lambda item: item.relative_to(repository_root).as_posix())


def source_symlink_paths(repository_root: Path):
    paths = []
    for root_name in SOURCE_SCAN_ROOTS:
        source_root = repository_root / root_name
        if source_root.is_symlink():
            paths.append(source_root)
        elif source_root.is_dir():
            paths.extend(
                path for path in source_root.rglob("*") if path.is_symlink()
            )
    return sorted(paths, key=lambda item: item.relative_to(repository_root).as_posix())


def scan_repository(repository_root: Path) -> List[Violation]:
    violations = []
    required_root = repository_root / KVMCORE_ROOT
    if not required_root.is_dir():
        return [
            Violation(
                path=KVMCORE_ROOT,
                line=0,
                rule="required-root-missing",
                detail="KVMCore",
            )
        ]

    for path in source_symlink_paths(repository_root):
        relative_path = path.relative_to(repository_root).as_posix()
        violations.append(
            Violation(
                path=relative_path,
                line=0,
                rule="source-symlink",
                detail="source-tree",
            )
        )

    for path in swift_source_paths(repository_root):
        relative_path = path.relative_to(repository_root).as_posix()
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            violations.append(
                Violation(
                    path=relative_path,
                    line=0,
                    rule="source-read-error",
                    detail="unreadable-utf8",
                )
            )
            continue

        token_is_allowed = any(
            is_within(relative_path, allowed_root)
            for allowed_root in BARRIER_TOKEN_ALLOWED_ROOTS
        )
        path_is_kvmcore = is_within(relative_path, KVMCORE_ROOT)
        path_is_contracts = is_within(relative_path, KVMCONTRACTS_ROOT)
        path_is_protocol = any(
            is_within(relative_path, protocol_root)
            for protocol_root in PROTOCOL_ROOTS
        )
        path_is_platform = any(
            is_within(relative_path, platform_root)
            for platform_root in PLATFORM_ROOTS
        )

        for line_number, line in enumerate(source.splitlines(), start=1):
            import_match = IMPORT_PATTERN.match(line)
            imported_module = import_match.group(1) if import_match else None

            if path_is_kvmcore and imported_module in FORBIDDEN_KVMCORE_IMPORTS:
                violations.append(
                    Violation(
                        path=relative_path,
                        line=line_number,
                        rule="kvmcore-forbidden-import",
                        detail=imported_module,
                    )
                )

            if path_is_contracts:
                if imported_module in FORBIDDEN_CONTRACT_IMPORTS:
                    violations.append(
                        Violation(
                            path=relative_path,
                            line=line_number,
                            rule="contracts-forbidden-import",
                            detail=imported_module,
                        )
                    )
                if import_match is None:
                    for type_match in CONTRACT_PLATFORM_TYPE_PATTERN.finditer(line):
                        violations.append(
                            Violation(
                                path=relative_path,
                                line=line_number,
                                rule="contracts-platform-type",
                                detail=type_match.group(1),
                            )
                        )
                    for code_match in CONTRACT_PLATFORM_CODE_PATTERN.finditer(line):
                        violations.append(
                            Violation(
                                path=relative_path,
                                line=line_number,
                                rule="contracts-platform-code",
                                detail=code_match.group(1),
                            )
                        )

            if path_is_protocol:
                if imported_module in PROTOCOL_PLATFORM_IMPORTS:
                    violations.append(
                        Violation(
                            path=relative_path,
                            line=line_number,
                            rule="protocol-platform-import",
                            detail=imported_module,
                        )
                    )
                elif imported_module in CONCRETE_NETWORK_IMPORTS:
                    violations.append(
                        Violation(
                            path=relative_path,
                            line=line_number,
                            rule="protocol-concrete-network-import",
                            detail=imported_module,
                        )
                    )
                elif import_match is None:
                    for transport_match in CONCRETE_TRANSPORT_PATTERN.finditer(line):
                        detail = transport_match.group(1) or transport_match.group(2)
                        violations.append(
                            Violation(
                                path=relative_path,
                                line=line_number,
                                rule="protocol-concrete-transport",
                                detail=detail,
                            )
                        )

            if path_is_platform and imported_module in PLATFORM_PROTOCOL_IMPORTS:
                violations.append(
                    Violation(
                        path=relative_path,
                        line=line_number,
                        rule="platform-protocol-import",
                        detail=imported_module,
                    )
                )

            if not token_is_allowed:
                for token_match in TOKEN_PATTERN.finditer(line):
                    violations.append(
                        Violation(
                            path=relative_path,
                            line=line_number,
                            rule="barrier-token-outside-adapter",
                            detail=token_match.group(1),
                        )
                    )

    return sorted(violations)


def format_violation(violation: Violation) -> str:
    return (
        f"{violation.path}:{violation.line}: {violation.rule}: "
        f"{violation.detail}"
    )


def parse_arguments(arguments):
    parser = argparse.ArgumentParser(description="Check MacKVM source boundaries")
    parser.add_argument(
        "--repository-root",
        default=str(Path(__file__).resolve().parents[2]),
    )
    return parser.parse_args(arguments)


def main(arguments=None) -> int:
    options = parse_arguments(arguments)
    repository_root = Path(options.repository_root).resolve()
    if not repository_root.is_dir():
        print(f"repository root does not exist: {repository_root}", file=sys.stderr)
        return EXIT_NOT_FOUND

    previous_sigterm_handler = signal.signal(
        signal.SIGTERM, handle_termination_signal
    )
    try:
        violations = scan_repository(repository_root)
    except KeyboardInterrupt:
        print("architecture check cancelled", file=sys.stderr)
        return EXIT_CANCELLED
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm_handler)

    if violations:
        for violation in violations:
            print(format_violation(violation), file=sys.stderr)
        print(
            f"architecture check failed: {len(violations)} violation(s)",
            file=sys.stderr,
        )
        return EXIT_FAILURE

    print("architecture check OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
