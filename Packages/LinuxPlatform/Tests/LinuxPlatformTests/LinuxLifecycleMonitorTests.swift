import Foundation
import KVMContracts
import LinuxPlatform
import Testing

// M4-020-FOLLOWUP-001: resume and network edge detection of the Linux lifecycle monitor, with
// injected clocks and network probes (plan b.16). No timer runs: every tick is explicit.

/// A settable clock offset and network state.
private final class FakeProbes: @unchecked Sendable {
  private let lock = NSLock()
  private var offset: Duration = .seconds(100)
  private var network = true
  private var networkReads = 0

  var probes: LinuxLifecycleProbes {
    LinuxLifecycleProbes(
      clockOffset: { [self] in lock.withLock { offset } },
      networkAvailable: { [self] in
        lock.withLock {
          networkReads += 1
          return network
        }
      })
  }

  func advanceOffset(by delta: Duration) { lock.withLock { offset += delta } }
  func setNetwork(_ available: Bool) { lock.withLock { network = available } }
  var reads: Int { lock.withLock { networkReads } }
}

/// Collects what the monitor yielded until `stop()` finishes the stream.
private func collect(_ monitor: LinuxLifecycleMonitor) async -> [LifecycleSignal] {
  monitor.stop()
  var seen: [LifecycleSignal] = []
  for await signal in monitor.signals { seen.append(signal) }
  return seen
}

@Suite("M4-020-FOLLOWUP-001 Linux lifecycle monitor", .timeLimit(.minutes(1)))
struct LinuxLifecycleMonitorTests {
  @Test("a boot-time jump over 5 s between ticks is one resume; smaller drift is not")
  func resumeDetector() {
    var detector = LinuxResumeDetector()
    #expect(detector.observe(offset: .seconds(10)) == false)
    #expect(detector.observe(offset: .seconds(10)) == false)
    #expect(detector.observe(offset: .seconds(15)) == false)
    #expect(detector.observe(offset: .milliseconds(20_001)) == true)
    #expect(detector.observe(offset: .milliseconds(20_001)) == false)
    #expect(detector.observe(offset: .seconds(3_600)) == true)
  }

  @Test("network samples make edges only on change, never on the baseline")
  func networkEdges() {
    var detector = LinuxNetworkEdgeDetector()
    #expect(detector.observe(available: false) == nil)
    #expect(detector.observe(available: false) == nil)
    #expect(detector.observe(available: true) == .networkAvailable)
    #expect(detector.observe(available: true) == nil)
    #expect(detector.observe(available: false) == .networkUnavailable)
  }

  @Test("the monitor yields didResume for a suspend seen through the clocks")
  func monitorResume() async {
    let fake = FakeProbes()
    let monitor = LinuxLifecycleMonitor(probes: fake.probes, armsTimers: false)
    monitor.tickResume()
    monitor.start()
    monitor.tickResume()
    fake.advanceOffset(by: .seconds(2))
    monitor.tickResume()
    fake.advanceOffset(by: .seconds(90))
    monitor.tickResume()
    monitor.tickResume()
    #expect(await collect(monitor) == [.didResume])
  }

  @Test("network edges are polled only while armed, and the poll takes a fresh baseline")
  func monitorNetwork() async {
    let fake = FakeProbes()
    let monitor = LinuxLifecycleMonitor(probes: fake.probes, armsTimers: false)
    monitor.start()
    fake.setNetwork(false)
    monitor.tickNetwork()
    #expect(fake.reads == 0)
    #expect(monitor.isPollingNetwork == false)

    monitor.setNetworkPolling(true)
    #expect(monitor.isPollingNetwork)
    monitor.tickNetwork()
    fake.setNetwork(true)
    monitor.tickNetwork()
    fake.setNetwork(false)
    monitor.tickNetwork()
    monitor.setNetworkPolling(false)
    fake.setNetwork(true)
    monitor.tickNetwork()
    #expect(monitor.isNetworkAvailable)
    #expect(await collect(monitor) == [.networkAvailable, .networkUnavailable])
  }

  @Test("stop is idempotent, finishes the stream and silences every tick")
  func stopSilences() async {
    let fake = FakeProbes()
    let monitor = LinuxLifecycleMonitor(probes: fake.probes, armsTimers: false)
    monitor.start()
    monitor.setNetworkPolling(true)
    monitor.stop()
    monitor.stop()
    fake.advanceOffset(by: .seconds(60))
    fake.setNetwork(false)
    monitor.tickResume()
    monitor.tickNetwork()
    monitor.setNetworkPolling(true)
    #expect(monitor.isPollingNetwork == false)
    #expect(await collect(monitor) == [])
  }

  @Test("the live probes read the system without failing")
  func liveProbes() {
    let first = LinuxSystemProbes.clockOffset()
    let second = LinuxSystemProbes.clockOffset()
    #expect(first > .seconds(-1))
    #expect(second - first < .seconds(1))
    _ = LinuxSystemProbes.network()
  }
}
