import CoreGraphics
import Foundation

/// Distinguishes first-party injected events from physical user input so the
/// server never captures and re-forwards its own injections (M2-006).
///
/// Primary rule: injected events carry a process-unique, non-zero
/// `eventSourceUserData` marker set with `tag(_:)`. Fallback rule, used when
/// a tag is missing or was not preserved: an event whose
/// `eventSourceUnixProcessID` equals this process is synthetic. Physical
/// events carry neither, so the filter never drops real user input. It does
/// not inspect key identity, text or position, and it never logs.
package struct SyntheticEventFilter: Equatable, Sendable {
  package enum Classification: Equatable, Sendable {
    case physical
    case synthetic(Reason)
  }

  package enum Reason: Equatable, Sendable {
    case marker
    case ownProcess
  }

  package let marker: Int64
  package let processID: Int64

  /// Returns `nil` for a zero marker (the physical default) or a
  /// non-positive process id.
  package init?(marker: Int64, processID: Int64) {
    guard marker != 0, processID > 0 else { return nil }
    self.marker = marker
    self.processID = processID
  }

  /// A filter with a random non-zero marker for this process.
  package static func live() -> SyntheticEventFilter {
    var generator = SystemRandomNumberGenerator()
    var marker: Int64 = 0
    while marker == 0 { marker = Int64.random(in: .min ... .max, using: &generator) }
    let pid = Int64(ProcessInfo.processInfo.processIdentifier)
    // A running process always has a positive id and the marker is non-zero.
    return SyntheticEventFilter(marker: marker, processID: pid)!
  }

  /// Marks an event this process is about to post.
  ///
  /// CoreGraphics ignores a second write of `eventSourceUserData` on the same
  /// event, so a tag can silently fail to apply; the own-process fallback
  /// covers that case. Injectors should tag exactly once, before posting.
  package func tag(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: marker)
  }

  package func classify(_ event: CGEvent) -> Classification {
    if event.getIntegerValueField(.eventSourceUserData) == marker {
      return .synthetic(.marker)
    }
    if event.getIntegerValueField(.eventSourceUnixProcessID) == processID {
      return .synthetic(.ownProcess)
    }
    return .physical
  }
}
