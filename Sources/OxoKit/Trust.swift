import CryptoKit
import Foundation
import Security

/// How the PBX's certificate is checked.
public enum TrustPolicy: Equatable, Sendable {
    /// macOS validation: the certificate must chain to a CA this Mac trusts.
    case system
    /// Only the certificate with this SHA-256 fingerprint (lower-case hex, see
    /// ``CertificateFingerprint``). nil: trust on first use – the first
    /// certificate seen is accepted and then fixed for the transport.
    case pinned(String?)
    case any
}

/// SHA-256 over the DER-encoded server certificate, as lower-case hex – the
/// value `openssl x509 -fingerprint -sha256` and browsers show.
public enum CertificateFingerprint {
    public static func sha256(_ der: Data) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Of the server's own (leaf) certificate.
    static func of(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        return sha256(SecCertificateCopyData(leaf) as Data)
    }

    /// Lower-case hex, or nil unless `text` is a SHA-256 fingerprint. Accepts
    /// colons and spaces between the digits and openssl's
    /// `sha256 Fingerprint=` prefix.
    public static func normalized(_ text: String) -> String? {
        var value = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if let equals = value.lastIndex(of: "=") {
            value = value[value.index(after: equals)...]
        }
        var hex = ""
        for character in value {
            if character.isASCII, character.isHexDigit {
                hex += character.lowercased()
            } else if character != ":", character != " " {
                return nil
            }
        }
        return hex.count == 64 ? hex : nil
    }

    /// `AB:CD:…`, for showing and comparing by eye.
    public static func display(_ fingerprint: String) -> String {
        var pairs: [String] = []
        var rest = Substring(fingerprint)
        while !rest.isEmpty {
            pairs.append(rest.prefix(2).uppercased())
            rest = rest.dropFirst(2)
        }
        return pairs.joined(separator: ":")
    }
}

/// Checks the PBX's certificate by the ``TrustPolicy`` – but only for the
/// configured host; every other host gets default validation.
///
/// Remembers the fingerprint of the certificate it accepted (with
/// `.pinned(nil)` the first one, which then stays the only one accepted) and
/// of one it refused, so the transport can report which certificate failed.
final class TrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    enum Verdict: Equatable {
        /// Let URLSession validate as usual.
        case systemDefault
        /// Take the certificate as is.
        case accept
        case reject
    }

    let host: String
    let policy: TrustPolicy
    private let lock = NSLock()
    private var accepted: String?
    private var rejected: String?

    init(host: String, policy: TrustPolicy) {
        self.host = host
        self.policy = policy
    }

    var acceptedFingerprint: String? { lock.withLock { accepted } }
    var rejectedFingerprint: String? { lock.withLock { rejected } }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    /// Streaming tasks (`bytes(for:)`) ask the task-level variant instead.
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        evaluate(challenge)
    }

    private func evaluate(_ challenge: URLAuthenticationChallenge)
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard let trust = space.serverTrust else { return (.performDefaultHandling, nil) }
        let verdict = verdict(space, fingerprint: CertificateFingerprint.of(trust),
                              systemTrusted: { SecTrustEvaluateWithError(trust, nil) })
        switch verdict {
        case .systemDefault: return (.performDefaultHandling, nil)
        case .accept: return (.useCredential, URLCredential(trust: trust))
        case .reject: return (.cancelAuthenticationChallenge, nil)
        }
    }

    /// The decision for one challenge; apart from `SecTrust` for the tests.
    func verdict(_ space: URLProtectionSpace, fingerprint: String?,
                 systemTrusted: () -> Bool) -> Verdict {
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == host else { return .systemDefault }
        switch policy {
        case .any:
            lock.withLock { accepted = fingerprint }
            return .accept
        case .system:
            guard systemTrusted() else {
                lock.withLock { rejected = fingerprint }
                return .reject
            }
            lock.withLock { accepted = fingerprint }
            return .systemDefault
        case .pinned(let expected):
            return lock.withLock {
                guard let fingerprint else { return .reject }
                // Trust on first use: the first certificate becomes the pin.
                if let pin = expected ?? accepted, pin != fingerprint {
                    rejected = fingerprint
                    return .reject
                }
                accepted = fingerprint
                return .accept
            }
        }
    }
}
