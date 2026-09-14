import Foundation

public struct CertificateFingerprint: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public enum StoredTrustState: Codable, Equatable, Sendable {
    case unknown
    case trusted(CertificateFingerprint)
    case revoked
}

public enum TrustDecision: Codable, Equatable, Sendable {
    case prompt(CertificateFingerprint)
    case allow
    case rejectChanged(previous: CertificateFingerprint, presented: CertificateFingerprint)
    case rejectRevoked
}

public protocol TrustPolicyEvaluating: Sendable {
    func evaluate(stored: StoredTrustState, presented: CertificateFingerprint) -> TrustDecision
}
