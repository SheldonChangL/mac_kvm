import CoreGraphics
import Foundation
import Testing

@testable import MacPlatform

private let ownPID: Int64 = 4242

private func event(userData: Int64 = 0, pid: Int64 = 0) throws -> CGEvent {
  let event = try #require(
    CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
      mouseButton: .left))
  // CoreGraphics ignores a second write of the user-data field, so the
  // helper writes it only when a non-default value is requested.
  if userData != 0 { event.setIntegerValueField(.eventSourceUserData, value: userData) }
  event.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
  return event
}

@Suite("M2-006 SyntheticEventFilter")
struct SyntheticEventFilterTests {
  @Test("tagged first-party events are synthetic")
  func taggedEvents() throws {
    let filter = try #require(SyntheticEventFilter(marker: 0x5EED, processID: ownPID))
    let injected = try event()
    filter.tag(injected)
    #expect(injected.getIntegerValueField(.eventSourceUserData) == 0x5EED)
    #expect(filter.classify(injected) == .synthetic(.marker))
  }

  @Test("fallback: a tag that cannot be written still leaves the own-process rule")
  func tagNotWritable() throws {
    let filter = try #require(SyntheticEventFilter(marker: 0x5EED, processID: ownPID))
    let injected = try event(userData: 0x1234, pid: ownPID)
    filter.tag(injected)
    #expect(injected.getIntegerValueField(.eventSourceUserData) == 0x1234)
    #expect(filter.classify(injected) == .synthetic(.ownProcess))
  }

  @Test("fallback: own-process events are synthetic even without a valid tag")
  func pidFallback() throws {
    let filter = try #require(SyntheticEventFilter(marker: 0x5EED, processID: ownPID))
    #expect(filter.classify(try event(userData: 0, pid: ownPID)) == .synthetic(.ownProcess))
    #expect(filter.classify(try event(userData: 0x1234, pid: ownPID)) == .synthetic(.ownProcess))
  }

  @Test("real user events, foreign tags and other processes are physical")
  func physicalEvents() throws {
    let filter = try #require(SyntheticEventFilter(marker: 0x5EED, processID: ownPID))
    #expect(filter.classify(try event()) == .physical)
    #expect(filter.classify(try event(userData: 0x1234, pid: 77)) == .physical)
    #expect(filter.classify(try event(userData: 0, pid: 77)) == .physical)
  }

  @Test("invalid configuration: zero marker or non-positive process id")
  func invalid() {
    #expect(SyntheticEventFilter(marker: 0, processID: ownPID) == nil)
    #expect(SyntheticEventFilter(marker: 1, processID: 0) == nil)
  }

  @Test("the live filter uses a non-zero marker and this process id")
  func live() throws {
    let filter = SyntheticEventFilter.live()
    #expect(filter.marker != 0)
    #expect(filter.processID == Int64(ProcessInfo.processInfo.processIdentifier))
    let other = SyntheticEventFilter.live()
    #expect(filter.classify(try event(userData: filter.marker, pid: 77)) == .synthetic(.marker))
    #expect(other.processID == filter.processID)
  }
}
