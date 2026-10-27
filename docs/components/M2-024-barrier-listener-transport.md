# M2-024 Barrier Listener Transport

## Outcome

`BarrierCompatibility` now has `BarrierListenerTransport`, an actor that
admits accepted connections for the Barrier server role, plus
`BarrierListenerPolicy`, `BarrierListenerAdmission` and
`BarrierListenerError`. Declarations are module-internal.

## Architecture decision

The guardrails forbid protocol modules from importing concrete networking or
naming socket types (M1-ARCH-001). The concrete listening socket therefore
belongs to a platform module, which hands every accepted connection to this
gate as an abstract `Transport` (C-002). This file owns only the
protocol-independent admission rules.

## Rules

- Policy: 1...8 concurrent connections; positive connect timeout.
- A slot is reserved before `connect()`, so concurrent admits cannot exceed
  the limit. Over the limit, the transport is disconnected and
  `capacityExceeded` is thrown.
- `connect()` races the injected `KVMClock` timeout; the loser is cancelled.
  Failure, timeout and cancellation all disconnect the transport and throw a
  typed error.
- `stop()` disconnects every admitted transport, is idempotent, and makes later
  admits disconnect and throw `stopped`.
- The gate never touches input state, so listener errors cannot suppress or
  block local input.

## Tests

`BarrierListenerTransportTests` (6) with a fake transport and a manual
cancellation-aware clock (no sleeps): policy bounds, admit/release
idempotency, capacity, connect failure, connect timeout, stop. Ten repeated
runs passed.

## Blocker

A concrete TLS server listener is not implemented: TLS must stay default on
and no server certificate identity provisioning decision exists (M2-023).

## Rollback

Revert the three M2-024 files.
