// Spike only: connect with TLS, compute the leaf certificate's SHA-256 in a
// custom verification callback (the pinning hook), print only its length.
import Crypto
import Foundation
import NIOCore
import NIOPosix
import NIOSSL

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
var configuration = TLSConfiguration.makeClientConfiguration()
configuration.minimumTLSVersion = .tlsv12
let context = try NIOSSLContext(configuration: configuration)
final class Seen: @unchecked Sendable {
  private let lock = NSLock()
  private var hex = ""
  func set(_ value: String) { lock.withLock { hex = value } }
  var count: Int { lock.withLock { hex.count } }
}
let seen = Seen()
let channel = try ClientBootstrap(group: group)
  .channelInitializer { channel in
    channel.eventLoop.makeCompletedFuture {
      let handler = try NIOSSLClientHandler(
        context: context, serverHostname: "github.com",
        customVerificationCallback: { certificates, promise in
          guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
            promise.succeed(.failed)
            return
          }
          let hex = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
          seen.set(hex)
          promise.succeed(.certificateVerified)
        })
      try channel.pipeline.syncOperations.addHandler(handler)
    }
  }
  .connect(host: "github.com", port: 443).wait()
try channel.writeAndFlush(ByteBuffer(string: "HEAD / HTTP/1.0\r\nHost: github.com\r\n\r\n")).wait()
try await Task.sleep(for: .seconds(2))
print("tls handshake done; leaf sha256 hex length:", seen.count)
try? channel.close().wait()
try await group.shutdownGracefully()
