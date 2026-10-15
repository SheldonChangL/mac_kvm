import base64
import hashlib
import json
import re
import struct
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE_DIRECTORY = (
    REPOSITORY_ROOT / "Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts"
)
FIXTURE = FIXTURE_DIRECTORY / "sanitized.json"
METADATA = FIXTURE_DIRECTORY / "metadata.json"
ADR = REPOSITORY_ROOT / "docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md"
REGISTER = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
COMMANDS = REPOSITORY_ROOT / "evidence/issues/M1-PROTOCOL-002/commands.json"

THIS_TEST = "Tests/Contracts/test_m1_protocol_002_control_message_contracts.py"

EXPECTED_RETAINED = {
    "server-to-client": [
        (1, "Barrier", "0000000b4261727269657200010006"),
        (2, "QINF", "0000000451494e46"),
        (3, "CIAK", "000000044349414b"),
        (4, "CROP", "0000000443524f50"),
        (5, "DSOP", "0000000844534f5000000000"),
        (6, "CALV", "0000000443414c56"),
        (7, "CINN", "0000000e43494e4e03040252000000012000"),
        (19, "COUT", "00000004434f5554"),
    ],
    "client-to-server": [
        (1, "Barrier", "0000001942617272696572000100060000000a6d312d636f6e74726f6c"),
        (2, "DINF", "0000001244494e46f88000000e40045d000003040252"),
        (3, "CALV", "0000000443414c56"),
        (4, "CNOP", "00000004434e4f50"),
    ],
}
TOKEN_ONLY = {"QINF", "CIAK", "CROP", "CALV", "CNOP", "COUT"}
EXCLUDED = {"DCLP", "DKDN", "DKUP"}


class M1Protocol002ControlMessageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_bytes = FIXTURE.read_bytes()
        cls.fixture = json.loads(cls.fixture_bytes.decode("utf-8"))
        cls.metadata = json.loads(METADATA.read_text(encoding="utf-8"))
        cls.adr = ADR.read_text(encoding="utf-8")
        cls.register = json.loads(REGISTER.read_text(encoding="utf-8"))
        cls.commands = COMMANDS.read_text(encoding="utf-8")
        cls.frames = {}
        for stream in cls.fixture["streams"]:
            for frame in stream["retainedFrames"]:
                cls.frames[(stream["direction"], frame["token"])] = base64.b64decode(
                    frame["base64"]
                )

    def frame_body(self, direction, token):
        frame = self.frames[(direction, token)]
        self.assertEqual(int.from_bytes(frame[0:4], "big"), len(frame) - 4)
        self.assertEqual(frame[4:8], token.encode("ascii"))
        return frame[8:]

    def test_metadata_pins_fixture_digest_and_size(self):
        self.assertEqual(self.metadata["payload"]["path"], "sanitized.json")
        self.assertEqual(
            self.metadata["payload"]["sha256"], hashlib.sha256(self.fixture_bytes).hexdigest()
        )
        self.assertEqual(self.metadata["payload"]["byteLength"], len(self.fixture_bytes))
        self.assertEqual(self.metadata["provenance"]["sourceKind"], "black-box-capture")
        self.assertFalse(self.metadata["sanitization"]["containsSensitiveData"])

    def test_retained_golden_frames_are_exact(self):
        retained = {
            stream["direction"]: [
                (
                    frame["streamFrameIndex"],
                    frame["token"],
                    base64.b64decode(frame["base64"]).hex(),
                )
                for frame in stream["retainedFrames"]
            ]
            for stream in self.fixture["streams"]
        }
        self.assertEqual(retained, EXPECTED_RETAINED)
        for stream in self.fixture["streams"]:
            for frame in stream["retainedFrames"]:
                decoded = base64.b64decode(frame["base64"])
                self.assertEqual(frame["byteLength"], len(decoded))
                self.assertIn(decoded.hex(" "), self.adr)

    def test_dinf_fields_are_big_endian(self):
        body = self.frame_body("client-to-server", "DINF")
        self.assertEqual(len(body), 14)
        self.assertEqual(
            struct.unpack(">hhHHHHH", body), (-1920, 0, 3648, 1117, 0, 772, 594)
        )
        self.assertEqual(body[0:2], bytes.fromhex("f880"))
        self.assertIn("signedness not frozen", self.adr)
        self.assertIn("use the DINF rectangle for validation", self.adr)

    def test_cinn_fields_are_big_endian(self):
        body = self.frame_body("server-to-client", "CINN")
        self.assertEqual(len(body), 10)
        self.assertEqual(struct.unpack(">HHIH", body), (772, 594, 1, 0x2000))
        self.assertIn("not sequence increment semantics", self.adr)

    def test_token_only_frames_have_payload_length_four(self):
        seen = set()
        for (direction, token), frame in self.frames.items():
            if token in TOKEN_ONLY:
                seen.add(token)
                self.assertEqual(int.from_bytes(frame[0:4], "big"), 4, (direction, token))
                self.assertEqual(len(frame), 8)
                self.assertEqual(self.frame_body(direction, token), b"")
        self.assertEqual(seen, TOKEN_ONLY)

    def test_dsop_observed_value_is_zero(self):
        body = self.frame_body("server-to-client", "DSOP")
        self.assertEqual(body, bytes(4))
        self.assertEqual(int.from_bytes(body, "big"), 0)
        self.assertIn("Any other `DSOP` payload length or", self.adr)

    def test_excluded_side_effect_tokens_are_not_retained_as_bytes(self):
        omitted = {}
        for stream in self.fixture["streams"]:
            for frame in stream["retainedFrames"]:
                self.assertNotIn(frame["token"], EXCLUDED)
                decoded = base64.b64decode(frame["base64"])
                for token in EXCLUDED:
                    self.assertNotIn(token.encode("ascii"), decoded)
            for item in stream["omittedFrames"]:
                self.assertFalse(item["bytesRetained"])
                self.assertNotIn("base64", item)
                if item["token"] in EXCLUDED:
                    self.assertEqual(item["reason"], "excluded-side-effect-not-consumable")
                    omitted[item["token"]] = item["count"]
            retained_count = len(stream["retainedFrames"])
            omitted_count = sum(item["count"] for item in stream["omittedFrames"])
            self.assertEqual(retained_count + omitted_count, stream["observedFrameCount"])
        self.assertEqual(omitted, {"DCLP": 6, "DKDN": 1, "DKUP": 2})
        self.assertIn("skip exactly one complete frame", self.adr)
        self.assertIn("must not synthesize a KVM event", " ".join(self.adr.split()))

    def test_non_claims_cover_tls_windows_keyboard_mouse_clipboard(self):
        non_claims = " ".join(self.fixture["nonClaims"])
        adr_non_claims = self.adr.split("## Non-claims", 1)[1].split("\n## ", 1)[0]
        normalized_adr_non_claims = " ".join(adr_non_claims.split())
        for term in ("TLS", "Windows", "keyboard", "mouse", "clipboard"):
            self.assertIn(term, non_claims)
            self.assertIn(term, adr_non_claims)
        for term in ("DINF cursor signedness", "CINN coordinate signedness", "CINN sequence semantics"):
            self.assertIn(term, normalized_adr_non_claims)

    def test_command_record_redacts_peer_address_and_notes_history_risk(self):
        command_strings = " ".join(
            item["command"] for item in json.loads(self.commands)["commands"]
        )
        self.assertIsNone(
            re.search(r"\bssh\b[^\n]*\b(?:\d{1,3}\.){3}\d{1,3}\b", command_strings),
            "commands.json command records must not name concrete peer IPv4 addresses",
        )
        self.assertIsNone(
            re.search(r"\bssh\b[^\n]*\b[A-Za-z0-9._%+-]+@", command_strings),
            "commands.json command records must not name concrete SSH user or host principals",
        )
        self.assertIn("<linux-peer>", self.commands)
        self.assertIn("public-history exposure remains a recorded review risk", self.adr)

    def test_register_records_approved_evidence_0005_for_m1_031(self):
        entry = next(
            item for item in self.register["entries"] if item["evidenceId"] == "BARRIER-EVID-0005"
        )
        self.assertEqual(entry["provenance"]["disposition"], "approved")
        self.assertTrue(entry["provenance"]["reviewer"]["independentFromProducer"])
        self.assertIn("final approval review", entry["provenance"]["reviewer"]["identity"])
        self.assertEqual(entry["source"]["category"], "black-box-capture")
        self.assertEqual(
            entry["fixture"],
            {
                "path": "Tests/Fixtures/Barrier/m1-protocol-002-control-message-contracts/sanitized.json",
                "sha256": self.metadata["payload"]["sha256"],
                "byteLength": self.metadata["payload"]["byteLength"],
            },
        )
        self.assertIn(THIS_TEST, entry["consumingTests"])
        self.assertIn(
            "docs/adr/M1-PROTOCOL-002-barrier-control-message-contracts.md",
            entry["frozenContractRefs"],
        )
        limitations = " ".join(entry["limitations"])
        self.assertIn("public PR history revision previously exposed one peer address", limitations)
        self.assertIn("skip the known excluded DCLP, DKDN and DKUP frames", limitations)
        blocked = {
            blocked
            for field in entry["ambiguousFields"]
            for blocked in field["blockedClaimIds"]
        }
        self.assertNotIn("M1-031", blocked)
        self.assertTrue({"M1-032", "M1-033", "M1-034", "M1-041"} <= blocked)
        ambiguous = {field["fieldId"] for field in entry["ambiguousFields"]}
        self.assertTrue(
            {
                "barrier-control-dinf-reserved-field",
                "barrier-control-dinf-cursor-signedness",
                "barrier-control-cinn-coordinate-signedness",
                "barrier-control-cinn-sequence-semantics",
                "barrier-control-keepalive-timing",
            }
            <= ambiguous
        )


if __name__ == "__main__":
    unittest.main()
