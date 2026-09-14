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

required_paths=(
  "README.md"
  "Package.swift"
  "Apps/macOS/MacKVM"
  "Packages"
  "Tests"
  "Tools"
  "docs"
  "docs/build/M1-004-repository-skeleton.md"
)

for required_path in "${required_paths[@]}"; do
  if [[ ! -e "$repository_root/$required_path" ]]; then
    echo "missing repository skeleton path: $required_path" >&2
    exit 1
  fi
done

swift build --package-path "$repository_root" >/dev/null

echo "M1-004 repository skeleton OK"
