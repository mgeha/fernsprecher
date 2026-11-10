import Foundation

public enum OxoError: Error, Sendable, Equatable {
    /// Non-OK `AlcStatus` returned by the PBX.
    case status(operation: String, code: Int, label: String)
    /// `55 BadSessionId`: the session expired or another client logged in on
    /// the same line (the OXO allows only one session per line).
    case badSession
    /// `8 BadPassword`.
    case badPassword
    /// The R63 answers operations it does not implement for this line with an
    /// empty `<…Response/>` and silently does nothing.
    case emptyResponse(operation: String)
    case notLoggedIn
    case soapFault(String)
    case invalidResponse(String)
    case transport(String)
    /// The PBX's certificate was refused by the ``TrustPolicy``; carries its
    /// SHA-256 fingerprint.
    case untrustedCertificate(String)
}

/// Shown to the user; looked up in the main bundle, so the app shows its
/// translation and `oxoctl` (no translations) the English text.
extension OxoError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .status(let operation, let code, let label):
            return String(localized: "\(operation) failed: \(code) \(label)")
        case .badSession:
            return String(localized: "Session invalid (expired or taken over by another client)")
        case .badPassword:
            return String(localized: "Wrong extension or PIN")
        case .emptyResponse(let operation):
            return String(localized: "\(operation) is not supported by the PBX")
        case .notLoggedIn:
            return String(localized: "Not logged in")
        case .soapFault(let text):
            return String(localized: "SOAP fault: \(text)")
        case .invalidResponse(let text):
            return String(localized: "Invalid response from the PBX: \(text)")
        case .transport(let text):
            return String(localized: "Connection failed: \(text)")
        case .untrustedCertificate:
            return String(localized: "PBX certificate rejected")
        }
    }
}
