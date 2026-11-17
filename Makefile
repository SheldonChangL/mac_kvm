PYTHON ?= python3
REPORT ?= artifacts/ci/m1-008-report.json

.PHONY: verify backlog-check ci-gate-tests code-quality-check architecture-check docs-check e2e

verify:
	$(PYTHON) Tools/cigates/cigates.py --repository-root . --report "$(REPORT)"

backlog-check:
	$(PYTHON) Tools/Backlog/validate_package.py

ci-gate-tests:
	$(PYTHON) -m unittest discover -s Tools/cigates/tests -p 'test_*.py' -v

code-quality-check:
	$(PYTHON) Tools/code-quality/code-quality.py --repository-root .

architecture-check:
	$(PYTHON) Tools/architecture-check/architecture-check.py --repository-root .

docs-check:
	$(PYTHON) Tools/docs-check/docs-check.py --repository-root .

# ISSUE is passed unexpanded as one single-quoted argv value; run_e2e.py validates it.
unexport ISSUE
e2e:
	$(PYTHON) Tools/Evidence/run_e2e.py --issue '$(subst ','\'',$(value ISSUE))'

# M4-020: build and test the shared and Linux targets in the pinned image from
# MacKVM_Implementation_Package_v2/toolchain.m4.lock.json (docs/platform/linux/M4-020-linux-skeleton.md).
# The repository is mounted read-only and copied to /work; build products go to .build-linux/,
# reports to artifacts/ci/linux/. Exit 64: bad ISSUE; exit 65: dependency graph drifted from the lock.
LINUX_IMAGE := swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6
DOCKER ?= docker
# A renamed suite must not let --filter LinuxPlatformTests pass with zero tests. Later Linux
# issues raise this as they add tests.
LINUX_MIN_TESTS := 15

define VERIFY_LINUX_SCRIPT
set -o pipefail
echo "== toolchain"
swift --version 2>&1
uname -m
echo "source commit: $$SOURCE_COMMIT"
echo "== system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends libx11-dev libxtst-dev libxrandr-dev libxfixes-dev xvfb xauth openssl >/dev/null
mkdir -p /work /artifacts/ci/linux
tar -C /src --exclude=./.build --exclude=./.build-linux --exclude=./artifacts --exclude=./.git -cf - . | tar -C /work -xf -
cd /work
echo "== dependency graph against the lock"
swift package --scratch-path /scratch show-dependencies --format json > /artifacts/ci/linux/$$ISSUE-dependencies.json
python3 - /artifacts/ci/linux/$$ISSUE-dependencies.json MacKVM_Implementation_Package_v2/toolchain.m4.lock.json <<'PY' || exit 65
import json, sys
graph = json.load(open(sys.argv[1]))
expected = json.load(open(sys.argv[2]))["linux"]["swift_dependencies"]
resolved = {}
def walk(node):
    for child in node.get("dependencies", []):
        resolved[child["identity"]] = child["version"]
        walk(child)
walk(graph)
if resolved != expected:
    print("dependency drift: resolved", sorted(resolved.items()), "lock", sorted(expected.items()))
    sys.exit(1)
print("dependency graph matches the lock:", len(resolved), "packages")
PY
echo "== build"
swift build --build-tests --scratch-path /scratch
echo "== root package tests"
swift test --skip-build --scratch-path /scratch --xunit-output /artifacts/ci/linux/$$ISSUE-xunit.xml
echo "== KVMContracts package tests"
swift test --package-path /work/Packages/KVMContracts --scratch-path /scratch/contracts
echo "== BarrierCompatibility package tests"
swift test --package-path /work/Packages/BarrierCompatibility --scratch-path /scratch/barrier
echo "== X11 tests under Xvfb"
MACKVM_X11_TESTS=1 xvfb-run -a -s "-screen 0 1600x900x24 +extension RANDR" swift test --skip-build --scratch-path /scratch --filter LinuxPlatformTests --xunit-output /artifacts/ci/linux/$$ISSUE-x11-xunit.xml
x11_cases=$$(grep -o '<testcase ' /artifacts/ci/linux/$$ISSUE-x11-xunit-swift-testing.xml | wc -l)
echo "LinuxPlatformTests cases under Xvfb: $$x11_cases (minimum $(LINUX_MIN_TESTS))"
test "$$x11_cases" -ge $(LINUX_MIN_TESTS)
echo "verify-linux OK"
endef
export VERIFY_LINUX_SCRIPT

.PHONY: verify-linux
verify-linux:
	@issue='$(subst ','\'',$(value ISSUE))'; \
	case "$$issue" in ''|*[!A-Za-z0-9-]*) echo "usage: make verify-linux ISSUE=<id> (letters, digits, -)" >&2; exit 64;; esac; \
	mkdir -p .build-linux artifacts/ci/linux; \
	commit=$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
	$(DOCKER) run --rm --platform linux/amd64 \
	  -v "$(CURDIR)":/src:ro -v "$(CURDIR)/.build-linux":/scratch -v "$(CURDIR)/artifacts":/artifacts \
	  -e ISSUE="$$issue" -e SOURCE_COMMIT="$$commit" -e VERIFY_LINUX_SCRIPT \
	  $(LINUX_IMAGE) bash -ec "$$VERIFY_LINUX_SCRIPT"

# M4-020-FOLLOWUP-001: the release binary for the owner's Ubuntu 22.04 x86_64 PC, built in the
# pinned image with the static Swift standard library (docs/platform/linux/M4-020-FOLLOWUP-001-linux-client-app.md).
# Writes artifacts/linux/mackvm-client, the systemd user unit and SHA256SUMS. Not stripped (M4-035).
define DIST_LINUX_SCRIPT
set -o pipefail
swift --version 2>&1
echo "source commit: $$SOURCE_COMMIT"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends libx11-dev libxtst-dev libxrandr-dev libxfixes-dev >/dev/null
mkdir -p /work /artifacts/linux
tar -C /src --exclude=./.build --exclude=./.build-linux --exclude=./artifacts --exclude=./.git -cf - . | tar -C /work -xf -
cd /work
swift build -c release --static-swift-stdlib --product mackvm-client --scratch-path /scratch/release
bin=$$(swift build -c release --static-swift-stdlib --product mackvm-client --scratch-path /scratch/release --show-bin-path)
rm -f /artifacts/linux/mackvm-client /artifacts/linux/mackvm-client.service /artifacts/linux/SHA256SUMS
cp "$$bin/mackvm-client" /artifacts/linux/mackvm-client
cp Apps/Linux/systemd/mackvm-client.service /artifacts/linux/mackvm-client.service
cd /artifacts/linux
sha256sum mackvm-client mackvm-client.service > SHA256SUMS
cat SHA256SUMS
echo "dist-linux OK"
endef
export DIST_LINUX_SCRIPT

.PHONY: dist-linux
dist-linux:
	@mkdir -p .build-linux artifacts/linux; \
	commit=$$(git rev-parse HEAD 2>/dev/null || echo unknown); \
	$(DOCKER) run --rm --platform linux/amd64 \
	  -v "$(CURDIR)":/src:ro -v "$(CURDIR)/.build-linux":/scratch -v "$(CURDIR)/artifacts":/artifacts \
	  -e SOURCE_COMMIT="$$commit" -e DIST_LINUX_SCRIPT \
	  $(LINUX_IMAGE) bash -ec "$$DIST_LINUX_SCRIPT"
