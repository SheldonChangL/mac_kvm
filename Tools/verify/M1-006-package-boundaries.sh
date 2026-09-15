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

swift package --package-path "$repository_root" dump-package |
  python3 -c '
import json
import sys

manifest = json.load(sys.stdin)
targets = {target["name"]: target for target in manifest.get("targets", [])}

expected_dependencies = {
    "KVMContracts": set(),
    "KVMCore": {"KVMContracts"},
    "BarrierCompatibility": {"KVMContracts"},
    "MacPlatform": {"KVMContracts"},
    "NativeProtocol": {"KVMContracts"},
}

def dependency_names(target):
    names = set()
    for dependency in target.get("dependencies", []):
        for value in dependency.values():
            if isinstance(value, list) and value and isinstance(value[0], str):
                names.add(value[0])
            elif isinstance(value, str):
                names.add(value)
    return names

for target_name, expected in expected_dependencies.items():
    if target_name not in targets:
        raise SystemExit(f"missing Swift target: {target_name}")
    actual = dependency_names(targets[target_name])
    if actual != expected:
        raise SystemExit(
            f"invalid dependencies for {target_name}: expected {sorted(expected)}, found {sorted(actual)}"
        )

app = targets.get("MacKVM")
if app is None:
    raise SystemExit("missing Swift target: MacKVM")
required_app_dependencies = {
    "KVMCore",
    "BarrierCompatibility",
    "MacPlatform",
    "NativeProtocol",
}
actual_app_dependencies = dependency_names(app)
if actual_app_dependencies != required_app_dependencies:
    raise SystemExit(
        "invalid dependencies for MacKVM: "
        f"expected {sorted(required_app_dependencies)}, "
        f"found {sorted(actual_app_dependencies)}"
    )
'

swift build --package-path "$repository_root" --arch arm64

echo "M1-006 package boundaries OK"
