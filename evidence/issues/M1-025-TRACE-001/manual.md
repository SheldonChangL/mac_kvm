# M1-025-TRACE-001 Manual Review Notes

## Source validity and traceability

The source blocker is GitHub Issue #293. It was created from the M1-025 review finding
that the M1-023 register workflow required M1-025 consumer links, while the M1-025
canonical issue forbade silently expanding its Exact Files.

## Product contract and architecture boundaries

This issue changes traceability only. It does not alter the M1-025 wire contract, and it
does not introduce parser, codec, networking, KVM Core or input-engine behavior.

## Test migration note

`Tests/Contracts/test_m1_wire_001_contract_sequence.py` previously named its source-entry
guard `test_source_entry_is_unchanged_byte_for_byte`. For #293, that guard was renamed to
`test_source_entry_only_adds_m1_025_consumer_links` because the approved register workflow
now permits exactly two in-place consumer-link fields on `BARRIER-EVID-0001` and rejects
any other source-entry change.

## Rollback

Revert this PR to remove the consumer links and restore the previous register
documentation. If M1-021 or M1-022 has already consumed M1-025, block those consumers
until an equivalent traceability link is restored.
