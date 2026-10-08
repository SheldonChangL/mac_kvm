"""M1-WIRE-002 discriminating length-prefix evidence contract tests.

GitHub Issue #279. This suite pins the accepted BARRIER-EVID-0003 fixture,
re-runs the exact width-4 and width-2 partition walks over the retained
sanitized streams, and checks that the register/ADR/review material keeps the
claim narrow: width 4 wins only over the approved {2, 4} candidate readings.
"""

import base64
import hashlib
import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE = (
    REPOSITORY_ROOT
    / "Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/sanitized.json"
)
FIXTURE_METADATA = (
    REPOSITORY_ROOT
    / "Tests/Fixtures/Barrier/m1-wire-002-length-prefix-discrimination/metadata.json"
)
ATTEMPT_ROOT = REPOSITORY_ROOT / "evidence/issues/M1-WIRE-002/attempt8"
ATTEMPT_METADATA = ATTEMPT_ROOT / "metadata.json"
ATTEMPT_ENVIRONMENT = ATTEMPT_ROOT / "environment.json"
ATTEMPT_RUNTIME_LOGS = ATTEMPT_ROOT / "runtime-log-excerpts.json"
REGISTER = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
REGISTER_DOC = REPOSITORY_ROOT / "docs/evidence/M1-023-barrier-evidence-register.md"
ADR = REPOSITORY_ROOT / "docs/adr/M1-WIRE-002-barrier-length-prefix-width.md"
PLAN = REPOSITORY_ROOT / "evidence/issues/M1-WIRE-002/discrimination-plan.md"
REVIEW = REPOSITORY_ROOT / "evidence/issues/M1-WIRE-002/independent-review.md"

EVIDENCE_ID = "BARRIER-EVID-0003"
EXPECTED_FIXTURE_SHA256 = "6b5049bb34694130186dd147353c14c072820825c98a2ede942a49f6bab674f1"
EXPECTED_FIXTURE_LENGTH = 100283
EXPECTED_TRIGGER_SHA256 = "c886c23ce4f108f6198b9a2f5a7fb703806256d14157c5f96410555ae45bbcfb"
EXPECTED_RAW_PCAP_SHA256 = "5ed5322b6edc0e3c8fd0a63776a25335de4a15d824769d1162361dfd05c6fabc"
TEST_PATH = "Tests/Contracts/test_m1_wire_002_length_prefix_evidence.py"

KNOWN_PUBLIC_DIGESTS = {
    EXPECTED_FIXTURE_SHA256,
    EXPECTED_TRIGGER_SHA256,
    EXPECTED_RAW_PCAP_SHA256,
    "af938d17dcea5701da7a990705acbd0686dfedfdbcd64721666ae0bef7644ba9",
    "2ad6d3b9b9d6dd8cb4bb403cea91f026d896842c5ba0134891daf90f8ef846b5",
    "53369a4579223e0f8742b897d96b6a9a6c3abc9f6ef9c4fec2779b0ef7bd5715",
    "6e2274a4438cf6450dee105ceb2e9db696d29027634517d94903d3e8924d5a7f",
    "31e76d0268e52f5aae1589c6556a642517eeab757330680409047dbf322c9220",
    "3f72948fdf9aa6eeecb8245553446e4e57c2dd2ad7801963273bcfa01605bbbd",
}

PRIVATE_PATTERNS = {
    "owner address": re.compile(r"\b122\.122\.122\.2\b"),
    "local user path": re.compile(r"(?i)(?:/Users/|/home/|C:\\Users\\)[^/\s\\]+"),
    "remote temp path": re.compile(r"/tmp/m1-wire-002-attempt8\.[A-Za-z0-9]+"),
    "email": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "token": re.compile(r"\b(?:ghp_|gho_|github_pat_|sk-|xox[abp]-)[\w-]+"),
    "long generated content": re.compile(r"m1w8-a{16,}"),
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(64 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def walk(stream, width):
    frames = []
    offset = 0
    while offset < len(stream):
        if len(stream) - offset < width:
            return {
                "width": width,
                "result": "failure",
                "frames": frames,
                "failure": {
                    "offset": offset,
                    "reason": "leftover-bytes",
                    "remaining": len(stream) - offset,
                },
            }
        declared = int.from_bytes(stream[offset : offset + width], "big")
        available = len(stream) - offset - width
        if declared > available:
            return {
                "width": width,
                "result": "failure",
                "frames": frames,
                "failure": {
                    "offset": offset,
                    "reason": "overrun",
                    "declared": declared,
                    "available": available,
                },
            }
        frames.append([offset, declared])
        offset += width + declared
    return {
        "width": width,
        "result": "success",
        "frames": frames,
        "finalOffset": offset,
    }


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


class M1Wire002LengthPrefixEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_bytes = FIXTURE.read_bytes()
        cls.fixture = json.loads(cls.fixture_bytes.decode("utf-8"))
        cls.fixture_metadata = load_json(FIXTURE_METADATA)
        cls.attempt_metadata = load_json(ATTEMPT_METADATA)
        cls.environment = load_json(ATTEMPT_ENVIRONMENT)
        cls.runtime_logs = load_json(ATTEMPT_RUNTIME_LOGS)
        cls.register = load_json(REGISTER)
        cls.register_entry = next(
            entry for entry in cls.register["entries"] if entry["evidenceId"] == EVIDENCE_ID
        )
        cls.register_doc = REGISTER_DOC.read_text(encoding="utf-8")
        cls.adr = ADR.read_text(encoding="utf-8")
        cls.plan = PLAN.read_text(encoding="utf-8")
        cls.review = REVIEW.read_text(encoding="utf-8")

    def test_fixture_identity_is_pinned(self):
        self.assertEqual(len(self.fixture_bytes), EXPECTED_FIXTURE_LENGTH)
        self.assertEqual(sha256(FIXTURE), EXPECTED_FIXTURE_SHA256)
        for metadata in (self.fixture_metadata, self.attempt_metadata):
            self.assertEqual(metadata["evidenceId"], EVIDENCE_ID)
            self.assertEqual(metadata["sanitizedFixture"]["path"], str(FIXTURE.relative_to(REPOSITORY_ROOT)))
            self.assertEqual(metadata["sanitizedFixture"]["sha256"], EXPECTED_FIXTURE_SHA256)
            self.assertEqual(metadata["sanitizedFixture"]["byteLength"], EXPECTED_FIXTURE_LENGTH)
            self.assertEqual(metadata["trigger"]["sha256"], EXPECTED_TRIGGER_SHA256)
            self.assertTrue(metadata["trigger"]["notCommitted"])
        for text in (
            self.attempt_metadata["runtime"]["peerLogReFetchLimitation"],
            self.environment["runtimeGate"]["rawPeerLogLimitation"],
        ):
            self.assertIn("2026-10-08T02:19:12Z", text)
            self.assertIn("summarized runtime evidence", text)
            self.assertIn("not as a hashable log fixture", text)

    def test_fixture_records_complete_fin_bounded_streams(self):
        self.assertEqual(self.fixture["input"]["sha256"], EXPECTED_RAW_PCAP_SHA256)
        self.assertEqual(self.fixture["input"]["byteLength"], 71230)
        self.assertEqual(len(self.fixture["connections"]), 1)
        connection = self.fixture["connections"][0]
        self.assertEqual(connection["label"], "connection-1")
        self.assertEqual(
            connection["lifecycle"],
            {
                "synObserved": {"client-to-server": True, "server-to-client": True},
                "finObserved": {"client-to-server": True, "server-to-client": True},
                "rstObserved": False,
            },
        )
        streams = {stream["direction"]: stream for stream in connection["streams"]}
        self.assertEqual(set(streams), {"client-to-server", "server-to-client"})
        self.assertEqual(streams["client-to-server"]["byteLength"], 70019)
        self.assertEqual(streams["server-to-client"]["byteLength"], 23)
        for stream in streams.values():
            self.assertTrue(stream["completeness"]["startedAtSyn"])
            self.assertTrue(stream["completeness"]["endedAtFin"])
            self.assertEqual(stream["completeness"]["sequenceGaps"], 0)
            self.assertEqual(stream["completeness"]["conflictingOverlaps"], 0)

    def test_width_walks_recompute_the_discriminating_result(self):
        recomputed = {}
        for stream in self.fixture["connections"][0]["streams"]:
            sanitized_bytes = base64.b64decode(stream["sanitized"]["base64"])
            self.assertEqual(len(sanitized_bytes), stream["sanitized"]["byteLength"])
            self.assertEqual(hashlib.sha256(sanitized_bytes).hexdigest(), stream["sanitized"]["sha256"])
            recomputed[(stream["direction"], 4)] = walk(sanitized_bytes, 4)
            recomputed[(stream["direction"], 2)] = walk(sanitized_bytes, 2)
            self.assertEqual(recomputed[(stream["direction"], 4)], stream["walks"]["sanitized"]["width4"])
            self.assertEqual(recomputed[(stream["direction"], 2)], stream["walks"]["sanitized"]["width2"])
            self.assertEqual(stream["walks"]["raw"], stream["walks"]["sanitized"])

        self.assertEqual(
            recomputed[("client-to-server", 4)],
            {"width": 4, "result": "success", "frames": [[0, 70015]], "finalOffset": 70019},
        )
        self.assertEqual(
            recomputed[("client-to-server", 2)]["failure"],
            {"offset": 57514, "reason": "overrun", "declared": 24929, "available": 12503},
        )
        self.assertEqual(recomputed[("server-to-client", 4)]["result"], "success")
        self.assertEqual(recomputed[("server-to-client", 2)]["result"], "success")
        self.assertEqual(
            self.fixture["outcome"],
            {
                "result": "DISCRIMINATING",
                "discriminating": True,
                "succeedingWidths": [4],
                "width4": {"succeedsOnEveryStream": True, "failingStreams": []},
                "width2": {
                    "succeedsOnEveryStream": False,
                    "failingStreams": [
                        {"connection": "connection-1", "direction": "client-to-server"}
                    ],
                },
            },
        )

    def test_register_appends_consumable_independently_reviewed_evidence(self):
        self.assertEqual(
            [entry["evidenceId"] for entry in self.register["entries"]],
            ["BARRIER-EVID-0001", "BARRIER-EVID-0002", EVIDENCE_ID],
        )
        entry = self.register_entry
        self.assertEqual(entry["provenance"]["disposition"], "approved")
        self.assertTrue(entry["provenance"]["reviewer"]["independentFromProducer"])
        self.assertNotEqual(
            entry["provenance"]["reviewer"]["identity"],
            entry["provenance"]["producer"],
        )
        self.assertEqual(entry["fixture"]["sha256"], EXPECTED_FIXTURE_SHA256)
        self.assertEqual(entry["fixture"]["byteLength"], EXPECTED_FIXTURE_LENGTH)
        self.assertEqual(entry["frozenContractRefs"], [str(ADR.relative_to(REPOSITORY_ROOT))])
        self.assertEqual(entry["consumingTests"], [TEST_PATH])
        claim = entry["coverage"]["wireClaims"][0]
        self.assertEqual(claim["claimId"], EVIDENCE_ID + "-CLAIM-001")
        self.assertEqual(
            claim["establishedFieldIds"],
            [
                "barrier-length-prefix-width",
                "barrier-length-prefix-endianness",
                "barrier-payload-length-meaning",
            ],
        )
        unknown_field_ids = {field["fieldId"] for field in entry["ambiguousFields"]}
        for established in claim["establishedFieldIds"]:
            self.assertNotIn(established, unknown_field_ids)
        self.assertTrue(
            any("maximum accepted production length" in text for text in entry["prohibitedInferences"])
        )

    def test_adr_and_review_keep_the_claim_narrow(self):
        required_adr_phrases = (
            "previously approved ambiguity between the 4-byte and\n2-byte",
            "does not\nevaluate every possible framing variant",
            "does not establish Barrier message codes",
            "explicit protocol-error close",
        )
        for phrase in required_adr_phrases:
            self.assertIn(phrase, self.adr)
        self.assertIn("## Checkpoint 2 — attempt-8 pre-registration re-derivation", self.review)
        self.assertIn("## Checkpoint 3 — attempt-8 pre-merge review", self.review)
        self.assertIn("peer raw-log re-fetch is unavailable", self.review)
        self.assertIn("Critical findings: **0 open", self.review)
        self.assertIn("High findings: **0 open", self.review)
        self.assertIn("### 17.8 Attempt-8 runtime result", self.plan)
        self.assertIn("raw peer log directory was unavailable", self.plan)
        self.assertIn("M1-025 may freeze", self.register_doc)

    def test_runtime_log_limitation_is_explicit(self):
        self.assertEqual(self.runtime_logs["status"], "summary-only-peer-runtime-log-evidence")
        self.assertIn("do not claim byte-for-byte raw log", self.runtime_logs["sourceLimitation"])
        self.assertFalse(self.runtime_logs["server"]["containsRealAddressPortHostOrUser"])
        self.assertFalse(self.runtime_logs["client"]["containsRealAddressPortHostOrUser"])
        for text in (
            self.environment["runtimeGate"]["rawPeerLogLimitation"],
            self.attempt_metadata["runtime"]["peerLogReFetchLimitation"],
        ):
            self.assertIn("2026-10-08T02:19:12Z", text)
            self.assertIn("summarized runtime evidence", text)
            self.assertIn("not as a hashable log fixture", text)

    def test_attempt8_artifacts_contain_no_private_identifiers_or_unexpected_hashes(self):
        files = [
            FIXTURE,
            FIXTURE_METADATA,
            ATTEMPT_METADATA,
            ATTEMPT_ENVIRONMENT,
            ATTEMPT_RUNTIME_LOGS,
            ATTEMPT_ROOT / "README.md",
            ATTEMPT_ROOT / "manual.md",
            ADR,
            REGISTER_DOC,
        ]
        for path in files:
            text = path.read_text(encoding="utf-8")
            with self.subTest(path=str(path.relative_to(REPOSITORY_ROOT))):
                for label, pattern in PRIVATE_PATTERNS.items():
                    self.assertIsNone(pattern.search(text), f"private content matched: {label}")
                scrubbed = text
                for digest in KNOWN_PUBLIC_DIGESTS:
                    scrubbed = scrubbed.replace(digest, "")
                self.assertIsNone(
                    re.search(r"\b[0-9a-f]{32,}\b", scrubbed, re.IGNORECASE),
                    "unexpected long hexadecimal string",
                )


if __name__ == "__main__":
    unittest.main()
