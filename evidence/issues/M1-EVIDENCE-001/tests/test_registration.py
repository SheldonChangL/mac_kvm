"""M1-EVIDENCE-001 registration contract tests.

These tests check the append-only registration of the independently reviewed
M1-024 Linux Barrier capture into the canonical M1-023 register. They reuse the
M1-023 validator rather than reimplementing it, so a registered entry must pass
the same fail-closed contract that M1-023 froze.

They assert nothing about Barrier payload semantics, message codes, fields,
endianness, framing or compatibility, and they require the register to keep
asserting nothing about them either.
"""

import base64
import binascii
import copy
import hashlib
import importlib.util
import json
import re
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
REGISTER_PATH = REPOSITORY_ROOT / "evidence/registers/M1-023.json"
REGISTER_DOCUMENTATION_PATH = (
    REPOSITORY_ROOT / "docs/evidence/M1-023-barrier-evidence-register.md"
)
M1_023_VALIDATOR_PATH = (
    REPOSITORY_ROOT / "evidence/issues/M1-023/tests/test_register.py"
)
M1_024_REVIEW_PATH = (
    REPOSITORY_ROOT / "evidence/issues/M1-024/independent-review.md"
)
SCOPE_ADR_PATH = REPOSITORY_ROOT / "docs/adr/M1-SCOPE-001-linux-only-validation.md"
TRACEABILITY_PATH = (
    REPOSITORY_ROOT / "MacKVM_Implementation_Package_v2/SOURCE_TRACEABILITY.md"
)

REGISTERED_EVIDENCE_ID = "BARRIER-EVID-0001"
EXPECTED_FIXTURE_PATH = (
    "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/handshake-capture.json"
)

# The three stable claim ids and the exact field identifier each one is allowed
# to establish. The mapping is positional and total: a claim may establish these
# identifiers and nothing else, and no other claim may establish them.
PAYLOAD_RUN_CLAIM_ID = f"{REGISTERED_EVIDENCE_ID}-CLAIM-001"
ORDERING_CLAIM_ID = f"{REGISTERED_EVIDENCE_ID}-CLAIM-002"
DIRECTION_CLAIM_ID = f"{REGISTERED_EVIDENCE_ID}-CLAIM-003"
EXPECTED_CLAIM_IDS = (PAYLOAD_RUN_CLAIM_ID, ORDERING_CLAIM_ID, DIRECTION_CLAIM_ID)
PAYLOAD_RUN_FIELD_ID_TEMPLATE = "observed-payload-run-{sequence}"
ORDERING_FIELD_ID = "observed-run-ordering"
DIRECTION_FIELD_ID = "observed-run-direction-label"

OBSERVATIONS_POINTER = "/observations"
PAYLOAD_POINTER_TEMPLATE = "/observations/{index}/applicationPayloadBase64"
PAYLOAD_KEY = "applicationPayloadBase64"
SEQUENCE_KEY = "sequence"
DIRECTION_KEY = "direction"

# Traceability chain required by Issue #249 "Update M1-024/M1-025 traceability
# and evidence links".
TRACEABILITY_HEADING = (
    "## M1-024 → M1-EVIDENCE-001 → M1-025 Barrier Evidence Chain"
)
TRACEABILITY_REQUIRED_MARKERS = (
    "M1-024",
    "M1-EVIDENCE-001",
    "#249",
    "M1-025",
    REGISTERED_EVIDENCE_ID,
    "evidence/registers/M1-023.json",
    "docs/evidence/M1-023-barrier-evidence-register.md",
    "evidence/issues/M1-024/independent-review.md",
    "evidence/issues/M1-EVIDENCE-001/tests/test_registration.py",
    EXPECTED_FIXTURE_PATH,
    "frozenContractRefs",
    "consumingTests",
    "approved",
    "append-only",
)
REPOSITORY_PATH_PATTERN = re.compile(
    r"(?:evidence|docs|Tests|MacKVM_Implementation_Package_v2)"
    r"/[A-Za-z0-9][A-Za-z0-9._/-]*\.(?:md|json|py|sh)"
)
NUMBER_PATTERN = re.compile(r"\d+")
# An address, a port or a host name must never be recorded in the register.
ENDPOINT_IDENTIFIER_PATTERN = re.compile(
    r"\b\d{1,3}(?:\.\d{1,3}){3}\b"
    r"|\b[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,}\b"
    r"|:\d{1,5}\b"
    r"|\b[A-Za-z0-9-]+\.(?:local|lan|internal|localdomain|com|net|org)\b"
)

# Every prohibited inference named by Issue #249 and by M1-SCOPE-001. Each one
# must be explicitly forbidden by every approved entry.
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

NEGATION_PATTERN = re.compile(
    r"\b(not|no|never|without|excluded|absent|unvalidated|non-execution|"
    r"nonexecution|cannot|must not|neither)\b",
    re.IGNORECASE,
)
SENTENCE_SPLIT_PATTERN = re.compile(r"(?<=[.;:])\s+")
# Identifiers inside code spans and fenced blocks are names, not assertions.
# They are removed before the non-claim scan so that a test or file name can
# mention a platform without being read as a claim about it.
CODE_SPAN_PATTERN = re.compile(r"`{1,3}[^`]*`{1,3}", re.DOTALL)
RETENTION_CLAIM_PATTERN = re.compile(
    r"raw capture[^.;:]*\bremain(?:s)? retained\b", re.IGNORECASE
)


def load_m1_023_validator():
    specification = importlib.util.spec_from_file_location(
        "m1_023_register_validator", M1_023_VALIDATOR_PATH
    )
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def sentences(text, strip_code_spans=False):
    if strip_code_spans:
        text = CODE_SPAN_PATTERN.sub(" ", text)
    normalized = " ".join(text.split())
    return [part for part in SENTENCE_SPLIT_PATTERN.split(normalized) if part]


def resolve_json_pointer(document, pointer):
    """Resolve an RFC 6901 JSON pointer, raising KeyError when it does not."""
    if pointer == "":
        return document
    if not pointer.startswith("/"):
        raise KeyError(pointer)
    current = document
    for raw_token in pointer.split("/")[1:]:
        token = raw_token.replace("~1", "/").replace("~0", "~")
        if isinstance(current, list):
            if not re.fullmatch(r"0|[1-9][0-9]*", token):
                raise KeyError(pointer)
            index = int(token)
            if index >= len(current):
                raise KeyError(pointer)
            current = current[index]
        elif isinstance(current, dict):
            if token not in current:
                raise KeyError(pointer)
            current = current[token]
        else:
            raise KeyError(pointer)
    return current


def numeric_tokens(text):
    return [int(token) for token in NUMBER_PATTERN.findall(text)]


def contains_contiguous_run(tokens, run):
    if not run:
        return False
    return any(
        tokens[start : start + len(run)] == run
        for start in range(0, len(tokens) - len(run) + 1)
    )


def decoded_payload_lengths(observations):
    """Exact decoded byte length per retained run, or None where it is absent."""
    lengths = []
    for observation in observations:
        payload = observation.get(PAYLOAD_KEY) if isinstance(observation, dict) else None
        if not isinstance(payload, str):
            lengths.append(None)
            continue
        try:
            lengths.append(len(base64.b64decode(payload, validate=True)))
        except (binascii.Error, ValueError):
            lengths.append(None)
    return lengths


def claim_mapping_failures(register, entry, fixture):
    """Every way the registered claims can fail to match the retained bytes.

    This checks identifier-to-pointer mapping and exact decoded lengths only. It
    reads no prose meaning and asserts no Barrier protocol semantics: a run is
    an opaque byte run and a direction label is a recorded capture label.
    """
    failures = []
    fixture_path = entry["fixture"]["path"]
    contract_directions = set(register["entryContract"]["directions"])

    observations = fixture.get("observations")
    if not isinstance(observations, list) or not observations:
        return ["fixture holds no non-empty observations list"]

    sequences = [
        observation.get(SEQUENCE_KEY) if isinstance(observation, dict) else None
        for observation in observations
    ]
    if sequences != list(range(1, len(observations) + 1)):
        failures.append(f"retained sequence is not contiguous 1-based: {sequences}")

    lengths = decoded_payload_lengths(observations)
    for index, length in enumerate(lengths):
        if length is None:
            failures.append(f"observation {index} carries no decodable {PAYLOAD_KEY}")
    if any(length is None for length in lengths):
        return failures

    labels = [
        observation.get(DIRECTION_KEY) if isinstance(observation, dict) else None
        for observation in observations
    ]
    single_directions = contract_directions - {"bidirectional"}
    for index, label in enumerate(labels):
        if label not in single_directions:
            failures.append(f"observation {index} carries an unusable direction label: {label!r}")
    observed_labels = set(labels)
    expected_coverage = (
        "bidirectional" if len(observed_labels & single_directions) > 1 else next(iter(labels), None)
    )
    if entry["coverage"]["direction"] != expected_coverage:
        failures.append(
            "coverage.direction "
            f"{entry['coverage']['direction']!r} does not match the observed labels "
            f"{sorted(observed_labels, key=str)}"
        )

    claims = {}
    for claim in entry["coverage"]["wireClaims"]:
        if claim["claimId"] in claims:
            failures.append(f"duplicate claim id: {claim['claimId']}")
        claims[claim["claimId"]] = claim
    if tuple(sorted(claims)) != tuple(sorted(EXPECTED_CLAIM_IDS)):
        failures.append(
            f"claim ids {sorted(claims)} are not exactly {sorted(EXPECTED_CLAIM_IDS)}"
        )
        return failures

    expected_mapping = {
        PAYLOAD_RUN_CLAIM_ID: (
            [
                PAYLOAD_RUN_FIELD_ID_TEMPLATE.format(sequence=sequence)
                for sequence in range(1, len(observations) + 1)
            ],
            [
                fixture_path + "#" + PAYLOAD_POINTER_TEMPLATE.format(index=index)
                for index in range(len(observations))
            ],
        ),
        ORDERING_CLAIM_ID: (
            [ORDERING_FIELD_ID],
            [fixture_path + "#" + OBSERVATIONS_POINTER],
        ),
        DIRECTION_CLAIM_ID: (
            [DIRECTION_FIELD_ID],
            [fixture_path + "#" + OBSERVATIONS_POINTER],
        ),
    }
    for claim_id, (expected_fields, expected_locations) in expected_mapping.items():
        claim = claims[claim_id]
        if claim["establishedFieldIds"] != expected_fields:
            failures.append(
                f"{claim_id} establishes {claim['establishedFieldIds']} "
                f"rather than exactly {expected_fields}"
            )
        if claim["evidenceLocations"] != expected_locations:
            failures.append(
                f"{claim_id} points at {claim['evidenceLocations']} "
                f"rather than exactly {expected_locations}"
            )

    # Every established identifier belongs to exactly one claim.
    established = [
        field_id
        for claim in entry["coverage"]["wireClaims"]
        for field_id in claim["establishedFieldIds"]
    ]
    if len(established) != len(set(established)):
        failures.append(f"an established field identifier is shared between claims: {established}")

    # Every pointer resolves, and the per-run pointers resolve to the exact
    # payload string whose decoded length the claim states.
    for claim in entry["coverage"]["wireClaims"]:
        for location in claim["evidenceLocations"]:
            prefix, separator, pointer = location.partition("#")
            if prefix != fixture_path or separator != "#":
                failures.append(f"{claim['claimId']} evidence leaves the registered fixture: {location}")
                continue
            try:
                resolved = resolve_json_pointer(fixture, pointer)
            except KeyError:
                failures.append(f"{claim['claimId']} pointer does not resolve: {location}")
                continue
            if pointer == OBSERVATIONS_POINTER and resolved is not observations:
                failures.append(f"{claim['claimId']} pointer does not resolve to the retained runs: {location}")
            if pointer.endswith(PAYLOAD_KEY):
                index = int(pointer.split("/")[2])
                if resolved != observations[index][PAYLOAD_KEY]:
                    failures.append(f"{claim['claimId']} pointer resolves to the wrong run: {location}")

    # The stated lengths are the decoded lengths, in observed order, followed by
    # their aggregate; the run count is stated by all three claims.
    payload_numbers = numeric_tokens(claims[PAYLOAD_RUN_CLAIM_ID]["assertion"])
    if not contains_contiguous_run(payload_numbers, lengths + [sum(lengths)]):
        failures.append(
            f"{PAYLOAD_RUN_CLAIM_ID} does not state the decoded lengths "
            f"{lengths} followed by their aggregate {sum(lengths)}"
        )
    for claim_id in EXPECTED_CLAIM_IDS:
        if len(observations) not in numeric_tokens(claims[claim_id]["assertion"]):
            failures.append(f"{claim_id} does not state the retained run count {len(observations)}")

    return failures


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


class BarrierCaptureRegistrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.validator = load_m1_023_validator()
        cls.register = json.loads(REGISTER_PATH.read_text(encoding="utf-8"))
        cls.documentation = REGISTER_DOCUMENTATION_PATH.read_text(encoding="utf-8")
        cls.approved_entries = [
            entry
            for entry in cls.register["entries"]
            if entry["provenance"]["disposition"]
            == cls.register["entryContract"]["consumableDisposition"]
        ]

    def registered_entry(self):
        matches = [
            entry
            for entry in self.register["entries"]
            if entry["evidenceId"] == REGISTERED_EVIDENCE_ID
        ]
        self.assertEqual(
            len(matches),
            1,
            f"exactly one {REGISTERED_EVIDENCE_ID} entry must exist",
        )
        return matches[0]

    def test_register_is_active_and_passes_the_m1_023_validator(self):
        self.validator.validate_register(self.register)
        self.assertEqual(self.register["status"], "active")
        self.assertTrue(self.register["entries"])
        self.assertTrue(self.approved_entries)

    def test_registered_entry_records_the_reviewed_linux_capture(self):
        entry = self.registered_entry()
        self.validator.validate_entry(self.register, entry)
        self.assertEqual(entry["relatedIssue"], "M1-024")
        self.assertEqual(entry["source"]["category"], "black-box-capture")
        self.assertEqual(entry["provenance"]["disposition"], "approved")
        self.assertEqual(entry["peer"]["role"], "server")
        self.assertEqual(entry["peer"]["os"]["name"], "Ubuntu")
        self.assertEqual(entry["fixture"]["path"], EXPECTED_FIXTURE_PATH)
        self.assertFalse(entry["transport"]["tls"]["enabled"])
        self.assertIsNone(entry["transport"]["tls"]["protocolVersion"])

    def test_approved_entries_carry_a_recorded_independent_review(self):
        for entry in self.approved_entries:
            reviewer = entry["provenance"]["reviewer"]
            self.assertTrue(reviewer["independentFromProducer"])
            self.assertNotEqual(reviewer["identity"], entry["provenance"]["producer"])
            self.assertTrue(reviewer["identity"].strip())
            review_paths = [
                token
                for token in re.findall(r"evidence/issues/[^\s,;)]+\.md", reviewer["identity"])
            ]
            self.assertTrue(
                review_paths,
                "reviewer identity must name the recorded independent review document",
            )
            for review_path in review_paths:
                resolved = REPOSITORY_ROOT / review_path
                self.assertFalse(resolved.is_symlink())
                self.assertTrue(resolved.is_file(), f"missing review: {review_path}")

    def test_registered_fixture_is_a_regular_file_with_matching_digest_and_length(self):
        entry = self.registered_entry()
        relative_path = Path(entry["fixture"]["path"])
        current = REPOSITORY_ROOT
        for component in relative_path.parts:
            current = current / component
            self.assertFalse(
                current.is_symlink(), f"fixture path component is a symlink: {current}"
            )
        fixture_path = REPOSITORY_ROOT / relative_path
        self.assertTrue(fixture_path.is_file())
        data = fixture_path.read_bytes()
        self.assertEqual(len(data), entry["fixture"]["byteLength"])
        self.assertEqual(hashlib.sha256(data).hexdigest(), entry["fixture"]["sha256"])

    def registered_fixture(self):
        entry = self.registered_entry()
        return json.loads(
            (REPOSITORY_ROOT / entry["fixture"]["path"]).read_text(encoding="utf-8")
        )

    def test_registered_claims_match_the_retained_fixture_bytes(self):
        entry = self.registered_entry()
        fixture = self.registered_fixture()
        self.assertEqual(
            claim_mapping_failures(self.register, entry, fixture),
            [],
        )

        # The exact mapping the registration is allowed to carry, restated here
        # so the expectation is readable rather than only computed.
        observations = fixture["observations"]
        self.assertEqual(len(observations), 7)
        self.assertEqual(
            decoded_payload_lengths(observations), [15, 28, 8, 22, 36, 16, 8]
        )
        claims = {claim["claimId"]: claim for claim in entry["coverage"]["wireClaims"]}
        self.assertEqual(tuple(claims), EXPECTED_CLAIM_IDS)
        self.assertEqual(
            claims[PAYLOAD_RUN_CLAIM_ID]["establishedFieldIds"],
            [f"observed-payload-run-{sequence}" for sequence in range(1, 8)],
        )
        self.assertEqual(
            claims[PAYLOAD_RUN_CLAIM_ID]["evidenceLocations"],
            [
                f"{EXPECTED_FIXTURE_PATH}#/observations/{index}/{PAYLOAD_KEY}"
                for index in range(7)
            ],
        )
        self.assertEqual(
            claims[ORDERING_CLAIM_ID]["establishedFieldIds"], [ORDERING_FIELD_ID]
        )
        self.assertEqual(
            claims[ORDERING_CLAIM_ID]["evidenceLocations"],
            [f"{EXPECTED_FIXTURE_PATH}#/observations"],
        )
        self.assertEqual(
            claims[DIRECTION_CLAIM_ID]["establishedFieldIds"], [DIRECTION_FIELD_ID]
        )
        self.assertEqual(
            claims[DIRECTION_CLAIM_ID]["evidenceLocations"],
            [f"{EXPECTED_FIXTURE_PATH}#/observations"],
        )
        self.assertEqual(entry["coverage"]["direction"], "bidirectional")
        self.assertEqual(
            {observation[DIRECTION_KEY] for observation in observations},
            {"server-to-client", "client-to-server"},
        )

    def test_claim_mapping_rejects_a_fixture_or_claim_that_drifts(self):
        entry = self.registered_entry()
        fixture = self.registered_fixture()

        def mutated_fixture(mutate):
            candidate = copy.deepcopy(fixture)
            mutate(candidate)
            return candidate

        def mutated_entry(mutate):
            candidate = copy.deepcopy(entry)
            mutate(candidate)
            return candidate

        def claim(candidate, claim_id):
            return next(
                item
                for item in candidate["coverage"]["wireClaims"]
                if item["claimId"] == claim_id
            )

        def drop_last_run(candidate):
            candidate["observations"].pop()

        def resize_a_run(candidate):
            candidate["observations"][2][PAYLOAD_KEY] = base64.b64encode(
                b"\x00" * 9
            ).decode("ascii")

        def reorder_runs(candidate):
            runs = candidate["observations"]
            runs[0][PAYLOAD_KEY], runs[1][PAYLOAD_KEY] = (
                runs[1][PAYLOAD_KEY],
                runs[0][PAYLOAD_KEY],
            )

        def renumber_runs(candidate):
            candidate["observations"][0][SEQUENCE_KEY] = 2

        def collapse_directions(candidate):
            for observation in candidate["observations"]:
                observation[DIRECTION_KEY] = "server-to-client"

        def corrupt_a_payload(candidate):
            candidate["observations"][4][PAYLOAD_KEY] = "not base64!"

        def repoint_a_claim(candidate):
            claim(candidate, PAYLOAD_RUN_CLAIM_ID)["evidenceLocations"][3] = (
                f"{EXPECTED_FIXTURE_PATH}#/observations/0/{PAYLOAD_KEY}"
            )

        def point_outside_the_fixture(candidate):
            claim(candidate, ORDERING_CLAIM_ID)["evidenceLocations"] = [
                "Tests/Fixtures/Barrier/m1-024-linux-client-handshake/metadata.json#/observations"
            ]

        def widen_established_fields(candidate):
            claim(candidate, DIRECTION_CLAIM_ID)["establishedFieldIds"] = [
                DIRECTION_FIELD_ID,
                "barrier-message-code",
            ]

        def reorder_established_fields(candidate):
            fields = claim(candidate, PAYLOAD_RUN_CLAIM_ID)["establishedFieldIds"]
            fields[0], fields[1] = fields[1], fields[0]

        def rename_a_claim(candidate):
            claim(candidate, ORDERING_CLAIM_ID)["claimId"] = (
                f"{REGISTERED_EVIDENCE_ID}-CLAIM-009"
            )

        def restate_the_aggregate(candidate):
            target = claim(candidate, PAYLOAD_RUN_CLAIM_ID)
            target["assertion"] = target["assertion"].replace("133", "134")

        fixture_mutations = (
            drop_last_run,
            resize_a_run,
            reorder_runs,
            renumber_runs,
            collapse_directions,
            corrupt_a_payload,
        )
        for mutate in fixture_mutations:
            with self.subTest(mutation=mutate.__name__):
                self.assertNotEqual(
                    claim_mapping_failures(
                        self.register, entry, mutated_fixture(mutate)
                    ),
                    [],
                    f"a {mutate.__name__} fixture must not satisfy the registered claims",
                )

        entry_mutations = (
            repoint_a_claim,
            point_outside_the_fixture,
            widen_established_fields,
            reorder_established_fields,
            rename_a_claim,
            restate_the_aggregate,
        )
        for mutate in entry_mutations:
            with self.subTest(mutation=mutate.__name__):
                self.assertNotEqual(
                    claim_mapping_failures(
                        self.register, mutated_entry(mutate), fixture
                    ),
                    [],
                    f"a {mutate.__name__} entry must not pass the claim mapping",
                )

    def test_transport_scope_records_only_the_observed_peer_loopback_leg(self):
        entry = self.registered_entry()
        scope = entry["transport"]["networkScope"]
        lowered = scope.lower()
        self.assertIn("peer loopback", lowered)
        # The recorder observed one leg. A blanket denial of any wider network
        # path is wider than the observation and must not be recorded.
        self.assertNotIn("no wider network path", lowered)
        self.assertTrue(
            any(
                "encrypt" in sentence.lower() and NEGATION_PATTERN.search(sentence)
                for sentence in sentences(scope)
            ),
            "the wider encrypted leg must be recorded as uncaptured, not denied",
        )
        self.assertIsNone(
            ENDPOINT_IDENTIFIER_PATTERN.search(scope),
            f"transport scope records an endpoint identifier: {scope}",
        )

    def test_producer_identity_names_durable_repository_evidence(self):
        entry = self.registered_entry()
        producer = entry["provenance"]["producer"]
        self.assertNotIn("root session", producer.lower())
        producer_paths = re.findall(
            r"evidence/issues/[^\s,;)]+\.(?:md|json)", producer
        )
        self.assertTrue(
            producer_paths,
            "producer identity must name repository evidence rather than an internal session label",
        )
        for producer_path in producer_paths:
            resolved = REPOSITORY_ROOT / producer_path
            self.assertFalse(resolved.is_symlink())
            self.assertTrue(resolved.is_file(), f"missing producer evidence: {producer_path}")
        self.assertNotEqual(producer, entry["provenance"]["reviewer"]["identity"])

    def test_traceability_index_records_the_m1_024_to_m1_025_chain(self):
        text = TRACEABILITY_PATH.read_text(encoding="utf-8")
        self.assertIn(TRACEABILITY_HEADING, text)
        section = text.split(TRACEABILITY_HEADING, 1)[1].split("\n## ", 1)[0]
        for marker in TRACEABILITY_REQUIRED_MARKERS:
            with self.subTest(marker=marker):
                self.assertIn(marker, section)
        named_paths = sorted(set(REPOSITORY_PATH_PATTERN.findall(section)))
        self.assertIn(EXPECTED_FIXTURE_PATH, named_paths)
        for named_path in named_paths:
            with self.subTest(path=named_path):
                resolved = REPOSITORY_ROOT / named_path
                self.assertFalse(resolved.is_symlink())
                self.assertTrue(
                    resolved.is_file(), f"traceability names a missing path: {named_path}"
                )

    def test_direction_convention_is_recorded_as_capture_provenance(self):
        entry = self.registered_entry()
        acquisition = entry["source"]["acquisitionMethod"].lower()
        self.assertIn("server", acquisition)
        self.assertIn("port", acquisition)
        self.assertIn("producer", acquisition)
        self.assertTrue(
            any(
                "direction" in sentence.lower() and "payload" in sentence.lower()
                and NEGATION_PATTERN.search(sentence)
                for sentence in sentences(entry["source"]["acquisitionMethod"])
            ),
            "acquisition method must state that direction is not derived from payload content",
        )

    def test_unknown_fields_remain_unknown_and_support_no_claim(self):
        for entry in self.register["entries"]:
            established = set()
            for claim in entry["coverage"]["wireClaims"]:
                established.update(claim["establishedFieldIds"])
            unknown = set()
            for field in entry["ambiguousFields"]:
                self.assertEqual(field["status"], "unknown")
                unknown.add(field["fieldId"])
            self.assertTrue(unknown, "an approved entry must record its unknowns")
            self.assertFalse(unknown & established)

    def test_prohibited_inferences_are_explicit(self):
        for entry in self.approved_entries:
            prohibited = " ".join(entry["prohibitedInferences"]).lower()
            self.assertTrue(entry["prohibitedInferences"])
            for topic in REQUIRED_PROHIBITED_INFERENCE_TOPICS:
                self.assertIn(
                    topic,
                    prohibited,
                    f"prohibited inferences must name {topic!r}",
                )

    def test_consumers_remain_bounded_and_resolvable(self):
        for entry in self.register["entries"]:
            for reference in entry["frozenContractRefs"] + entry["consumingTests"]:
                resolved = REPOSITORY_ROOT / reference
                self.assertFalse(resolved.is_symlink())
                self.assertTrue(
                    resolved.exists(),
                    f"consumer reference does not exist: {reference}",
                )

    def test_no_windows_result_is_claimed_anywhere_in_the_registration(self):
        documents = {
            "evidence/registers/M1-023.json": REGISTER_PATH.read_text(encoding="utf-8"),
            "docs/evidence/M1-023-barrier-evidence-register.md": self.documentation,
        }
        for name in ("summary.md", "manual.md"):
            path = REPOSITORY_ROOT / "evidence/issues/M1-EVIDENCE-001" / name
            documents[f"evidence/issues/M1-EVIDENCE-001/{name}"] = path.read_text(
                encoding="utf-8"
            )
        for path_text, text in documents.items():
            for sentence in sentences(text, strip_code_spans=True):
                if "windows" not in sentence.lower():
                    continue
                self.assertIsNotNone(
                    NEGATION_PATTERN.search(sentence),
                    f"{path_text} asserts a Windows result: {sentence}",
                )

    def test_registration_records_the_windows_non_execution_disposition(self):
        entry = self.registered_entry()
        text = " ".join(collect_strings(entry, [])).lower()
        self.assertIn("windows was not executed", text)
        self.assertIn("m1-scope-001-linux-only-validation.md", text)
        self.assertTrue(SCOPE_ADR_PATH.is_file())

    def test_registration_does_not_claim_the_raw_capture_is_retained(self):
        entry = self.registered_entry()
        for text in collect_strings(entry, []) + [self.documentation]:
            self.assertIsNone(
                RETENTION_CLAIM_PATTERN.search(text),
                "the deleted private raw capture must not be claimed as retained",
            )
        limitations = " ".join(entry["limitations"]).lower()
        self.assertIn("raw capture", limitations)
        self.assertIn("deleted", limitations)

    def test_documentation_tracks_the_registered_state(self):
        self.assertNotIn("No approved wire evidence exists yet", self.documentation)
        self.assertIn(REGISTERED_EVIDENCE_ID, self.documentation)
        self.assertIn("M1-EVIDENCE-001", self.documentation)
        self.assertIn(EXPECTED_FIXTURE_PATH, self.documentation)
        self.assertIn("M1-025", self.documentation)

    def test_m1_024_independent_review_remains_the_recorded_review_source(self):
        self.assertTrue(M1_024_REVIEW_PATH.is_file())
        review = M1_024_REVIEW_PATH.read_text(encoding="utf-8")
        self.assertIn("independentFromProducer", json.dumps(self.registered_entry()))
        self.assertIn("57a10c6f4ee04a6ba9725787d401b980188007e40690d66aee29090c90d266d2", review)


if __name__ == "__main__":
    unittest.main()
