import Foundation
import KVMContracts
import KVMCore
import Testing

// M1-050: the release-all ordering. Keys that are not modifiers release first, newest first; then
// the buttons, newest first; then the modifier keys (C-005's Modifiers group: shift, control,
// option, command, capsLock), newest first. Every key release carries the modifiers recorded at its
// press, as ServerCoordinator's releaseRemoteInput does.

// MARK: - Fixtures

private typealias Held = (key: VirtualKey, modifiers: ModifierState)

private let noModifiers = ModifierState()
private let shiftHeld = ModifierState(shift: true)
private let commandHeld = ModifierState(command: true)
private let shiftAndCommand = ModifierState(shift: true, command: true)

private func up(_ key: VirtualKey, _ modifiers: ModifierState = ModifierState()) -> KVMEvent {
  .key(key: key, phase: .up, modifiers: modifiers)
}

private func buttonUp(_ button: MouseButton) -> KVMEvent {
  .mouseButton(button: button, phase: .up)
}

private let releaseFailure = CoreError(
  code: .inputSafety(.cleanupFailed), severity: .error, retryDisposition: .never,
  cleanupDisposition: .failed)

/// Records every event it is asked to release; the calls whose zero-based indices are in
/// `failingCalls` throw after being recorded.
private final class RecordingReleaser: InputReleaser, @unchecked Sendable {
  private let lock = NSLock()
  private let failingCalls: Set<Int>
  private var events: [KVMEvent] = []

  init(failingCalls: Set<Int> = []) {
    self.failingCalls = failingCalls
  }

  var released: [KVMEvent] { lock.withLock { events } }

  func release(_ event: KVMEvent) throws(CoreError) {
    let index = lock.withLock { () -> Int in
      events.append(event)
      return events.count - 1
    }
    if failingCalls.contains(index) { throw releaseFailure }
  }
}

/// A platform stand-in that holds keys and buttons and whose release of something it does not
/// hold is a harmless no-op, which is what `InputReleaser` requires.
private final class HoldingReleaser: InputReleaser, @unchecked Sendable {
  private let lock = NSLock()
  private var heldKeys: [String]
  private var heldButtons: [MouseButton]
  private var calls = 0

  init(keys: [VirtualKey], buttons: [MouseButton]) {
    heldKeys = keys.map { "\($0)" }
    heldButtons = buttons
  }

  var holdsAnything: Bool { lock.withLock { !heldKeys.isEmpty || !heldButtons.isEmpty } }
  var releaseCalls: Int { lock.withLock { calls } }

  func release(_ event: KVMEvent) throws(CoreError) {
    lock.withLock {
      calls += 1
      switch event {
      case .key(let key, _, _): heldKeys.removeAll { $0 == "\(key)" }
      case .mouseButton(let button, _): heldButtons.removeAll { $0 == button }
      default: break
      }
    }
  }
}

// MARK: - Ordering

@Suite("ReleaseAllKeys plan")
struct ReleaseAllKeysPlanTests {
  @Test func nonModifierKeysReleaseNewestFirst() {
    let keys: [Held] = [(.letter(0), noModifiers), (.digit(3), noModifiers), (.enter, noModifiers)]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [])
    #expect(plan.steps == [up(.enter), up(.digit(3)), up(.letter(0))])
  }

  @Test func buttonsReleaseNewestFirst() {
    let plan = ReleaseAllKeys.plan(keys: [], buttons: [.left, .right, .middle])
    #expect(plan.steps == [buttonUp(.middle), buttonUp(.right), buttonUp(.left)])
  }

  @Test func modifierKeysReleaseNewestFirst() {
    let keys: [Held] = [(.shift, noModifiers), (.control, shiftHeld), (.command, shiftHeld)]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [])
    #expect(plan.steps == [up(.command, shiftHeld), up(.control, shiftHeld), up(.shift)])
  }

  @Test func keysThenButtonsThenModifiersWithEachGroupInReversePressOrder() {
    let keys: [Held] = [
      (.shift, noModifiers), (.letter(0), shiftHeld), (.command, shiftHeld),
      (.letter(1), shiftAndCommand), (.control, shiftAndCommand), (.space, shiftAndCommand),
    ]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [.left, .right])
    let expected: [KVMEvent] = [
      up(.space, shiftAndCommand), up(.letter(1), shiftAndCommand), up(.letter(0), shiftHeld),
      buttonUp(.right), buttonUp(.left),
      up(.control, shiftAndCommand), up(.command, shiftHeld), up(.shift),
    ]
    #expect(plan.steps == expected)
  }

  @Test func everyModifierKeyReleasesAfterTheButtons() {
    for key in [VirtualKey.shift, .control, .option, .command, .capsLock] {
      let keys: [Held] = [(key, noModifiers), (.letter(2), noModifiers)]
      let plan = ReleaseAllKeys.plan(keys: keys, buttons: [.left])
      #expect(plan.steps == [up(.letter(2)), buttonUp(.left), up(key)], "\(key)")
    }
  }

  @Test func capsLockIsAModifierKeyAndReleasesWithTheModifiers() {
    // capsLock sits between two ordinary keys in press order; grouped with the ordinary keys it
    // would release between them and before the button.
    let keys: [Held] = [
      (.shift, noModifiers), (.letter(0), shiftHeld), (.capsLock, shiftHeld),
      (.letter(1), shiftHeld),
    ]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [.left])
    let expected: [KVMEvent] = [
      up(.letter(1), shiftHeld), up(.letter(0), shiftHeld), buttonUp(.left),
      up(.capsLock, shiftHeld), up(.shift),
    ]
    #expect(plan.steps == expected)
  }

  @Test func eachKeyReleaseCarriesTheModifiersRecordedAtItsPress() {
    let keys: [Held] = [
      (.letter(0), shiftAndCommand), (.letter(1), noModifiers), (.shift, commandHeld),
    ]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [])
    let expected: [KVMEvent] = [
      up(.letter(1), noModifiers), up(.letter(0), shiftAndCommand), up(.shift, commandHeld),
    ]
    #expect(plan.steps == expected)
  }

  @Test func everyStepIsARelease() {
    let keys: [Held] = [
      (.letter(0), noModifiers), (.shift, noModifiers), (.unknown(7), noModifiers),
    ]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [.left, .auxiliary])
    for step in plan.steps {
      switch step {
      case .key(_, let phase, _): #expect(phase == .up)
      case .mouseButton(_, let phase): #expect(phase == .up)
      default: Issue.record("a step that is not a key or button release")
      }
    }
    #expect(plan.steps.count == 5)
  }

  @Test func anUnclassifiedKeyIsAnOrdinaryKey() {
    let keys: [Held] = [
      (.shift, noModifiers), (.unknown(UInt32.max), noModifiers), (.volumeUp, noModifiers),
    ]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [])
    #expect(plan.steps == [up(.volumeUp), up(.unknown(UInt32.max)), up(.shift)])
  }

  @Test func nothingHeldMakesAnEmptyPlan() {
    #expect(ReleaseAllKeys.plan(keys: [], buttons: []).steps.isEmpty)
  }

  @Test func planningIsPureAndRepeatable() {
    let keys: [Held] = [(.shift, noModifiers), (.letter(0), shiftHeld)]
    let first = ReleaseAllKeys.plan(keys: keys, buttons: [.left])
    let second = ReleaseAllKeys.plan(keys: keys, buttons: [.left])
    #expect(first == second)
  }
}

// MARK: - Execution

@Suite("ReleaseAllKeys execute")
struct ReleaseAllKeysExecuteTests {
  private static let plan: ReleasePlan = {
    let keys: [Held] = [(.shift, noModifiers), (.letter(0), shiftHeld), (.letter(1), shiftHeld)]
    return ReleaseAllKeys.plan(keys: keys, buttons: [.left, .right])  // five steps
  }()

  @Test func releasesEveryStepInPlanOrderAndReportsCompleted() {
    let releaser = RecordingReleaser()
    let report = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(releaser.released == Self.plan.steps)
    #expect(report == ReleaseReport(attempted: 5, failed: 0, disposition: .completed))
  }

  @Test func anEmptyPlanIsNotRequiredAndTouchesNothing() {
    let releaser = RecordingReleaser()
    let report = ReleaseAllKeys.execute(ReleaseAllKeys.plan(keys: [], buttons: []), with: releaser)
    #expect(report == ReleaseReport(attempted: 0, failed: 0, disposition: .notRequired))
    #expect(releaser.released.isEmpty)
  }

  @Test func aFailureOnTheSecondStepStillAttemptsTheRest() {
    let releaser = RecordingReleaser(failingCalls: [1])
    let report = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(releaser.released == Self.plan.steps)
    #expect(report == ReleaseReport(attempted: 5, failed: 1, disposition: .partial))
  }

  @Test func aFailureOnTheFirstStepStillAttemptsTheRest() {
    let releaser = RecordingReleaser(failingCalls: [0])
    let report = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(releaser.released.count == 5)
    #expect(report == ReleaseReport(attempted: 5, failed: 1, disposition: .partial))
  }

  @Test func oneFailureInATwoStepPlanIsPartial() {
    let plan = ReleaseAllKeys.plan(keys: [(.letter(0), noModifiers)], buttons: [.left])
    for failing in [0, 1] {
      let report = ReleaseAllKeys.execute(plan, with: RecordingReleaser(failingCalls: [failing]))
      #expect(report == ReleaseReport(attempted: 2, failed: 1, disposition: .partial))
    }
  }

  @Test func twoFailuresInAThreeStepPlanArePartial() {
    let keys: [Held] = [(.letter(0), noModifiers), (.letter(1), noModifiers)]
    let plan = ReleaseAllKeys.plan(keys: keys, buttons: [.left])
    let report = ReleaseAllKeys.execute(plan, with: RecordingReleaser(failingCalls: [0, 2]))
    #expect(report == ReleaseReport(attempted: 3, failed: 2, disposition: .partial))
  }

  @Test func aFailureOnTheLastStepIsPartial() {
    let releaser = RecordingReleaser(failingCalls: [4])
    let report = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(report == ReleaseReport(attempted: 5, failed: 1, disposition: .partial))
  }

  @Test func everyStepFailingIsFailedNotPartial() {
    let releaser = RecordingReleaser(failingCalls: [0, 1, 2, 3, 4])
    let report = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(releaser.released == Self.plan.steps)
    #expect(report == ReleaseReport(attempted: 5, failed: 5, disposition: .failed))
  }

  @Test func aSingleStepPlanIsCompletedOrFailed() {
    let single = ReleaseAllKeys.plan(keys: [(.letter(0), noModifiers)], buttons: [])
    #expect(
      ReleaseAllKeys.execute(single, with: RecordingReleaser())
        == ReleaseReport(attempted: 1, failed: 0, disposition: .completed))
    #expect(
      ReleaseAllKeys.execute(single, with: RecordingReleaser(failingCalls: [0]))
        == ReleaseReport(attempted: 1, failed: 1, disposition: .failed))
  }

  @Test func runningThePlanTwiceIsHarmless() {
    let releaser = HoldingReleaser(
      keys: [.shift, .letter(0), .letter(1)], buttons: [.left, .right])
    let first = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(!releaser.holdsAnything)
    let second = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(!releaser.holdsAnything)
    #expect(first == second)
    #expect(second == ReleaseReport(attempted: 5, failed: 0, disposition: .completed))
    #expect(releaser.releaseCalls == 10)
  }

  @Test func eachRunAttemptsEachStepExactlyOnce() {
    let releaser = RecordingReleaser()
    _ = ReleaseAllKeys.execute(Self.plan, with: releaser)
    _ = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(releaser.released == Self.plan.steps + Self.plan.steps)
  }

  @Test func aFailedRunCanBeRepeatedAndRetriesEveryStep() {
    let releaser = RecordingReleaser(failingCalls: [1])
    _ = ReleaseAllKeys.execute(Self.plan, with: releaser)
    let retry = ReleaseAllKeys.execute(Self.plan, with: releaser)
    #expect(releaser.released.count == 10)
    #expect(retry == ReleaseReport(attempted: 5, failed: 0, disposition: .completed))
  }

  @Test func planAndExecuteFromHeldInputReleaseEverythingInOrder() {
    let keys: [Held] = [(.command, noModifiers), (.letter(2), commandHeld)]
    let releaser = RecordingReleaser()
    let report = ReleaseAllKeys.execute(
      ReleaseAllKeys.plan(keys: keys, buttons: [.middle]), with: releaser)
    #expect(releaser.released == [up(.letter(2), commandHeld), buttonUp(.middle), up(.command)])
    #expect(report.disposition == .completed)
  }
}
