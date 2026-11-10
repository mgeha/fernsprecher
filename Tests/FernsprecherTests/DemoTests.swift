import Foundation
import OxoKit
import Testing
@testable import Fernsprecher

/// The demo PBX answers in a form the real client understands.
struct DemoTests {
    func client(incomingCall: Bool = false) async throws -> OxoClient {
        let client = OxoClient(transport: DemoTransport(pbx: DemoPBX(incomingCall: incomingCall)))
        let logon = try await client.login(line: DemoPBX.line, password: "0000")
        #expect(logon.name == "Alex Morgan")
        return client
    }

    @Test func callLogAndMissedCalls() async throws {
        let client = try await client()
        let log = try await client.callLog()
        #expect(log.total == 14 && log.entries.count == 14)
        #expect(log.entries[1].name == "Dana Reyes" && log.entries[1].duration == 222)
        #expect(log.entries[4].outcome == .busy && log.entries[4].unreached)
        let missed = log.entries.filter { $0.missed && !$0.acknowledged }
        #expect(missed.map(\.number) == ["07700900321", "01614960789"])
        #expect(missed[0].ringDuration == 21)
        #expect(try await client.unansweredCount() == 2)
        try await client.acknowledge(missed.map(\.id))
        #expect(try await client.unansweredCount() == 0)
        #expect(try await client.callLog(index: 12, count: 50).entries.count == 2)
    }

    @Test func directoryAndForward() async throws {
        let client = try await client()
        #expect(try await client.phoneBook().count == DemoPBX.directory.count)
        #expect(try await client.forwardState() == .off)
        try await client.forward(to: "10")
        #expect(try await client.forwardState()
                    == ForwardState(kind: .immediate, targetNumber: "10", targetName: "Reception", toVoiceMail: false))
        try await client.cancelForward()
        #expect(try await client.forwardState() == .off)
    }

    @Test func outgoingCall() async throws {
        let client = try await client()
        var events = client.lineEvents().makeAsyncIterator()
        #expect(try await events.next() == .live)
        #expect(try await events.next() == .calls([]))
        try await client.makeCall("002079460123")
        guard case .calls(let calls)? = try await events.next(), let call = calls.first else {
            Issue.record("no call")
            return
        }
        #expect(call.number == "02079460123" && call.state == .ringingOutgoing)
        try await client.hangup(callRef: call.callRef)
        #expect(try await events.next() == .calls([]))
        #expect(try await events.next() == .callLogChanged)
        let newest = try #require(try await client.callLog().entries.first)
        #expect(newest.number == "02079460123" && newest.unreached)
    }
}
