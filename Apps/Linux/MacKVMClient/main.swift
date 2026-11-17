import Dispatch
import Foundation
import Glibc
import LinuxPlatform
import NIOPosix

// M4-020-FOLLOWUP-001: `mackvm-client`, the first-party Barrier-compatible client for Linux
// (X11). The command dispatch and the composition root live in ClientRuntime.swift; this file
// only builds the live process and exits with the code it returns.

/// Reads one line from standard input on a dedicated thread, never on the cooperative pool.
@Sendable func readAnswer() async -> String? {
  await withCheckedContinuation { continuation in
    Thread { continuation.resume(returning: readLine(strippingNewline: true)) }.start()
  }
}

let output = ClientStandardOutput()
let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
let signalQueue = DispatchQueue(label: "mackvm.signals")
nonisolated(unsafe) var signalSources: [any DispatchSourceSignal] = []

let process = ClientProcess(
  variables: ProcessInfo.processInfo.environment,
  effectiveUserID: geteuid(),
  stdinIsTerminal: isatty(STDIN_FILENO) == 1,
  output: output,
  trustStore: LinuxTrustedServerStore(),
  connector: { ClientTLSConnector(server: $0, group: group) },
  xlib: ClientXlib(),
  factory: .live,
  prompt: readAnswer,
  runtimeStarted: { runtime in
    // SIGINT, SIGTERM and SIGHUP end through the one cleanup (plan b.16).
    signalQueue.sync {
      signalSources = [SIGINT, SIGTERM, SIGHUP].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: signalQueue)
        source.setEventHandler { runtime.requestTermination(signal: number) }
        source.resume()
        return source
      }
    }
  })

let arguments = Array(CommandLine.arguments.dropFirst())
Task {
  let code = await ClientMain.run(arguments, process: process)
  output.flush()
  exit(code.rawValue)
}
dispatchMain()
