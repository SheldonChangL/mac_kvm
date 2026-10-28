import Carbon.HIToolbox
import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

private let ownPID: Int64 = 9191

private func makeSuppressor() throws -> LocalEventSuppressor {
  let filter = try #require(SyntheticEventFilter(marker: 0x13, processID: ownPID))
  return LocalEventSuppressor(filter: filter) { event in
    if case .key(.backspace, _, let modifiers) = event {
      return modifiers.control && modifiers.option && modifiers.command
    }
    return false
  }
}

private func keyEvent(_ code: Int, flags: CGEventFlags = []) throws -> CGEvent {
  let event = try #require(
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: true))
  event.flags = flags
  event.setIntegerValueField(.eventSourceUnixProcessID, value: 1)
  return event
}

private func moveEvent() throws -> CGEvent {
  let event = try #require(
    CGEvent(
      mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: .zero,
      mouseButton: .left))
  event.setIntegerValueField(.eventSourceUnixProcessID, value: 1)
  return event
}

private func buttonEvent(_ type: CGEventType, number: Int64) throws -> CGEvent {
  let event = try #require(
    CGEvent(
      mouseEventSource: nil, mouseType: type, mouseCursorPosition: .zero, mouseButton: .center))
  event.setIntegerValueField(.mouseEventButtonNumber, value: number)
  event.setIntegerValueField(.eventSourceUnixProcessID, value: 1)
  return event
}

private func scrollEvent(vertical: Int32, horizontal: Int32) throws -> CGEvent {
  let event = try #require(
    CGEvent(
      scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical,
      wheel2: horizontal, wheel3: 0))
  event.setIntegerValueField(.eventSourceUnixProcessID, value: 1)
  return event
}

@Suite("M2-013 LocalEventSuppressor")
struct LocalEventSuppressorTests {
  @Test("events pass through until suppression is enabled for committed remote")
  func passThroughByDefault() throws {
    let suppressor = try makeSuppressor()
    #expect(!suppressor.isSuppressing)
    #expect(suppressor.decide(type: .mouseMoved, event: try moveEvent()) == .passThrough)
    suppressor.enableSuppression()
    #expect(suppressor.decide(type: .mouseMoved, event: try moveEvent()) == .suppress)
    #expect(suppressor.decide(type: .keyDown, event: try keyEvent(kVK_ANSI_A)) == .suppress)
    suppressor.disableSuppression()
    suppressor.disableSuppression()
    #expect(suppressor.decide(type: .keyDown, event: try keyEvent(kVK_ANSI_A)) == .passThrough)
  }

  @Test("tap disabled by timeout or user input fails open immediately")
  func tapDisabled() throws {
    for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
      let suppressor = try makeSuppressor()
      suppressor.enableSuppression()
      #expect(suppressor.decide(type: type, event: try moveEvent()) == .failOpen)
      #expect(!suppressor.isSuppressing)
      #expect(suppressor.decide(type: .mouseMoved, event: try moveEvent()) == .passThrough)
    }
  }

  @Test("tap or permission errors fail open")
  func tapFailure() throws {
    let suppressor = try makeSuppressor()
    suppressor.enableSuppression()
    suppressor.tapFailed()
    #expect(!suppressor.isSuppressing)
    #expect(suppressor.decide(type: .keyDown, event: try keyEvent(kVK_ANSI_A)) == .passThrough)
  }

  @Test("the emergency chord is never suppressed and stops suppression synchronously")
  func emergencyEscape() throws {
    let suppressor = try makeSuppressor()
    suppressor.enableSuppression()
    let chord = try keyEvent(kVK_Delete, flags: [.maskControl, .maskAlternate, .maskCommand])
    #expect(suppressor.decide(type: .keyDown, event: chord) == .emergencyEscape)
    #expect(!suppressor.isSuppressing)
  }

  @Test("the system Force Quit chord is never suppressed")
  func systemHotkey() throws {
    let suppressor = try makeSuppressor()
    suppressor.enableSuppression()
    let forceQuit = try keyEvent(kVK_Escape, flags: [.maskCommand, .maskAlternate])
    #expect(suppressor.decide(type: .keyDown, event: forceQuit) == .passThrough)
    #expect(suppressor.isSuppressing)
    #expect(suppressor.decide(type: .keyDown, event: try keyEvent(kVK_Escape)) == .suppress)
  }

  @Test("synthetic first-party events always pass through")
  func synthetic() throws {
    let suppressor = try makeSuppressor()
    suppressor.enableSuppression()
    let own = try moveEvent()
    own.setIntegerValueField(.eventSourceUnixProcessID, value: ownPID)
    #expect(suppressor.decide(type: .mouseMoved, event: own) == .passThrough)
  }

  /// Codex review H-9: suppression never exceeds what capture forwards, so
  /// input the server cannot send to the remote screen fails open locally.
  @Test("unsupported input passes through while suppressing")
  func unsupportedInputPassesThrough() throws {
    let suppressor = try makeSuppressor()
    suppressor.enableSuppression()
    let mouse = try #require(MacMouseCapture(bounds: CGRect(x: 0, y: 0, width: 100, height: 100)))

    for number: Int64 in [4, 5, 7, 31] {
      for type in [CGEventType.otherMouseDown, .otherMouseUp] {
        let event = try buttonEvent(type, number: number)
        #expect(mouse.map(event) == nil)
        #expect(suppressor.decide(type: type, event: event) == .passThrough, "button \(number)")
      }
    }
    let zeroScroll = try scrollEvent(vertical: 0, horizontal: 0)
    #expect(mouse.map(zeroScroll) == nil)
    #expect(suppressor.decide(type: .scrollWheel, event: zeroScroll) == .passThrough)

    let tabletPointer = CGEventType.tabletPointer
    let tabletProximity = CGEventType.tabletProximity
    let others = [
      tabletPointer, tabletProximity,
      try #require(CGEventType(rawValue: 29)),  // gesture
      try #require(CGEventType(rawValue: 14)),  // system-defined
    ]
    for type in others {
      let event = try moveEvent()
      event.type = type
      #expect(suppressor.decide(type: type, event: event) == .passThrough, "type \(type.rawValue)")
    }

    // Forwardable input is still suppressed.
    let middle = try buttonEvent(.otherMouseDown, number: 2)
    #expect(suppressor.decide(type: .otherMouseDown, event: middle) == .suppress)
    let wheel = try scrollEvent(vertical: 1, horizontal: 0)
    #expect(suppressor.decide(type: .scrollWheel, event: wheel) == .suppress)
    #expect(suppressor.decide(type: .mouseMoved, event: try moveEvent()) == .suppress)
    #expect(suppressor.decide(type: .keyDown, event: try keyEvent(kVK_ANSI_A)) == .suppress)
  }

  @Test("concurrent decisions observe enable and disable consistently")
  func concurrency() async throws {
    let suppressor = try makeSuppressor()
    suppressor.enableSuppression()
    let whileOn = await decideConcurrently(suppressor, count: 32)
    #expect(whileOn.allSatisfy { $0 == .suppress })
    suppressor.disableSuppression()
    let whileOff = await decideConcurrently(suppressor, count: 32)
    #expect(whileOff.allSatisfy { $0 == .passThrough })
  }
}

private func decideConcurrently(_ suppressor: LocalEventSuppressor, count: Int) async
  -> [LocalEventSuppressor.Decision]
{
  await withTaskGroup(of: LocalEventSuppressor.Decision?.self) { group in
    for _ in 0..<count {
      group.addTask { (try? moveEvent()).map { suppressor.decide(type: .mouseMoved, event: $0) } }
    }
    var decisions: [LocalEventSuppressor.Decision] = []
    for await decision in group {
      decisions.append(decision ?? .failOpen)
    }
    return decisions
  }
}
