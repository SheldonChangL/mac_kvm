// Release-all ordering for the client role (M1-050). First-party policy: the plan that a terminal
// path runs over what the client holds. It never logs.

import KVMContracts

package struct ReleasePlan: Equatable, Sendable {
  package let steps: [KVMEvent]

  package init(steps: [KVMEvent]) {
    self.steps = steps
  }
}

package protocol InputReleaser: Sendable {
  func release(_ event: KVMEvent) throws(CoreError)
}

package struct ReleaseReport: Equatable, Sendable {
  package let attempted: Int
  package let failed: Int
  package let disposition: CleanupDisposition

  package init(attempted: Int, failed: Int, disposition: CleanupDisposition) {
    self.attempted = attempted
    self.failed = failed
    self.disposition = disposition
  }
}

package enum ReleaseAllKeys {
  /// Non-modifier keys in reverse press order, then buttons in reverse press order, then modifier
  /// keys in reverse press order. A key release carries the modifiers recorded at its press.
  package static func plan(
    keys: [(key: VirtualKey, modifiers: ModifierState)], buttons: [MouseButton]
  ) -> ReleasePlan {
    var ordinary: [KVMEvent] = []
    var modifierKeys: [KVMEvent] = []
    for held in keys.reversed() {
      let release = KVMEvent.key(key: held.key, phase: .up, modifiers: held.modifiers)
      if isModifierKey(held.key) {
        modifierKeys.append(release)
      } else {
        ordinary.append(release)
      }
    }
    let buttonReleases = buttons.reversed().map { KVMEvent.mouseButton(button: $0, phase: .up) }
    return ReleasePlan(steps: ordinary + buttonReleases + modifierKeys)
  }

  /// Attempts every step even after a failure. Safe to run again with the same plan.
  package static func execute(
    _ plan: ReleasePlan, with releaser: any InputReleaser
  ) -> ReleaseReport {
    var failed = 0
    for step in plan.steps {
      do {
        try releaser.release(step)
      } catch {
        failed += 1
      }
    }
    let attempted = plan.steps.count
    let disposition: CleanupDisposition
    if attempted == 0 {
      disposition = .notRequired
    } else if failed == 0 {
      disposition = .completed
    } else if failed == attempted {
      disposition = .failed
    } else {
      disposition = .partial
    }
    return ReleaseReport(attempted: attempted, failed: failed, disposition: disposition)
  }

  /// C-005's Modifiers group, which M4-002's `releaseAllHeld()` also uses. Listed without a
  /// `default` so a later catalog member fails compilation until it is classified.
  private static func isModifierKey(_ key: VirtualKey) -> Bool {
    switch key {
    case .shift, .control, .option, .command, .capsLock:
      return true
    case .letter, .digit, .enter, .escape, .tab, .space, .backspace, .delete, .left, .right,
      .up, .down, .home, .end, .pageUp, .pageDown, .function, .volumeUp, .volumeDown, .mute,
      .punctuation, .unknown:
      return false
    }
  }
}
