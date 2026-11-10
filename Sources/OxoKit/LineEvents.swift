/// What happens on the line, reduced from the PBX's events to what a client
/// acts on.
public enum LineEvent: Sendable, Equatable {
    /// The event channel is up; call events flow from now on.
    case live
    /// All calls on the line now; empty when there are none.
    case calls([ActiveCall])
    /// A call ended or a missed call arrived: the call log has (or is about
    /// to have) a new entry.
    case callLogChanged
    /// Another client logged in on the line and ended this session.
    case takenOver
    /// The PBX sent the line's static state (forward, do not disturb): right
    /// after subscribing, possibly on changes too. Reload it.
    case staticStateChanged
}

/// Merges the `e_callState` snapshots with the `e_callChange` details; a
/// change may arrive before or after the snapshot that lists its call.
struct CallTracker {
    private(set) var calls: [ActiveCall] = []
    private var changes: [String: CallChange] = [:]
    /// Calls seen ringing in, so they still count as incoming once answered.
    private var incoming: Set<String> = []

    mutating func handle(_ event: OxoEvent) -> [LineEvent] {
        switch event.name {
        case "e_callState":
            let snapshot = ActiveCall.snapshot(event)
            let ended = calls.contains { old in !snapshot.contains { $0.callRef == old.callRef } }
            if snapshot.isEmpty { changes = [:] }
            incoming = incoming.union(snapshot.filter(\.isRinging).map(\.callRef))
                .intersection(snapshot.map(\.callRef))
            calls = snapshot.map(withDetails)
            return ended ? [.calls(calls), .callLogChanged] : [.calls(calls)]
        case "e_callChange":
            guard var change = CallChange(event) else { return [] }
            if let earlier = changes[change.callRef] { change.keepRoute(of: earlier) }
            changes[change.callRef] = change.isPresent ? change : nil
            let updated = calls.map(withDetails)
            guard updated != calls else { return [] }
            calls = updated
            return [.calls(calls)]
        case "e_unanswdCallNotif":
            return [.callLogChanged]
        case "e_phoneStaticState":
            return [.staticStateChanged]
        default:
            return []
        }
    }

    private func withDetails(_ call: ActiveCall) -> ActiveCall {
        var call = call
        call.isIncoming = incoming.contains(call.callRef)
        if let change = changes[call.callRef] { call.apply(change) }
        return call
    }
}

extension OxoClient {
    public nonisolated func lineEvents() -> AsyncThrowingStream<LineEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var tracker = CallTracker()
                    for try await event in events() {
                        switch event.name {
                        case "startSubscribeAppResponse":
                            continuation.yield(.live)
                        case "e_newSession":
                            if event.isTakeOver(of: await sessionId) { continuation.yield(.takenOver) }
                        default:
                            tracker.handle(event).forEach { continuation.yield($0) }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
