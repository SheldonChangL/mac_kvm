#!/usr/bin/env bash

set -euo pipefail

if [[ $# -gt 1 ]]; then
  echo "usage: $0 [repository-root]" >&2
  exit 64
fi

repository_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

if [[ ! -d "$repository_root" ]]; then
  echo "repository root does not exist: $repository_root" >&2
  exit 66
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "native Apple Silicon host required; found $(uname -m)" >&2
  exit 1
fi

translated="$(sysctl -in sysctl.proc_translated 2>/dev/null || echo 0)"
if [[ "$translated" == "1" ]]; then
  echo "Rosetta-translated execution is not allowed" >&2
  exit 1
fi

swift package --package-path "$repository_root" dump-package |
  python3 -c '
import json
import sys

manifest = json.load(sys.stdin)
platforms = manifest.get("platforms", [])
is_macos_14 = any(
    platform.get("platformName") == "macos"
    and platform.get("version") == "14.0"
    for platform in platforms
)
if not is_macos_14:
    raise SystemExit("Package.swift must declare macOS 14.0")
'

swift build --package-path "$repository_root" --arch arm64
binary_directory="$(swift build --package-path "$repository_root" --arch arm64 --show-bin-path)"
binary_path="$binary_directory/MacKVM"

if [[ ! -x "$binary_path" ]]; then
  echo "MacKVM build product is missing or not executable: $binary_path" >&2
  exit 1
fi

binary_architectures="$(lipo -archs "$binary_path")"
if [[ "$binary_architectures" != "arm64" ]]; then
  echo "MacKVM must be arm64-only; found: $binary_architectures" >&2
  exit 1
fi

minimum_macos_version="$(
  otool -l "$binary_path" |
    awk '/LC_BUILD_VERSION/ { in_build_version = 1; next } in_build_version && $1 == "minos" { print $2; exit }'
)"
if [[ "$minimum_macos_version" != "14.0" ]]; then
  echo "MacKVM deployment target must be macOS 14.0; found: $minimum_macos_version" >&2
  exit 1
fi

echo "M1-005 macOS 14 arm64 build OK"
