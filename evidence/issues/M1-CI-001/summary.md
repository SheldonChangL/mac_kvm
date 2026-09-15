# M1-CI-001 Evidence Summary

GitHub Issue: #227

Implementation commit: `17470abd101001264ae9ab94eda44989b8808125`

## Trigger

M1-009 post-merge run 34940209487 passed but emitted a GitHub annotation that the pinned checkout/upload actions targeted deprecated Node.js 20 and were being forced to Node.js 24.

## Change

- `actions/checkout` → official v7.0.1 Node 24 runtime, immutable commit `3d3c42e5aac5ba805825da76410c181273ba90b1`.
- `actions/upload-artifact` → official v7.0.1 Node 24 runtime, immutable commit `043fb46d1a93c77aae656e7c1c64a875d1fc6a0a`.
- CI contract test and M1-008 tooling documentation updated to require/record those exact refs.

Read-only permissions, non-persisted checkout credentials, always-run artifact upload, retention, gate command, required check context, and branch protection are unchanged.

## Acceptance criteria

- CI unit tests require exact reviewed Node 24 action SHAs: passed 10/10.
- Local full gate passes: 6/6.
- PR-head and post-merge GitHub runs must pass with no Node 20 annotation before this corrective Issue closes.

## Rollback

Revert the corrective PR. Required check context and runtime product behavior are unaffected.
