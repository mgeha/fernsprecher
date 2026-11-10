import Foundation
import os

/// Sends one SOAP POST to `https://<host>:<port>/services/xmlsrv/services/<Service>`
/// and returns the raw body.
public protocol SoapTransport: Sendable {
    func post(service: String, soapAction: String, body: Data) async throws -> Data
    /// Long-lived POST whose response streams concatenated envelopes; yields
    /// each complete envelope. Finishes when the server closes the response.
    func stream(service: String, soapAction: String, body: Data) -> AsyncThrowingStream<Data, Error>
}

public final class HTTPSTransport: SoapTransport {
    public static let basePath = "/services/xmlsrv/services"

    let host: String
    let port: Int
    private let session: URLSession
    /// Separate session for the event channel: the PBX only sends an
    /// `e_ping` now and then, so the idle timeout must be generous.
    private let streamSession: URLSession
    private let trust: TrustDelegate

    public init(host: String, port: Int = 443, timeout: TimeInterval = 15,
                trust policy: TrustPolicy = .system) {
        self.host = host
        self.port = port
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let trust = TrustDelegate(host: host, policy: policy)
        self.trust = trust
        session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        let streamConfig = URLSessionConfiguration.ephemeral
        streamConfig.timeoutIntervalForRequest = 150
        streamConfig.timeoutIntervalForResource = .infinity
        streamConfig.httpShouldSetCookies = false
        streamConfig.urlCache = nil
        streamSession = URLSession(configuration: streamConfig, delegate: trust, delegateQueue: nil)
    }

    /// SHA-256 of the certificate the PBX presented and this transport
    /// accepted; nil before the first connection.
    public var certificateFingerprint: String? { trust.acceptedFingerprint }

    /// A refused certificate makes URLSession fail with "cancelled"; report
    /// which certificate it was instead.
    private func transportError(_ error: Error) -> OxoError {
        if let fingerprint = trust.rejectedFingerprint {
            return .untrustedCertificate(fingerprint)
        }
        return .transport(error.localizedDescription)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    private func request(service: String, soapAction: String, body: Data,
                         keepAlive: Bool) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = port
        components.path = "\(Self.basePath)/\(service)"
        guard let url = components.url else {
            throw OxoError.transport("invalid address \(host):\(port)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(soapAction)\"", forHTTPHeaderField: "SOAPAction")
        if !keepAlive {
            request.setValue("close", forHTTPHeaderField: "Connection")
        }
        return request
    }

    public func stream(service: String, soapAction: String, body: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try request(service: service, soapAction: soapAction,
                                              body: body, keepAlive: true)
                    let (bytes, response) = try await streamSession.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        OxoLog.events.notice("stream: HTTP \(http.statusCode, privacy: .public)")
                    }
                    var splitter = EnvelopeSplitter()
                    for try await byte in bytes {
                        if let envelope = try splitter.feed(byte) {
                            continuation.yield(envelope)
                        }
                    }
                    continuation.finish()
                } catch let error as OxoError {
                    continuation.finish(throwing: error)
                } catch {
                    // The URLError code is lost in the conversion; keep it in the log.
                    if !Task.isCancelled {
                        OxoLog.events.error("""
                            stream: transport error \(error.diagnosticKind, privacy: .public): \
                            \(error.localizedDescription)
                            """)
                    }
                    continuation.finish(throwing: transportError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func post(service: String, soapAction: String, body: Data) async throws -> Data {
        let request = try request(service: service, soapAction: soapAction, body: body, keepAlive: false)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw transportError(error)
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400, data.isEmpty {
            throw OxoError.transport("HTTP \(http.statusCode)")
        }
        return data
    }
}
