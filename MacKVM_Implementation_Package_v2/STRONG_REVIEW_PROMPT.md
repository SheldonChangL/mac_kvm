# Strong Model / Engineer Review Prompt

Review the PR against the Issue, frozen contracts and evidence—not against the implementer's explanation.

- Verify scope and Exact Files.
- Re-run required tests and architecture checks.
- Inspect error/cancel/disconnect/cleanup paths.
- For protocol work, compare exact bytes with frozen vectors.
- For input work, inspect state ledger and release ordering.
- For security work, verify fail-closed, identity change, secure storage and secret redaction.
- Reject tests that merely mirror implementation or skip real boundaries.
- Mark each AC Pass/Fail/Insufficient Evidence.
- Do not merge C/S/H without required human/security/hardware evidence.
