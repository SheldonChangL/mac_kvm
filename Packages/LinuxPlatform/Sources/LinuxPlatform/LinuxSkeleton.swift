// M4-020: the LinuxPlatform skeleton.
//
// - Display-server detection reads only environment variables. It never links or opens X11,
//   so it is safe in headless processes, tests and systemd units.
// - X11 and Wayland are separate capabilities. The toolchain lock supports X11 only; a
//   Wayland session is reported as such so callers refuse it instead of half-working through
//   XWayland.
// - The toolchain lock constants mirror MacKVM_Implementation_Package_v2/toolchain.m4.lock.json.
//   A test compares them with the file, so drift fails the build (the lock's FAIL_CLOSED rule).

/// The display server a Linux process can reach.
package enum LinuxDisplayServer: String, CaseIterable, Hashable, Sendable {
  /// An X11 session with a `DISPLAY` to connect to.
  case x11
  /// A Wayland session (`WAYLAND_DISPLAY` or `XDG_SESSION_TYPE=wayland`), even when XWayland
  /// also provides a `DISPLAY`.
  case wayland
  /// No display server: a console, an SSH session or a test run without Xvfb.
  case headless

  /// Whether this build's X11 backends can serve this display server. Only X11 is locked.
  package var isSupported: Bool {
    self == .x11
  }
}

/// Detects the display server from the process environment.
package enum LinuxDisplayEnvironment {
  package static let displayVariable = "DISPLAY"
  package static let waylandDisplayVariable = "WAYLAND_DISPLAY"
  package static let sessionTypeVariable = "XDG_SESSION_TYPE"

  /// Rules, in order (first-party policy):
  /// 1. a non-blank `WAYLAND_DISPLAY`, or `XDG_SESSION_TYPE` equal to `wayland` in any case,
  ///    is `.wayland`;
  /// 2. a non-blank `DISPLAY` is `.x11`;
  /// 3. anything else is `.headless`, including `XDG_SESSION_TYPE=x11` without a `DISPLAY`.
  /// Empty and whitespace-only values count as unset; other session types are ignored.
  package static func detect(environment: [String: String]) -> LinuxDisplayServer {
    let sessionType = value(sessionTypeVariable, in: environment)?.lowercased()
    if value(waylandDisplayVariable, in: environment) != nil || sessionType == "wayland" {
      return .wayland
    }
    if value(displayVariable, in: environment) != nil {
      return .x11
    }
    return .headless
  }

  private static func value(_ name: String, in environment: [String: String]) -> String? {
    guard let raw = environment[name] else {
      return nil
    }
    let isBlank = raw.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" }
    return isBlank ? nil : raw
  }
}

/// The Linux fields of the toolchain lock that the build depends on.
package struct LinuxToolchainLock: Equatable, Sendable {
  package let language: String
  package let buildImage: String
  package let targetOS: String
  package let architecture: String
  package let displayServer: String
  package let swiftDependencies: [String: String]
  package let systemLibraries: [String]
}

package enum LinuxPlatformSkeleton {
  /// Mirrors `linux` in `MacKVM_Implementation_Package_v2/toolchain.m4.lock.json`.
  package static let toolchainLock = LinuxToolchainLock(
    language: "Swift 6.2.3",
    buildImage:
      "swift:6.2.3-jammy@sha256:33c73fc133767cdaafde26f0f9967c96ab25ff77618b7df1eabf46140bf2b6e6",
    targetOS: "Ubuntu 22.04",
    architecture: "x86_64",
    displayServer: "X11",
    swiftDependencies: [
      "swift-nio": "2.104.0",
      "swift-nio-ssl": "2.37.5",
      "swift-crypto": "3.15.1",
      "swift-asn1": "1.7.3",
      "swift-atomics": "1.3.1",
      "swift-collections": "1.7.5",
      "swift-system": "1.8.1",
    ],
    systemLibraries: ["libX11", "libXtst", "libXrandr", "libXfixes"]
  )

  /// The environment variable that enables tests tagged `.x11`.
  package static let x11TestsVariable = "MACKVM_X11_TESTS"

  /// Headless test mode is the default: X11 tests run only when the variable is exactly `1`,
  /// which `make verify-linux` sets under `xvfb-run`.
  package static func x11TestsEnabled(environment: [String: String]) -> Bool {
    environment[x11TestsVariable] == "1"
  }
}
