import base64
import hashlib
import json
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
FIXTURE = (
    REPOSITORY_ROOT
    / "Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/sanitized.json"
)
METADATA = (
    REPOSITORY_ROOT
    / "Tests/Fixtures/Barrier/m1-protocol-001-message-contracts/metadata.json"
)
ADR = REPOSITORY_ROOT / "docs/adr/M1-PROTOCOL-001-barrier-message-contracts.md"
REGISTER = REPOSITORY_ROOT / "evidence/registers/M1-023.json"


EXPECTED_HELLOBACK = {
    "m1-client": bytes.fromhex(
        "000000184261727269657200010006000000096d312d636c69656e74"
    ),
    "m1x": bytes.fromhex("000000124261727269657200010006000000036d3178"),
}


class M1Protocol001MessageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        cls.metadata = json.loads(METADATA.read_text(encoding="utf-8"))
        cls.adr = ADR.read_text(encoding="utf-8")
        cls.register = json.loads(REGISTER.read_text(encoding="utf-8"))

    def test_metadata_pins_fixture_digest_and_size(self):
        payload = FIXTURE.read_bytes()
        self.assertEqual(self.metadata["payload"]["sha256"], hashlib.sha256(payload).hexdigest())
        self.assertEqual(self.metadata["payload"]["byteLength"], len(payload))

    def test_fixture_retains_only_helloback_client_payloads(self):
        retained = {}
        for attempt in self.fixture["attempts"]:
            name = attempt["screenName"]["value"]
            self.assertIn(name, EXPECTED_HELLOBACK)
            client_streams = [
                stream
                for connection in attempt["connections"]
                for stream in connection["streams"]
                if stream["direction"] == "client-to-server"
            ]
            self.assertEqual(len(client_streams), 1)
            runs = client_streams[0]["runs"]
            self.assertEqual(len(runs), 1, "DINF and other client payloads must not be retained")
            retained[name] = base64.b64decode(runs[0]["base64"])
        self.assertEqual(retained, EXPECTED_HELLOBACK)

    def test_observed_server_tokens_are_qinf_ciak_crop_dsop_only(self):
        for attempt in self.fixture["attempts"]:
            server_streams = [
                stream
                for connection in attempt["connections"]
                for stream in connection["streams"]
                if stream["direction"] == "server-to-client"
            ]
            self.assertEqual(len(server_streams), 1)
            decoded = [
                base64.b64decode(run["base64"])
                for run in server_streams[0]["runs"]
            ]
            self.assertEqual(decoded[0], bytes.fromhex("0000000b4261727269657200010006"))
            self.assertEqual(decoded[1], bytes.fromhex("0000000451494e46"))
            self.assertEqual(decoded[2], bytes.fromhex("000000044349414b"))
            self.assertEqual(
                decoded[3],
                bytes.fromhex("0000000443524f500000000844534f5000000000"),
            )
            self.assertNotIn("ESOP", self.adr)
            self.assertIn("DSOP", self.adr)

    def test_helloback_length_and_screen_name_fields_match_adr(self):
        for name, frame in EXPECTED_HELLOBACK.items():
            frame_length = int.from_bytes(frame[0:4], "big")
            payload = frame[4:]
            self.assertEqual(frame_length, len(payload))
            self.assertEqual(payload[0:7], b"Barrier")
            self.assertEqual(payload[7:11], bytes.fromhex("00010006"))
            name_length = int.from_bytes(payload[11:15], "big")
            name_bytes = payload[15:]
            self.assertEqual(name_length, len(name_bytes))
            self.assertEqual(name_bytes, name.encode("utf-8"))
            self.assertIn(frame.hex(" "), self.adr)

    def test_register_limits_consumption_to_m1_028(self):
        entry = next(
            item for item in self.register["entries"] if item["evidenceId"] == "BARRIER-EVID-0004"
        )
        self.assertEqual(
            entry["consumingTests"],
            [
                "Tests/Contracts/test_m1_protocol_001_message_contracts.py"
            ],
        )
        blocked = {
            blocked
            for field in entry["ambiguousFields"]
            for blocked in field["blockedClaimIds"]
        }
        self.assertEqual({"M1-031", "M1-032", "M1-033", "M1-034", "M1-041"}, blocked)


if __name__ == "__main__":
    unittest.main()
