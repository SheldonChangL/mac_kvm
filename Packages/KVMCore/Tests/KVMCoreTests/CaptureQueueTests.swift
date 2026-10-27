import Foundation
import KVMContracts
import KVMCore
import Testing

private func move(_ x: Double) -> KVMEvent {
  .mouseMove(position: NormalizedPoint(x: x, y: 0.5))
}

private let buttonDown = KVMEvent.mouseButton(button: .left, phase: .down)
private let buttonUp = KVMEvent.mouseButton(button: .left, phase: .up)
private let keyDown = KVMEvent.key(key: .letter(0), phase: .down, modifiers: ModifierState())

private let overflowError = CoreError(
  code: .inputSafety(.cleanupRequired),
  severity: .error,
  retryDisposition: .never,
  cleanupDisposition: .partial
)

private func makeQueue(_ capacity: Int) throws -> CaptureQueue {
  try #require(CaptureQueue(capacity: capacity))
}

private func drainAll(_ queue: CaptureQueue) -> [KVMEvent] {
  queue.drain(maximumCount: Int.max)
}

@Suite("M2-003 CaptureQueue")
struct CaptureQueueTests {
  @Test("capacity below two or above the bound is rejected")
  func invalidCapacity() {
    #expect(CaptureQueue(capacity: 1) == nil)
    #expect(CaptureQueue(capacity: 0) == nil)
    #expect(CaptureQueue(capacity: -4) == nil)
    #expect(CaptureQueue(capacity: CaptureQueue.maximumCapacity + 1) == nil)
    #expect(CaptureQueue(capacity: CaptureQueue.maximumCapacity) != nil)
  }

  @Test("happy path: events keep their order")
  func order() throws {
    let queue = try makeQueue(8)
    #expect(queue.enqueue(move(0.1)) == .enqueued)
    #expect(queue.enqueue(buttonDown) == .enqueued)
    #expect(queue.enqueue(keyDown) == .enqueued)
    #expect(queue.enqueue(buttonUp) == .enqueued)
    #expect(drainAll(queue) == [move(0.1), buttonDown, keyDown, buttonUp])
    #expect(queue.count == 0)
  }

  @Test("consecutive moves coalesce to the latest; moves never jump a button")
  func moveCoalescing() throws {
    let queue = try makeQueue(8)
    #expect(queue.enqueue(move(0.1)) == .enqueued)
    #expect(queue.enqueue(move(0.2)) == .coalesced)
    #expect(queue.enqueue(buttonDown) == .enqueued)
    #expect(queue.enqueue(move(0.3)) == .enqueued)
    #expect(queue.enqueue(move(0.4)) == .coalesced)
    #expect(drainAll(queue) == [move(0.2), buttonDown, move(0.4)])
  }

  @Test("consecutive scrolls sum with saturation")
  func scrollCoalescing() throws {
    let queue = try makeQueue(4)
    #expect(queue.enqueue(.scroll(deltaX: 1, deltaY: 2)) == .enqueued)
    #expect(queue.enqueue(.scroll(deltaX: 3, deltaY: -5)) == .coalesced)
    #expect(queue.enqueue(.scroll(deltaX: .max, deltaY: .min)) == .coalesced)
    #expect(drainAll(queue) == [.scroll(deltaX: .max, deltaY: .min)])
  }

  @Test("boundary: a full queue drops only a non-coalescible move")
  func fullDropsMove() throws {
    let queue = try makeQueue(2)
    #expect(queue.enqueue(buttonDown) == .enqueued)
    #expect(queue.enqueue(buttonUp) == .enqueued)
    #expect(queue.enqueue(move(0.9)) == .droppedMove)
    #expect(!queue.hasOverflowed)
    #expect(drainAll(queue) == [buttonDown, buttonUp])
  }

  @Test("failure: a full queue never silently drops key or button events")
  func overflowLatches() async throws {
    let queue = try makeQueue(2)
    #expect(queue.enqueue(keyDown) == .enqueued)
    #expect(queue.enqueue(move(0.1)) == .enqueued)
    #expect(queue.enqueue(buttonDown) == .overflow)
    #expect(queue.hasOverflowed)
    #expect(queue.enqueue(move(0.2)) == .overflow)
    #expect(queue.count == 0)
    await #expect(throws: overflowError) { try await queue.next() }
    queue.reset()
    #expect(!queue.hasOverflowed)
    #expect(queue.enqueue(keyDown) == .enqueued)
  }

  @Test("drain honours its maximum count")
  func drainMaximum() throws {
    let queue = try makeQueue(4)
    _ = queue.enqueue(buttonDown)
    _ = queue.enqueue(keyDown)
    _ = queue.enqueue(buttonUp)
    #expect(queue.drain(maximumCount: 2) == [buttonDown, keyDown])
    #expect(queue.drain(maximumCount: 0) == [])
    #expect(drainAll(queue) == [buttonUp])
  }

  @Test("ring buffer keeps order across wrap-around")
  func wrapAround() throws {
    let queue = try makeQueue(3)
    for round in 0..<5 {
      let down = KVMEvent.key(key: .digit(UInt8(round)), phase: .down, modifiers: ModifierState())
      let up = KVMEvent.key(key: .digit(UInt8(round)), phase: .up, modifiers: ModifierState())
      #expect(queue.enqueue(down) == .enqueued)
      #expect(queue.enqueue(up) == .enqueued)
      #expect(drainAll(queue) == [down, up])
    }
  }

  @Test("next resumes a waiting consumer when the producer enqueues")
  func nextWakesConsumer() async throws {
    let queue = try makeQueue(4)
    let received = Task { try await queue.next() }
    await queue.waitForPendingConsumer()
    #expect(queue.enqueue(keyDown) == .enqueued)
    #expect(try await received.value == keyDown)
  }

  @Test("close finishes a waiting consumer and is idempotent")
  func closeIsIdempotent() async throws {
    let queue = try makeQueue(4)
    _ = queue.enqueue(keyDown)
    queue.close()
    queue.close()
    #expect(try await queue.next() == nil)
    #expect(queue.enqueue(keyDown) == .closed)

    let waiting = try makeQueue(4)
    let received = Task { try await waiting.next() }
    await waiting.waitForPendingConsumer()
    waiting.close()
    #expect(try await received.value == nil)
  }

  @Test("a served consumer later observes overflow as a typed error")
  func overflowWakesConsumer() async throws {
    let queue = try makeQueue(2)
    let received = Task { try await queue.next() }
    await queue.waitForPendingConsumer()
    #expect(queue.enqueue(keyDown) == .enqueued)
    let first = try await received.value
    #expect(first == keyDown)
    _ = queue.enqueue(keyDown)
    _ = queue.enqueue(keyDown)
    #expect(queue.enqueue(keyDown) == .overflow)
    await #expect(throws: overflowError) { try await queue.next() }
  }

  @Test("cancellation of a waiting consumer throws a typed cancellation")
  func cancellation() async throws {
    let queue = try makeQueue(4)
    let task = Task { try await queue.next() }
    await queue.waitForPendingConsumer()
    task.cancel()
    let cancelled = CoreError(
      code: .cancellation(.requested),
      severity: .info,
      retryDisposition: .never,
      cleanupDisposition: .notRequired
    )
    await #expect(throws: cancelled) { try await task.value }
    #expect(queue.enqueue(keyDown) == .enqueued)
    #expect(try await queue.next() == keyDown)
  }
}
