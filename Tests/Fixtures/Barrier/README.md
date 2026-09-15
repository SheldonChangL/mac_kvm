# Barrier Fixtures

Store only independently obtained, sanitized Barrier test fixtures here. Do not copy Barrier or Deskflow implementation code, and do not infer or commit unverified wire bytes.

Each future fixture belongs in `<fixture-id>/` with:

- `metadata.json`, conforming to `../fixture-metadata.schema.json`
- the relative payload named by `metadata.json`
- reproduction notes referenced by the provenance metadata

Fixtures must not contain hostnames, IP addresses, typed text, clipboard payloads, credentials, key material, or other private data. M1-007 creates the format only; it does not add a Barrier capture.
