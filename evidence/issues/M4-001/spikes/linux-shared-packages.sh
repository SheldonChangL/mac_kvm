#!/usr/bin/env bash
# M4-001 evidence: build and test the Foundation-only shared packages on Linux in the
# pinned toolchain image. KVMContracts and BarrierCompatibility are tested as their own
# packages. KVMCore's tests run in a scratch package that holds KVMContracts and KVMCore
# together, because the two share `package`-level declarations and so must sit in one
# SwiftPM package. The repository is mounted read-only; nothing is written to it.
set -euo pipefail
image="swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6"
root=$(cd "$(dirname "$0")/../../../.." && pwd)
docker run --rm --platform linux/amd64 -v "$root":/src:ro "$image" bash -ec 'set -o pipefail
  swift --version 2>&1 | head -1
  uname -m
  echo "== KVMContracts"
  swift test --package-path /src/Packages/KVMContracts --scratch-path /tmp/contracts 2>&1 | grep -E "error:|Test run"
  echo "== BarrierCompatibility"
  swift test --package-path /src/Packages/BarrierCompatibility --scratch-path /tmp/barrier 2>&1 | grep -E "error:|Test run"
  echo "== KVMCore"
  mkdir -p /work/Sources /work/Tests
  cp -r /src/Packages/KVMContracts/Sources/KVMContracts /src/Packages/KVMCore/Sources/KVMCore /work/Sources/
  cp -r /src/Packages/KVMCore/Tests/KVMCoreTests /work/Tests/
  printf "%s\n" "// swift-tools-version: 6.2" "import PackageDescription" \
    "let package = Package(name: \"KVMCoreLinux\", targets: [" \
    "  .target(name: \"KVMContracts\")," \
    "  .target(name: \"KVMCore\", dependencies: [\"KVMContracts\"])," \
    "  .testTarget(name: \"KVMCoreTests\", dependencies: [\"KVMCore\", \"KVMContracts\"])," \
    "])" > /work/Package.swift
  swift test --package-path /work --scratch-path /tmp/core 2>&1 | grep -E "error:|Test run"
'
