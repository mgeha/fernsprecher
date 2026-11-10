import Foundation
import os

/// Unified-logging channels (`log show --predicate 'subsystem == "de.1lov.fernsprecher"'`).
///
/// Error kinds, codes, PBX status labels, counts and durations are logged as
/// public. Free-text error messages (`localizedDescription`), which may
/// contain numbers, names or hosts, are logged as private.
public enum OxoLog {
    public static let subsystem = "de.1lov.fernsprecher"
    public static let events = Logger(subsystem: subsystem, category: "events")
    public static let session = Logger(subsystem: subsystem, category: "session")
}

extension ConnectionState {
    /// Name for logs; the failure message stays out.
    var diagnosticName: String {
        switch self {
        case .unconfigured: "unconfigured"
        case .connecting: "connecting"
        case .connected: "connected"
        case .failed: "failed"
        case .badPin: "badPin"
        case .sessionLost: "sessionLost"
        case .untrustedCertificate: "untrustedCertificate"
        }
    }
}

extension Error {
    /// Short classification for logs without the error's free text, e.g.
    /// `transport` or `status subscribe 4 UnknownUser`.
    public var diagnosticKind: String {
        switch self {
        case let error as OxoError:
            switch error {
            case .status(let operation, let code, let label): return "status \(operation) \(code) \(label)"
            case .badSession: return "badSession"
            case .badPassword: return "badPassword"
            case .emptyResponse(let operation): return "emptyResponse \(operation)"
            case .notLoggedIn: return "notLoggedIn"
            case .soapFault: return "soapFault"
            case .invalidResponse: return "invalidResponse"
            case .transport: return "transport"
            case .untrustedCertificate: return "untrustedCertificate"
            }
        case let error as URLError:
            return "url \(error.code.rawValue)"
        case is CancellationError:
            return "cancelled"
        default:
            let error = self as NSError
            return "\(error.domain) \(error.code)"
        }
    }
}
