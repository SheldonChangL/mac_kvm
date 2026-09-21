import Testing

@testable import KVMContracts

@Test func testClockAdvancesWithoutWallClockSleep() async throws {
  let clock = TestKVMClock()
  let sleeper = Task {
    try await clock.sleep(for: .seconds(5))
  }

  try await clock.waitUntilPendingSleepCount(1)
  try await clock.advance(by: .seconds(4))
  #expect(await clock.pendingSleepCount == 1)

  try await clock.advance(by: .seconds(1))
  try await sleeper.value

  #expect(await clock.pendingSleepCount == 0)
  #expect(await clock.elapsed == .seconds(5))
}

@Test func testClockReleasesEachDeadlineAtItsExplicitBoundary() async throws {
  let clock = TestKVMClock()
  let earlier = Task {
    try await clock.sleep(for: .seconds(2))
  }
  let later = Task {
    try await clock.sleep(for: .seconds(5))
  }

  try await clock.waitUntilPendingSleepCount(2)
  try await clock.advance(by: .seconds(2))
  try await earlier.value
  #expect(await clock.pendingSleepCount == 1)

  try await clock.advance(by: .seconds(3))
  try await later.value
  #expect(await clock.pendingSleepCount == 0)
}

@Test func backoffSequenceUsesOnlyExplicitClockAdvances() async throws {
  let clock = TestKVMClock()
  let backoff = Task {
    for delay in [Duration.seconds(1), .seconds(2), .seconds(4)] {
      try await clock.sleep(for: delay)
    }
  }

  for delay in [Duration.seconds(1), .seconds(2), .seconds(4)] {
    try await clock.waitUntilPendingSleepCount(1)
    try await clock.advance(by: delay)
  }
  try await backoff.value

  #expect(await clock.elapsed == .seconds(7))
  #expect(await clock.pendingSleepCount == 0)
}

@Test func zeroDurationCompletesWithoutScheduling() async throws {
  let clock = TestKVMClock()

  try await clock.sleep(for: .zero)
  try await clock.advance(by: .zero)

  #expect(await clock.elapsed == .zero)
  #expect(await clock.pendingSleepCount == 0)
}

@Test func negativeDurationsFailClosed() async {
  let clock = TestKVMClock()

  do {
    try await clock.sleep(for: .seconds(-1))
    Issue.record("negative sleep duration must fail")
  } catch {
    #expect(error.code == .internalFailure(.preconditionFailed))
    #expect(error.retryDisposition == .never)
  }

  do {
    try await clock.advance(by: .seconds(-1))
    Issue.record("negative clock advance must fail")
  } catch {
    #expect(error.code == .internalFailure(.preconditionFailed))
  }
}

@Test func cancellingSleepRemovesPendingContinuationAndStaysTyped() async throws {
  let clock = TestKVMClock()
  let sleeper = Task {
    try await clock.sleep(for: .seconds(60))
  }

  try await clock.waitUntilPendingSleepCount(1)
  sleeper.cancel()

  do {
    try await sleeper.value
    Issue.record("cancelled sleep must not complete successfully")
  } catch let error as CoreError {
    #expect(error.code == .cancellation(.requested))
    #expect(error.cleanupDisposition == .completed)
  } catch {
    Issue.record("cancellation must remain a CoreError")
  }
  #expect(await clock.pendingSleepCount == 0)
}

@Test func productionClockMapsTaskCancellationToCoreError() async {
  let clock = ContinuousKVMClock()
  let sleeper = Task {
    try await clock.sleep(for: .seconds(60))
  }
  sleeper.cancel()

  do {
    try await sleeper.value
    Issue.record("cancelled production sleep must not complete successfully")
  } catch let error as CoreError {
    #expect(error.code == .cancellation(.requested))
    #expect(error.cleanupDisposition == .completed)
  } catch {
    Issue.record("production cancellation must remain a CoreError")
  }
}
