import base64
import json
import unittest
from collections import defaultdict
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ADR = "docs/adr/M1-PROTOCOL-003-barrier-input-clipboard-message-contracts.md"
THIS_TEST = "Tests/Contracts/test_m1_protocol_003_input_clipboard_message_contracts.py"
REGISTER = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
FIXTURES = {
    "BARRIER-EVID-0006": "Tests/Fixtures/Barrier/m2-022-linux-server-input/server-input-capture.json",
    "BARRIER-EVID-0007": "Tests/Fixtures/Barrier/m2-022-linux-client-clipboard-keepalive/"
    "client-clipboard-keepalive-capture.json",
    "BARRIER-EVID-0008": "Tests/Fixtures/Barrier/m2-022-linux-punctuation-clipboard/"
    "punctuation-clipboard-capture.json",
}
S2C = "server-to-client"
C2S = "client-to-server"

# Frozen key identifiers: BARRIER-EVID-0006-CLAIM-005 and BARRIER-EVID-0008-CLAIM-001.
PLAIN_PUNCTUATION = (0x2D, 0x3D, 0x5B, 0x5D, 0x5C, 0x3B, 0x27, 0x60, 0x2C, 0x2E, 0x2F)
SHIFTED_PUNCTUATION = (0x5F, 0x2B, 0x7B, 0x7D, 0x7C, 0x3A, 0x22, 0x7E, 0x3C, 0x3E, 0x3F)
PUNCTUATION_BUTTONS = (20, 21, 34, 35, 51, 47, 48, 49, 59, 60, 61)
FROZEN_KEY_IDENTIFIERS = (
    set(range(0x61, 0x7B))
    | set(range(0x30, 0x3A))
    | {0x20, 0x41, 0x21}
    | set(PLAIN_PUNCTUATION)
    | set(SHIFTED_PUNCTUATION)
    | {0xEF0D, 0xEF1B, 0xEF09, 0xEF08, 0xEFFF, 0xEF63, 0xEF50, 0xEF57, 0xEF55, 0xEF56, 0xEF8D}
    | set(range(0xEF51, 0xEF55))
    | set(range(0xEFBE, 0xEFCA))
    | {0xE0AF, 0xE0AE, 0xE0AD}
    | {0xEFE1, 0xEFE2, 0xEFE3, 0xEFE4, 0xEFE9, 0xEFEA, 0xEFEB, 0xEFEC, 0xEFE5}
)
FROZEN_MASK_BITS = 0x0001 | 0x0002 | 0x0004 | 0x0010 | 0x1000
WITHDRAWN_LABELS = ("HTML", "bitmap", "primary selection", "warp")


def frames(evidence_id):
    observations = json.loads((REPOSITORY_ROOT / FIXTURES[evidence_id]).read_text(encoding="utf-8"))[
        "observations"
    ]
    result = []
    for observation in observations:
        raw = base64.b64decode(observation["applicationPayloadBase64"])
        result.append((observation["direction"], raw[4:8].decode("ascii", "replace"), raw[8:], raw))
    return result


def u16(data, offset, signed=False):
    return int.from_bytes(data[offset : offset + 2], "big", signed=signed)


def u32(data, offset):
    return int.from_bytes(data[offset : offset + 4], "big")


def dclp(body):
    """id, sequence, mark and data of a DCLP body; asserts the length field."""
    length = u32(body, 6)
    assert length == len(body) - 10, "DCLP data length must equal the remaining body"
    return body[0], u32(body, 1), body[5], body[10:]


def marshalled(data):
    count = u32(data, 0)
    offset = 4
    formats = []
    for _ in range(count):
        format_id, size = u32(data, offset), u32(data, offset + 4)
        offset += 8 + size
        formats.append((format_id, size))
    assert offset == len(data), "a marshalled clipboard has no trailing bytes"
    return formats


class M1Protocol003InputClipboardContractTests(unittest.TestCase):
    def test_every_frame_uses_the_common_envelope(self):
        for evidence_id in FIXTURES:
            for _, _, _, raw in frames(evidence_id):
                self.assertEqual(u32(raw, 0), len(raw) - 4)

    def test_dmmv_is_two_unsigned_big_endian_client_coordinates(self):
        observed = frames("BARRIER-EVID-0006")
        values = [(u16(observed[i][2], 0), u16(observed[i][2], 2)) for i in (27, 29, 31, 33, 38, 40, 64)]
        self.assertEqual(
            values, [(10, 450), (10, 460), (0, 460), (0, 450), (100, 500), (101, 501), (116, 506)]
        )
        for _, code, body, _ in observed:
            if code == "DMMV":
                self.assertEqual(len(body), 4)
                self.assertLess(u16(body, 0), 0x8000)
                self.assertLess(u16(body, 2), 0x8000)

    def test_buttons_are_one_byte_values_one_to_five_in_down_up_pairs(self):
        presses = [(code, body[0]) for _, code, body, _ in frames("BARRIER-EVID-0006") if code in ("DMDN", "DMUP")]
        self.assertEqual(
            presses,
            [("DMDN", 1), ("DMUP", 1), ("DMDN", 3), ("DMUP", 3), ("DMDN", 2), ("DMUP", 2),
             ("DMDN", 4), ("DMUP", 4), ("DMDN", 5), ("DMUP", 5), ("DMDN", 1), ("DMUP", 1)],
        )

    def test_wheel_is_signed_big_endian_with_120_per_notch(self):
        wheel = [(u16(body, 0, True), u16(body, 2, True)) for _, code, body, _ in frames("BARRIER-EVID-0006") if code == "DMWM"]
        self.assertEqual(wheel, [(0, 120), (0, -120), (-120, 0), (120, 0)])

    def test_key_frames_layout_identifiers_masks_and_pairing(self):
        identifiers = set()
        for evidence_id in ("BARRIER-EVID-0006", "BARRIER-EVID-0008"):
            held = defaultdict(int)
            for direction, code, body, _ in frames(evidence_id):
                if code in ("DKDN", "DKUP", "DKRP"):
                    self.assertEqual(direction, S2C)
                    self.assertEqual(len(body), 8 if code == "DKRP" else 6)
                    identifiers.add(u16(body, 0))
                    self.assertEqual(u16(body, 2) & ~FROZEN_MASK_BITS, 0)
                    button = u16(body, 6 if code == "DKRP" else 4)
                    if code == "DKRP":
                        self.assertEqual(u16(body, 4), 1)
                        self.assertGreater(held[button], 0)
                    elif code == "DKDN":
                        held[button] += 1
                    else:
                        self.assertGreater(held[button], 0, "every DKUP pairs with a DKDN by button")
                        held[button] -= 1
            self.assertFalse([button for button, count in held.items() if count], "no key left held")
        self.assertEqual(identifiers, FROZEN_KEY_IDENTIFIERS)

    def test_shifted_punctuation_is_four_frames(self):
        keys = [(code, u16(body, 0), u16(body, 2), u16(body, 4)) for _, code, body, _ in frames("BARRIER-EVID-0008") if code in ("DKDN", "DKUP")]
        for plain, shifted, button in zip(PLAIN_PUNCTUATION, SHIFTED_PUNCTUATION, PUNCTUATION_BUTTONS):
            start = keys.index(("DKDN", shifted, 0x0001, button))
            self.assertEqual(keys[start - 1], ("DKDN", 0xEFE1, 0x0000, 50))
            self.assertEqual(keys[start + 1], ("DKUP", 0xEFE1, 0x0001, 50))
            self.assertEqual(keys[start + 2], ("DKUP", plain, 0x0000, button))

    def test_server_clipboards_on_enter_with_interleaved_keepalive(self):
        for evidence_id in FIXTURES:
            observed = frames(evidence_id)
            self.assertEqual(
                [code for _, code, _, _ in observed[7:16]],
                ["CINN", "DCLP", "CALV", "DCLP", "DCLP", "DCLP", "CALV", "DCLP", "DCLP"],
            )
            transfers = [dclp(body) for _, code, body, _ in observed[8:16] if code == "DCLP"]
            self.assertEqual([(t[0], t[1], t[2]) for t in transfers], [(0, 0, 1), (0, 0, 2), (0, 0, 3), (1, 0, 1), (1, 0, 2), (1, 0, 3)])
            for start, chunk, end in (transfers[0:3], transfers[3:6]):
                self.assertEqual(int(start[3].decode("ascii")), len(chunk[3]))
                self.assertEqual(end[3], b"")

    def test_dclp_both_directions_and_marshalled_structure(self):
        observed = frames("BARRIER-EVID-0008")
        server = dclp(observed[10][2])
        self.assertEqual((server[0], server[1], server[2]), (0, 0, 2))
        self.assertEqual(marshalled(server[3]), [(0, 36), (1, 54), (2, 0)])
        client = [dclp(observed[i][2]) for i in (168, 169, 170)]
        self.assertTrue(all(observed[i][0] == C2S for i in (168, 169, 170)))
        self.assertEqual([(t[0], t[1], t[2]) for t in client], [(0, 1, 1), (0, 1, 2), (0, 1, 3)])
        self.assertEqual(int(client[0][3].decode("ascii")), len(client[1][3]))
        self.assertEqual(marshalled(client[1][3]), [(0, 37), (1, 54), (2, 0)])
        self.assertEqual(client[2][3], b"")
        self.assertEqual(marshalled(dclp(observed[14][2])[3]), [])

    def test_client_cclp_carries_the_enter_sequence(self):
        for evidence_id, index in (("BARRIER-EVID-0007", 27), ("BARRIER-EVID-0008", 165)):
            direction, code, body, _ = frames(evidence_id)[index]
            self.assertEqual((direction, code, body), (C2S, "CCLP", bytes([0, 0, 0, 0, 1])))
        for evidence_id in FIXTURES:
            self.assertFalse(
                [1 for direction, code, _, _ in frames(evidence_id) if code == "CCLP" and direction == S2C]
            )

    def test_register_links_the_contract_and_this_test(self):
        entries = {entry["evidenceId"]: entry for entry in json.loads(REGISTER.read_text(encoding="utf-8"))["entries"]}
        for evidence_id, fixture in FIXTURES.items():
            entry = entries[evidence_id]
            self.assertEqual(entry["provenance"]["disposition"], "approved")
            self.assertEqual(entry["fixture"]["path"], fixture)
            self.assertIn(ADR, entry["frozenContractRefs"])
            self.assertIn(THIS_TEST, entry["consumingTests"])

    def test_adr_keeps_semantics_unfrozen_and_labels_withdrawn(self):
        text = " ".join((REPOSITORY_ROOT / ADR).read_text(encoding="utf-8").split())
        for phrase in (
            "No format's meaning is frozen",
            "First-party convention, not a capture claim",
            "First-party conventions, not capture claims",
            "fails closed",
            "Non-claims",
        ):
            self.assertIn(phrase, text)
        for label in WITHDRAWN_LABELS:
            self.assertNotIn(label, text)
        m2_023 = (REPOSITORY_ROOT / "docs/adr/M2-023-barrier-server-wire-contract.md").read_text(encoding="utf-8")
        self.assertIn("M1-PROTOCOL-003", m2_023)


if __name__ == "__main__":
    unittest.main()
