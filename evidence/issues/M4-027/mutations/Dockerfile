# Local Linux image used by run_mutations.py and the RED/GREEN runs on an Apple Silicon Mac.
# The base is the multi-arch index of the image pinned in toolchain.m4.lock.json (same digest as
# `make verify-linux`), run as linux/arm64 so it executes natively instead of under amd64
# emulation. The packages are the ones `make verify-linux` installs, plus rsync.
FROM --platform=linux/arm64 swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends libx11-dev libxtst-dev libxrandr-dev libxfixes-dev xvfb xauth openssl rsync >/dev/null
