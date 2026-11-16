#if os(Linux)
  import CX11
  import CXRandR
  import Foundation
  import KVMContracts
  import LinuxPlatform
  import Testing

  // M4-027 tests. The pure rules and the headless failure run everywhere on Linux. The `.x11`
  // tests start their own Xvfb (`-displayfd`, so the display number is free, and a fixed
  // 1600x900 screen with RANDR) instead of sharing the runner's display: one test resizes the
  // screen, and the other X11 suites run in parallel with this one.

  private let unavailable = CoreError(
    code: .lifecycle(.subsystemUnavailable), severity: .error, retryDisposition: .never,
    cleanupDisposition: .notRequired)

  private let invariant = CoreError(
    code: .protocolViolation(.invariantViolation), severity: .error, retryDisposition: .never,
    cleanupDisposition: .notRequired)

  private let capability = CoreError(
    code: .permission(.capabilityUnavailable), severity: .error, retryDisposition: .never,
    cleanupDisposition: .notRequired)

  @Suite("M4-027 Linux screen backend: geometry rules")
  struct LinuxScreenGeometryRulesTests {
    @Test("happy path: a 1600x900 screen with the pointer inside has origin (0, 0)")
    func happyPath() throws {
      let geometry = try LinuxScreenGeometryRules.geometry(
        width: 1600, height: 900, cursorX: 10, cursorY: 20
      ).get()
      #expect(
        geometry
          == PlatformScreenGeometry(
            originX: 0, originY: 0, width: 1600, height: 900, cursorX: 10, cursorY: 20))
    }

    @Test("boundary: 1x1 and the largest DINF size 0x7FFF are accepted")
    func boundarySizes() throws {
      #expect(LinuxScreenGeometryRules.maximumDimension == 0x7FFF)
      let smallest = try LinuxScreenGeometryRules.geometry(
        width: 1, height: 1, cursorX: 0, cursorY: 0
      ).get()
      #expect(smallest.width == 1 && smallest.height == 1)
      let largest = try LinuxScreenGeometryRules.geometry(
        width: 0x7FFF, height: 0x7FFF, cursorX: 0x7FFE, cursorY: 0x7FFE
      ).get()
      #expect(largest.width == 0x7FFF && largest.height == 0x7FFF)
      #expect(largest.cursorX == 0x7FFE && largest.cursorY == 0x7FFE)
    }

    @Test("invalid: a zero width or height fails with protocol.invariantViolation")
    func zeroSizeFails() {
      let zeroWidth = LinuxScreenGeometryRules.geometry(
        width: 0, height: 900, cursorX: 0, cursorY: 0)
      #expect(zeroWidth == .failure(invariant))
      let zeroHeight = LinuxScreenGeometryRules.geometry(
        width: 1600, height: 0, cursorX: 0, cursorY: 0)
      #expect(zeroHeight == .failure(invariant))
    }

    @Test("invalid: a width or height above 0x7FFF fails with protocol.invariantViolation")
    func oversizeFails() {
      let wide = LinuxScreenGeometryRules.geometry(
        width: 0x8000, height: 900, cursorX: 0, cursorY: 0)
      #expect(wide == .failure(invariant))
      let tall = LinuxScreenGeometryRules.geometry(
        width: 1600, height: 0x8000, cursorX: 0, cursorY: 0)
      #expect(tall == .failure(invariant))
      let negative = LinuxScreenGeometryRules.geometry(
        width: -1, height: 900, cursorX: 0, cursorY: 0)
      #expect(negative == .failure(invariant))
    }

    @Test("a change is a different origin or size; pointer movement alone is not one")
    func changeDefinition() {
      let base = PlatformScreenGeometry(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 1, cursorY: 2)
      let moved = PlatformScreenGeometry(
        originX: 0, originY: 0, width: 1600, height: 900, cursorX: 800, cursorY: 450)
      let wider = PlatformScreenGeometry(
        originX: 0, originY: 0, width: 1601, height: 900, cursorX: 1, cursorY: 2)
      let taller = PlatformScreenGeometry(
        originX: 0, originY: 0, width: 1600, height: 901, cursorX: 1, cursorY: 2)
      let shifted = PlatformScreenGeometry(
        originX: 1, originY: 0, width: 1600, height: 900, cursorX: 1, cursorY: 2)
      let lower = PlatformScreenGeometry(
        originX: 0, originY: 3, width: 1600, height: 900, cursorX: 1, cursorY: 2)
      #expect(!LinuxScreenGeometryRules.hasChanged(from: base, to: base))
      #expect(!LinuxScreenGeometryRules.hasChanged(from: base, to: moved))
      #expect(LinuxScreenGeometryRules.hasChanged(from: base, to: wider))
      #expect(LinuxScreenGeometryRules.hasChanged(from: base, to: taller))
      #expect(LinuxScreenGeometryRules.hasChanged(from: base, to: shifted))
      #expect(LinuxScreenGeometryRules.hasChanged(from: base, to: lower))
    }

    @Test("the errors are terminal and carry no cleanup")
    func errorShapes() {
      #expect(LinuxScreenError.subsystemUnavailable == unavailable)
      #expect(LinuxScreenError.invariantViolation == invariant)
      #expect(LinuxScreenError.capabilityUnavailable == capability)
      for error in [unavailable, invariant, capability] {
        #expect(!error.retryDisposition.allowsRetry)
      }
    }
  }

  @Suite("M4-027 Linux screen backend: headless failure")
  struct LinuxScreenBackendHeadlessTests {
    @Test("failure: a display that cannot be opened fails with lifecycle.subsystemUnavailable")
    func unreachableDisplay() {
      for name in [":4999", "not-a-display", "unix:/nonexistent/socket:0"] {
        do {
          _ = try LinuxScreenBackend(displayName: name)
          Issue.record("opened \(name)")
        } catch {
          #expect(error == unavailable)
        }
      }
    }
  }

  // MARK: - Xvfb harness

  private struct XvfbError: Error {}

  private final class PrivateXvfb: @unchecked Sendable {
    let displayName: String
    private let process: Process

    init(randr: Bool = true) throws {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "Xvfb", "-displayfd", "1", "-screen", "0", "1600x900x24",
        randr ? "+extension" : "-extension", "RANDR", "-nolisten", "tcp",
      ]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      try process.run()
      var received = Data()
      while !received.contains(10) {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty {
          process.terminate()
          throw XvfbError()
        }
        received.append(chunk)
      }
      let number = String(decoding: received, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard Int(number) != nil else {
        process.terminate()
        throw XvfbError()
      }
      self.process = process
      self.displayName = ":" + number
    }

    func stop() {
      // SIGKILL, then reap here. `Process.waitUntilExit()` can miss the exit of one of several
      // concurrent children in swift-corelibs-foundation and hang the test; `waitpid` returns
      // when the child is gone, or at once with ECHILD when Foundation already reaped it.
      kill(process.processIdentifier, SIGKILL)
      var status: Int32 = 0
      _ = waitpid(process.processIdentifier, &status, 0)
    }
  }

  /// A second X client the tests use to move the pointer and resize the screen.
  private final class XTestClient: @unchecked Sendable {
    private let display: OpaquePointer
    private let root: Window
    private var createdModes: [String: RRMode] = [:]

    init(displayName: String) throws {
      guard let display = XOpenDisplay(displayName) else { throw XvfbError() }
      self.display = display
      self.root = XDefaultRootWindow(display)
    }

    deinit {
      XCloseDisplay(display)
    }

    func warpPointer(x: Int, y: Int) {
      XWarpPointer(display, 0, root, 0, 0, 0, 0, Int32(x), Int32(y))
      XSync(display, 0)
    }

    /// Whether the server lets the screen shrink to this size.
    func canResize(toWidth width: Int, height: Int) -> Bool {
      var minWidth: Int32 = 0
      var minHeight: Int32 = 0
      var maxWidth: Int32 = 0
      var maxHeight: Int32 = 0
      guard
        XRRGetScreenSizeRange(display, root, &minWidth, &minHeight, &maxWidth, &maxHeight) != 0
      else { return false }
      let fitsWidth = Int32(width) >= minWidth && Int32(width) <= maxWidth
      let fitsHeight = Int32(height) >= minHeight && Int32(height) <= maxHeight
      return fitsWidth && fitsHeight
    }

    /// Shrinks the screen the way `xrandr` does: a mode of the new size on the output and the
    /// CRTC first (Xvfb refuses a screen smaller than a CRTC with BadMatch), then the screen
    /// size. Xvfb cannot grow past its starting size, and every new size must
    /// be no larger than the current one in both dimensions.
    func resize(toWidth width: Int, height: Int) {
      guard let resources = XRRGetScreenResources(display, root) else { return }
      defer { XRRFreeScreenResources(resources) }
      guard resources.pointee.noutput > 0, resources.pointee.ncrtc > 0,
        let outputs = resources.pointee.outputs, let crtcs = resources.pointee.crtcs
      else { return }
      // The server lists a user-defined mode only after it is attached to an output, and
      // creating the same name twice fails, so the client remembers the modes it made.
      var mode: RRMode = createdModes["\(width)x\(height)"] ?? 0
      if mode == 0 {
        var info = XRRModeInfo()
        info.width = UInt32(width)
        info.height = UInt32(height)
        info.hSyncStart = UInt32(width + 8)
        info.hSyncEnd = UInt32(width + 16)
        info.hTotal = UInt32(width + 32)
        info.vSyncStart = UInt32(height + 2)
        info.vSyncEnd = UInt32(height + 4)
        info.vTotal = UInt32(height + 8)
        info.dotClock = UInt(info.hTotal) * UInt(info.vTotal) * 60
        let name = "mackvm\(width)x\(height)"
        info.nameLength = UInt32(name.utf8.count)
        mode = name.withCString { pointer in
          info.name = UnsafeMutablePointer(mutating: pointer)
          return XRRCreateMode(display, root, &info)
        }
        XRRAddOutputMode(display, outputs[0], mode)
        createdModes["\(width)x\(height)"] = mode
      }
      var output = outputs[0]
      _ = XRRSetCrtcConfig(display, resources, crtcs[0], 0, 0, 0, mode, 1, &output, 1)
      let millimetersWide = Int32(Double(width) * 25.4 / 96.0)
      let millimetersHigh = Int32(Double(height) * 25.4 / 96.0)
      XRRSetScreenSize(display, root, Int32(width), Int32(height), millimetersWide, millimetersHigh)
      XSync(display, 0)
    }
  }

  private actor GeometryRecorder {
    private(set) var values: [PlatformScreenGeometry] = []
    private(set) var finished = false

    func add(_ value: PlatformScreenGeometry) { values.append(value) }
    func finish() { finished = true }
  }

  private func record(_ backend: LinuxScreenBackend) -> (GeometryRecorder, Task<Void, Never>) {
    let recorder = GeometryRecorder()
    let stream = backend.changes
    let task = Task {
      for await geometry in stream { await recorder.add(geometry) }
      await recorder.finish()
    }
    return (recorder, task)
  }

  private func eventually(
    seconds: Double = 15, _ condition: @Sendable () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
  }

  /// Opens a backend on the test server. Xvfb refuses an occasional connection when clients
  /// connect and disconnect in quick succession (a plain Xlib loop shows about 8 percent in
  /// the Linux container), which says nothing about the backend, so the harness retries a
  /// refused open. Only the open is retried; every behavior under test runs once.
  private func openBackend(_ server: PrivateXvfb) throws -> LinuxScreenBackend {
    var attempts = 0
    while true {
      do {
        return try LinuxScreenBackend(displayName: server.displayName)
      } catch {
        attempts += 1
        if attempts >= 8 { throw error }
      }
    }
  }

  private func openDescriptorCount() -> Int {
    (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").count) ?? 0
  }

  @Suite(
    "M4-027 Linux screen backend: X11 under Xvfb",
    .tags(.x11),
    .enabled(
      if: LinuxPlatformSkeleton.x11TestsEnabled(
        environment: ProcessInfo.processInfo.environment))
  )
  struct LinuxScreenBackendX11Tests {
    @Test("happy path: Xvfb 1600x900 reads as origin (0, 0), 1600x900")
    func geometryOfTheRootWindow() throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let geometry = try backend.currentGeometry().get()
      #expect(geometry.originX == 0 && geometry.originY == 0)
      #expect(geometry.width == 1600 && geometry.height == 900)
    }

    @Test("the pointer position follows XWarpPointer, corners included")
    func pointerPosition() throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let client = try XTestClient(displayName: server.displayName)
      for (x, y) in [(123, 456), (0, 0), (1599, 899), (800, 450)] {
        client.warpPointer(x: x, y: y)
        let geometry = try backend.currentGeometry().get()
        #expect(geometry.cursorX == x && geometry.cursorY == y)
        #expect(geometry.width == 1600 && geometry.height == 900)
      }
    }

    @Test("idempotent: stop() twice, then currentGeometry fails and changes has finished")
    func stopTwice() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let (recorder, task) = record(backend)
      await backend.stop()
      await backend.stop()
      #expect(backend.currentGeometry() == .failure(unavailable))
      let finished = await eventually { await recorder.finished }
      #expect(finished)
      task.cancel()
      await task.value
    }

    @Test("cancel and cleanup: concurrent stop() calls all return and the backend is closed")
    func concurrentStops() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
          group.addTask { await backend.stop() }
        }
      }
      #expect(backend.currentGeometry() == .failure(unavailable))
    }

    @Test("cancel: stop() releases a consumer that is waiting on changes")
    func stopReleasesWaitingConsumer() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let (recorder, task) = record(backend)
      #expect(await recorder.values.isEmpty)
      await backend.stop()
      let finished = await eventually { await recorder.finished }
      #expect(finished)
      task.cancel()
      await task.value
    }

    @Test("cleanup: creating and stopping a backend repeatedly does not leak descriptors")
    func noDescriptorLeak() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      // Warm up so one-time descriptors (locale, /proc) are not counted.
      let warmUp = try openBackend(server)
      await warmUp.stop()
      let before = openDescriptorCount()
      for _ in 0..<30 {
        let backend = try openBackend(server)
        await backend.stop()
      }
      let after = openDescriptorCount()
      // A leak costs at least two descriptors per backend (60 or more); other test suites
      // opening files in parallel move the count by a handful.
      #expect(after - before < 20)
    }

    @Test("a screen resize yields the new geometry, and pointer movement alone yields nothing")
    func resizeIsReported() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let client = try XTestClient(displayName: server.displayName)
      guard client.canResize(toWidth: 1280, height: 720) else {
        // Recorded in the summary: owner-E2E only on an X server that cannot resize.
        Issue.record("this Xvfb cannot resize the screen; the change path is owner-E2E only")
        return
      }
      let (recorder, task) = record(backend)
      // No currentGeometry() call first: the backend observes from its creation.
      client.warpPointer(x: 300, y: 200)
      client.warpPointer(x: 400, y: 250)
      client.resize(toWidth: 1280, height: 720)
      let seen = await eventually { await recorder.values.contains { $0.width == 1280 } }
      #expect(seen)
      let values = await recorder.values
      #expect(values.count == 1, "pointer movement alone must not be reported as a change")
      if let first = values.first {
        #expect(first.originX == 0 && first.originY == 0)
        #expect(first.width == 1280 && first.height == 720)
        #expect(first.cursorX == 400 && first.cursorY == 250)
      }
      #expect(try backend.currentGeometry().get().width == 1280)

      // The same size again is not a change; the next real change is still reported, and it
      // is the second value, so nothing was reported in between.
      client.resize(toWidth: 1280, height: 720)
      client.resize(toWidth: 1200, height: 700)
      let second = await eventually { await recorder.values.count >= 2 }
      #expect(second)
      let all = await recorder.values
      #expect(all.map { $0.width } == [1280, 1200])
      await backend.stop()
      task.cancel()
      await task.value
    }

    @Test("a consumer that falls behind receives the newest geometry")
    func newestGeometryWins() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let client = try XTestClient(displayName: server.displayName)
      guard client.canResize(toWidth: 1024, height: 640) else {
        Issue.record("this Xvfb cannot resize the screen; the change path is owner-E2E only")
        return
      }
      for (width, height) in [(1500, 850), (1400, 800), (1280, 720), (1024, 640)] {
        client.resize(toWidth: width, height: height)
      }
      // Nobody reads `changes` while the backend reports; give the event thread time to
      // report all four, then start consuming. The stream holds only the newest value.
      try await Task.sleep(for: .milliseconds(500))
      let (recorder, task) = record(backend)
      let ended = await eventually {
        await recorder.values.last.map { $0.width == 1024 && $0.height == 640 } ?? false
      }
      #expect(ended)
      for geometry in await recorder.values {
        #expect(geometry.width >= 1 && geometry.height >= 1)
      }
      await backend.stop()
      task.cancel()
      await task.value
    }

    @Test("failure: an X server without RandR fails with permission.capabilityUnavailable")
    func serverWithoutRandR() throws {
      let server = try PrivateXvfb(randr: false)
      defer { server.stop() }
      do {
        _ = try LinuxScreenBackend(displayName: server.displayName)
        Issue.record("opened a display without RandR")
      } catch {
        #expect(error == capability)
      }
    }

    @Test("failure: losing the X server finishes changes and fails currentGeometry, no crash")
    func serverLoss() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let (recorder, task) = record(backend)
      server.stop()
      let finished = await eventually { await recorder.finished }
      #expect(finished)
      #expect(backend.currentGeometry() == .failure(unavailable))
      await backend.stop()
      task.cancel()
      await task.value
    }

    @Test("no change is reported after stop(), even when the screen resizes")
    func nothingAfterStop() async throws {
      let server = try PrivateXvfb()
      defer { server.stop() }
      let backend = try openBackend(server)
      let client = try XTestClient(displayName: server.displayName)
      guard client.canResize(toWidth: 1280, height: 720) else {
        Issue.record("this Xvfb cannot resize the screen; the change path is owner-E2E only")
        return
      }
      let (recorder, task) = record(backend)
      await backend.stop()
      client.resize(toWidth: 1280, height: 720)
      let finished = await eventually { await recorder.finished }
      #expect(finished)
      #expect(await recorder.values.isEmpty)
      task.cancel()
      await task.value
    }
  }
#endif
