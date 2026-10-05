#!/usr/bin/env python3
"""Offline M1-WIRE-002 classic-pcap stream analysis and allowlist sanitizer.

Reads one raw capture of the Linux loopback leg, reconstructs every in-scope TCP
connection, runs the width-4 and width-2 partition walks of
`evidence/issues/M1-WIRE-002/discrimination-plan.md` section 4.2 on identical
complete direction streams, and writes one sanitized JSON document. It never
interprets Barrier semantics and never prints capture bytes.

Supported input, all else is rejected fail closed:
- classic pcap, microsecond magic in either byte order, version 2.4, link type 1
  (EN10MB, the Linux loopback link type recorded by M1-024); pcapng, nanosecond
  pcap and every other link type are rejected;
- every record has incl_len == orig_len <= snaplen and a valid microsecond field;
- every frame is Ethernet carrying IPv4 (IPv6, VLAN, ARP and all other ethertypes
  are rejected); IPv4 without options or fragmentation, total length equal to the
  frame payload, protocol TCP only, both addresses in 127.0.0.0/8;
- every TCP segment has exactly one port equal to the configured server port
  (the capture filter is that port only, so any other segment means the input is
  not the planned capture); URG is rejected; checksums are not validated.

Connection policy:
- a connection is the client endpoint and server address seen with the server
  port; its first captured segment must be the client SYN and a server SYN-ACK
  must be captured; SYNs with payload, a SYN-ACK from the client or a bare SYN
  from the server are rejected; retransmitted SYNs must repeat the same sequence
  number, so connection reuse on one endpoint is rejected;
- any RST rejects the input; FIN must be captured in both directions; every
  connection must qualify, otherwise the whole input is rejected (no cherry-pick);
- payload is placed by sequence number relative to the SYN (modulo 2**32, so
  sequence wrap is handled; offsets of 2**31 or more are data before the stream
  start), sorted by offset and concatenated; overlap must be byte-identical; any
  gap, conflicting overlap, conflicting FIN position or payload past FIN rejects;
  segment and record boundaries are discarded;
- an empty direction stream is still a required stream; both walks partition it.

Sanitizer policy: original bytes are retained only at positions that either raw
walk reads as a length prefix (including the prefix of a failing overrun); every
other byte becomes FILL_BYTE. The registered marker and version bytes are not
retained, so this helper keeps no payload beyond prefix positions. Both walks
are re-run on the sanitized stream and must equal the raw results exactly.

The output is published with a temporary file in the output directory and a
hard link that refuses an existing target, so no partial file and no overwrite
can occur. No real port, address, MAC, timestamp, path or payload is emitted.
"""

import argparse
import base64
import contextlib
import hashlib
import json
import os
import re
import stat
import struct
import sys
import tempfile


SCHEMA_VERSION = 1
TOOL_ID = "m1-wire-002-stream-analysis"
TOOL_VERSION = "1"
WIDTHS = (4, 2)
FILL_BYTE = 0x00
MAX_INPUT_BYTES = 256 * 1024 * 1024
READ_CHUNK_BYTES = 1024 * 1024
OUTPUT_MODE = 0o600
INPUT_IDENTITY_FIELDS = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
SERVER_PORT_PLACEHOLDER = "<configured-barrier-server-port>"

EXIT_OK = 0
EXIT_STOP = 1
EXIT_USAGE = 64
EXIT_DATA = 65
EXIT_NO_INPUT = 66
EXIT_SOFTWARE = 70
EXIT_CANT_CREATE = 73
EXIT_UNSAFE_PATH = 77
EXIT_CANCELLED = 130

PCAP_GLOBAL_HEADER_BYTES = 24
PCAP_RECORD_HEADER_BYTES = 16
PCAP_MAGIC_ORDERS = {b"\xa1\xb2\xc3\xd4": ">", b"\xd4\xc3\xb2\xa1": "<"}
LINKTYPE_ETHERNET = 1
ETHERNET_HEADER_BYTES = 14
ETHERTYPE_IPV4 = 0x0800
IPV4_HEADER_BYTES = 20
IPV4_RESERVED_FLAG = 0x8000
IPV4_MORE_FRAGMENTS = 0x2000
IPV4_FRAGMENT_OFFSET = 0x1FFF
IP_PROTOCOL_TCP = 6
LOOPBACK_FIRST_OCTET = 127
TCP_HEADER_BYTES = 20
TCP_FIN, TCP_SYN, TCP_RST, TCP_ACK, TCP_URG = 0x01, 0x02, 0x04, 0x10, 0x20
SEQUENCE_MODULUS = 1 << 32
SEQUENCE_HALF = 1 << 31

CLIENT_TO_SERVER = "client-to-server"
SERVER_TO_CLIENT = "server-to-client"
DIRECTIONS = (CLIENT_TO_SERVER, SERVER_TO_CLIENT)
DIRECTION_ROLES = {
    CLIENT_TO_SERVER: ("role-client", "role-server"),
    SERVER_TO_CLIENT: ("role-server", "role-client"),
}

PORT_PATTERN = re.compile(r"[1-9][0-9]{0,4}")
NON_CLAIMS = (
    "No Barrier message, field, type, marker or semantic meaning is asserted.",
    "A succeeding width is a partition fact over these streams only; it is not a width "
    "decision, ADR, register entry or M1-025 unblock.",
    "Capture-tool dropped-packet counts are not visible in a classic pcap and are not "
    "verified by this helper.",
    "Marker and version bytes are not retained; only prefix positions read by either walk "
    "keep original bytes.",
    "IPv4 and TCP checksums are not validated.",
)


class AnalysisError(Exception):
    """Rejection with a fixed code; never carries capture bytes, paths or values."""

    def __init__(self, code, exit_code=EXIT_DATA):
        super().__init__(code)
        self.code = code
        self.exit_code = exit_code


def walk(stream, width):
    """Plan section 4.2 partition walk with an unsigned big-endian prefix of `width` bytes."""
    frames = []
    offset = 0
    length = len(stream)
    while offset < length:
        if length - offset < width:
            failure = {"offset": offset, "reason": "leftover-bytes", "remaining": length - offset}
            return {"width": width, "result": "failure", "frames": frames, "failure": failure}
        declared = int.from_bytes(stream[offset : offset + width], "big")
        available = length - offset - width
        if declared > available:
            failure = {
                "offset": offset,
                "reason": "overrun",
                "declared": declared,
                "available": available,
            }
            return {"width": width, "result": "failure", "frames": frames, "failure": failure}
        frames.append([offset, declared])
        offset += width + declared
    return {"width": width, "result": "success", "frames": frames, "finalOffset": offset}


def prefix_offsets(result):
    offsets = [frame[0] for frame in result["frames"]]
    if result["result"] == "failure" and result["failure"]["reason"] == "overrun":
        offsets.append(result["failure"]["offset"])
    return offsets


def retained_mask(length, walks):
    mask = bytearray(length)
    for result in walks:
        for offset in prefix_offsets(result):
            mask[offset : offset + result["width"]] = b"\x01" * result["width"]
    return mask


def sanitize_stream(stream, walks):
    """Keep bytes only at positions read as prefixes by the given raw walks."""
    sanitized = bytearray([FILL_BYTE]) * len(stream)
    for result in walks:
        for offset in prefix_offsets(result):
            end = offset + result["width"]
            sanitized[offset:end] = stream[offset:end]
    return bytes(sanitized)


def read_pcap(data):
    """Return (record count, frames) of a classic microsecond EN10MB pcap."""
    if len(data) < PCAP_GLOBAL_HEADER_BYTES:
        raise AnalysisError("pcap-header-truncated")
    order = PCAP_MAGIC_ORDERS.get(bytes(data[:4]))
    if order is None:
        raise AnalysisError("pcap-unsupported-format")
    major, minor, _, _, snaplen, link_type = struct.unpack(
        order + "HHiIII", data[4:PCAP_GLOBAL_HEADER_BYTES]
    )
    if (major, minor) != (2, 4):
        raise AnalysisError("pcap-unsupported-version")
    if link_type != LINKTYPE_ETHERNET:
        raise AnalysisError("pcap-unsupported-link-type")
    view = memoryview(data)
    frames = []
    offset = PCAP_GLOBAL_HEADER_BYTES
    while offset < len(data):
        if len(data) - offset < PCAP_RECORD_HEADER_BYTES:
            raise AnalysisError("pcap-record-truncated")
        _, microseconds, included, original = struct.unpack(
            order + "IIII", data[offset : offset + PCAP_RECORD_HEADER_BYTES]
        )
        offset += PCAP_RECORD_HEADER_BYTES
        if microseconds >= 1000000:
            raise AnalysisError("pcap-malformed-timestamp")
        if included != original:
            raise AnalysisError("pcap-record-snapped")
        if included > snaplen:
            raise AnalysisError("pcap-record-exceeds-snaplen")
        if len(data) - offset < included:
            raise AnalysisError("pcap-record-truncated")
        frames.append(view[offset : offset + included])
        offset += included
    return frames


def parse_segment(frame, server_port):
    """Return (connection key, direction, sequence, flags, payload) of one frame."""
    if len(frame) < ETHERNET_HEADER_BYTES:
        raise AnalysisError("ethernet-truncated")
    if int.from_bytes(frame[12:14], "big") != ETHERTYPE_IPV4:
        raise AnalysisError("unsupported-ethertype")
    ip = frame[ETHERNET_HEADER_BYTES:]
    if len(ip) < IPV4_HEADER_BYTES or ip[0] >> 4 != 4 or ip[0] & 0x0F < 5:
        raise AnalysisError("ipv4-malformed")
    if ip[0] & 0x0F != 5:
        raise AnalysisError("ipv4-options-unsupported")
    if int.from_bytes(ip[2:4], "big") != len(ip):
        raise AnalysisError("ipv4-length-mismatch")
    flags_fragment = int.from_bytes(ip[6:8], "big")
    if flags_fragment & IPV4_RESERVED_FLAG:
        raise AnalysisError("ipv4-malformed")
    if flags_fragment & (IPV4_MORE_FRAGMENTS | IPV4_FRAGMENT_OFFSET):
        raise AnalysisError("ipv4-fragment")
    if ip[9] != IP_PROTOCOL_TCP:
        raise AnalysisError("unsupported-ip-protocol")
    source, destination = bytes(ip[12:16]), bytes(ip[16:20])
    if source[0] != LOOPBACK_FIRST_OCTET or destination[0] != LOOPBACK_FIRST_OCTET:
        raise AnalysisError("non-loopback-address")
    tcp = ip[IPV4_HEADER_BYTES:]
    if len(tcp) < TCP_HEADER_BYTES:
        raise AnalysisError("tcp-malformed")
    source_port, destination_port, sequence = struct.unpack("!HHI", tcp[:8])
    header_length = (tcp[12] >> 4) * 4
    if header_length < TCP_HEADER_BYTES or header_length > len(tcp):
        raise AnalysisError("tcp-malformed")
    flags = tcp[13]
    if flags & TCP_URG:
        raise AnalysisError("tcp-urgent-unsupported")
    if source_port == server_port and destination_port == server_port:
        raise AnalysisError("ambiguous-direction")
    if source_port == server_port:
        direction, key = SERVER_TO_CLIENT, (destination, destination_port, source)
    elif destination_port == server_port:
        direction, key = CLIENT_TO_SERVER, (source, source_port, destination)
    else:
        raise AnalysisError("out-of-scope-traffic")
    return key, direction, sequence, flags, bytes(tcp[header_length:])


def collect_connections(frames, server_port):
    """Group segments by connection in order of first capture; never drop one."""
    connections = {}
    for frame in frames:
        key, direction, sequence, flags, payload = parse_segment(frame, server_port)
        segments = connections.get(key)
        if segments is None:
            handshake_flags = flags & (TCP_SYN | TCP_ACK | TCP_FIN | TCP_RST)
            if direction != CLIENT_TO_SERVER or handshake_flags != TCP_SYN:
                raise AnalysisError("missing-syn")
            segments = connections[key] = []
        segments.append((direction, sequence, flags, payload))
    if not connections:
        raise AnalysisError("no-in-scope-connection")
    return list(connections.values())


def assemble(pieces, fin_offset):
    """Concatenate (offset, payload) pieces in sequence order up to the FIN."""
    stream = bytearray()
    identical = 0
    for offset, payload in sorted(pieces, key=lambda piece: piece[0]):
        end = offset + len(payload)
        if end > fin_offset:
            raise AnalysisError("payload-after-fin")
        if offset > len(stream):
            raise AnalysisError("sequence-gap")
        overlap = min(end, len(stream)) - offset
        if stream[offset : offset + overlap] != payload[:overlap]:
            raise AnalysisError("conflicting-overlap")
        identical += overlap
        stream += payload[overlap:]
    if len(stream) != fin_offset:
        raise AnalysisError("sequence-gap")
    return bytes(stream), identical


def reconstruct(segments):
    """Return {direction: (stream bytes, identical retransmitted byte count)}."""
    if any(flags & TCP_RST for _, _, flags, _ in segments):
        raise AnalysisError("rst-observed")
    initial = {}
    for direction, sequence, flags, payload in segments:
        if not flags & TCP_SYN:
            continue
        server_side = direction == SERVER_TO_CLIENT
        if payload or flags & TCP_FIN or bool(flags & TCP_ACK) != server_side:
            raise AnalysisError("unsupported-syn")
        if initial.setdefault(direction, sequence) != sequence:
            raise AnalysisError("conflicting-syn")
    if set(initial) != set(DIRECTIONS):
        raise AnalysisError("missing-syn")
    streams = {}
    for direction in DIRECTIONS:
        base = (initial[direction] + 1) % SEQUENCE_MODULUS
        pieces = []
        fin_offset = None
        for segment_direction, sequence, flags, payload in segments:
            if segment_direction != direction or flags & TCP_SYN:
                continue
            if not payload and not flags & TCP_FIN:
                continue  # A bare ACK carries no stream bytes.
            offset = (sequence - base) % SEQUENCE_MODULUS
            if offset >= SEQUENCE_HALF:
                raise AnalysisError("data-before-stream-start")
            if payload:
                pieces.append((offset, payload))
            if flags & TCP_FIN:
                position = offset + len(payload)
                if fin_offset is not None and fin_offset != position:
                    raise AnalysisError("conflicting-fin")
                fin_offset = position
        if fin_offset is None:
            raise AnalysisError("fin-missing")
        streams[direction] = assemble(pieces, fin_offset)
    return streams


def walk_set(stream):
    return {"width{0}".format(width): walk(stream, width) for width in WIDTHS}


def stream_document(direction, stream, identical):
    raw_walks = walk_set(stream)
    sanitized = sanitize_stream(stream, list(raw_walks.values()))
    sanitized_walks = walk_set(sanitized)
    if len(sanitized) != len(stream) or sanitized_walks != raw_walks:
        raise AnalysisError("sanitizer-round-trip-mismatch")
    source, destination = DIRECTION_ROLES[direction]
    return {
        "direction": direction,
        "from": source,
        "to": destination,
        "byteLength": len(stream),
        "completeness": {
            "startedAtSyn": True,
            "endedAtFin": True,
            "sequenceGaps": 0,
            "conflictingOverlaps": 0,
            "identicalRetransmittedBytes": identical,
        },
        "sanitized": {
            "byteLength": len(sanitized),
            "sha256": hashlib.sha256(sanitized).hexdigest(),
            "retainedByteCount": sum(retained_mask(len(stream), raw_walks.values())),
            "base64": base64.b64encode(sanitized).decode("ascii"),
        },
        "walks": {"raw": raw_walks, "sanitized": sanitized_walks},
    }


def outcome_document(connections):
    widths = {}
    succeeding = []
    for width in WIDTHS:
        key = "width{0}".format(width)
        failing = [
            {"connection": connection["label"], "direction": stream["direction"]}
            for connection in connections
            for stream in connection["streams"]
            if stream["walks"]["raw"][key]["result"] != "success"
        ]
        widths[key] = {"succeedsOnEveryStream": not failing, "failingStreams": failing}
        if not failing:
            succeeding.append(width)
    if len(succeeding) == 1:
        result = "DISCRIMINATING"
    elif succeeding:
        result = "STOP-BOTH-SUCCEED"
    else:
        result = "STOP-BOTH-FAIL"
    outcome = {
        "result": result,
        "discriminating": result == "DISCRIMINATING",
        "succeedingWidths": succeeding,
    }
    outcome.update(widths)
    return outcome


def analyze(data, server_port):
    """Analyze raw classic-pcap bytes and return the sanitized document."""
    if type(server_port) is not int or not 1 <= server_port <= 65535:
        raise AnalysisError("invalid-port", EXIT_USAGE)
    frames = read_pcap(data)
    connections = []
    for index, segments in enumerate(collect_connections(frames, server_port), 1):
        streams = reconstruct(segments)
        connections.append(
            {
                "label": "connection-{0}".format(index),
                "lifecycle": {
                    "synObserved": {direction: True for direction in DIRECTIONS},
                    "finObserved": {direction: True for direction in DIRECTIONS},
                    "rstObserved": False,
                },
                "streams": [
                    stream_document(direction, *streams[direction]) for direction in DIRECTIONS
                ],
            }
        )
    return {
        "schemaVersion": SCHEMA_VERSION,
        "tool": {"id": TOOL_ID, "version": TOOL_VERSION},
        "input": {
            "format": "pcap-classic-microsecond",
            "linkType": "EN10MB",
            "network": "IPv4-TCP",
            "byteLength": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "recordCount": len(frames),
        },
        "serverPort": SERVER_PORT_PLACEHOLDER,
        "sanitizer": {
            "retainedPositions": "length-prefix-bytes-read-by-either-raw-walk",
            "fillByte": "0x{0:02x}".format(FILL_BYTE),
            "markerBytesRetained": False,
            "roundTrip": "sanitized-walks-equal-raw-walks",
        },
        "connections": connections,
        "outcome": outcome_document(connections),
        "nonClaims": list(NON_CLAIMS),
    }


def serialize(document):
    return (json.dumps(document, indent=2, ensure_ascii=True) + "\n").encode("ascii")


def parse_port(text):
    if not PORT_PATTERN.fullmatch(text) or int(text) > 65535:
        raise AnalysisError("invalid-port", EXIT_USAGE)
    return int(text)


def read_input(path):
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise AnalysisError("input-missing", EXIT_NO_INPUT) from None
    except OSError:
        raise AnalysisError("input-unsafe", EXIT_UNSAFE_PATH) from None
    try:
        status = os.fstat(descriptor)
        if not stat.S_ISREG(status.st_mode):
            raise AnalysisError("input-unsafe", EXIT_UNSAFE_PATH)
        if status.st_size > MAX_INPUT_BYTES:
            raise AnalysisError("input-too-large")
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, READ_CHUNK_BYTES)
            if not chunk:
                break
            total += len(chunk)
            if total > status.st_size:
                raise AnalysisError("input-changed")
            chunks.append(chunk)
        if total != status.st_size:
            raise AnalysisError("input-changed")
        after = os.fstat(descriptor)
        for field in INPUT_IDENTITY_FIELDS:
            if getattr(after, field) != getattr(status, field):
                raise AnalysisError("input-changed")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def check_output(input_path, output_path):
    """Return the output directory after the path refusals."""
    output = os.path.abspath(output_path)
    if os.path.realpath(input_path) == os.path.realpath(output):
        raise AnalysisError("input-output-same", EXIT_UNSAFE_PATH)
    parent = os.path.dirname(output)
    if not os.path.isdir(parent):
        raise AnalysisError("output-parent-missing", EXIT_CANT_CREATE)
    if os.path.lexists(output):
        raise AnalysisError("output-exists", EXIT_CANT_CREATE)
    return parent


def publish(parent, output_path, payload):
    """Write a temporary file, then hard-link it into place without overwriting."""
    descriptor, temporary = tempfile.mkstemp(prefix=".m1-wire-002-", suffix=".tmp", dir=parent)
    try:
        try:
            try:
                os.fchmod(descriptor, OUTPUT_MODE)
                view = memoryview(payload)
                while view:
                    view = view[os.write(descriptor, view) :]
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
        except OSError:
            raise AnalysisError("output-write-failed", EXIT_CANT_CREATE) from None
        try:
            os.link(temporary, output_path)
        except FileExistsError:
            raise AnalysisError("output-exists", EXIT_CANT_CREATE) from None
        except OSError:
            raise AnalysisError("output-publish-failed", EXIT_CANT_CREATE) from None
    finally:
        with contextlib.suppress(OSError):
            os.unlink(temporary)


class _SafeArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise AnalysisError("invalid-arguments", EXIT_USAGE)


def _parse_arguments(arguments):
    parser = _SafeArgumentParser(
        description="Analyze one M1-WIRE-002 classic pcap into one sanitized JSON document."
    )
    parser.add_argument("--input", required=True, help="raw classic pcap on role-capture")
    parser.add_argument("--server-port", required=True, help="configured Barrier server port")
    parser.add_argument("--output", required=True, help="new JSON file; never overwritten")
    return parser.parse_args(arguments)


def main(arguments=None):
    try:
        options = _parse_arguments(arguments)
        port = parse_port(options.server_port)
        parent = check_output(options.input, options.output)
        document = analyze(read_input(options.input), port)
        publish(parent, os.path.abspath(options.output), serialize(document))
    except AnalysisError as error:
        print("stream-analysis error: {0}".format(error.code), file=sys.stderr)
        return error.exit_code
    except KeyboardInterrupt:
        print("stream-analysis error: cancelled", file=sys.stderr)
        return EXIT_CANCELLED
    except Exception:
        # Never let a traceback (local paths, capture values) reach the log.
        print("stream-analysis error: internal-failure", file=sys.stderr)
        return EXIT_SOFTWARE
    print("stream-analysis result: {0}".format(document["outcome"]["result"]))
    return EXIT_OK if document["outcome"]["discriminating"] else EXIT_STOP


if __name__ == "__main__":
    sys.exit(main())
