# Native Protocol Fixtures

Store only synthetic or approved, sanitized Native Protocol fixtures here. Encoding and frame bytes remain blocked until their owning decisions and Issues are complete.

Each future fixture belongs in `<fixture-id>/` with:

- `metadata.json`, conforming to `../fixture-metadata.schema.json`
- the relative payload named by `metadata.json`
- reproduction notes referenced by the provenance metadata

Fixtures must not contain hostnames, IP addresses, typed text, clipboard payloads, credentials, key material, or other private data. M1-007 creates the format only; it does not select or implement a Native wire encoding.
