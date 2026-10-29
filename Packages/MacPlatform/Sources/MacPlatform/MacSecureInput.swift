// Secure event input (for example a password field, or a terminal with Secure
// Keyboard Entry) makes macOS deliver keys only to the app that asked for it, past
// every event tap. A server forwarding keys would then lose them to that app, so
// while it is active input must stay local.

import Carbon

package enum MacSecureInput {
  /// Whether any process has secure event input enabled.
  package static var isEnabled: Bool {
    IsSecureEventInputEnabled()
  }
}
