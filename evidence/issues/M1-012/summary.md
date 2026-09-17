# M1-012 Evidence Summary

GitHub Issue: #8

Implementation commit: `3891f43dc05cb7d05885932f4599c35375ddf5f1`

## Deliverables

- `Tools/diagnostic-bundle/diagnostic-bundle.py`
- `Tools/diagnostic-bundle/tests/test_diagnostic_bundle.py`
- `docs/tooling/M1-012-diagnostic-bundle.md`
- This evidence package.

## Acceptance criteria mapping

- Allowlisted export: implementation reconstructs `manifest.json` and
  `events.jsonl` from a closed config/event/metadata schema; it never copies
  source JSON into the archive.
- Privacy: typed text, clipboard payload/hash, keychain/key material, input
  content, arbitrary event ids/strings, paths, peer/network identifiers, and
  unknown fields have no allowed representation and fail before serialization.
- Happy path: direct API and CLI tests create a two-file ZIP whose decoded
  values equal the safe structured input.
- Boundaries: 1 MiB input and 256-record limits are enforced; exact maximum is
  accepted and one over is rejected without output.
- Invalid/error behavior: malformed JSON, boolean schema masquerading as one,
  free-form version text, unknown events/categories/fields, invalid enum data,
  and noncanonical correlation ids return typed failures.
- Cancel/cleanup/idempotency: cancellation removes the temporary file; an
  existing output is preserved; no partial archive remains after rejection.
- Architecture/public behavior: internal Python tooling only; no Swift API,
  protocol, KVMEvent, TLS, trust, input, networking, or frozen contract changes.
- Formal gates: the three Required Commands and all 11 cumulative repository
  gates pass at the implementation commit.

## Security and fail-safe properties

- Input reads are bounded before JSON parsing.
- Input must be a regular non-symlink file opened once with `O_NOFOLLOW`, so a
  path swap cannot redirect validation and reading to different sources.
- Output is assembled in a mode-0600 same-directory temporary file and linked
  atomically only after validation and ZIP closure.
- Existing output is never overwritten, including a creation race.
- CLI failure output uses closed error codes and omits input content and paths.
- Invalid CLI tokens and unexpected internal exceptions are also reduced to
  fixed nonzero errors without echoing untrusted values or stack traces.
- `KeyboardInterrupt` exits 130 and cleanup is verified without sleeps/retries.

## Known limitations and follow-ups

- This skeleton does not integrate a product sink, OSLog, UI, scheduled
  retention, automatic collection, or upload.
- The two-entry internal event catalog is deliberately minimal. A future event
  requires its emitting Issue and M1-011 catalog/privacy review.
- An explicit product-owner export action remains required before application
  UI integration; the tool must not be invoked automatically.

## Rollback

Revert the M1-012 PR and delete any locally generated bundle no longer needed.
No runtime, secure-storage, input, network, or migration state is changed.
