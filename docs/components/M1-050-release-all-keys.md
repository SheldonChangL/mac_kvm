# M1-050 Release-all Ordering

## Outcome

`KVMCore` provides `ReleasePlan`, `InputReleaser`, `ReleaseReport` and `ReleaseAllKeys` in
`Packages/KVMCore/Sources/KVMCore/ReleaseAllKeys.swift`, with `package` access. Given the keys and
mouse buttons a client holds, `ReleaseAllKeys.plan` returns the ordered releases and
`ReleaseAllKeys.execute` runs them through an `InputReleaser`.

The consumer is the first-party Linux client on the Barrier wire
(`docs/adr/M4-SCOPE-001-linux-client-first.md`). The release order is platform-neutral, so it lives
in `KVMCore` and each platform injector adapts to `InputReleaser`. The order is first-party policy,
not a Barrier or protocol rule. Nothing is public and `KVMContracts` is unchanged. The file imports
only `KVMContracts`, contains no Barrier token and never logs (Frozen Decision 8).

## API

```swift
package struct ReleasePlan: Equatable, Sendable { package let steps: [KVMEvent] }
package protocol InputReleaser: Sendable {
  func release(_ event: KVMEvent) throws(CoreError)  // synchronous, best effort, idempotent
}
package struct ReleaseReport: Equatable, Sendable {
  package let attempted: Int
  package let failed: Int
  package let disposition: CleanupDisposition
}
package enum ReleaseAllKeys {
  package static func plan(
    keys: [(key: VirtualKey, modifiers: ModifierState)], buttons: [MouseButton]) -> ReleasePlan
  package static func execute(_ plan: ReleasePlan, with releaser: any InputReleaser) -> ReleaseReport
}
```

`plan` takes `(key:, modifiers:)` pairs in press order, the shape `ServerCoordinator` keeps for its
`remoteKeys`, so this issue does not depend on M1-062's held-key type. The caller maps its record to
pairs. Buttons are in press order as well.

## Order

1. Keys that are not modifier keys, in reverse press order.
2. Mouse buttons, in reverse press order.
3. Modifier keys, in reverse press order.

"Modifier keys" means C-005's Modifiers group: `shift`, `control`, `option`, `command` and
`capsLock`. That is the grouping M4-002's `releaseAllHeld()` uses, so the plan and the platform sweep
release in the same order. Caps Lock is an ordinary key in M1-062's ledger but belongs to the
modifier group here. Every other `VirtualKey`, `unknown` included, is a non-modifier key. The
classification is an exhaustive `switch` without `default`, so a later catalog member fails
compilation until it is placed.

Each key release is `KVMEvent.key(key:, phase: .up, modifiers:)` with the modifiers recorded at that
key's press, the way `ServerCoordinator` releases its remote keys. Each button release is
`KVMEvent.mouseButton(button:, phase: .up)`. A plan never holds anything else. An empty input gives
an empty plan.

## Execution

`execute` calls the releaser once for every step, in plan order, and never stops at a failure. The
report carries the step count (`attempted`), the number of throwing steps (`failed`) and a
disposition:

| attempted and failed | disposition |
|---|---|
| no step | `notRequired` |
| no failure | `completed` |
| every step failed | `failed` |
| some steps failed | `partial` |

Releasing is idempotent: a plan is a value and `execute` keeps no state, so running the same plan
twice attempts every step twice and reports the same result when the releaser behaves the same. An
`InputReleaser` must treat the release of something it does not hold as a no-op that succeeds, which
makes a second run harmless. A failed run can be retried with the same plan.

## Evidence and known limitations

- The Product Owner decided on 2026-11-02 that the Xvfb release-all test of M4-024 and the owner's
  end-to-end run (issue #351) are the hardware evidence for M1-050 and M1-061. No separate manual run
  is recorded here, so the pull request says `Part of #64`.
- `execute` does not decide what happens after a `partial` or `failed` report. The fail-safe
  coordinator (M1-063) maps it to its own outcome and the platform sweep (`releaseAllHeld()`) is the
  second line.
- Whether a repeat or a duplicate press is recorded belongs to the input-state ledger, not to this
  plan.
