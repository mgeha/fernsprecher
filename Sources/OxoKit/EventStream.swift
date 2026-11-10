import Foundation
import os

/// One decoded event from the streaming channel, e.g. `e_callChange`.
public struct OxoEvent: Sendable {
    /// Local name with the `…Response` wrapper removed, e.g. `e_callChange`.
    public let name: String
    public let payload: XMLNode
    public let raw: String

    /// Another client logged in on the line: the PBX sends `e_newSession`
    /// with the id of the session it just invalidated (observed on an R63).
    /// Only an event for `sessionId` counts; after our own re-login the event
    /// names the old session.
    func isTakeOver(of sessionId: String?) -> Bool {
        guard name == "e_newSession", let sessionId else { return false }
        return payload.value("sessionId") == sessionId
    }
}

/// Cuts the endless event body into complete envelopes. The PBX streams
/// concatenated SOAP envelopes over one open HTTP response; we cut at the
/// closing envelope tag.
public struct EnvelopeSplitter: Sendable {
    static let closers = ["</SOAP-ENV:Envelope>", "</soap:Envelope>", "</Envelope>"].map { Array($0.utf8) }
    private var buffer: [UInt8] = []
    /// Guard against a peer that never closes an envelope.
    static let maxEnvelope = 1 << 20

    public init() {}

    /// Feed one byte; returns a complete envelope when this byte closed one.
    /// Throws once an unclosed envelope grows past `maxEnvelope`; the caller
    /// ends the stream, and the event loop reconnects with a fresh buffer.
    public mutating func feed(_ byte: UInt8) throws -> Data? {
        buffer.append(byte)
        if byte == UInt8(ascii: ">") {
            for closer in Self.closers where buffer.count >= closer.count
                && buffer.suffix(closer.count).elementsEqual(closer) {
                let envelope = Data(buffer)
                buffer.removeAll(keepingCapacity: true)
                return envelope
            }
        }
        if buffer.count > Self.maxEnvelope {
            buffer.removeAll()
            throw OxoError.invalidResponse("event envelope larger than \(Self.maxEnvelope) bytes")
        }
        return nil
    }
}

/// Decode one envelope; unwraps `<e_callChangeResponse><e_callChange>…`.
func parseEvent(_ envelope: Data) throws -> OxoEvent {
    let first = try responseElement(envelope)
    let raw = String(decoding: envelope, as: UTF8.self)
    if first.name.hasSuffix("Response") {
        let inner = String(first.name.dropLast("Response".count))
        if let payload = first.child(inner), !payload.children.isEmpty || !payload.text.isEmpty {
            return OxoEvent(name: inner, payload: payload, raw: raw)
        }
    }
    return OxoEvent(name: first.name, payload: first, raw: raw)
}

extension OxoClient {
    /// The fixed application id the OXO accepts for phone events (as read on the wire);
    /// an arbitrary id is rejected with `4 UnknownUser`.
    public static let eventApplicationId = "OXOWebServices"

    /// Open the event channel and bind this session's phone events to it.
    ///
    /// `startSubscribeApp` keeps its HTTP response open and streams one
    /// envelope per event. Its first envelope carries the `subscribeId`, which
    /// `subscribe` binds to the logged-in phone session; only then do call
    /// events flow. The stream finishes when the PBX closes the connection.
    public nonisolated func events() -> AsyncThrowingStream<OxoEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let body = buildEnvelope(
                        method: "startSubscribeApp", serviceNamespace: Namespace.app,
                        scalars: [SoapField("applicationId", .string(Self.eventApplicationId))])
                    var bound = false
                    for try await envelope in transport.stream(
                        service: "XmlApp", soapAction: Namespace.app + "/startSubscribeApp", body: body) {
                        let event: OxoEvent
                        do {
                            event = try parseEvent(envelope)
                        } catch {
                            OxoLog.events.notice("""
                                stream: skipped envelope (\(envelope.count, privacy: .public) bytes, \
                                bound=\(bound, privacy: .public)): \(error.diagnosticKind, privacy: .public)
                                """)
                            continue
                        }
                        if !bound, event.name.hasPrefix("startSubscribeApp") {
                            guard let id = event.payload.find("subscribeId").flatMap({ Int($0.text) }),
                                  id > 0 else {
                                throw OxoError.invalidResponse("no subscribeId")
                            }
                            do {
                                try await subscribe(id)
                            } catch {
                                OxoLog.events.error("stream: subscribe failed: \(error.diagnosticKind, privacy: .public)")
                                throw error
                            }
                            bound = true
                            OxoLog.events.notice("stream: subscribed")
                        }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func subscribe(_ subscribeId: Int) async throws {
        let structure = SoapStruct("SubscribeInvoke", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("subscribeId", .scalar(String(subscribeId), xsd: "long")),
        ])
        let response = try await call("XmlPhone", action: "subscribe", method: "subscribe",
                                      namespace: Namespace.phone, structure: structure)
        try requireStatus(response, "subscribe")
        eventsBound = true
    }
}
