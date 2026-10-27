#!/usr/bin/env bash
# M2-035 local precondition gate and E2E result generator.
#
# Local only and read-only: it never invokes ssh, barrierc, barriers, tcpdump,
# dumpcap or any network or peer operation. It checks repository preconditions
# from Tests/SystemTests/Plans/M2-035-mac-to-linux-barrier-e2-e.md. While any
# precondition is unmet it exits 69 and writes no result. It never writes a
# result at all: a live run needs a human operator, who records result.json
# from the executed cases. Exit 70 means preconditions hold but no automated
# live run exists.
set -euo pipefail

if [[ "${MACKVM_E2E_ISSUE:-}" != "M2-035" ]]; then
  echo "M2-035: MACKVM_E2E_ISSUE must be M2-035" >&2
  exit 64
fi
result="${MACKVM_E2E_RESULT:-}"
if [[ "$result" != "evidence/e2e/M2-035/result.json" ]]; then
  echo "M2-035: unexpected MACKVM_E2E_RESULT" >&2
  exit 64
fi

unmet=()
grep -q '^Accepted' docs/adr/M2-023-barrier-server-wire-contract.md 2>/dev/null \
  || unmet+=("P1:M2-023 not accepted")
[[ -f Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierMouseEncoder.swift ]] \
  || unmet+=("P2:pointer encoding not frozen")
[[ -f Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierKeyboardEncoder.swift ]] \
  || unmet+=("P3:key encoding not frozen")
unmet+=("P4:server TLS listener not implemented")
unmet+=("P6:app composition root not implemented")
unmet+=("P7:human operator required")

if ((${#unmet[@]} > 0)); then
  # The result schema allows "not_executed" only with an approved decision
  # reference, and no decision approves skipping M2-035. Fail closed instead
  # of inventing one: report the blockers and write no result file.
  for item in "${unmet[@]}"; do
    echo "M2-035 blocked: ${item}" >&2
  done
  exit 69
fi

echo "M2-035: preconditions met; run the manual cases in the plan and record evidence" >&2
exit 70
