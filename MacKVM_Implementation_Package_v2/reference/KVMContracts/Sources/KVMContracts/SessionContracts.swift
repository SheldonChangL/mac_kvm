import Foundation

public enum DisconnectReason: Codable, Equatable, Sendable {
    case userRequested
    case transportClosed
    case protocolError(String)
    case securityRejected(String)
    case timeout
    case applicationTermination
}

public protocol KVMProtocolSession: Sendable {
    var events: AsyncThrowingStream<KVMEvent, Error> { get }
    func connect() async throws
    func send(_ event: KVMEvent) async throws
    func disconnect(reason: DisconnectReason) async
}

public protocol Transport: Sendable {
    var incomingBytes: AsyncThrowingStream<Data, Error> { get }
    func connect() async throws
    func send(_ data: Data) async throws
    func disconnect() async
}

public protocol KVMClock: Sendable {
    func sleep(for duration: Duration) async throws
}
