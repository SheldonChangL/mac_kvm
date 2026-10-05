import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import stat
import struct
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
TOOL_PATH = REPOSITORY_ROOT / "Tools/Evidence/m1_wire_002_stream_analysis.py"


def load_tool():
    specification = importlib.util.spec_from_file_location(
        "m1_wire_002_stream_analysis_under_test", TOOL_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


analysis = load_tool()

# Synthetic identifiers only. They exist so the privacy tests can prove that none
# of them reaches the sanitized output.
SERVER_PORT = 24813
CLIENT_PORT = 47321
CLIENT_ADDRESS = bytes([127, 10, 20, 30])
SERVER_ADDRESS = bytes([127, 40, 50, 60])
CLIENT_MAC = bytes.fromhex("02a1b2c3d4e5")
SERVER_MAC = bytes.fromhex("02f6e7d8c9ba")
TIMESTAMP_SECONDS = 1790000000
SECRET = b"SECRET-CLIPBOARD-VALUE"

FIN, SYN, RST, PSH, ACK, URG = 0x01, 0x02, 0x04, 0x08, 0x10, 0x20
C2S = "client-to-server"
S2C = "server-to-client"

# Width 2 partitions both streams; width 4 overruns the client-to-server stream.
WIDTH_2_ONLY = (b"\x00\x02hi", b"\x00\x00\x00\x01Z")
# Width 4 partitions a 65540-byte stream; width 2 is left with one leftover byte.
WIDTH_4_ONLY_STREAM = b"\x00\x01\x00\x00" + b"\x00" * 65536
BOTH_SUCCEED = (b"\x00\x00\x00\x02ab", b"\x00\x00\x00\x00")
BOTH_FAIL = (b"\x00\x05ab", b"")


def pcap(frames, magic=b"\xd4\xc3\xb2\xa1", version=(2, 4), link_type=1, snaplen=262144):
    order = "<" if magic == b"\xd4\xc3\xb2\xa1" else ">"
    header = magic + struct.pack(order + "HHiIII", version[0], version[1], 0, 0, snaplen, link_type)
    records = []
    for index, frame in enumerate(frames):
        records.append(
            struct.pack(order + "IIII", TIMESTAMP_SECONDS + index, 123456, len(frame), len(frame))
            + frame
        )
    return header + b"".join(records)


def ethernet_ipv4_tcp(
    source,
    destination,
    source_port,
    destination_port,
    seq,
    flags,
    payload=b"",
    flags_fragment=0x4000,
    protocol=6,
    ethertype=0x0800,
):
    tcp = struct.pack(
        "!HHIIBBHHH", source_port, destination_port, seq % (1 << 32), 0, 5 << 4, flags, 65535, 0, 0
    ) + payload
    ip = struct.pack(
        "!BBHHHBBH4s4s",
        0x45,
        0,
        20 + len(tcp),
        0x1234,
        flags_fragment,
        64,
        protocol,
        0,
        source,
        destination,
    )
    return SERVER_MAC + CLIENT_MAC + struct.pack("!H", ethertype) + ip + tcp


class Connection:
    """Synthetic TCP connection; offsets are relative to each direction's first data byte."""

    def __init__(self, client_port=CLIENT_PORT, client_isn=1000, server_isn=500000):
        self.client_port = client_port
        self.isn = {C2S: client_isn, S2C: server_isn}

    def frame(self, direction, seq, flags, payload=b"", **options):
        if direction == C2S:
            return ethernet_ipv4_tcp(
                CLIENT_ADDRESS, SERVER_ADDRESS, self.client_port, SERVER_PORT, seq, flags, payload,
                **options
            )
        return ethernet_ipv4_tcp(
            SERVER_ADDRESS, CLIENT_ADDRESS, SERVER_PORT, self.client_port, seq, flags, payload,
            **options
        )

    def syn(self):
        return self.frame(C2S, self.isn[C2S], SYN)

    def syn_ack(self):
        return self.frame(S2C, self.isn[S2C], SYN | ACK)

    def ack(self, direction=C2S, offset=0):
        return self.at(direction, offset, b"", ACK)

    def at(self, direction, offset, payload, flags=ACK | PSH, **options):
        return self.frame(direction, self.isn[direction] + 1 + offset, flags, payload, **options)

    def fin(self, direction, offset):
        return self.at(direction, offset, b"", FIN | ACK)

    def segments(self, direction, stream, size):
        return [
            self.at(direction, offset, stream[offset : offset + size])
            for offset in range(0, len(stream), size)
        ]

    def complete(self, c2s, s2c, size=1000):
        return (
            [self.syn(), self.syn_ack(), self.ack()]
            + self.segments(C2S, c2s, size)
            + self.segments(S2C, s2c, size)
            + [self.fin(C2S, len(c2s)), self.fin(S2C, len(s2c)), self.ack(C2S, len(c2s) + 1)]
        )


def analyze(frames, **options):
    return analysis.analyze(pcap(frames, **options), SERVER_PORT)


def decoded_streams(document):
    return {
        (connection["label"], stream["direction"]): base64.b64decode(stream["sanitized"]["base64"])
        for connection in document["connections"]
        for stream in connection["streams"]
    }


def error(code):
    return "stream-analysis error: {0}\n".format(code)


def raw_walk(document, connection_index, direction, width):
    connection = document["connections"][connection_index]
    stream = next(s for s in connection["streams"] if s["direction"] == direction)
    return stream["walks"]["raw"]["width{0}".format(width)]


class WalkTests(unittest.TestCase):
    def test_walk_admits_zero_length_frames_and_records_success(self):
        result = analysis.walk(b"\x00\x00\x00\x00\x00\x01Z", 2)
        self.assertEqual(
            result,
            {
                "width": 2,
                "result": "success",
                "frames": [[0, 0], [2, 0], [4, 1]],
                "finalOffset": 7,
            },
        )
        self.assertEqual(analysis.walk(b"", 4)["result"], "success")
        self.assertEqual(analysis.walk(b"", 4)["frames"], [])

    def test_walk_records_first_failure_offset_reason_declared_and_available(self):
        result = analysis.walk(b"\x00\x00\x00\x01Z\x00\x00\x00\x09ab", 4)
        self.assertEqual(result["result"], "failure")
        self.assertEqual(result["frames"], [[0, 1]])
        self.assertEqual(
            result["failure"], {"offset": 5, "reason": "overrun", "declared": 9, "available": 2}
        )
        result = analysis.walk(b"\x00\x02a", 2)
        self.assertEqual(
            result["failure"], {"offset": 0, "reason": "overrun", "declared": 2, "available": 1}
        )
        result = analysis.walk(b"\x00\x00\x00", 2)
        self.assertEqual(result["frames"], [[0, 0]])
        self.assertEqual(
            result["failure"], {"offset": 2, "reason": "leftover-bytes", "remaining": 1}
        )


class OutcomeTests(unittest.TestCase):
    def test_width_2_discriminating_fixture(self):
        document = analyze(Connection().complete(*WIDTH_2_ONLY))
        outcome = document["outcome"]
        self.assertEqual(outcome["result"], "DISCRIMINATING")
        self.assertTrue(outcome["discriminating"])
        self.assertEqual(outcome["succeedingWidths"], [2])
        self.assertEqual(
            outcome["width4"]["failingStreams"],
            [{"connection": "connection-1", "direction": C2S}],
        )
        self.assertEqual(outcome["width2"]["failingStreams"], [])
        self.assertEqual(
            raw_walk(document, 0, C2S, 4)["failure"],
            {"offset": 0, "reason": "overrun", "declared": 0x00026869, "available": 0},
        )

    def test_width_4_discriminating_fixture_across_segments(self):
        connection = Connection()
        document = analyze(connection.complete(WIDTH_4_ONLY_STREAM, b"", size=30000))
        self.assertEqual(document["outcome"]["result"], "DISCRIMINATING")
        self.assertEqual(document["outcome"]["succeedingWidths"], [4])
        self.assertEqual(
            raw_walk(document, 0, C2S, 2)["failure"],
            {"offset": 65539, "reason": "leftover-bytes", "remaining": 1},
        )
        self.assertEqual(raw_walk(document, 0, C2S, 4)["frames"], [[0, 65536]])

    def test_both_succeed_is_non_discriminating_stop(self):
        document = analyze(Connection().complete(*BOTH_SUCCEED))
        outcome = document["outcome"]
        self.assertEqual(outcome["result"], "STOP-BOTH-SUCCEED")
        self.assertFalse(outcome["discriminating"])
        self.assertEqual(outcome["succeedingWidths"], [4, 2])

    def test_both_fail_is_non_discriminating_stop(self):
        document = analyze(Connection().complete(*BOTH_FAIL))
        self.assertEqual(document["outcome"]["result"], "STOP-BOTH-FAIL")
        self.assertFalse(document["outcome"]["discriminating"])
        self.assertEqual(document["outcome"]["succeedingWidths"], [])

    def test_each_width_failing_on_a_different_stream_is_both_fail(self):
        # Width 4 fails client-to-server, width 2 fails server-to-client.
        document = analyze(Connection().complete(b"\x00\x02hi", WIDTH_4_ONLY_STREAM, size=30000))
        self.assertEqual(document["outcome"]["result"], "STOP-BOTH-FAIL")

    def test_empty_direction_streams_are_required_and_partition_trivially(self):
        document = analyze(Connection().complete(b"", b""))
        self.assertEqual(document["outcome"]["result"], "STOP-BOTH-SUCCEED")
        for stream in document["connections"][0]["streams"]:
            self.assertEqual(stream["byteLength"], 0)
            self.assertEqual(stream["walks"]["raw"]["width4"]["frames"], [])

    def test_every_in_scope_connection_is_analyzed_without_cherry_picking(self):
        first = Connection(client_port=40001, client_isn=10, server_isn=20)
        second = Connection(client_port=40002, client_isn=30, server_isn=40)
        frames = first.complete(*WIDTH_2_ONLY) + second.complete(*BOTH_FAIL)
        document = analyze(frames)
        self.assertEqual(
            [c["label"] for c in document["connections"]], ["connection-1", "connection-2"]
        )
        self.assertEqual(document["outcome"]["result"], "STOP-BOTH-FAIL")
        self.assertEqual(
            document["outcome"]["width2"]["failingStreams"],
            [{"connection": "connection-2", "direction": C2S}],
        )
        # An incomplete second connection rejects the whole input.
        frames = first.complete(*WIDTH_2_ONLY) + second.complete(*BOTH_SUCCEED)[:-2]
        with self.assertRaisesRegex(analysis.AnalysisError, "^fin-missing$"):
            analyze(frames)

    def test_interleaved_connections_are_labelled_by_syn_order(self):
        first = Connection(client_port=40001)
        second = Connection(client_port=40002)
        a, b = first.complete(*WIDTH_2_ONLY), second.complete(*BOTH_SUCCEED)
        frames = [frame for pair in zip(a, b) for frame in pair]
        document = analyze(frames)
        self.assertEqual(
            decoded_streams(document)[("connection-2", C2S)][:4], BOTH_SUCCEED[0][:4]
        )
        self.assertEqual(document["outcome"]["result"], "DISCRIMINATING")


class ReassemblyTests(unittest.TestCase):
    def test_reordered_segments_reassemble_identically(self):
        connection = Connection()
        stream = b"\x00\x00\x00\x06abcdef\x00\x00\x00\x02gh"
        ordered = analyze(connection.complete(stream, b"", size=4))
        handshake, data, tail = (
            connection.complete(stream, b"", size=4)[:3],
            connection.segments(C2S, stream, 4),
            connection.complete(stream, b"", size=4)[-3:],
        )
        reordered = analyze(handshake + [tail[0]] + list(reversed(data)) + tail[1:])
        self.assertEqual(ordered["connections"], reordered["connections"])
        self.assertEqual(reordered["outcome"], ordered["outcome"])

    def test_server_data_captured_before_syn_ack_is_reordered(self):
        connection = Connection()
        frames = connection.complete(b"", b"\x00\x00")
        frames.insert(1, frames.pop(3))  # server data before the SYN-ACK record
        document = analyze(frames)
        self.assertEqual(document["connections"][0]["streams"][1]["byteLength"], 2)

    def test_identical_retransmission_and_overlap_are_counted_once(self):
        connection = Connection()
        stream = b"\x00\x00\x00\x06abcdef"
        frames = connection.complete(stream, b"", size=5)
        frames[4:4] = [connection.at(C2S, 0, stream[:5]), connection.at(C2S, 3, stream[3:8])]
        document = analyze(frames)
        c2s = document["connections"][0]["streams"][0]
        self.assertEqual(c2s["byteLength"], len(stream))
        self.assertEqual(c2s["completeness"]["identicalRetransmittedBytes"], 5 + 5)
        self.assertEqual(c2s["walks"]["raw"]["width4"]["frames"], [[0, 6]])

    def test_retransmitted_syn_and_fin_are_accepted_when_identical(self):
        connection = Connection()
        frames = connection.complete(*BOTH_SUCCEED)
        frames.insert(1, connection.syn())
        frames.append(connection.fin(C2S, len(BOTH_SUCCEED[0])))
        self.assertEqual(analyze(frames)["outcome"]["result"], "STOP-BOTH-SUCCEED")

    def test_conflicting_overlap_is_rejected(self):
        connection = Connection()
        stream = b"\x00\x00\x00\x06abcdef"
        frames = connection.complete(stream, b"", size=5)
        frames.insert(5, connection.at(C2S, 3, b"\x06abXd"))
        with self.assertRaisesRegex(analysis.AnalysisError, "^conflicting-overlap$"):
            analyze(frames)

    def test_sequence_gap_is_rejected(self):
        connection = Connection()
        stream = b"\x00\x00\x00\x06abcdef"
        frames = connection.complete(stream, b"", size=4)
        del frames[4]
        with self.assertRaisesRegex(analysis.AnalysisError, "^sequence-gap$"):
            analyze(frames)
        # A segment after the gap that is longer than the gap is still a gap.
        frames = connection.complete(stream, b"", size=10)
        frames[3:4] = [connection.at(C2S, 0, stream[:2]), connection.at(C2S, 4, stream[4:])]
        with self.assertRaisesRegex(analysis.AnalysisError, "^sequence-gap$"):
            analyze(frames)

    def test_trailing_gap_before_fin_is_rejected(self):
        connection = Connection()
        frames = connection.complete(b"\x00\x00\x00\x06abcdef", b"", size=4)
        del frames[5]
        with self.assertRaisesRegex(analysis.AnalysisError, "^sequence-gap$"):
            analyze(frames)

    def test_payload_after_fin_is_rejected(self):
        connection = Connection()
        frames = connection.complete(*BOTH_SUCCEED)
        frames.append(connection.at(C2S, len(BOTH_SUCCEED[0]), b"\x00\x00"))
        with self.assertRaisesRegex(analysis.AnalysisError, "^payload-after-fin$"):
            analyze(frames)

    def test_conflicting_fin_is_rejected(self):
        connection = Connection()
        frames = connection.complete(*BOTH_SUCCEED)
        frames.append(connection.fin(S2C, 2))
        with self.assertRaisesRegex(analysis.AnalysisError, "^conflicting-fin$"):
            analyze(frames)

    def test_sequence_number_wrap_is_handled(self):
        connection = Connection(client_isn=0xFFFFFFF8, server_isn=0xFFFFFFFE)
        stream = b"\x00\x00\x00\x0c" + b"0123456789AB"
        document = analyze(connection.complete(stream, b"\x00\x00\x00\x00", size=3))
        c2s = document["connections"][0]["streams"][0]
        self.assertEqual(c2s["byteLength"], len(stream))
        self.assertEqual(c2s["walks"]["raw"]["width4"]["frames"], [[0, 12]])

    def test_data_before_stream_start_is_rejected(self):
        connection = Connection()
        frames = connection.complete(*BOTH_SUCCEED)
        frames.insert(4, connection.at(C2S, -1, b"\x00"))
        with self.assertRaisesRegex(analysis.AnalysisError, "^data-before-stream-start$"):
            analyze(frames)

    def test_missing_client_syn_is_rejected(self):
        frames = Connection().complete(*BOTH_SUCCEED)
        del frames[0]
        with self.assertRaisesRegex(analysis.AnalysisError, "^missing-syn$"):
            analyze(frames)

    def test_missing_server_syn_ack_is_rejected(self):
        frames = Connection().complete(*BOTH_SUCCEED)
        del frames[1]
        with self.assertRaisesRegex(analysis.AnalysisError, "^missing-syn$"):
            analyze(frames)

    def test_conflicting_or_unsupported_syn_is_rejected(self):
        connection = Connection()
        frames = connection.complete(*BOTH_SUCCEED)
        frames.append(connection.frame(C2S, 77, SYN))
        with self.assertRaisesRegex(analysis.AnalysisError, "^conflicting-syn$"):
            analyze(frames)
        frames = connection.complete(*BOTH_SUCCEED)
        frames[0] = connection.frame(C2S, connection.isn[C2S], SYN, b"x")
        with self.assertRaisesRegex(analysis.AnalysisError, "^unsupported-syn$"):
            analyze(frames)

    def test_one_sided_fin_is_rejected(self):
        frames = Connection().complete(*BOTH_SUCCEED)
        del frames[-2]  # server FIN
        with self.assertRaisesRegex(analysis.AnalysisError, "^fin-missing$"):
            analyze(frames)

    def test_rst_never_qualifies(self):
        connection = Connection()
        for frames in (
            connection.complete(*BOTH_SUCCEED) + [connection.at(S2C, 5, b"", RST | ACK)],
            connection.complete(*BOTH_SUCCEED)[:-3] + [connection.at(C2S, 8, b"", RST)],
        ):
            with self.subTest(frames=len(frames)):
                with self.assertRaisesRegex(analysis.AnalysisError, "^rst-observed$"):
                    analyze(frames)


class CaptureFormatTests(unittest.TestCase):
    def frames(self):
        return Connection().complete(*BOTH_SUCCEED)

    def assertRejected(self, data, code):
        with self.assertRaises(analysis.AnalysisError) as context:
            analysis.analyze(data, SERVER_PORT)
        self.assertEqual(context.exception.code, code)

    def test_big_endian_pcap_is_supported(self):
        document = analysis.analyze(pcap(self.frames(), magic=b"\xa1\xb2\xc3\xd4"), SERVER_PORT)
        self.assertEqual(document["outcome"]["result"], "STOP-BOTH-SUCCEED")

    def test_unsupported_or_truncated_pcap_header_is_rejected(self):
        data = pcap(self.frames())
        self.assertRejected(data[:23], "pcap-header-truncated")
        self.assertRejected(b"\x0a\x0d\x0d\x0a" + data[4:], "pcap-unsupported-format")
        nanosecond = pcap(self.frames(), magic=b"\x4d\x3c\xb2\xa1")
        self.assertRejected(nanosecond, "pcap-unsupported-format")
        self.assertRejected(pcap(self.frames(), version=(2, 3)), "pcap-unsupported-version")

    def test_wrong_link_type_is_rejected(self):
        for link_type in (0, 113, 276, 1 | (1 << 28)):
            with self.subTest(link_type=link_type):
                self.assertRejected(
                    pcap(self.frames(), link_type=link_type), "pcap-unsupported-link-type"
                )

    def test_truncated_and_malformed_records_are_rejected(self):
        data = pcap(self.frames())
        self.assertRejected(data[:-1], "pcap-record-truncated")
        self.assertRejected(data + b"\x00" * 15, "pcap-record-truncated")
        frame = self.frames()[0]
        header = pcap([])
        snapped = struct.pack("<IIII", 1, 0, len(frame) - 4, len(frame)) + frame[:-4]
        self.assertRejected(header + snapped, "pcap-record-snapped")
        bad_time = struct.pack("<IIII", 1, 1000000, len(frame), len(frame)) + frame
        self.assertRejected(header + bad_time, "pcap-malformed-timestamp")
        self.assertRejected(pcap(self.frames(), snaplen=40), "pcap-record-exceeds-snaplen")
        self.assertRejected(pcap([b"\x00" * 13]), "ethernet-truncated")

    def test_empty_capture_is_rejected(self):
        self.assertRejected(pcap([]), "no-in-scope-connection")

    def test_fragmentation_is_rejected(self):
        connection = Connection()
        for flags_fragment in (0x2000, 0x0001, 0x4000 | 0x0010):
            with self.subTest(flags_fragment=flags_fragment):
                frames = self.frames()
                frames.insert(3, connection.at(C2S, 0, b"\x00", flags_fragment=flags_fragment))
                self.assertRejected(pcap(frames), "ipv4-fragment")

    def test_ipv6_and_other_ethertypes_are_rejected(self):
        for ethertype in (0x86DD, 0x0806, 0x8100):
            with self.subTest(ethertype=ethertype):
                frames = self.frames()
                frames.insert(2, Connection().at(C2S, 0, b"", ethertype=ethertype))
                self.assertRejected(pcap(frames), "unsupported-ethertype")

    def test_non_tcp_protocols_are_rejected(self):
        for protocol in (17, 1):
            with self.subTest(protocol=protocol):
                frames = self.frames()
                frames.insert(2, Connection().at(C2S, 0, b"", protocol=protocol))
                self.assertRejected(pcap(frames), "unsupported-ip-protocol")

    def test_malformed_ip_and_tcp_headers_are_rejected(self):
        frame = self.frames()[0]
        cases = (
            (frame[:14] + b"\x65" + frame[15:], "ipv4-malformed"),
            (frame[:14] + b"\x44" + frame[15:], "ipv4-malformed"),
            (frame[:14] + b"\x46" + frame[15:], "ipv4-options-unsupported"),
            (frame + b"\x00", "ipv4-length-mismatch"),
            (frame[:20] + b"\x80" + frame[21:], "ipv4-malformed"),
            (frame[:46] + b"\x40" + frame[47:], "tcp-malformed"),
            (frame[:46] + b"\xf0" + frame[47:], "tcp-malformed"),
            (frame[:47] + bytes([SYN | URG]) + frame[48:], "tcp-urgent-unsupported"),
            (frame[:14] + frame[14:16] + struct.pack("!H", 30) + frame[18:44], "tcp-malformed"),
        )
        for data, code in cases:
            with self.subTest(code=code):
                self.assertRejected(pcap([data]), code)

    def test_non_loopback_out_of_scope_or_ambiguous_traffic_is_rejected(self):
        frames = self.frames()
        frames.insert(
            2,
            ethernet_ipv4_tcp(
                bytes([10, 0, 0, 5]), SERVER_ADDRESS, CLIENT_PORT, SERVER_PORT, 1, ACK
            ),
        )
        self.assertRejected(pcap(frames), "non-loopback-address")
        frames = self.frames()
        frames.insert(2, ethernet_ipv4_tcp(CLIENT_ADDRESS, SERVER_ADDRESS, 5000, 6000, 1, ACK))
        self.assertRejected(pcap(frames), "out-of-scope-traffic")
        frames = [
            ethernet_ipv4_tcp(CLIENT_ADDRESS, SERVER_ADDRESS, SERVER_PORT, SERVER_PORT, 1, SYN)
        ]
        self.assertRejected(pcap(frames), "ambiguous-direction")

    def test_invalid_server_port_is_rejected(self):
        for port in (0, -1, 65536, True, "24813"):
            with self.subTest(port=port):
                with self.assertRaises(analysis.AnalysisError) as context:
                    analysis.analyze(pcap(self.frames()), port)
                self.assertEqual(context.exception.code, "invalid-port")


class SanitizerTests(unittest.TestCase):
    def test_sanitizer_retains_only_prefix_positions_and_round_trips(self):
        c2s = b"\x00\x00\x00\x16" + SECRET
        s2c = b"\x00\x02" + b"hi"
        document = analyze(Connection().complete(c2s, s2c))
        streams = decoded_streams(document)
        fill = bytes([analysis.FILL_BYTE])
        self.assertEqual(streams[("connection-1", C2S)], b"\x00\x00\x00\x16" + fill * len(SECRET))
        # Width 4 reads the whole 4-byte server stream as one overrunning prefix.
        self.assertEqual(streams[("connection-1", S2C)], s2c)
        for connection in document["connections"]:
            for stream in connection["streams"]:
                sanitized = streams[(connection["label"], stream["direction"])]
                self.assertEqual(stream["walks"]["sanitized"], stream["walks"]["raw"])
                self.assertEqual(stream["sanitized"]["byteLength"], len(sanitized))
                self.assertEqual(
                    stream["sanitized"]["sha256"], hashlib.sha256(sanitized).hexdigest()
                )
                for width in (4, 2):
                    self.assertEqual(
                        analysis.walk(sanitized, width),
                        stream["walks"]["raw"]["width{0}".format(width)],
                    )
        c2s = document["connections"][0]["streams"][0]
        self.assertEqual(c2s["sanitized"]["retainedByteCount"], 4)

    def test_round_trip_mismatch_fails_closed(self):
        frames = Connection().complete(*WIDTH_2_ONLY)
        with mock.patch.object(
            analysis, "sanitize_stream", side_effect=lambda stream, walks: bytes(len(stream))
        ):
            with self.assertRaisesRegex(
                analysis.AnalysisError, "^sanitizer-round-trip-mismatch$"
            ):
                analyze(frames)

    def test_document_carries_no_identifiers_timestamps_or_payload(self):
        c2s = b"\x00\x00\x00\x16" + SECRET
        document = analyze(Connection().complete(c2s, b"\x00\x00\x00\x00"))
        text = json.dumps(document)
        forbidden_text = (
            SECRET.decode(),
            "127.",
            "7f0a141e",
            "7f28323c",
            "02a1b2c3d4e5",
            "02:a1",
            "02f6e7d8c9ba",
            "/Users/",
            "/home/",
            "/tmp",
            "/var/",
        )
        for value in forbidden_text:
            with self.subTest(value=value):
                self.assertNotIn(value, text)
        forbidden_numbers = {SERVER_PORT, CLIENT_PORT, TIMESTAMP_SECONDS, 123456, 1000, 500000}

        def leaves(value, key=""):
            if isinstance(value, dict):
                for child_key, child in value.items():
                    yield from leaves(child, child_key)
            elif isinstance(value, list):
                for child in value:
                    yield from leaves(child, key)
            else:
                yield key, value

        for key, value in leaves(document):
            if isinstance(value, int) and not isinstance(value, bool):
                self.assertNotIn(value, forbidden_numbers, key)
            elif isinstance(value, str) and key not in ("sha256", "base64"):
                for number in forbidden_numbers:
                    self.assertNotIn(str(number), value, key)
        self.assertEqual(document["serverPort"], analysis.SERVER_PORT_PLACEHOLDER)
        for stream in decoded_streams(document).values():
            self.assertNotIn(SECRET[:3], stream)

    def test_document_shape_and_input_digest(self):
        data = pcap(Connection().complete(*WIDTH_2_ONLY))
        document = analysis.analyze(data, SERVER_PORT)
        self.assertEqual(
            list(document),
            [
                "schemaVersion",
                "tool",
                "input",
                "serverPort",
                "sanitizer",
                "connections",
                "outcome",
                "nonClaims",
            ],
        )
        self.assertEqual(document["schemaVersion"], 1)
        self.assertEqual(document["input"]["byteLength"], len(data))
        self.assertEqual(document["input"]["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(document["input"]["linkType"], "EN10MB")
        self.assertEqual(document["sanitizer"]["fillByte"], "0x00")
        self.assertFalse(document["sanitizer"]["markerBytesRetained"])
        connection = document["connections"][0]
        self.assertEqual(
            connection["lifecycle"],
            {
                "synObserved": {C2S: True, S2C: True},
                "finObserved": {C2S: True, S2C: True},
                "rstObserved": False,
            },
        )
        self.assertEqual(
            [(s["direction"], s["from"], s["to"]) for s in connection["streams"]],
            [(C2S, "role-client", "role-server"), (S2C, "role-server", "role-client")],
        )
        self.assertTrue(document["nonClaims"])
        again = analysis.analyze(data, SERVER_PORT)
        self.assertEqual(analysis.serialize(document), analysis.serialize(again))
        self.assertTrue(analysis.serialize(document).endswith(b"}\n"))


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.input = self.root / "capture.pcap"
        self.output = self.root / "analysis.json"

    def tearDown(self):
        self.directory.cleanup()

    def run_main(self, *arguments):
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = analysis.main(list(arguments))
        return code, stdout.getvalue(), stderr.getvalue()

    def default_arguments(self, port=str(SERVER_PORT), output=None):
        return (
            "--input",
            str(self.input),
            "--server-port",
            port,
            "--output",
            str(output or self.output),
        )

    def entries(self):
        return sorted(path.name for path in self.root.iterdir())

    def test_discriminating_run_writes_output_atomically(self):
        self.input.write_bytes(pcap(Connection().complete(*WIDTH_2_ONLY)))
        code, stdout, stderr = self.run_main(*self.default_arguments())
        self.assertEqual(code, analysis.EXIT_OK)
        self.assertEqual((stdout, stderr), ("stream-analysis result: DISCRIMINATING\n", ""))
        self.assertEqual(self.entries(), ["analysis.json", "capture.pcap"])
        document = json.loads(self.output.read_bytes())
        self.assertEqual(document["outcome"]["succeedingWidths"], [2])
        self.assertEqual(
            self.output.read_bytes(),
            analysis.serialize(analysis.analyze(self.input.read_bytes(), SERVER_PORT)),
        )

    def test_output_is_created_owner_only(self):
        self.input.write_bytes(pcap(Connection().complete(*WIDTH_2_ONLY)))
        previous = os.umask(0o022)
        try:
            code, _, stderr = self.run_main(*self.default_arguments())
        finally:
            os.umask(previous)
        self.assertEqual((code, stderr), (analysis.EXIT_OK, ""))
        self.assertEqual(stat.S_IMODE(os.lstat(self.output).st_mode), 0o600)

    def test_stop_run_writes_output_and_exits_non_zero(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        code, stdout, stderr = self.run_main(*self.default_arguments())
        self.assertEqual(code, analysis.EXIT_STOP)
        self.assertEqual(stdout, "stream-analysis result: STOP-BOTH-SUCCEED\n")
        self.assertTrue(self.output.exists())

    def test_rejected_capture_writes_nothing_and_leaks_no_bytes(self):
        frames = Connection().complete(b"\x00\x00\x00\x16" + SECRET, b"")
        del frames[-2]
        self.input.write_bytes(pcap(frames))
        code, stdout, stderr = self.run_main(*self.default_arguments())
        self.assertEqual((code, stdout), (analysis.EXIT_DATA, ""))
        self.assertEqual(stderr, "stream-analysis error: fin-missing\n")
        self.assertEqual(self.entries(), ["capture.pcap"])

    def test_invalid_ports_are_refused(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        for port in ("0", "65536", "-1", "+80", "080", "abc", "", "24813.0"):
            with self.subTest(port=port):
                code, stdout, stderr = self.run_main(*self.default_arguments(port=port))
                self.assertEqual(code, analysis.EXIT_USAGE)
                self.assertEqual(stderr, "stream-analysis error: invalid-port\n")
        self.assertEqual(self.entries(), ["capture.pcap"])

    def test_missing_arguments_are_refused_without_usage_echo(self):
        code, stdout, stderr = self.run_main("--input", str(self.input))
        self.assertEqual((code, stdout), (analysis.EXIT_USAGE, ""))
        self.assertEqual(stderr, "stream-analysis error: invalid-arguments\n")

    def test_existing_output_is_never_overwritten(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        self.output.write_bytes(b"keep")
        code, _, stderr = self.run_main(*self.default_arguments())
        self.assertEqual(code, analysis.EXIT_CANT_CREATE)
        self.assertEqual(stderr, "stream-analysis error: output-exists\n")
        self.assertEqual(self.output.read_bytes(), b"keep")
        self.assertEqual(self.entries(), ["analysis.json", "capture.pcap"])

    def test_output_created_concurrently_is_not_overwritten(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        real_link = os.link

        def racing_link(source, destination):
            Path(destination).write_bytes(b"racer")
            return real_link(source, destination)

        with mock.patch.object(analysis.os, "link", side_effect=racing_link):
            code, _, stderr = self.run_main(*self.default_arguments())
        self.assertEqual((code, stderr), (analysis.EXIT_CANT_CREATE, error("output-exists")))
        self.assertEqual(self.output.read_bytes(), b"racer")
        self.assertEqual(self.entries(), ["analysis.json", "capture.pcap"])

    def test_input_and_output_must_differ(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        original = self.input.read_bytes()
        alias = self.root / "." / "capture.pcap"
        code, _, stderr = self.run_main(*self.default_arguments(output=alias))
        self.assertEqual(code, analysis.EXIT_UNSAFE_PATH)
        self.assertEqual(stderr, "stream-analysis error: input-output-same\n")
        self.assertEqual(self.input.read_bytes(), original)

    def test_output_parent_must_exist(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        code, _, stderr = self.run_main(
            *self.default_arguments(output=self.root / "missing" / "analysis.json")
        )
        self.assertEqual(code, analysis.EXIT_CANT_CREATE)
        self.assertEqual(stderr, "stream-analysis error: output-parent-missing\n")
        self.assertEqual(self.entries(), ["capture.pcap"])

    def test_input_must_be_an_existing_regular_non_symlink_file(self):
        code, _, stderr = self.run_main(*self.default_arguments())
        self.assertEqual((code, stderr), (analysis.EXIT_NO_INPUT, error("input-missing")))
        target = self.root / "real.pcap"
        target.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        self.input.symlink_to(target)
        code, _, stderr = self.run_main(*self.default_arguments())
        self.assertEqual((code, stderr), (analysis.EXIT_UNSAFE_PATH, error("input-unsafe")))
        self.input.unlink()
        self.input.mkdir()
        code, _, stderr = self.run_main(*self.default_arguments())
        self.assertEqual((code, stderr), (analysis.EXIT_UNSAFE_PATH, error("input-unsafe")))
        self.assertFalse(self.output.exists())

    def fstat_drifting(self, field):
        real_fstat = os.fstat
        calls = []

        def drifting_fstat(descriptor):
            status = real_fstat(descriptor)
            calls.append(field)
            if field is None or len(calls) == 1:
                return status
            fields = {
                name: getattr(status, name)
                for name in ("st_mode", "st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
            }
            fields[field] += 1
            return types.SimpleNamespace(**fields)

        return drifting_fstat, calls

    def test_same_size_metadata_drift_while_reading_is_rejected(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        for field in ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns"):
            with self.subTest(field=field):
                drifting_fstat, calls = self.fstat_drifting(field)
                with mock.patch.object(analysis.os, "fstat", side_effect=drifting_fstat):
                    code, stdout, stderr = self.run_main(*self.default_arguments())
                self.assertEqual(len(calls), 2)
                self.assertEqual((code, stdout), (analysis.EXIT_DATA, ""))
                self.assertEqual(stderr, error("input-changed"))
                self.assertEqual(self.entries(), ["capture.pcap"])

    def test_stable_input_is_checked_before_and_after_reading(self):
        data = pcap(Connection().complete(*BOTH_SUCCEED))
        self.input.write_bytes(data)
        stable_fstat, calls = self.fstat_drifting(None)
        with mock.patch.object(analysis.os, "fstat", side_effect=stable_fstat):
            self.assertEqual(analysis.read_input(str(self.input)), data)
        self.assertEqual(len(calls), 2)

    def test_publish_failures_leave_no_partial_or_temporary_output(self):
        self.input.write_bytes(pcap(Connection().complete(*BOTH_SUCCEED)))
        for target, code in (("fsync", "output-write-failed"), ("link", "output-publish-failed")):
            with self.subTest(target=target):
                with mock.patch.object(analysis.os, target, side_effect=OSError("boom")):
                    exit_code, stdout, stderr = self.run_main(*self.default_arguments())
                self.assertEqual(exit_code, analysis.EXIT_CANT_CREATE)
                self.assertEqual((stdout, stderr), ("", error(code)))
                self.assertEqual(self.entries(), ["capture.pcap"])

    def test_unexpected_failure_prints_no_traceback(self):
        self.input.write_bytes(pcap(Connection().complete(b"\x00\x00\x00\x16" + SECRET, b"")))
        with mock.patch.object(analysis, "analyze", side_effect=ValueError(SECRET.decode())):
            code, stdout, stderr = self.run_main(*self.default_arguments())
        self.assertEqual((code, stdout), (analysis.EXIT_SOFTWARE, ""))
        self.assertEqual(stderr, "stream-analysis error: internal-failure\n")


if __name__ == "__main__":
    unittest.main()
