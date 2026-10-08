"""M1-025 Barrier Client Wire Contract v0.1 contract tests."""

import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ADR = REPOSITORY_ROOT / "docs/adr/M1-025-barrier-client-wire-contract.md"
SUMMARY = REPOSITORY_ROOT / "evidence/issues/M1-025/summary.md"
MANUAL = REPOSITORY_ROOT / "evidence/issues/M1-025/manual.md"
REVIEW = REPOSITORY_ROOT / "evidence/issues/M1-025/independent-review.md"
REGISTER = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
WIRE_001_ADR = REPOSITORY_ROOT / "docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md"
WIRE_002_ADR = REPOSITORY_ROOT / "docs/adr/M1-WIRE-002-barrier-length-prefix-width.md"
WIRE_001_FIXTURE = REPOSITORY_ROOT / "evidence/issues/M1-WIRE-001/barrier-frame-conformance.json"


class M1025BarrierClientWireContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.adr = ADR.read_text(encoding="utf-8")
        cls.summary = SUMMARY.read_text(encoding="utf-8")
        cls.manual = MANUAL.read_text(encoding="utf-8")
        cls.review = REVIEW.read_text(encoding="utf-8")
        cls.register = json.loads(REGISTER.read_text(encoding="utf-8"))
        cls.wire_001 = WIRE_001_ADR.read_text(encoding="utf-8")
        cls.wire_002 = WIRE_002_ADR.read_text(encoding="utf-8")
        cls.wire_001_fixture = json.loads(WIRE_001_FIXTURE.read_text(encoding="utf-8"))

    def test_required_sources_exist_and_are_cited(self):
        for path in (
            ADR,
            SUMMARY,
            MANUAL,
            REVIEW,
            REGISTER,
            WIRE_001_ADR,
            WIRE_002_ADR,
            WIRE_001_FIXTURE,
        ):
            self.assertTrue(path.is_file(), path)

        for evidence_id in ("BARRIER-EVID-0001", "BARRIER-EVID-0002", "BARRIER-EVID-0003"):
            self.assertIn(evidence_id, self.adr)
            self.assertIn(evidence_id, self.summary)

        entries = {entry["evidenceId"]: entry for entry in self.register["entries"]}
        for evidence_id in ("BARRIER-EVID-0001", "BARRIER-EVID-0002", "BARRIER-EVID-0003"):
            self.assertEqual(entries[evidence_id]["provenance"]["disposition"], "approved")

    def test_frame_envelope_contract_is_frozen_narrowly(self):
        required_phrases = (
            "4-byte unsigned big-endian length prefix",
            "number of payload bytes following the prefix",
            "complete ordered byte stream",
            "not to individual TCP packets",
            "Coalesced frames are therefore valid",
        )
        for phrase in required_phrases:
            self.assertIn(phrase, self.adr)

        self.assertIn("width: `4` bytes", self.wire_002)
        self.assertIn("byte order: unsigned big-endian", self.wire_002)
        self.assertIn("value: number of payload bytes following the prefix", self.wire_002)

    def test_marker_version_policy_is_exact_fail_closed_only(self):
        for phrase in (
            "42 61 72 72 69 65 72",
            "00 01 00 06",
            "exact-supported-version-fail-closed",
            "must fail closed",
            "typed error",
            "does not create version negotiation",
            "opaque 4-byte sequence",
        ):
            self.assertIn(phrase, self.adr)

        self.assertIn("00 01 00 06", self.wire_001)
        self.assertNotIn("allows fallback", self.adr.lower())
        self.assertNotIn("allows downgrade", self.adr.lower())

    def test_unknowns_remain_out_of_scope(self):
        for phrase in (
            "Barrier message codes or message names",
            "Payload field layout beyond the top-level prefix",
            "Maximum accepted payload length",
            "Oversize-frame behavior",
            "Windows behavior",
            "Production TLS behavior",
            "Successful interoperability",
            "GitHub Issue #293",
        ):
            self.assertIn(phrase, self.adr)
        self.assertIn("| Unknown or unsupported item | Owner | Blocking condition |", self.adr)

        forbidden_claims = (
            "message code is",
            "maximum accepted payload length is",
            "Windows compatibility is supported",
            "TLS is disabled",
            "successful interoperability is established",
        )
        lowered = self.adr.lower()
        for claim in forbidden_claims:
            self.assertNotIn(claim.lower(), lowered)

    def test_architecture_boundary_is_protocol_adapter_only(self):
        normalized = re.sub(r"\s+", " ", self.adr + self.manual)
        for phrase in (
            "Barrier protocol-adapter boundary",
            "does not move Barrier message codes into KVM Core",
            "does not implement later codec or reassembler work",
            "Production TLS remains default-on",
            "Security/Compatibility impact",
        ):
            self.assertIn(phrase, normalized)

    def test_independent_review_and_followup_blocker_are_recorded(self):
        for phrase in (
            "Critical findings: none",
            "High findings: none remaining after remediation",
            "GitHub Issue #293",
            "M1-021 and M1-022 must not consume M1-025 before #293 is\n  complete",
        ):
            self.assertIn(phrase, self.review)

    def test_m1_wire_001_fixture_stays_candidate_input_not_message_semantics(self):
        self.assertEqual(self.wire_001_fixture["registerEntry"], "BARRIER-EVID-0002")
        self.assertEqual(
            self.wire_001_fixture["derived"]["candidateLengthPrefix"]["interpretation"],
            "candidate",
        )
        self.assertIn("No message code", "\n".join(self.wire_001_fixture["nonClaims"]))
        self.assertIn("No field meaning", "\n".join(self.wire_001_fixture["nonClaims"]))


if __name__ == "__main__":
    unittest.main()
