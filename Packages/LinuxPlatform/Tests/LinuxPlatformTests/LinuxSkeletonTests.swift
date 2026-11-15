import Foundation
import LinuxPlatform
import Testing

extension Tag {
  /// Tests that need a live X server. `make verify-linux` runs them under `xvfb-run` with
  /// `MACKVM_X11_TESTS=1`; every other run skips them (headless test mode).
  @Tag static var x11: Self
}

@Suite("M4-020 Linux skeleton: display-server detection")
struct LinuxDisplayDetectionTests {
  @Test("an X11 session with DISPLAY set is x11")
  func x11Session() {
    #expect(LinuxDisplayEnvironment.detect(environment: ["DISPLAY": ":0"]) == .x11)
    let typed = ["DISPLAY": ":1", "XDG_SESSION_TYPE": "x11"]
    #expect(LinuxDisplayEnvironment.detect(environment: typed) == .x11)
  }

  @Test("WAYLAND_DISPLAY makes the session wayland, even with an XWayland DISPLAY")
  func waylandDisplay() {
    let alone = ["WAYLAND_DISPLAY": "wayland-0"]
    #expect(LinuxDisplayEnvironment.detect(environment: alone) == .wayland)
    let withXWayland = ["WAYLAND_DISPLAY": "wayland-0", "DISPLAY": ":0"]
    #expect(LinuxDisplayEnvironment.detect(environment: withXWayland) == .wayland)
  }

  @Test("XDG_SESSION_TYPE=wayland makes the session wayland, whatever its case")
  func waylandSessionType() {
    for value in ["wayland", "Wayland", "WAYLAND"] {
      let environment = ["XDG_SESSION_TYPE": value, "DISPLAY": ":0"]
      #expect(LinuxDisplayEnvironment.detect(environment: environment) == .wayland)
    }
  }

  @Test("nothing set is headless")
  func nothingSet() {
    #expect(LinuxDisplayEnvironment.detect(environment: [:]) == .headless)
  }

  @Test("empty and blank values count as unset")
  func blankValues() {
    #expect(LinuxDisplayEnvironment.detect(environment: ["DISPLAY": ""]) == .headless)
    #expect(LinuxDisplayEnvironment.detect(environment: ["DISPLAY": "  \t"]) == .headless)
    let emptyWayland = ["WAYLAND_DISPLAY": "", "DISPLAY": ":0"]
    #expect(LinuxDisplayEnvironment.detect(environment: emptyWayland) == .x11)
  }

  @Test("XDG_SESSION_TYPE=x11 without DISPLAY is headless: there is nothing to connect to")
  func x11TypeWithoutDisplay() {
    let environment = ["XDG_SESSION_TYPE": "x11"]
    #expect(LinuxDisplayEnvironment.detect(environment: environment) == .headless)
  }

  @Test("unknown session types fall back to the DISPLAY rule")
  func unknownSessionType() {
    let tty = ["XDG_SESSION_TYPE": "tty"]
    #expect(LinuxDisplayEnvironment.detect(environment: tty) == .headless)
    let mir = ["XDG_SESSION_TYPE": "mir", "DISPLAY": ":0"]
    #expect(LinuxDisplayEnvironment.detect(environment: mir) == .x11)
  }

  @Test("unrelated variables do not change the answer")
  func unrelatedVariables() {
    let environment = ["HOME": "/home/user", "TERM": "xterm", "DISPLAY_NAME": ":0"]
    #expect(LinuxDisplayEnvironment.detect(environment: environment) == .headless)
  }

  @Test("detection is deterministic")
  func deterministic() {
    let environment = ["DISPLAY": ":0", "XDG_SESSION_TYPE": "x11"]
    let answers = (0..<100).map { _ in LinuxDisplayEnvironment.detect(environment: environment) }
    #expect(Set(answers) == [.x11])
  }

  @Test("only x11 is supported by this toolchain lock")
  func supportedServers() {
    #expect(LinuxDisplayServer.x11.isSupported)
    #expect(!LinuxDisplayServer.wayland.isSupported)
    #expect(!LinuxDisplayServer.headless.isSupported)
    #expect(Set(LinuxDisplayServer.allCases) == [.x11, .wayland, .headless])
  }
}

@Suite("M4-020 Linux skeleton: headless test mode")
struct LinuxHeadlessTestModeTests {
  @Test("X11 tests run only when MACKVM_X11_TESTS is exactly 1")
  func x11TestsFlag() {
    #expect(LinuxPlatformSkeleton.x11TestsEnabled(environment: ["MACKVM_X11_TESTS": "1"]))
    for value in ["", "0", "true", "yes", " 1", "1 ", "01"] {
      let environment = ["MACKVM_X11_TESTS": value]
      #expect(!LinuxPlatformSkeleton.x11TestsEnabled(environment: environment))
    }
    #expect(!LinuxPlatformSkeleton.x11TestsEnabled(environment: [:]))
  }

  @Test(
    "the X11 gate sees a display when it is enabled",
    .tags(.x11),
    .enabled(
      if: LinuxPlatformSkeleton.x11TestsEnabled(
        environment: ProcessInfo.processInfo.environment))
  )
  func x11GateSeesDisplay() {
    let environment = ProcessInfo.processInfo.environment
    #expect(LinuxDisplayEnvironment.detect(environment: environment) == .x11)
  }
}

@Suite("M4-020 Linux skeleton: toolchain lock")
struct LinuxToolchainLockTests {
  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // LinuxPlatformTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // LinuxPlatform
    .deletingLastPathComponent()  // Packages
    .deletingLastPathComponent()

  static func lockLinuxSection() throws -> [String: Any] {
    let url = repositoryRoot.appendingPathComponent(
      "MacKVM_Implementation_Package_v2/toolchain.m4.lock.json")
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    let root = try #require(object as? [String: Any])
    return try #require(root["linux"] as? [String: Any])
  }

  @Test("the constants mirror the LOCK file exactly")
  func constantsMatchLock() throws {
    let linux = try Self.lockLinuxSection()
    let lock = LinuxPlatformSkeleton.toolchainLock
    #expect(linux["status"] as? String == "LOCKED")
    #expect(linux["language"] as? String == lock.language)
    #expect(linux["build_image"] as? String == lock.buildImage)
    let target = try #require(linux["target"] as? [String: String])
    #expect(target["os"] == lock.targetOS)
    #expect(target["architecture"] == lock.architecture)
    #expect(target["display_server"] == lock.displayServer)
    #expect(linux["swift_dependencies"] as? [String: String] == lock.swiftDependencies)
    #expect(linux["system_libraries"] as? [String] == lock.systemLibraries)
  }

  @Test("the root manifest pins every LOCK dependency with exact:")
  func manifestPinsExactVersions() throws {
    let manifestURL = Self.repositoryRoot.appendingPathComponent("Package.swift")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    for (name, version) in LinuxPlatformSkeleton.toolchainLock.swiftDependencies {
      let pin = "github.com/apple/\(name).git\", exact: \"\(version)\""
      #expect(manifest.contains(pin), "Package.swift must pin \(name) at exactly \(version)")
    }
  }

  @Test("the lock targets X11 on x86_64 Ubuntu 22.04")
  func lockTargetsX11() {
    let lock = LinuxPlatformSkeleton.toolchainLock
    #expect(lock.displayServer == "X11")
    #expect(lock.architecture == "x86_64")
    #expect(lock.targetOS == "Ubuntu 22.04")
    #expect(lock.buildImage.hasPrefix("swift:6.2.3-jammy@sha256:"))
  }
}
