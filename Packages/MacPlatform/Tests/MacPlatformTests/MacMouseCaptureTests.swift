import CoreGraphics
import Foundation
import KVMContracts
import Testing

@testable import MacPlatform

private let bounds = CGRect(x: 0, y: 0, width: 1001, height: 501)

private func mouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) throws
  -> CGEvent
{
  try #require(
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
  )
}

private func scroll(_ vertical: Int32, _ horizontal: Int32) throws -> CGEvent {
  try #require(
    CGEvent(
      scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical,
      wheel2: horizontal, wheel3: 0))
}

@Suite("M2-004 MacMouseCapture")
struct MacMouseCaptureTests {
  /// The suppression allowlist (M2-013, Codex review H-9) relies on `canMap`
  /// agreeing with `map` for every event shape.
  @Test("canMap agrees with map for every event type and button number")
  func canMapAgreesWithMap() throws {
    let capture = try #require(MacMouseCapture(bounds: bounds))
    var corpus: [CGEvent] = []
    for raw in UInt32(0)...40 {
      guard let type = CGEventType(rawValue: raw) else { continue }
      for number: Int64 in [0, 1, 2, 3, 4, 7] {
        let event = try mouse(.mouseMoved, at: CGPoint(x: 10, y: 10))
        event.type = type
        event.setIntegerValueField(.mouseEventButtonNumber, value: number)
        corpus.append(event)
      }
    }
    corpus += [try scroll(0, 0), try scroll(1, 0), try scroll(0, -1), try scroll(5, 5)]
    for event in corpus {
      #expect(
        MacMouseCapture.canMap(event) == (capture.map(event) != nil),
        "type \(event.type.rawValue)")
    }
  }

  @Test("moves and drags map to normalized positions within the capture bounds")
  func moves() throws {
    let capture = try #require(MacMouseCapture(bounds: bounds))
    for type in [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
    {
      let captured = capture.map(try mouse(type, at: CGPoint(x: 500, y: 125)))
      #expect(captured?.event == .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.25)))
    }
  }

  @Test("positions outside the bounds clamp; offset bounds are respected")
  func clamping() throws {
    let capture = try #require(MacMouseCapture(bounds: bounds))
    let outside = capture.map(try mouse(.mouseMoved, at: CGPoint(x: -40, y: 900)))
    #expect(outside?.event == .mouseMove(position: NormalizedPoint(x: 0, y: 1)))
    let offset = try #require(
      MacMouseCapture(bounds: CGRect(x: 100, y: 50, width: 201, height: 101)))
    #expect(
      offset.map(try mouse(.mouseMoved, at: CGPoint(x: 200, y: 100)))?.event
        == .mouseMove(position: NormalizedPoint(x: 0.5, y: 0.5)))
  }

  @Test("buttons map left, right, middle and one auxiliary; others are dropped")
  func buttons() throws {
    let capture = try #require(MacMouseCapture(bounds: bounds))
    let point = CGPoint(x: 1, y: 1)
    #expect(
      capture.map(try mouse(.leftMouseDown, at: point))?.event
        == .mouseButton(button: .left, phase: .down))
    #expect(
      capture.map(try mouse(.leftMouseUp, at: point))?.event
        == .mouseButton(button: .left, phase: .up))
    #expect(
      capture.map(try mouse(.rightMouseDown, at: point, button: .right))?.event
        == .mouseButton(button: .right, phase: .down))
    #expect(
      capture.map(try mouse(.otherMouseDown, at: point, button: .center))?.event
        == .mouseButton(button: .middle, phase: .down))
    let aux = try mouse(.otherMouseUp, at: point, button: .center)
    aux.setIntegerValueField(.mouseEventButtonNumber, value: 3)
    #expect(capture.map(aux)?.event == .mouseButton(button: .auxiliary, phase: .up))
    let unsupported = try mouse(.otherMouseDown, at: point, button: .center)
    unsupported.setIntegerValueField(.mouseEventButtonNumber, value: 7)
    #expect(capture.map(unsupported) == nil)
  }

  @Test("scroll uses line deltas: vertical to deltaY, horizontal to deltaX")
  func scrolling() throws {
    let capture = try #require(MacMouseCapture(bounds: bounds))
    #expect(capture.map(try scroll(3, -2))?.event == .scroll(deltaX: -2, deltaY: 3))
    #expect(capture.map(try scroll(0, 0)) == nil)
  }

  @Test("timestamps are preserved for ordering")
  func timestamps() throws {
    let capture = try #require(MacMouseCapture(bounds: bounds))
    let event = try mouse(.mouseMoved, at: CGPoint(x: 2, y: 2))
    event.timestamp = 123_456_789
    #expect(capture.map(event)?.timestamp == 123_456_789)
  }

  @Test("non-mouse events and degenerate bounds are rejected")
  func invalid() throws {
    #expect(MacMouseCapture(bounds: CGRect(x: 0, y: 0, width: 1, height: 100)) == nil)
    #expect(MacMouseCapture(bounds: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 100)) == nil)
    let capture = try #require(MacMouseCapture(bounds: bounds))
    let key = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
    #expect(capture.map(key) == nil)
  }
}
