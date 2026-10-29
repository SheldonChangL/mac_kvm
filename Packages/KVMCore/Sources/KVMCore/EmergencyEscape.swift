import KVMContracts

/// The fixed emergency escape gesture frozen by the proposed M2-001:
/// Control + Option + Command + Delete (Backspace), or + Return. On the owner's
/// Mac (macOS 26.6.2, 2026-10-28) the system never delivers Delete with all
/// three modifiers to a session event tap, while Return arrives, so Return is
/// accepted as well (M2-035 owner run).
///
/// Detection is a pure function of one `KVMEvent`, so the capture owner can
/// evaluate it synchronously before suppression is applied, with no network,
/// thread or remote acknowledgement involved. The resulting
/// `InputAction.emergencyEscape` makes `InputStateReducer` reach `local` from
/// every state in one step; remote sends during escape are best effort only.
package enum EmergencyEscape {
  /// Returns `.emergencyEscape` for the chord's key down, otherwise `nil`.
  ///
  /// Shift and Caps Lock are ignored so the gesture works regardless of them.
  package static func action(for event: KVMEvent) -> InputAction? {
    guard case .key(_, .down, _) = event, isChordKey(event) else { return nil }
    return .emergencyEscape
  }

  /// True for any phase of the chord key while the chord modifiers are held.
  ///
  /// The owner must not forward these events to a remote target.
  package static func isChordKey(_ event: KVMEvent) -> Bool {
    guard case .key(let key, _, let modifiers) = event, key == .backspace || key == .enter
    else { return false }
    return modifiers.control && modifiers.option && modifiers.command
  }
}
