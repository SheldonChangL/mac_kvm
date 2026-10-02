"""M1-WIRE-001 evidence-first Barrier wire contract sequence tests.

GitHub Issue #278. The suite derives the conformance artifact from the approved
sanitized M1-024 fixture, pins BARRIER-EVID-0001 byte for byte, checks the
appended BARRIER-EVID-0002 entry against the bytes it cites, and checks the
M1-WIRE-001 -> M1-025 -> M1-021 -> M1-022 sequence in the package data.

It uses the Python standard library only, reads no Barrier or Deskflow source,
and freezes no wire contract: M1-025 owns that decision. The 4-byte unsigned
big-endian length prefix is a candidate interpretation only; these bytes do not
establish its width, and the suite keeps that width unknown.
"""

import base64
import copy
import csv
import hashlib
import importlib.util
import json
import re
import textwrap
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
PACKAGE_ROOT = REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2"
MANIFEST = PACKAGE_ROOT / "issues_manifest.json"
EXECUTION_ORDER = PACKAGE_ROOT / "EXECUTION_ORDER.md"
ISSUES_INDEX = PACKAGE_ROOT / "issues_index.csv"
TRACEABILITY = PACKAGE_ROOT / "SOURCE_TRACEABILITY.md"
FROZEN_DECISIONS = PACKAGE_ROOT / "FROZEN_DECISIONS.md"
CANONICAL_SPEC = REPOSITORY_ROOT / "docs/spec/CANONICAL_SPEC_SECTIONS_60_64.md"
PRODUCT_CONTRACT = REPOSITORY_ROOT / "docs/adr/M1-001-product-contract.md"
REGISTER = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
REGISTER_DOCUMENTATION = (
    REPOSITORY_ROOT / "docs/evidence/M1-023-barrier-evidence-register.md"
)
M1_023_VALIDATOR = REPOSITORY_ROOT / "evidence/issues/M1-023/tests/test_register.py"

ADR_PATH = "docs/adr/M1-WIRE-001-evidence-first-wire-contract-sequence.md"
ARTIFACT_PATH = "evidence/issues/M1-WIRE-001/barrier-frame-conformance.json"
SUMMARY_PATH = "evidence/issues/M1-WIRE-001/summary.md"
REVIEW_PATH = "evidence/issues/M1-WIRE-001/independent-review.md"
TEST_PATH = "Tests/Contracts/test_m1_wire_001_contract_sequence.py"
FIXTURE_PATH = (
    "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json"
)
M1_025_ADR_PATH = "docs/adr/M1-025-barrier-client-wire-contract.md"
EVIDENCE_ROOT = REPOSITORY_ROOT / "evidence/issues/M1-WIRE-001"
BARRIER_PACKAGE = REPOSITORY_ROOT / "Packages/BarrierCompatibility"
BARRIER_BOUNDARY_SWIFT = (
    "Packages/BarrierCompatibility/Sources/BarrierCompatibility/BarrierCompatibility.swift"
)
BARRIER_BOUNDARY_TEXT = (
    "// Module boundary only. Barrier behavior requires approved evidence and an owning Issue.\n"
)

FIXTURE_SHA256 = "57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2"
FIXTURE_BYTE_LENGTH = 1079
CANONICAL_SHA256 = "f56253ccadff8edac045d9ba3d09eda9dd5722d12460f236a74981f7d37eedc7"
ALLOWED_DIGESTS = (FIXTURE_SHA256, CANONICAL_SHA256)

SOURCE_EVIDENCE_ID = "BARRIER-EVID-0001"
DERIVED_EVIDENCE_ID = "BARRIER-EVID-0002"
WIRE_ISSUE = "M1-WIRE-001"
FOLLOW_UP_ISSUE = "M1-WIRE-002"
FOLLOW_UP_GITHUB_ISSUE = "#279"
SEQUENCE_MARKER = "M1-WIRE-001 → M1-025 → M1-021 → M1-022"
PRODUCTION_TLS_STATEMENT = (
    "Production behavior uses TLS by default; insecure TCP is not a production fallback."
)
FROZEN_TLS_DECISION = "TLS/security 預設 fail closed"

CANDIDATE_PREFIX_WIDTH = 4
MARKER = b"Barrier"
VERSION_BYTE_COUNT = 4
PAYLOAD_KEY = "applicationPayloadBase64"
ALTERNATIVE_READINGS = (
    ("same 4 bytes read little-endian", 4, "little"),
    ("narrower 2-byte big-endian prefix", 2, "big"),
)

M1_025_WIDTH_GATE = (
    "即使 M1-WIRE-001 已 merge 且 `BARRIER-EVID-0002` 為 `approved`，仍須在凍結 exact length-prefix width 前停止",
    "separately approved discriminating evidence",
    "不足以證明 exact length-prefix width",
    "GitHub Issue #279（M1-WIRE-002",
    "GitHub Issue #279（M1-WIRE-002）是取得該 evidence 的 separately approved workflow",
    "在 #279 完成並取得 `approved` entry 前，M1-025 不得完成 exact length-prefix width 凍結",
)

CHAIN_ISSUES = ("M1-025", "M1-021", "M1-022")
EXPECTED_DEPENDS_ON = {
    "M1-025": ["M1-024"],
    "M1-021": ["M1-015", "M1-025"],
    "M1-022": ["M1-019", "M1-020", "M1-021"],
}
EXPECTED_ORDER = {"M1-025": 22, "M1-021": 36, "M1-022": 38}

CLAIM_PARTITION = DERIVED_EVIDENCE_ID + "-CLAIM-001"
CLAIM_MARKER = DERIVED_EVIDENCE_ID + "-CLAIM-002"
CLAIM_VERSION = DERIVED_EVIDENCE_ID + "-CLAIM-003"
EXPECTED_CLAIM_FIELDS = {
    CLAIM_PARTITION: [
        "candidate-length-prefix-u32-big-endian-interpretation",
        "candidate-frame-partition",
    ],
    CLAIM_MARKER: ["observed-marker-bytes"],
    CLAIM_VERSION: ["observed-version-bytes"],
}
REQUIRED_UNKNOWN_FIELD_IDS = (
    "barrier-message-code",
    "barrier-field-layout-beyond-prefix-and-marker",
    "barrier-length-prefix-width-uniqueness",
    "barrier-maximum-frame-length-and-oversize-behavior",
    "barrier-fragmentation-and-reassembly",
    "barrier-version-field-width-and-meaning",
    "barrier-version-negotiation-and-mismatch-behavior",
    "barrier-optional-and-variant-fields",
)
REQUIRED_PROHIBITED_INFERENCE_TOPICS = (
    "field",
    "message code",
    "endian",
    "framing",
    "boundar",
    "compatib",
    "windows",
    "tls",
)
REQUIRED_NON_CLAIM_TOPICS = (
    "message code",
    "field",
    "negotiation",
    "compatib",
    "windows",
    "tls",
)
EXPECTED_ARTIFACT_KEYS = (
    "schemaVersion",
    "artifactId",
    "producingIssue",
    "githubIssue",
    "registerEntry",
    "derivation",
    "derived",
    "proposedVersionPolicy",
    "limits",
    "nonClaims",
)
UTC_PATTERN = re.compile(
    r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?Z"
)

NEGATION = re.compile(
    r"(?i)\b(?:not|no|never|without|excluded|absent|unvalidated|non-execution|"
    r"cannot|neither|nor|none)\b|不|未|無"
)
TLS_WEAKENING = re.compile(r"(?i)\b(?:disabled|off|insecure|optional)\b")
VERSION_CLAIM = re.compile(r"(?i)negotiat|compatib|cross-version|interoperat")
WIDTH_STATEMENT = re.compile(
    r"(?i)prefix width|4-byte (?:unsigned )?(?:big-endian )?(?:length[- ])?prefix"
)
WIDTH_QUALIFIER = re.compile(
    r"(?i)candidate|\bnot\b|\bno\b|\bnor\b|unknown|narrower|\bunique|blocked|discriminating|不|未"
)
SENTENCE_SPLIT = re.compile(r"(?<=[.;:])\s+")
CODE_SPAN = re.compile(r"`{1,3}[^`]*`{1,3}", re.DOTALL)
NUMBER = re.compile(r"\d+")
GPL_DERIVED = re.compile(
    r"(?i)GNU General Public License|Copyright \(c\)|#include\s*[<\"]|\bkMsg[A-Za-z]"
    r"|\bProtocolTypes\b|\b[\w/-]+\.(?:cpp|hpp|cxx)\b|SPDX-License-Identifier"
)
IDENTIFYING_PATTERNS = {
    "ipv4": re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),
    "ipv6": re.compile(r"(?i)\b(?:[0-9a-f]{1,4}:){2,7}[0-9a-f]{0,4}\b"),
    "user path": re.compile(r"(?i)(?:/Users/|/home/|C:\\Users\\)[^/\s\\]+"),
    "email": re.compile(r"[\w.+-]+@[\w-]+\.[\w.-]+"),
    "local hostname": re.compile(r"(?i)\b[\w-]+\.(?:local|lan|internal|corp|home)\b"),
    "certificate fingerprint": re.compile(
        r"(?i)\b(?:[0-9a-f]{2}:){7,}[0-9a-f]{2}\b|\b[0-9a-f]{32,}\b"
    ),
    "pem material": re.compile(r"-----BEGIN [A-Z ]+-----"),
    "token": re.compile(r"\b(?:ghp_|gho_|github_pat_|sk-|xox[abp]-)[\w-]+"),
}

# BARRIER-EVID-0001 exactly as M1-EVIDENCE-001 registered it, in the canonical
# two-space serialization that the register stores at a four-space indent.
# M1-WIRE-001 must leave every byte of it unchanged; it is never rewritten,
# upgraded or marked superseded by the derived entry.
PINNED_BARRIER_EVID_0001 = r"""{
  "evidenceId": "BARRIER-EVID-0001",
  "relatedIssue": "M1-024",
  "source": {
    "category": "black-box-capture",
    "acquisitionMethod": "Controlled black-box observation of two lawfully installed external Barrier programs on an isolated peer loopback, executed by the capture producer under Tests/SystemTests/Plans/M1-024-barrier-client-handshake-fixtures.md and bounded to one connection window. Direction labelling is capture provenance rather than analysis: the capture producer supplied the server test port of the endpoint role it operated, and the sanitizer applied that producer-selected server-port role to label every retained run. No direction label is derived from payload content."
  },
  "capture": {
    "capturedAt": "2026-09-30T07:01:02Z",
    "tools": [
      {
        "name": "tcpdump",
        "version": "4.99.1"
      }
    ]
  },
  "peer": {
    "product": "Barrier",
    "version": "2.4.0-release",
    "role": "server",
    "os": {
      "name": "Ubuntu",
      "version": "22.04",
      "build": "not-reported"
    }
  },
  "transport": {
    "networkScope": "The recorder ran on the peer loopback interface and observed the Barrier leg there only; every retained byte comes from that peer-loopback observation. The wider transport leg that reached that host was an encrypted local forward whose contents the recorder did not capture, so no cleartext Barrier payload was observed or retained outside the peer-loopback leg and nothing is claimed about that encrypted leg. No identifying address, port or host name was recorded.",
    "tls": {
      "enabled": false,
      "protocolVersion": null,
      "certificateIdentitySanitized": true
    }
  },
  "provenance": {
    "lawfulUseStatement": "Both endpoints were lawfully installed external Barrier programs operated by their owner on hosts under that owner's control, and only externally observable application payload bytes were recorded. No Barrier or Deskflow source, header, constant table, generated implementation artifact or decompiled material was read, copied, linked or bundled.",
    "permittedUse": "Independent clean-room interoperability implementation inside the MacKVM Barrier Protocol Adapter only. This entry authorises no consumer yet: frozenContractRefs and consumingTests stay empty until M1-025 freezes a wire contract and names the tests that consume it.",
    "producer": "M1-024 capture producer, recorded in evidence/issues/M1-024/summary.md and evidence/issues/M1-024/environment.json",
    "reviewer": {
      "identity": "M1-024 independent reviewer, fresh isolated non-producing session, recorded in evidence/issues/M1-024/independent-review.md",
      "independentFromProducer": true,
      "reviewedAt": "2026-10-01T02:36:57Z"
    },
    "disposition": "approved"
  },
  "sanitization": {
    "procedure": "Allowlist sanitization by the capture producer's private temporary sanitizer, SHA-256 d273a45575b75d433e07fb29fe6361aa9d76bf62a9585645affc19698be004a4, whose self-test SHA-256 d8c5c6db42f0e2eac39946ded502e83795b70f7b0a2a8771da57db782b5f8794 passed 21 checks. The retained document keeps sequence numbers, direction labels and base64 application payload runs only; every packet header, address, port, timestamp and transport metadata key is dropped, and a private denylist scan over the decoded payload reported zero hits. Before the raw capture was deleted the independent reviewer re-ran that sanitizer over it and reproduced the retained document byte for byte.",
    "status": "sanitized",
    "containsSensitiveData": false,
    "removedCategories": [
      "ip-address",
      "other-private-data"
    ]
  },
  "fixture": {
    "path": "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json",
    "sha256": "57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2",
    "byteLength": 1079
  },
  "coverage": {
    "direction": "bidirectional",
    "behaviors": [
      "Seven contiguous application-payload runs numbered 1 through 7 were retained from a single bounded 9-second connection window.",
      "Both direction labels occur and the retained labels alternate strictly, beginning with the run labelled server-to-client.",
      "The retained runs decode to 15, 28, 8, 22, 36, 16 and 8 bytes in sequence order, totalling 133 bytes.",
      "No input, clipboard or screen-switch traffic was observed inside the bounded window."
    ],
    "wireClaims": [
      {
        "claimId": "BARRIER-EVID-0001-CLAIM-001",
        "assertion": "In this single observation the retained document holds exactly 7 application-payload runs whose decoded lengths are, in sequence order, 15, 28, 8, 22, 36, 16 and 8 bytes, totalling 133 bytes. The claim covers the retained bytes and their lengths only and asserts no field, message or framing meaning for any of them.",
        "establishedFieldIds": [
          "observed-payload-run-1",
          "observed-payload-run-2",
          "observed-payload-run-3",
          "observed-payload-run-4",
          "observed-payload-run-5",
          "observed-payload-run-6",
          "observed-payload-run-7"
        ],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/0/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/1/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/2/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/3/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/4/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/5/applicationPayloadBase64",
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations/6/applicationPayloadBase64"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0001-CLAIM-002",
        "assertion": "The 7 retained runs form a contiguous 1-based sequence in the order the recorder observed them inside the bounded window, and both direction labels occur. Ordering is an observation of the capture; it is not evidence of a message boundary, a request-response pairing or a protocol state machine.",
        "establishedFieldIds": [
          "observed-run-ordering"
        ],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations"
        ]
      },
      {
        "claimId": "BARRIER-EVID-0001-CLAIM-003",
        "assertion": "Every retained direction label was assigned from the capture producer's selected server test port, which is recorded as capture provenance, and no label was derived from payload content. The independent reviewer confirmed that the opposite server-port selection yields a structurally valid document of the same run count and the same aggregate length with all 7 labels inverted, so only the producer-recorded role reproduces the registered digest.",
        "establishedFieldIds": [
          "observed-run-direction-label"
        ],
        "evidenceLocations": [
          "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json#/observations"
        ]
      }
    ]
  },
  "limitations": [
    "One observation of one external version pair on one locked host pair; it represents nothing beyond that observation.",
    "The observation ran with encryption disabled so that application payload bytes were observable. No payload under TLS was observed, and the MacKVM production TLS default stays enabled, fail-closed and unvalidated by this entry.",
    "The recorder observed only the peer-loopback Barrier leg. The encrypted local forward that reached that host was not captured, so nothing about that leg, its transport or its endpoints is observed or claimed here.",
    "The window is bounded to the connection handshake; no input, clipboard or screen-switch traffic exists in the retained fixture.",
    "The external programs reported protocol version 1.6 through their own command-line metadata. That is a report by the external binaries and establishes nothing about on-wire version negotiation.",
    "peer.os.build records not-reported because the capture producer did not record a Linux peer OS build identifier before the observation and MacKVM_Implementation_Package_v2/toolchain.lock.json pins the peer OS by name and version only. The value is recorded as unreported rather than inferred.",
    "Windows was not executed in M1 under docs/adr/M1-SCOPE-001-linux-only-validation.md; this entry claims no Windows result and no Windows Barrier Server compatibility.",
    "The private raw capture, the peer configuration and the private capture logs were deleted by the capture producer after M1-024 merged. They are not retained, must not be required or recreated, and re-deriving this fixture from raw bytes is therefore no longer repeatable.",
    "The pre-deletion independent re-derivation of this fixture from the raw capture, together with the independent provenance, licensing, privacy and content review, is recorded in evidence/issues/M1-024/independent-review.md, which is the verification record of record for this entry.",
    "Direction labels rest on the capture producer's selected server test port rather than on anything inside an observation, so a consumer that relies on direction relies on capture provenance."
  ],
  "ambiguousFields": [
    {
      "fieldId": "barrier-message-code",
      "observation": "The retained runs are uninterpreted bytes. No message code, message type or command identifier is identified anywhere in them.",
      "status": "unknown",
      "blockedClaimIds": []
    },
    {
      "fieldId": "barrier-field-layout-and-widths",
      "observation": "No field offset, field width, field order or record layout is identified inside any retained run.",
      "status": "unknown",
      "blockedClaimIds": []
    },
    {
      "fieldId": "barrier-field-endianness",
      "observation": "No multi-byte value is identified inside any retained run, so byte order is not observed.",
      "status": "unknown",
      "blockedClaimIds": []
    },
    {
      "fieldId": "barrier-message-framing-and-boundaries",
      "observation": "A retained run is a direction run of the captured byte stream. Whether a run contains zero, one or several protocol messages is not observed.",
      "status": "unknown",
      "blockedClaimIds": []
    },
    {
      "fieldId": "barrier-protocol-version-negotiation-fields",
      "observation": "No version field, negotiation exchange or version compatibility rule is identified inside any retained run.",
      "status": "unknown",
      "blockedClaimIds": []
    },
    {
      "fieldId": "barrier-optional-and-variant-fields",
      "observation": "Optionality, repetition, defaulting and variant selection are not observed; a single successful connection does not enumerate them.",
      "status": "unknown",
      "blockedClaimIds": []
    },
    {
      "fieldId": "barrier-payload-length-and-limit-fields",
      "observation": "Maximum payload length, allocation limits and oversize handling are not observed inside this bounded window.",
      "status": "unknown",
      "blockedClaimIds": []
    }
  ],
  "prohibitedInferences": [
    "Do not infer any Barrier field meaning, field identity, field width or field order from this entry.",
    "Do not infer any Barrier message code, message type or message boundary from this entry.",
    "Do not infer byte order or endianness for any value inside the retained payload runs.",
    "Do not infer message framing, length prefixing or stream segmentation. A retained run is a direction run of the captured byte stream and is not a message.",
    "Do not infer compatibility between Barrier and MacKVM, between Barrier versions, or between platforms.",
    "Windows Barrier Server behavior must not be inferred from this entry; Windows was not executed in M1 and no Windows compatibility is claimed.",
    "Do not infer TLS, certificate or trust behavior. TLS was disabled for this single observation and the product TLS default is neither exercised nor validated here.",
    "Do not fill unknown bytes from model output, Barrier or Deskflow source, analogy or memory. New approved evidence is the only way to supersede an unknown."
  ],
  "frozenContractRefs": [],
  "consumingTests": []
}"""


def load_m1_023_validator():
    specification = importlib.util.spec_from_file_location(
        "m1_wire_001_register_validator", M1_023_VALIDATOR
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def section(text, heading, level="##"):
    pattern = rf"(?ms)^{re.escape(level)} {re.escape(heading)}\n(.*?)(?=^{re.escape(level)} |\Z)"
    match = re.search(pattern, text)
    return match.group(1) if match else ""


def bullets(text):
    return [line[2:] for line in text.splitlines() if line.startswith("- ")]


def sentences(text):
    text = CODE_SPAN.sub(" ", text)
    return [part for part in SENTENCE_SPLIT.split(" ".join(text.split())) if part]


def numeric_tokens(text):
    return [int(token) for token in NUMBER.findall(text)]


def contains_contiguous_run(tokens, run):
    return bool(run) and any(
        tokens[start : start + len(run)] == run
        for start in range(0, len(tokens) - len(run) + 1)
    )


def spaced_hex(hex_text):
    return " ".join(hex_text[index : index + 2] for index in range(0, len(hex_text), 2))


def collect_strings(value, accumulator):
    if isinstance(value, str):
        accumulator.append(value)
    elif isinstance(value, dict):
        for item in value.values():
            collect_strings(item, accumulator)
    elif isinstance(value, list):
        for item in value:
            collect_strings(item, accumulator)
    return accumulator


def resolve_json_pointer(document, pointer):
    """Resolve an RFC 6901 JSON pointer, raising KeyError when it does not."""
    if not pointer.startswith("/"):
        raise KeyError(pointer)
    current = document
    for raw_token in pointer.split("/")[1:]:
        token = raw_token.replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            if not re.fullmatch(r"0|[1-9][0-9]*", token) or int(token) >= len(current):
                raise KeyError(pointer)
            current = current[int(token)]
        elif isinstance(current, dict) and token in current:
            current = current[token]
        else:
            raise KeyError(pointer)
    return current


def decoded_runs(fixture):
    return [
        base64.b64decode(observation[PAYLOAD_KEY], validate=True)
        for observation in fixture["observations"]
    ]


def partition(data, width, byteorder):
    """Return (offset, length) frames that cover data exactly, or None."""
    frames = []
    offset = 0
    while offset < len(data):
        payload_offset = offset + width
        if payload_offset > len(data):
            return None
        length = int.from_bytes(data[offset:payload_offset], byteorder)
        if payload_offset + length > len(data):
            return None
        frames.append((offset, length))
        offset = payload_offset + length
    return frames


def derive_conformance(fixture_bytes):
    """Derive the candidate frame view of the approved fixture.

    Every run is partitioned under one candidate interpretation, a 4-byte
    unsigned big-endian length prefix, which the bytes do not prove: the
    alternative readings record that a narrower 2-byte big-endian prefix also
    partitions every run, so the width stays unknown. The result holds
    offsets, lengths, candidate length-prefix values, the marker bytes and the
    4 bytes after them only. No other payload byte is copied.
    """
    fixture = json.loads(fixture_bytes.decode("utf-8"))
    runs = []
    markers = []
    versions = []
    length_values = []
    for index, (observation, data) in enumerate(
        zip(fixture["observations"], decoded_runs(fixture))
    ):
        frames = partition(data, CANDIDATE_PREFIX_WIDTH, "big")
        if frames is None:
            raise ValueError(
                "run {0} does not partition into candidate length-prefixed frames".format(
                    observation["sequence"]
                )
            )
        recorded = []
        for frame_index, (offset, length) in enumerate(frames):
            payload_offset = offset + CANDIDATE_PREFIX_WIDTH
            payload_end = payload_offset + length
            recorded.append(
                {
                    "frameIndex": frame_index,
                    "prefixOffset": offset,
                    "lengthPrefixHex": data[offset:payload_offset].hex(),
                    "lengthValue": length,
                    "payloadOffset": payload_offset,
                    "payloadEndOffset": payload_end,
                }
            )
            length_values.append(length)
            if not data[payload_offset:payload_end].startswith(MARKER):
                continue
            version_offset = payload_offset + len(MARKER)
            if version_offset + VERSION_BYTE_COUNT > payload_end:
                raise ValueError("marker-bearing frame is too short for version bytes")
            markers.append(
                {
                    "sequence": observation["sequence"],
                    "frameIndex": frame_index,
                    "runOffset": payload_offset,
                    "byteLength": len(MARKER),
                    "hex": MARKER.hex(),
                    "ascii": MARKER.decode("ascii"),
                }
            )
            versions.append(
                {
                    "sequence": observation["sequence"],
                    "frameIndex": frame_index,
                    "runOffset": version_offset,
                    "byteLength": VERSION_BYTE_COUNT,
                    "hex": data[version_offset : version_offset + VERSION_BYTE_COUNT].hex(),
                }
            )
        runs.append(
            {
                "sequence": observation["sequence"],
                "direction": observation["direction"],
                "sourcePointer": "/observations/{0}/{1}".format(index, PAYLOAD_KEY),
                "byteLength": len(data),
                "frames": recorded,
            }
        )
    payloads = decoded_runs(fixture)
    alternatives = [
        {
            "reading": reading,
            "widthBytes": width,
            "byteOrder": byteorder + "-endian",
            "runsPartitioned": sum(
                1 for data in payloads if partition(data, width, byteorder) is not None
            ),
            "runsTotal": len(payloads),
        }
        for reading, width, byteorder in ALTERNATIVE_READINGS
    ]
    return {
        "byteSource": {
            "evidenceId": SOURCE_EVIDENCE_ID,
            "fixturePath": FIXTURE_PATH,
            "fixtureSha256": hashlib.sha256(fixture_bytes).hexdigest(),
            "fixtureByteLength": len(fixture_bytes),
        },
        "candidateLengthPrefix": {
            "interpretation": "candidate",
            "widthBytes": CANDIDATE_PREFIX_WIDTH,
            "byteOrder": "big-endian",
            "signedness": "unsigned",
            "value": "count of bytes that follow the prefix in the same candidate frame",
            "widthUniqueness": "unknown",
        },
        "runs": runs,
        "markerObservations": markers,
        "versionByteObservations": versions,
        "alternativeReadings": alternatives,
        "totals": {
            "runs": len(runs),
            "frames": len(length_values),
            "bytes": sum(len(data) for data in payloads),
            "prefixBytes": CANDIDATE_PREFIX_WIDTH * len(length_values),
            "payloadBytes": sum(length_values),
            "minLengthValue": min(length_values),
            "maxLengthValue": max(length_values),
        },
        "runsWithMultipleCandidateFrames": [
            run["sequence"] for run in runs if len(run["frames"]) > 1
        ],
    }


def payload_texts(fixture_bytes):
    """Printable payload text and encoded payloads that must never be copied out."""
    fixture = json.loads(fixture_bytes.decode("utf-8"))
    texts = {observation[PAYLOAD_KEY] for observation in fixture["observations"]}
    for data in decoded_runs(fixture):
        texts.update(run.decode("ascii") for run in re.findall(rb"[\x20-\x7e]{3,}", data))
    texts.discard(MARKER.decode("ascii"))
    return texts


def text_violations(name, text, fixture_bytes, check_versions=False):
    """Claims and content a M1-WIRE-001 document must never carry."""
    violations = []
    for sentence in sentences(text):
        lowered = sentence.lower()
        if "windows" in lowered and not NEGATION.search(sentence):
            violations.append("{0}: claims a Windows result: {1}".format(name, sentence))
        if (
            re.search(r"(?i)\btls\b", sentence)
            and TLS_WEAKENING.search(sentence)
            and "observation" not in lowered
        ):
            violations.append("{0}: weakens the TLS default: {1}".format(name, sentence))
        if check_versions and VERSION_CLAIM.search(sentence) and not NEGATION.search(sentence):
            violations.append("{0}: claims version behavior: {1}".format(name, sentence))
        if WIDTH_STATEMENT.search(sentence) and not WIDTH_QUALIFIER.search(sentence):
            violations.append("{0}: claims an exact prefix width: {1}".format(name, sentence))
    for leaked in sorted(payload_texts(fixture_bytes)):
        if leaked in text:
            violations.append("{0}: copies payload text".format(name))
            break
    if GPL_DERIVED.search(text):
        violations.append("{0}: carries GPL-derived material".format(name))
    scrubbed = text
    for digest in ALLOWED_DIGESTS:
        scrubbed = scrubbed.replace(digest, "")
    for label, pattern in IDENTIFYING_PATTERNS.items():
        if pattern.search(scrubbed):
            violations.append("{0}: identifying content: {1}".format(name, label))
    return violations


def artifact_violations(artifact, fixture_bytes):
    violations = []
    if tuple(artifact) != EXPECTED_ARTIFACT_KEYS:
        return ["artifact keys are not exactly {0}".format(list(EXPECTED_ARTIFACT_KEYS))]
    try:
        derived = derive_conformance(fixture_bytes)
    except (ValueError, KeyError, TypeError) as error:
        return ["fixture no longer derives a frame view: {0}".format(error)]
    if artifact["derived"] != derived:
        violations.append("derived section does not match the derivation from the fixture")
    if derived["byteSource"]["fixtureSha256"] != FIXTURE_SHA256:
        violations.append("fixture digest is not the approved M1-024 digest")
    if derived["byteSource"]["fixtureByteLength"] != FIXTURE_BYTE_LENGTH:
        violations.append("fixture length is not the approved M1-024 length")
    candidate = artifact["derived"].get("candidateLengthPrefix", {})
    narrower = [
        item for item in derived["alternativeReadings"]
        if item["widthBytes"] < CANDIDATE_PREFIX_WIDTH and item["runsPartitioned"] == item["runsTotal"]
    ]
    if (
        candidate.get("interpretation") != "candidate"
        or candidate.get("widthUniqueness") != "unknown"
        or not narrower
    ):
        violations.append("the candidate length prefix is presented as a proven width")
    if not any(item.startswith("No exact length-prefix width is established.") for item in artifact["nonClaims"]):
        violations.append("non-claims do not exclude an exact length-prefix width")
    identity = (
        artifact["producingIssue"],
        artifact["githubIssue"],
        artifact["registerEntry"],
        artifact["derivation"].get("deriver"),
        artifact["derivation"].get("function"),
    )
    if identity != (WIRE_ISSUE, 278, DERIVED_EVIDENCE_ID, TEST_PATH, "derive_conformance"):
        violations.append("artifact identity or deriver drifted")
    policy = artifact["proposedVersionPolicy"]
    observed = {item["hex"] for item in derived["versionByteObservations"]}
    if (
        policy.get("status") != "proposed-for-M1-025-decision"
        or policy.get("decisionOwner") != "M1-025"
        or policy.get("rule") != "exact-supported-version-fail-closed"
    ):
        violations.append("version policy is no longer a fail-closed proposal for M1-025")
    if observed != {policy.get("supportedVersionBytesHex")}:
        violations.append("proposed version bytes are not exactly the observed version bytes")
    if spaced_hex(policy.get("supportedVersionBytesHex", "")) not in policy.get("statement", ""):
        violations.append("version policy statement does not name the exact version bytes")
    non_claims = " ".join(artifact["nonClaims"]).lower()
    for topic in REQUIRED_NON_CLAIM_TOPICS:
        if topic not in non_claims:
            violations.append("non-claims do not cover {0!r}".format(topic))
    for value in collect_strings(
        [artifact["derivation"]["rule"], policy, artifact["limits"], artifact["nonClaims"]], []
    ):
        violations.extend(text_violations("artifact", value, fixture_bytes, check_versions=True))
    return violations


def payload_location(index):
    return "{0}#/observations/{1}/{2}".format(FIXTURE_PATH, index, PAYLOAD_KEY)


def expected_claim_locations(derived):
    index_of = {
        run["sequence"]: int(run["sourcePointer"].split("/")[2]) for run in derived["runs"]
    }
    marker_runs = [index_of[item["sequence"]] for item in derived["markerObservations"]]
    version_runs = [index_of[item["sequence"]] for item in derived["versionByteObservations"]]
    return {
        CLAIM_PARTITION: [payload_location(index_of[run["sequence"]]) for run in derived["runs"]]
        + [ARTIFACT_PATH + "#/derived/runs"],
        CLAIM_MARKER: [payload_location(index) for index in marker_runs]
        + [ARTIFACT_PATH + "#/derived/markerObservations"],
        CLAIM_VERSION: [payload_location(index) for index in version_runs]
        + [ARTIFACT_PATH + "#/derived/versionByteObservations"],
    }


def pinned_source_violations(register_text, register):
    violations = []
    block = textwrap.indent(PINNED_BARRIER_EVID_0001, "    ")
    if register_text.count(block) != 1:
        violations.append("BARRIER-EVID-0001 is not byte-for-byte unchanged")
    elif '  "entries": [\n' + block + ",\n    {\n" not in register_text:
        violations.append("BARRIER-EVID-0001 is not the first entry followed by an appended entry")
    entries = register.get("entries") or [None]
    if entries[0] != json.loads(PINNED_BARRIER_EVID_0001):
        violations.append("BARRIER-EVID-0001 is not semantically unchanged")
    return violations


def derived_entry_violations(register, artifact, fixture_bytes, validator):
    violations = []
    ids = [entry.get("evidenceId") for entry in register.get("entries", [])]
    if ids[:2] != [SOURCE_EVIDENCE_ID, DERIVED_EVIDENCE_ID] or ids.count(DERIVED_EVIDENCE_ID) != 1:
        return ["BARRIER-EVID-0002 is not appended exactly once after BARRIER-EVID-0001"]
    source, entry = register["entries"][0], register["entries"][1]
    try:
        validator.validate_register(register)
    except (ValueError, KeyError, TypeError) as error:
        violations.append("M1-023 validator rejects the register: {0}".format(error))
    if entry.get("relatedIssue") != "M1-024":
        violations.append("relatedIssue must record the M1-024 byte producer")
    if entry.get("source", {}).get("category") != "sanitized-conformance-vector":
        violations.append("derived entry is not a sanitized conformance vector")
    if WIRE_ISSUE not in entry.get("source", {}).get("acquisitionMethod", ""):
        violations.append("acquisition method does not name M1-WIRE-001")
    if ARTIFACT_PATH not in entry.get("source", {}).get("acquisitionMethod", ""):
        violations.append("acquisition method does not name the derived artifact")
    expected_fixture = {
        "path": FIXTURE_PATH,
        "sha256": FIXTURE_SHA256,
        "byteLength": FIXTURE_BYTE_LENGTH,
    }
    if entry.get("fixture") != expected_fixture or source.get("fixture") != expected_fixture:
        violations.append("derived entry does not pin the approved M1-024 fixture")
    tls = entry.get("transport", {}).get("tls", {})
    if tls != {"enabled": False, "protocolVersion": None, "certificateIdentitySanitized": True}:
        violations.append("derived entry changes the recorded TLS observation")
    if entry.get("frozenContractRefs") != [] or entry.get("consumingTests") != []:
        violations.append("derived entry names a consumer before M1-025 freezes a contract")
    if entry.get("coverage", {}).get("direction") != source.get("coverage", {}).get("direction"):
        violations.append("derived entry changes the recorded direction coverage")

    derived = artifact["derived"]
    claims = {claim.get("claimId"): claim for claim in entry["coverage"]["wireClaims"]}
    if sorted(claims) != sorted(EXPECTED_CLAIM_FIELDS):
        return violations + ["claim ids are not exactly {0}".format(sorted(EXPECTED_CLAIM_FIELDS))]
    locations = expected_claim_locations(derived)
    documents = {
        FIXTURE_PATH: json.loads(fixture_bytes.decode("utf-8")),
        ARTIFACT_PATH: artifact,
    }
    for claim_id, fields in EXPECTED_CLAIM_FIELDS.items():
        claim = claims[claim_id]
        if claim.get("establishedFieldIds") != fields:
            violations.append("{0} establishes {1}".format(claim_id, claim.get("establishedFieldIds")))
        if claim.get("evidenceLocations") != locations[claim_id]:
            violations.append("{0} points at the wrong bytes".format(claim_id))
        for location in claim.get("evidenceLocations", []):
            path, _, pointer = location.partition("#")
            try:
                resolve_json_pointer(documents[path], pointer)
            except KeyError:
                violations.append("{0} pointer does not resolve: {1}".format(claim_id, location))

    numbers = numeric_tokens(claims[CLAIM_PARTITION]["assertion"])
    frames_per_run = [len(run["frames"]) for run in derived["runs"]]
    length_values = [frame["lengthValue"] for run in derived["runs"] for frame in run["frames"]]
    totals = derived["totals"]
    if not (
        contains_contiguous_run(numbers, frames_per_run)
        and contains_contiguous_run(numbers, length_values)
        and {totals["runs"], totals["frames"], totals["bytes"], CANDIDATE_PREFIX_WIDTH} <= set(numbers)
    ):
        violations.append("{0} does not state the derived frame counts and length values".format(CLAIM_PARTITION))
    little_endian = next(item for item in derived["alternativeReadings"] if item["byteOrder"] == "little-endian")
    if little_endian["runsPartitioned"] != 0 or "little-endian partitions none" not in claims[CLAIM_PARTITION]["assertion"]:
        violations.append("{0} does not record that the little-endian reading fails".format(CLAIM_PARTITION))
    if "does not establish the prefix width" not in claims[CLAIM_PARTITION]["assertion"]:
        violations.append("{0} does not keep the prefix width unestablished".format(CLAIM_PARTITION))
    marker_assertion = claims[CLAIM_MARKER]["assertion"]
    for marker in derived["markerObservations"]:
        if spaced_hex(marker["hex"]) not in marker_assertion or "offset {0}".format(marker["runOffset"]) not in marker_assertion:
            violations.append("{0} does not state the marker bytes and offset".format(CLAIM_MARKER))
    version_assertion = claims[CLAIM_VERSION]["assertion"]
    for version in derived["versionByteObservations"]:
        span = "offsets {0} to {1}".format(
            version["runOffset"], version["runOffset"] + version["byteLength"] - 1
        )
        if spaced_hex(version["hex"]) not in version_assertion or span not in version_assertion:
            violations.append("{0} does not state the version bytes and offsets".format(CLAIM_VERSION))

    unknown = {field.get("fieldId") for field in entry.get("ambiguousFields", [])}
    established = {field for fields in EXPECTED_CLAIM_FIELDS.values() for field in fields}
    for field_id in REQUIRED_UNKNOWN_FIELD_IDS:
        if field_id not in unknown:
            violations.append("derived entry does not keep {0} unknown".format(field_id))
    if unknown & established:
        violations.append("an unknown field supports a derived claim")
    prohibited = " ".join(entry.get("prohibitedInferences", [])).lower()
    for topic in REQUIRED_PROHIBITED_INFERENCE_TOPICS:
        if topic not in prohibited:
            violations.append("prohibited inferences do not name {0!r}".format(topic))

    claim_texts = collect_strings(
        [
            entry["source"],
            entry["transport"]["networkScope"],
            entry["provenance"],
            entry["sanitization"]["procedure"],
            entry["coverage"]["behaviors"],
            [claim["assertion"] for claim in entry["coverage"]["wireClaims"]],
            entry["limitations"],
            [field["observation"] for field in entry["ambiguousFields"]],
            entry["prohibitedInferences"],
        ],
        [],
    )
    for value in claim_texts:
        violations.extend(text_violations(DERIVED_EVIDENCE_ID, value, fixture_bytes, check_versions=True))
    return violations


def review_gate_violations(entry, review_exists, m1_025_adr_exists):
    """BARRIER-EVID-0002 is consumable only after a recorded independent review."""
    violations = []
    provenance = entry["provenance"]
    reviewer = provenance["reviewer"]
    if provenance["disposition"] == "approved":
        if not review_exists:
            violations.append("approved without {0}".format(REVIEW_PATH))
        if reviewer.get("independentFromProducer") is not True:
            violations.append("approved without an independent reviewer")
        if REVIEW_PATH not in reviewer.get("identity", ""):
            violations.append("approved reviewer does not name {0}".format(REVIEW_PATH))
        if reviewer.get("identity") == provenance.get("producer"):
            violations.append("producer approved its own evidence")
        if not UTC_PATTERN.fullmatch(reviewer.get("reviewedAt", "")):
            violations.append("approved review has no UTC review time")
    elif provenance["disposition"] == "pending-review":
        if reviewer.get("independentFromProducer") is not False:
            violations.append("pending entry claims an independent review")
    if m1_025_adr_exists and provenance["disposition"] != "approved":
        violations.append("M1-025 froze a contract before BARRIER-EVID-0002 was approved")
    return violations


def frontmatter_depends_on(text):
    match = re.search(r"(?m)^depends_on:\n((?:  - \".*\"\n)*)", text)
    return re.findall(r'  - "(.*)"', match.group(1)) if match else None


def execution_order_rows(text):
    rows = {}
    for line in text.splitlines():
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) != 6 or not cells[0].isdigit():
            continue
        match = re.match(r"\[(M[1-5]-\d{3})\]", cells[1])
        if match:
            rows[match.group(1)] = (int(cells[0]), cells[5])
    return rows


def read_index_rows():
    with ISSUES_INDEX.open(encoding="utf-8-sig", newline="") as handle:
        return list(csv.DictReader(handle))


def sequence_violations(manifest, issue_texts, execution_order, index_rows):
    violations = []
    issues = manifest["issues"]
    entries = {issue["id"]: issue for issue in issues}
    order = {issue["id"]: issue["topological_order"] for issue in issues}
    if WIRE_ISSUE in entries:
        violations.append("M1-WIRE-001 must stay outside the canonical manifest")
    if FOLLOW_UP_ISSUE in entries:
        violations.append("M1-WIRE-002 must stay outside the canonical manifest")
    for issue in issues:
        for dependency in issue["depends_on"]:
            if dependency not in entries:
                violations.append(
                    "{0}: dependency outside the canonical manifest: {1}".format(issue["id"], dependency)
                )
            elif (issue["id"] in CHAIN_ISSUES or dependency in CHAIN_ISSUES) and order[dependency] >= order[issue["id"]]:
                violations.append("{0} is ordered before its dependency {1}".format(issue["id"], dependency))
    if not order["M1-025"] < order["M1-021"] < order["M1-022"]:
        violations.append("order is not M1-025 -> M1-021 -> M1-022")
    positions = {issue["id"]: index for index, issue in enumerate(issues)}
    for issue_id, expected in EXPECTED_DEPENDS_ON.items():
        entry = entries[issue_id]
        text = issue_texts[issue_id]
        if entry["depends_on"] != expected:
            violations.append("{0} manifest depends_on is {1}".format(issue_id, entry["depends_on"]))
        if entry["topological_order"] != EXPECTED_ORDER[issue_id]:
            violations.append("{0} topological_order is {1}".format(issue_id, entry["topological_order"]))
        index = positions[issue_id]
        neighbours = [issues[index - 1]["topological_order"], issues[index + 1]["topological_order"]]
        if neighbours != [entry["topological_order"] - 1, entry["topological_order"] + 1]:
            violations.append("{0} manifest position does not follow topological_order".format(issue_id))
        if frontmatter_depends_on(text) != entry["depends_on"]:
            violations.append("{0} issue file depends_on differs from the manifest".format(issue_id))
        precondition = "所有 dependencies 已完成：{0}。".format(", ".join(entry["depends_on"]))
        if precondition not in section(text, "Preconditions"):
            violations.append("{0} preconditions do not list its dependencies".format(issue_id))
        if bullets(section(text, "Scope"))[: len(entry["focus"])] != entry["focus"]:
            violations.append("{0} scope differs from the manifest focus".format(issue_id))
    m1_025 = section(issue_texts["M1-025"], "Preconditions") + section(
        issue_texts["M1-025"], "Frozen Contract References"
    )
    for marker in (WIRE_ISSUE, "#278", DERIVED_EVIDENCE_ID, "`approved`", ARTIFACT_PATH, ADR_PATH, "exact-supported-version"):
        if marker not in m1_025:
            violations.append("M1-025 prerequisite prose does not name {0}".format(marker))
    m1_025_preconditions = section(issue_texts["M1-025"], "Preconditions")
    if any(marker not in m1_025_preconditions for marker in M1_025_WIDTH_GATE):
        violations.append(
            "M1-025 preconditions do not block an exact prefix width on GitHub Issue #279 (M1-WIRE-002) evidence"
        )
    for issue_id in ("M1-021", "M1-022"):
        if M1_025_ADR_PATH not in section(issue_texts[issue_id], "Preconditions"):
            violations.append("{0} does not make the frozen-contract prerequisite explicit".format(issue_id))
    rows = execution_order_rows(execution_order)
    for issue_id in CHAIN_ISSUES:
        expected_row = (order[issue_id], ", ".join(entries[issue_id]["depends_on"]))
        if rows.get(issue_id) != expected_row:
            violations.append("EXECUTION_ORDER.md row for {0} is {1}".format(issue_id, rows.get(issue_id)))
    if SEQUENCE_MARKER not in execution_order or WIRE_ISSUE + "）" not in execution_order:
        violations.append("EXECUTION_ORDER.md does not state the M1-WIRE-001 sequence")
    found = set()
    for position, row in enumerate(index_rows, start=1):
        if row["id"] not in CHAIN_ISSUES:
            continue
        found.add(row["id"])
        if row["depends_on"] != ",".join(entries[row["id"]]["depends_on"]) or position != order[row["id"]]:
            violations.append("issues_index.csv row for {0} drifted".format(row["id"]))
    if found != set(CHAIN_ISSUES):
        violations.append("issues_index.csv is missing a chain issue")
    return violations


def barrier_swift_files():
    return sorted(
        path.relative_to(REPOSITORY_ROOT).as_posix()
        for path in BARRIER_PACKAGE.rglob("*.swift")
        if ".build" not in path.relative_to(BARRIER_PACKAGE).parts
    )


def ordering_gate_violations(swift_files, boundary_text, m1_025_adr_exists):
    """No Barrier Swift codec or parser may exist before M1-025 freezes the contract."""
    if m1_025_adr_exists:
        return []
    violations = [
        "Barrier Swift source exists before M1-025: {0}".format(path)
        for path in swift_files
        if path != BARRIER_BOUNDARY_SWIFT
    ]
    if boundary_text != BARRIER_BOUNDARY_TEXT:
        violations.append("Barrier module boundary changed before M1-025")
    return violations


def tls_default_violations(canonical_bytes, frozen_text, contract_text):
    violations = []
    if hashlib.sha256(canonical_bytes).hexdigest() != CANONICAL_SHA256:
        violations.append("canonical specification changed")
    if FROZEN_TLS_DECISION not in frozen_text:
        violations.append("frozen TLS fail-closed decision changed")
    if PRODUCTION_TLS_STATEMENT not in contract_text:
        violations.append("production TLS default statement changed")
    return violations


def adr_violations(adr):
    violations = []
    status = section(adr, "Status")
    if "Accepted by Product Owner authorization on 2026-10-02" not in status or "Issue #278" not in status:
        violations.append("ADR status does not record the Product Owner authorization")
    for heading in (
        "Context",
        "Decision",
        "Proposed version policy for M1-025",
        "Selected alternative",
        "Rejected alternatives",
        "Security and privacy",
        "Compatibility",
        "Consequences",
        "Rollback",
        "Traceability",
    ):
        if not section(adr, heading).strip():
            violations.append("ADR section missing: {0}".format(heading))
    for marker in (
        SOURCE_EVIDENCE_ID,
        DERIVED_EVIDENCE_ID,
        SEQUENCE_MARKER,
        "exact-supported-version",
        "does not change canonical or frozen product architecture",
        ARTIFACT_PATH,
        TEST_PATH,
        REVIEW_PATH,
    ):
        if marker not in adr:
            violations.append("ADR does not name {0}".format(marker))
    for heading in ("Consequences", "Traceability"):
        if "GitHub Issue #279 (M1-WIRE-002" not in section(adr, heading):
            violations.append("ADR {0} does not name the #279 (M1-WIRE-002) width blocker".format(heading))
    if "#279 is not complete" not in adr:
        violations.append("ADR does not keep #279 (M1-WIRE-002) open")
    if re.search(r"\b(?:TODO|TBD)\b", adr):
        violations.append("ADR has an unresolved placeholder")
    return violations


class M1Wire001ContractSequenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture_bytes = (REPOSITORY_ROOT / FIXTURE_PATH).read_bytes()
        cls.artifact_text = (REPOSITORY_ROOT / ARTIFACT_PATH).read_text(encoding="utf-8")
        cls.artifact = json.loads(cls.artifact_text)
        cls.register_text = REGISTER.read_text(encoding="utf-8")
        cls.register = json.loads(cls.register_text)
        cls.validator = load_m1_023_validator()
        cls.manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
        entries = {issue["id"]: issue for issue in cls.manifest["issues"]}
        cls.issue_texts = {
            issue_id: (PACKAGE_ROOT / entries[issue_id]["issue_file"]).read_text(encoding="utf-8")
            for issue_id in CHAIN_ISSUES
        }
        cls.execution_order = EXECUTION_ORDER.read_text(encoding="utf-8")
        cls.index_rows = read_index_rows()
        cls.adr = (REPOSITORY_ROOT / ADR_PATH).read_text(encoding="utf-8")
        cls.summary = (REPOSITORY_ROOT / SUMMARY_PATH).read_text(encoding="utf-8")
        cls.register_documentation = REGISTER_DOCUMENTATION.read_text(encoding="utf-8")
        cls.traceability = TRACEABILITY.read_text(encoding="utf-8")
        cls.review_exists = (REPOSITORY_ROOT / REVIEW_PATH).is_file()
        cls.m1_025_adr_exists = (REPOSITORY_ROOT / M1_025_ADR_PATH).exists()

    def derived_entry(self):
        return next(
            entry for entry in self.register["entries"] if entry["evidenceId"] == DERIVED_EVIDENCE_ID
        )

    def test_fixture_hash_and_length_match_the_approved_source(self):
        fixture = REPOSITORY_ROOT / FIXTURE_PATH
        self.assertFalse(fixture.is_symlink())
        self.assertEqual(len(self.fixture_bytes), FIXTURE_BYTE_LENGTH)
        self.assertEqual(hashlib.sha256(self.fixture_bytes).hexdigest(), FIXTURE_SHA256)

    def test_artifact_is_derived_from_the_fixture(self):
        self.assertEqual(artifact_violations(self.artifact, self.fixture_bytes), [])
        derived = self.artifact["derived"]
        self.assertEqual(derived["totals"]["frames"], 11)
        self.assertEqual(derived["totals"]["bytes"], 133)
        self.assertEqual(
            [item["hex"] for item in derived["versionByteObservations"]],
            ["00010006", "00010006"],
        )
        self.assertEqual(
            [item["runsPartitioned"] for item in derived["alternativeReadings"]], [0, 7]
        )
        self.assertEqual(derived["candidateLengthPrefix"]["interpretation"], "candidate")
        self.assertEqual(derived["candidateLengthPrefix"]["widthUniqueness"], "unknown")
        self.assertEqual(derived["runsWithMultipleCandidateFrames"], [5, 6])

    def test_artifact_is_deterministic_canonical_json(self):
        self.assertEqual(
            derive_conformance(self.fixture_bytes), derive_conformance(self.fixture_bytes)
        )
        self.assertEqual(self.artifact_text, json.dumps(self.artifact, indent=2) + "\n")
        self.assertTrue(self.artifact_text.isascii())

    def test_artifact_rejects_fixture_drift(self):
        def mutated(mutate):
            fixture = json.loads(self.fixture_bytes.decode("utf-8"))
            runs = [bytearray(data) for data in decoded_runs(fixture)]
            mutate(fixture, runs)
            for observation, data in zip(fixture["observations"], runs):
                observation[PAYLOAD_KEY] = base64.b64encode(bytes(data)).decode("ascii")
            return json.dumps(fixture, indent=2).encode("utf-8") + b"\n"

        def change_version_byte(fixture, runs):
            runs[1][14] = 7

        def break_a_length_prefix(fixture, runs):
            runs[2][3] += 1

        def swap_two_runs(fixture, runs):
            runs[0], runs[1] = runs[1], runs[0]

        def remove_the_marker(fixture, runs):
            runs[0][4] ^= 0x20

        def relabel_a_direction(fixture, runs):
            fixture["observations"][0]["direction"] = "client-to-server"

        for mutate in (
            change_version_byte,
            break_a_length_prefix,
            swap_two_runs,
            remove_the_marker,
            relabel_a_direction,
        ):
            with self.subTest(mutation=mutate.__name__):
                self.assertNotEqual(artifact_violations(self.artifact, mutated(mutate)), [])

    def test_artifact_rejects_content_drift(self):
        leaked = sorted(payload_texts(self.fixture_bytes))[0]

        def mutated(mutate):
            artifact = copy.deepcopy(self.artifact)
            mutate(artifact)
            return artifact_violations(artifact, self.fixture_bytes)

        mutations = {
            "length value": lambda a: a["derived"]["runs"][4]["frames"][2].update(lengthValue=9),
            "dropped frame": lambda a: a["derived"]["runs"][5]["frames"].pop(),
            "source digest": lambda a: a["derived"]["byteSource"].update(fixtureSha256="0" * 64),
            "policy bytes": lambda a: a["proposedVersionPolicy"].update(supportedVersionBytesHex="00010007"),
            "policy frozen": lambda a: a["proposedVersionPolicy"].update(status="frozen"),
            "width proven": lambda a: a["derived"]["candidateLengthPrefix"].update(widthUniqueness="unique"),
            "candidate dropped": lambda a: a["derived"]["candidateLengthPrefix"].update(interpretation="observed"),
            "width non-claim": lambda a: a.update(
                nonClaims=[item for item in a["nonClaims"] if "length-prefix width" not in item]
            ),
            "width claim": lambda a: a["limits"].append(
                "Every run partitions exactly into frames with a 4-byte length prefix."
            ),
            "deriver": lambda a: a["derivation"].update(deriver="Tools/derive.py"),
            "windows non-claim": lambda a: a.update(
                nonClaims=[item for item in a["nonClaims"] if "Windows" not in item]
            ),
            "windows claim": lambda a: a["limits"].append("Windows Barrier Server interoperability passed."),
            "negotiation claim": lambda a: a["limits"].append("Version negotiation between Barrier versions works."),
            "tls default": lambda a: a["limits"].append("Production TLS is disabled by default."),
            "payload text": lambda a: a["limits"].append("Frame text " + leaked + "."),
            "gpl material": lambda a: a["limits"].append("Copied from a GNU General Public License header."),
            "address": lambda a: a["limits"].append("Peer at 192.168.1.20."),
            "extra key": lambda a: a.update(notes="unreviewed"),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated(mutate), [])

    def test_source_entry_is_unchanged_byte_for_byte(self):
        self.assertEqual(pinned_source_violations(self.register_text, self.register), [])
        source = self.register["entries"][0]
        self.assertEqual(source["evidenceId"], SOURCE_EVIDENCE_ID)
        self.assertEqual(source["provenance"]["disposition"], "approved")

    def test_source_entry_pin_is_canonical_serialization(self):
        pinned = json.loads(PINNED_BARRIER_EVID_0001)
        self.assertEqual(json.dumps(pinned, indent=2, ensure_ascii=False), PINNED_BARRIER_EVID_0001)
        self.assertEqual(pinned["fixture"]["sha256"], FIXTURE_SHA256)

    def test_source_entry_check_rejects_rewrite_or_upgrade(self):
        def check(text_change, entry_change):
            text = text_change(self.register_text)
            register = json.loads(text)
            entry_change(register["entries"][0])
            return pinned_source_violations(text, register)

        same_text = lambda text: text
        cases = {
            "rewritten digest text": (
                lambda text: text.replace('"byteLength": 1079', '"byteLength": 1080', 1),
                lambda entry: None,
            ),
            "marked superseded": (
                same_text,
                lambda entry: entry["provenance"].update(disposition="superseded"),
            ),
            "upgraded unknown field": (
                same_text,
                lambda entry: entry["ambiguousFields"].pop(2),
            ),
            "consumer added": (
                same_text,
                lambda entry: entry["consumingTests"].append(TEST_PATH),
            ),
        }
        for name, (text_change, entry_change) in cases.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(check(text_change, entry_change), [])
        reordered = copy.deepcopy(self.register)
        reordered["entries"].reverse()
        self.assertNotEqual(pinned_source_violations(self.register_text, reordered), [])

    def test_derived_entry_is_appended_and_linked(self):
        self.assertEqual(
            derived_entry_violations(self.register, self.artifact, self.fixture_bytes, self.validator),
            [],
        )

    def test_derived_entry_check_rejects_drift(self):
        def mutated(mutate):
            register = copy.deepcopy(self.register)
            mutate(register)
            return derived_entry_violations(register, self.artifact, self.fixture_bytes, self.validator)

        def claim(register, claim_id):
            return next(
                item for item in register["entries"][1]["coverage"]["wireClaims"] if item["claimId"] == claim_id
            )

        mutations = {
            "removed": lambda r: r["entries"].pop(1),
            "prepended": lambda r: r["entries"].reverse(),
            "fixture digest": lambda r: r["entries"][1]["fixture"].update(sha256="0" * 64),
            "related issue": lambda r: r["entries"][1].update(relatedIssue="M1-025"),
            "unknown promoted": lambda r: claim(r, CLAIM_VERSION)["establishedFieldIds"].append(
                "barrier-version-negotiation-and-mismatch-behavior"
            ),
            "unknown dropped": lambda r: r["entries"][1]["ambiguousFields"].pop(0),
            "width promoted": lambda r: claim(r, CLAIM_PARTITION)["establishedFieldIds"].append(
                "barrier-length-prefix-width-uniqueness"
            ),
            "width restated as observed": lambda r: claim(r, CLAIM_PARTITION).update(
                establishedFieldIds=[
                    "observed-frame-length-prefix-u32-big-endian",
                    "observed-frame-partition",
                ]
            ),
            "width asserted": lambda r: claim(r, CLAIM_PARTITION).update(
                assertion=claim(r, CLAIM_PARTITION)["assertion"].replace(
                    "does not establish the prefix width", "establishes the prefix width"
                )
            ),
            "repointed claim": lambda r: claim(r, CLAIM_MARKER)["evidenceLocations"].__setitem__(
                0, payload_location(3)
            ),
            "restated total": lambda r: claim(r, CLAIM_PARTITION).update(
                assertion=claim(r, CLAIM_PARTITION)["assertion"].replace("133", "134")
            ),
            "restated version": lambda r: claim(r, CLAIM_VERSION).update(
                assertion=claim(r, CLAIM_VERSION)["assertion"].replace("00 01 00 06", "00 01 00 07")
            ),
            "consumer added": lambda r: r["entries"][1]["consumingTests"].append(TEST_PATH),
            "tls enabled": lambda r: r["entries"][1]["transport"]["tls"].update(enabled=True, protocolVersion="1.3"),
            "windows claim": lambda r: r["entries"][1]["limitations"].append(
                "Windows Barrier Server interoperability passed."
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated(mutate), [])

    def test_review_gate_keeps_unreviewed_evidence_unconsumable(self):
        entry = self.derived_entry()
        self.assertEqual(
            review_gate_violations(entry, self.review_exists, self.m1_025_adr_exists), []
        )
        if not self.review_exists:
            self.assertNotEqual(entry["provenance"]["disposition"], "approved")
        approved = copy.deepcopy(entry)
        approved["provenance"]["disposition"] = "approved"
        self.assertNotEqual(review_gate_violations(approved, False, False), [])
        self_approved = copy.deepcopy(approved)
        self_approved["provenance"]["reviewer"].update(
            identity=self_approved["provenance"]["producer"], independentFromProducer=True
        )
        self.assertNotEqual(review_gate_violations(self_approved, True, False), [])
        pending = copy.deepcopy(entry)
        pending["provenance"]["disposition"] = "pending-review"
        self.assertNotEqual(review_gate_violations(pending, False, True), [])

    def test_sequence_data_and_prose(self):
        self.assertEqual(
            sequence_violations(self.manifest, self.issue_texts, self.execution_order, self.index_rows),
            [],
        )
        self.assertEqual(sum(1 for issue in self.manifest["issues"] if issue["milestone"] == "M1"), 70)

    def test_sequence_check_rejects_drift(self):
        def mutated(mutate_manifest=None, mutate_texts=None, order_text=None):
            manifest = copy.deepcopy(self.manifest)
            texts = dict(self.issue_texts)
            entries = {issue["id"]: issue for issue in manifest["issues"]}
            if mutate_manifest:
                mutate_manifest(entries)
            if mutate_texts:
                mutate_texts(texts)
            return sequence_violations(
                manifest, texts, order_text or self.execution_order, self.index_rows
            )

        cases = {
            "codec back before contract": dict(
                mutate_manifest=lambda e: e["M1-025"]["depends_on"].extend(["M1-021", "M1-022"])
            ),
            "contract dropped from codec": dict(
                mutate_manifest=lambda e: e["M1-021"]["depends_on"].remove("M1-025")
            ),
            "corrective issue in depends_on": dict(
                mutate_manifest=lambda e: e["M1-025"]["depends_on"].append(WIRE_ISSUE)
            ),
            "order swapped": dict(
                mutate_manifest=lambda e: (
                    e["M1-025"].update(topological_order=36),
                    e["M1-021"].update(topological_order=22),
                )
            ),
            "precondition drift": dict(
                mutate_texts=lambda t: t.update(
                    {"M1-022": t["M1-022"].replace(M1_025_ADR_PATH, "docs/adr/other.md")}
                )
            ),
            "prerequisite prose removed": dict(
                mutate_texts=lambda t: t.update({"M1-025": t["M1-025"].replace(WIRE_ISSUE, "M1-XXX-001")})
            ),
            "width gate removed": dict(
                mutate_texts=lambda t: t.update(
                    {"M1-025": t["M1-025"].replace("separately approved discriminating evidence", "this evidence")}
                )
            ),
            "current evidence treated as exact-width proof": dict(
                mutate_texts=lambda t: t.update(
                    {"M1-025": t["M1-025"].replace("不足以證明 exact", "足以證明 exact")}
                )
            ),
            "follow-up issue link removed": dict(
                mutate_texts=lambda t: t.update(
                    {"M1-025": t["M1-025"].replace(FOLLOW_UP_GITHUB_ISSUE, "#000")}
                )
            ),
            "follow-up issue id removed": dict(
                mutate_texts=lambda t: t.update(
                    {"M1-025": t["M1-025"].replace(FOLLOW_UP_ISSUE, "M1-XXX-002")}
                )
            ),
            "follow-up issue treated as complete": dict(
                mutate_texts=lambda t: t.update(
                    {"M1-025": t["M1-025"].replace("在 #279 完成並取得 `approved` entry 前，", "#279 已完成，")}
                )
            ),
            "follow-up issue in depends_on": dict(
                mutate_manifest=lambda e: e["M1-025"]["depends_on"].append(FOLLOW_UP_ISSUE)
            ),
            "execution order stale": dict(
                order_text=self.execution_order.replace(SEQUENCE_MARKER, "M1-021 → M1-022 → M1-025")
            ),
        }
        for name, arguments in cases.items():
            with self.subTest(mutation=name):
                self.assertNotEqual(mutated(**arguments), [])

    def test_no_swift_or_parser_files_before_m1_025(self):
        boundary = (REPOSITORY_ROOT / BARRIER_BOUNDARY_SWIFT).read_text(encoding="utf-8")
        self.assertEqual(
            ordering_gate_violations(barrier_swift_files(), boundary, self.m1_025_adr_exists), []
        )
        self.assertEqual(
            sorted(path.name for path in EVIDENCE_ROOT.rglob("*.swift")),
            [],
        )
        codec = BARRIER_BOUNDARY_SWIFT.replace("BarrierCompatibility.swift", "BarrierBinaryCodec.swift")
        self.assertNotEqual(
            ordering_gate_violations([BARRIER_BOUNDARY_SWIFT, codec], boundary, False), []
        )
        self.assertNotEqual(
            ordering_gate_violations([BARRIER_BOUNDARY_SWIFT], boundary + "struct Parser {}\n", False), []
        )

    def test_production_tls_default_is_unchanged(self):
        frozen = FROZEN_DECISIONS.read_text(encoding="utf-8")
        contract = PRODUCT_CONTRACT.read_text(encoding="utf-8")
        canonical = CANONICAL_SPEC.read_bytes()
        self.assertEqual(tls_default_violations(canonical, frozen, contract), [])
        self.assertNotEqual(
            tls_default_violations(canonical, frozen.replace(FROZEN_TLS_DECISION, "TLS/security 可選"), contract),
            [],
        )
        self.assertNotEqual(
            tls_default_violations(canonical + b"\n", frozen, contract), []
        )

    def test_documents_make_no_windows_tls_or_leak_claims(self):
        traceability = self.traceability.split("\n## " + SEQUENCE_MARKER, 1)
        self.assertEqual(len(traceability), 2, "traceability section is missing")
        documents = {
            ADR_PATH: self.adr,
            SUMMARY_PATH: self.summary,
            "docs/evidence/M1-023-barrier-evidence-register.md": self.register_documentation,
            "SOURCE_TRACEABILITY.md sequence section": traceability[1].split("\n## ", 1)[0],
        }
        for issue_id, text in self.issue_texts.items():
            documents[issue_id] = text
        for name, text in documents.items():
            with self.subTest(document=name):
                self.assertEqual(text_violations(name, text, self.fixture_bytes), [])

    def test_text_check_rejects_claims_and_leaks(self):
        leaked = sorted(payload_texts(self.fixture_bytes))
        for text in (
            "Windows Barrier Server compatibility passed.",
            "Production TLS is disabled by default.",
            "The frame text is " + leaked[0] + ".",
            "Copyright (C) example contributors.",
            "Reviewer at /Users/someone/review.md.",
            "Each run partitions exactly into frames with a 4-byte unsigned big-endian length prefix.",
            "M1-025 decides the prefix width from this evidence.",
        ):
            with self.subTest(text=text):
                self.assertNotEqual(text_violations("sample", text, self.fixture_bytes), [])
        self.assertNotEqual(
            text_violations("sample", "Version negotiation is supported.", self.fixture_bytes, True), []
        )
        self.assertEqual(
            text_violations("sample", "Windows was not executed in M1.", self.fixture_bytes, True), []
        )
        self.assertEqual(
            text_violations(
                "sample", "A candidate 4-byte length prefix partitions every run.", self.fixture_bytes, True
            ),
            [],
        )

    def test_adr_records_the_decision(self):
        self.assertEqual(adr_violations(self.adr), [])
        self.assertNotEqual(adr_violations(self.adr.replace(SEQUENCE_MARKER, "M1-021 first")), [])
        self.assertNotEqual(adr_violations(self.adr + "\nTBD\n"), [])
        self.assertNotEqual(adr_violations(self.adr.replace(FOLLOW_UP_GITHUB_ISSUE, "#000")), [])
        self.assertNotEqual(adr_violations(self.adr.replace("#279 is not complete", "#279 is complete")), [])

    def test_follow_up_width_blocker_stays_outside_the_manifest(self):
        self.assertNotIn(FOLLOW_UP_ISSUE, {issue["id"] for issue in self.manifest["issues"]})
        manifest = copy.deepcopy(self.manifest)
        follow_up = copy.deepcopy(manifest["issues"][-1])
        follow_up.update(id=FOLLOW_UP_ISSUE, depends_on=[], topological_order=len(manifest["issues"]) + 1)
        manifest["issues"].append(follow_up)
        self.assertNotEqual(
            sequence_violations(manifest, self.issue_texts, self.execution_order, self.index_rows), []
        )
        remaining_gates = section(self.summary, "Remaining gates")
        for marker in ("GitHub Issue #279", "(M1-WIRE-002", "#279 is not complete"):
            with self.subTest(marker=marker):
                self.assertIn(marker, remaining_gates)

    def test_traceability_records_the_sequence(self):
        chain = section(self.traceability, SEQUENCE_MARKER + " Barrier Wire Contract Sequence")
        self.assertIn("不是產品合約", chain)
        for marker in (
            "#278",
            DERIVED_EVIDENCE_ID,
            SOURCE_EVIDENCE_ID,
            ARTIFACT_PATH,
            ADR_PATH,
            TEST_PATH,
            REVIEW_PATH,
            "pending-review",
            "depends_on",
            "GitHub Issue #279（M1-WIRE-002",
            "#279 尚未完成",
        ):
            with self.subTest(marker=marker):
                self.assertIn(marker, chain)
        for path in (ARTIFACT_PATH, ADR_PATH, TEST_PATH, SUMMARY_PATH, FIXTURE_PATH):
            with self.subTest(path=path):
                self.assertTrue((REPOSITORY_ROOT / path).is_file())
        self.assertIsNone(re.search(r"\b(?:TODO|TBD)\b", self.traceability))


if __name__ == "__main__":
    unittest.main()
