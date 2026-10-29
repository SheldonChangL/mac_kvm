#!/usr/bin/env bash
# M4-001 evidence: build the TLS pinning spike as a release binary with a static Swift
# standard library in the pinned image, run it (it connects to github.com:443 and computes
# the leaf certificate's SHA-256 in a custom verification callback, printing only the
# digest length), and list the binary's dynamic libraries.
# Usage: run.sh [scratch-dir]   (the scratch dir caches the BoringSSL build between runs)
set -euo pipefail
image="swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6"
here=$(cd "$(dirname "$0")" && pwd)
scratch=${1:-$(mktemp -d "${TMPDIR:-/tmp}/m4-001-tls.XXXXXX")}
docker run --rm --platform linux/amd64 -v "$here":/spike:ro -v "$scratch":/scratch "$image" bash -ec 'set -o pipefail
  cp -r /spike /work
  cd /work
  swift build -c release --static-swift-stdlib --scratch-path /scratch 2>&1 | grep -E "error:|Build complete"
  /scratch/release/TLSSpike
  echo "binary size: $(du -h /scratch/release/TLSSpike | cut -f1)"
  echo "dynamic libraries: $(ldd /scratch/release/TLSSpike | awk "{print \$1}" | tr "\n" " ")"
'
