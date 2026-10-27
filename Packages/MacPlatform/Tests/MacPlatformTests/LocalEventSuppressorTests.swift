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

  @Test("concurrent enable and disable leave a consistent final state")
  func concurrency() async throws {
    let suppressor = try makeSuppressor()
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<64 {
        group.addTask {
          if index % 2 == 0 {
            suppressor.enableSuppression()
          } else {
            suppressor.disableSuppression()
          }
        }
      }
    }
    suppressor.disableSuppression()
    #expect(!suppressor.isSuppressing)
  }
}
