import Dispatch
import Foundation
import Glibc
import KVMContracts

// M4-020-FOLLOWUP-001: the Linux lifecycle monitor (C-015 `LifecycleBackend`, plan b.16,
// decision 12). First-party policy:
//
// - No D-Bus, no logind and no netlink in this cut. A resume is seen as a jump of
//   `CLOCK_BOOTTIME − CLOCK_MONOTONIC`: both clocks advance together while the machine runs, and
//   only the boot-time clock advances while it is suspended. A jump of more than 5 s between two
//   one-second ticks yields `didResume`. `willSuspend` is never yielded: without logind the
//   client cannot see a suspend coming, so a sleep is handled by the keepalive timeout and the
//   cleanup of the dead stream (plan f.10).
// - Network availability is "some interface that is up and not loopback has an IPv4 or IPv6
//   address" (`getifaddrs`). It is polled every 2 s, and only while the owner asks for it (while
//   a reconnect is waiting); a change between two polls yields `networkAvailable` or
//   `networkUnavailable`.
// - The decisions are pure values, driven by injected clocks and probes in tests. Nothing here
//   logs, and no interface name or address leaves `getifaddrs`.

/// Detects a resume from the offset between the boot-time clock and the monotonic clock.
package struct LinuxResumeDetector: Equatable, Sendable {
  /// A jump of more than this between two samples is a resume.
  package static let defaultThreshold: Duration = .seconds(5)

  private let threshold: Duration
  private var lastOffset: Duration?

  package init(threshold: Duration = LinuxResumeDetector.defaultThreshold) {
    self.threshold = threshold
  }

  /// Records one sample of `CLOCK_BOOTTIME − CLOCK_MONOTONIC` and answers whether it grew by
  /// more than the threshold since the previous sample. The first sample is the baseline.
  package mutating func observe(offset: Duration) -> Bool {
    defer { lastOffset = offset }
    guard let lastOffset else { return false }
    return offset - lastOffset > threshold
  }
}

/// Turns network availability samples into edges.
package struct LinuxNetworkEdgeDetector: Equatable, Sendable {
  private var last: Bool?

  package init() {}

  /// The edge a sample makes, or `nil` when it equals the previous one. The first sample is
  /// the baseline and makes no edge.
  package mutating func observe(available: Bool) -> LifecycleSignal? {
    defer { last = available }
    guard let last, last != available else { return nil }
    return available ? .networkAvailable : .networkUnavailable
  }
}

/// The process's view of the two clocks and the network, injected so tests can drive them.
package struct LinuxLifecycleProbes: Sendable {
  /// `CLOCK_BOOTTIME − CLOCK_MONOTONIC`.
  package var clockOffset: @Sendable () -> Duration
  /// Whether a non-loopback interface that is up has an address.
  package var networkAvailable: @Sendable () -> Bool

  package init(
    clockOffset: @escaping @Sendable () -> Duration,
    networkAvailable: @escaping @Sendable () -> Bool
  ) {
    self.clockOffset = clockOffset
    self.networkAvailable = networkAvailable
  }

  /// The running system: `clock_gettime` and `getifaddrs`.
  package static var live: Self {
    Self(clockOffset: LinuxSystemProbes.clockOffset, networkAvailable: LinuxSystemProbes.network)
  }
}

/// The live probes.
package enum LinuxSystemProbes {
  /// `CLOCK_BOOTTIME − CLOCK_MONOTONIC`, or zero when a clock cannot be read (no jump is then
  /// ever seen, which only delays a resume until the keepalive notices it).
  package static func clockOffset() -> Duration {
    var boot = timespec()
    var monotonic = timespec()
    guard clock_gettime(CLOCK_BOOTTIME, &boot) == 0,
      clock_gettime(CLOCK_MONOTONIC, &monotonic) == 0
    else { return .zero }
    return duration(boot) - duration(monotonic)
  }

  /// Whether some interface that is up and not loopback has an IPv4 or IPv6 address. A failing
  /// `getifaddrs` counts as available, so the monitor never holds back a reconnect it cannot
  /// judge.
  package static func network() -> Bool {
    var list: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&list) == 0, let first = list else { return true }
    defer { freeifaddrs(list) }
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let entry = cursor {
      defer { cursor = entry.pointee.ifa_next }
      let flags = Int32(bitPattern: entry.pointee.ifa_flags)
      guard flags & Int32(IFF_UP) != 0, flags & Int32(IFF_LOOPBACK) == 0,
        let address = entry.pointee.ifa_addr
      else { continue }
      let family = Int32(address.pointee.sa_family)
      if family == AF_INET || family == AF_INET6 { return true }
    }
    return false
  }

  private static func duration(_ value: timespec) -> Duration {
    .seconds(Int64(value.tv_sec)) + .nanoseconds(Int64(value.tv_nsec))
  }
}

/// The Linux `LifecycleBackend`: resume by clock jump, network edges by polling.
///
/// `start()` arms a 1 s resume timer; `setNetworkPolling(_:)` arms or disarms the 2 s network
/// poll. `stop()` disarms both and finishes `signals`; it is idempotent, and nothing is yielded
/// after it. `tick(...)` methods are the timers' bodies, callable directly by tests.
package final class LinuxLifecycleMonitor: LifecycleBackend, @unchecked Sendable {
  package static let resumeInterval: Duration = .seconds(1)
  package static let networkInterval: Duration = .seconds(2)

  package let signals: AsyncStream<LifecycleSignal>
  private let continuation: AsyncStream<LifecycleSignal>.Continuation
  private let probes: LinuxLifecycleProbes
  private let queue = DispatchQueue(label: "mackvm.lifecycle")
  private let lock = NSLock()
  private var resume: LinuxResumeDetector
  private var network = LinuxNetworkEdgeDetector()
  private var resumeTimer: (any DispatchSourceTimer)?
  private var networkTimer: (any DispatchSourceTimer)?
  private var started = false
  private var pollingNetwork = false
  private var stopped = false
  private let armsTimers: Bool

  /// `armsTimers` false is a test seam: nothing ticks by itself, and the test calls `tick...`.
  package init(
    probes: LinuxLifecycleProbes = .live,
    resumeThreshold: Duration = LinuxResumeDetector.defaultThreshold,
    armsTimers: Bool = true
  ) {
    self.probes = probes
    self.armsTimers = armsTimers
    resume = LinuxResumeDetector(threshold: resumeThreshold)
    (signals, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
  }

  deinit {
    resumeTimer?.cancel()
    networkTimer?.cancel()
  }

  /// The current network availability, read now. The composition root reports it before each
  /// wake (plan h.3).
  package var isNetworkAvailable: Bool { probes.networkAvailable() }

  /// Takes the clock baseline and arms the 1 s resume timer. Idempotent.
  package func start() {
    let timer = lock.withLock { () -> (any DispatchSourceTimer)? in
      guard !stopped, !started else { return nil }
      started = true
      _ = resume.observe(offset: probes.clockOffset())
      guard armsTimers else { return nil }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      resumeTimer = timer
      return timer
    }
    guard let timer else { return }
    timer.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
    timer.setEventHandler { [weak self] in self?.tickResume() }
    timer.resume()
  }

  /// Arms (`true`) or disarms (`false`) the 2 s network poll. Arming takes a baseline sample
  /// first, so an edge is a change seen while polling. Idempotent.
  package func setNetworkPolling(_ enabled: Bool) {
    typealias Change = (arm: (any DispatchSourceTimer)?, disarm: (any DispatchSourceTimer)?)
    let change = lock.withLock { () -> Change in
      guard !stopped, enabled != pollingNetwork else { return (nil, nil) }
      pollingNetwork = enabled
      guard enabled else {
        defer { networkTimer = nil }
        return (nil, networkTimer)
      }
      network = LinuxNetworkEdgeDetector()
      _ = network.observe(available: probes.networkAvailable())
      guard armsTimers else { return (nil, nil) }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      networkTimer = timer
      return (timer, nil)
    }
    change.disarm?.cancel()
    guard let timer = change.arm else { return }
    timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
    timer.setEventHandler { [weak self] in self?.tickNetwork() }
    timer.resume()
  }

  /// Whether the network poll is armed. Read by tests.
  package var isPollingNetwork: Bool { lock.withLock { pollingNetwork } }

  /// One resume check: yields `didResume` when the clock offset jumped. Does nothing before
  /// `start()` or after `stop()`.
  package func tickResume() {
    let resumed = lock.withLock { () -> Bool in
      guard !stopped, started else { return false }
      return resume.observe(offset: probes.clockOffset())
    }
    if resumed { continuation.yield(.didResume) }
  }

  /// One network poll: yields the edge, if any. Does nothing while the poll is disarmed.
  package func tickNetwork() {
    let edge = lock.withLock { () -> LifecycleSignal? in
      guard !stopped, pollingNetwork else { return nil }
      return network.observe(available: probes.networkAvailable())
    }
    if let edge { continuation.yield(edge) }
  }

  package func stop() {
    let timers = lock.withLock { () -> [any DispatchSourceTimer] in
      guard !stopped else { return [] }
      stopped = true
      pollingNetwork = false
      defer {
        resumeTimer = nil
        networkTimer = nil
      }
      return [resumeTimer, networkTimer].compactMap { $0 }
    }
    for timer in timers { timer.cancel() }
    continuation.finish()
  }
}
