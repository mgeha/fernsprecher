import Foundation
import Testing
@testable import OxoKit

/// Records the requests and answers with canned bodies, keyed by SOAP action,
/// or by `action:method` where one action serves several methods (`privateOxo`).
final class FakeTransport: SoapTransport, @unchecked Sendable {
    var responses: [String: String]
    var sent: [(service: String, action: String, body: String)] = []
    var streamed: [String] = []

    init(_ responses: [String: String]) {
        self.responses = responses
    }

    func stream(service: String, soapAction: String, body: Data) -> AsyncThrowingStream<Data, Error> {
        let envelopes = streamed
        return AsyncThrowingStream { continuation in
            do {
                for envelope in envelopes {
                    var splitter = EnvelopeSplitter()
                    for byte in Data(envelope.utf8) {
                        if let complete = try splitter.feed(byte) { continuation.yield(complete) }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    func post(service: String, soapAction: String, body: Data) async throws -> Data {
        let text = String(decoding: body, as: UTF8.self)
        sent.append((service, soapAction, text))
        let method = text.range(of: "<tns:").map { start in
            String(text[start.upperBound...].prefix { $0 != ">" && $0 != " " })
        } ?? ""
        guard let response = responses["\(soapAction):\(method)"] ?? responses[soapAction] else {
            throw OxoError.transport("no fixture for \(soapAction)")
        }
        return Data(response.utf8)
    }
}

/// Wrap a body fragment the way the R63 does (SOAP-ENV prefix, ns2 = phone).
func r63(_ inner: String) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP-ENV:Envelope "
        + "xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" "
        + "xmlns:SOAP-ENC=\"http://schemas.xmlsoap.org/soap/encoding/\" "
        + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
        + "xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\" "
        + "xmlns:ns3=\"http://xmlapi.alcatel.com/phone/types\" "
        + "xmlns:ns2=\"http://xmlapi.alcatel.com/phone\" "
        + "xmlns:nsOxo2=\"http://xmlapi.alcatel.com/oxo\"><SOAP-ENV:Body "
        + "SOAP-ENV:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
        + inner + "</SOAP-ENV:Body></SOAP-ENV:Envelope>"
}

/// Responses shaped like the R63's. All numbers, names, ids, times and the
/// session id are invented; short numbers are PBX extensions.
enum Fixture {
    static let version = r63("<nsOxo2:getAPIVersionResponse><result>2.0.0</result></nsOxo2:getAPIVersionResponse>")
    static let login = r63("<ns2:loginResponse><loginResult><status><code>0</code><label>OK</label></status>"
        + "<sessionId>FAKE-SESSION-0001</sessionId><userName>51</userName><name>Muster M 51</name>"
        + "<firstName></firstName><lineNumber>51</lineNumber><newAddress>alize</newAddress>"
        + "<newPort>8894</newPort></loginResult></ns2:loginResponse>")
    static let badPassword = r63("<ns2:loginResponse><loginResult><status><code>8</code>"
        + "<label>ERROR - BadPassword</label></status><sessionId></sessionId></loginResult></ns2:loginResponse>")
    static let logout = r63("<ns2:logoutResponse><logoutResult><code>0</code><label>OK</label>"
        + "</logoutResult></ns2:logoutResponse>")
    static let unanswered = r63("<ns2:getNbUnansweredCallResponse><result><status><code>0</code>"
        + "<label>OK</label></status><nbUCall>125</nbUCall></result></ns2:getNbUnansweredCallResponse>")
    static let badSession = r63("<ns2:getNbUnansweredCallResponse><result><status><code>55</code>"
        + "<label>ERROR - BadSessionId</label></status><nbUCall>-1</nbUCall></result>"
        + "</ns2:getNbUnansweredCallResponse>")
    static let modifyCallLog = r63("<ns2:modifyCallLogResponse><status><code>0</code><label>OK</label>"
        + "</status></ns2:modifyCallLogResponse>")
    static let callLog = r63("<ns2:getCallLogResponse><result><status><code>0</code><label>OK</label></status>"
        + "<total>225</total><content>"
        + "<item><itemId><timeId>1000000001</timeId><diffId>101</diffId></itemId><dirNumber>51</dirNumber>"
        + "<corrNumber><number>01230000001</number><type>none</type></corrNumber><corrName></corrName>"
        + "<corrFirstName></corrFirstName><calltype><incoming>true</incoming><external>true</external>"
        + "<redirected>false</redirected><answered>false</answered></calltype>"
        + "<dateOfBegin>2026-01-05T09:00:00</dateOfBegin><dateOfConvers>2026-01-05T09:00:06</dateOfConvers>"
        + "<dateOfEnd>2026-01-05T09:00:06</dateOfEnd><cause>none</cause>"
        + "<acknowledged>false</acknowledged></item>"
        + "<item><itemId><timeId>1000000002</timeId><diffId>102</diffId></itemId><dirNumber>51</dirNumber>"
        + "<corrNumber><number>19</number><type>none</type></corrNumber><corrName>Beispiel B 19</corrName>"
        + "<calltype><incoming>false</incoming><answered>true</answered></calltype>"
        + "<dateOfBegin>2026-01-05T10:00:00</dateOfBegin><dateOfConvers>2026-01-05T10:00:05</dateOfConvers>"
        + "<dateOfEnd>2026-01-05T10:01:23</dateOfEnd><acknowledged>true</acknowledged></item>"
        // Outgoing, not reached, no corrNumber: as the R63 reports it.
        + "<item><itemId><timeId>1000000003</timeId><diffId>103</diffId></itemId><dirNumber>51</dirNumber>"
        + "<corrNumber><number></number><type>none</type></corrNumber><initialNumber><number>***</number>"
        + "<type>none</type></initialNumber><calltype><incoming>false</incoming><external>false</external>"
        + "<redirected>false</redirected><answered>false</answered></calltype>"
        + "<dateOfBegin>2026-01-05T11:00:00</dateOfBegin><dateOfConvers>2026-01-05T11:00:02</dateOfConvers>"
        + "<dateOfEnd>2026-01-05T11:00:02</dateOfEnd><cause>busy</cause><acknowledged>false</acknowledged></item>"
        + "</content></result></ns2:getCallLogResponse>")
    static let phoneBook = r63("<ns2:getPhoneBookResponse><result><status><code>0</code><label>OK</label></status>"
        + "<total>2</total><content><item><dirNumber>19</dirNumber><firstName></firstName>"
        + "<lastName>Beispiel B 19</lastName></item><item><dirNumber>*600</dirNumber><firstName></firstName>"
        + "<lastName>Sachbearbeiter</lastName></item></content></result></ns2:getPhoneBookResponse>")
    /// Invented values in the shape of a real `getStaticState` answer.
    static let staticState = r63("<ns2:getStaticStateResponse><getStaticStateReturn><campOnActivated>false"
        + "</campOnActivated><doNotDisturbActivated>false</doNotDisturbActivated><forwardState><type>IMMEDIATE</type>"
        + "<targetNumber>11</targetNumber><firstName></firstName><name>Zentrale</name><targetType>NUMBER</targetType>"
        + "</forwardState><locked>false</locked><overflowType>NO_OVERFLOW</overflowType></getStaticStateReturn>"
        + "</ns2:getStaticStateResponse>")
    /// Shaped like a real answer (forward on no answer to voice mail, set by another client).
    static let dynamicRouting = r63("<ns2:getDynamicRoutingResponse><result><status><code>0</code><label>OK</label>"
        + "</status><dynamicRoutingState>true</dynamicRoutingState><number>729</number><delay>20</delay>"
        + "<vmail>true</vmail></result></ns2:getDynamicRoutingResponse>")
    static let noDynamicRouting = r63("<ns2:getDynamicRoutingResponse><result><status><code>0</code><label>OK</label>"
        + "</status><dynamicRoutingState>false</dynamicRoutingState><number></number><delay>20</delay>"
        + "<vmail>false</vmail></result></ns2:getDynamicRoutingResponse>")
    static let cancelDynamicRouting = r63("<ns2:cancelDynamicRoutingResponse><status><code>0</code>"
        + "<label>OK</label></status></ns2:cancelDynamicRoutingResponse>")
    /// The method returns nothing.
    static let setForwardState = r63("<ns2:setForwardStateResponse></ns2:setForwardStateResponse>")
    /// Shaped like a real answer.
    static let userState = r63("<nsOxo2:getOXOUserStateResponse><result><status><code>0</code><label>OK</label>"
        + "</status><oxoUserState><name>Muster</name><firstName>M 51</firstName><loginName>51</loginName>"
        + "<mainNumber>51</mainNumber><barring>0</barring><staticState><campOnActivated>false</campOnActivated>"
        + "<doNotDisturbActivated>false</doNotDisturbActivated><forwardState><type>NO_FORWARD</type>"
        + "<targetNumber></targetNumber><firstName></firstName><name></name><targetType>NONE</targetType>"
        + "</forwardState><locked>false</locked><overflowType>NO_OVERFLOW</overflowType><associate></associate>"
        + "</staticState><nomadicState><nomadicMode>LOCAL</nomadicMode><homeNumber></homeNumber></nomadicState>"
        + "</oxoUserState></result></nsOxo2:getOXOUserStateResponse>")
}

func loggedInClient(_ extra: [String: String] = [:]) async throws -> (OxoClient, FakeTransport) {
    var responses = ["privateOxo": Fixture.version, "login": Fixture.login, "logout": Fixture.logout]
    responses.merge(extra) { $1 }
    let transport = FakeTransport(responses)
    let client = OxoClient(transport: transport)
    try await client.login(line: "51", password: "DEMOPASS")
    return (client, transport)
}

@Suite struct EnvelopeTests {
    @Test func scalarInline() {
        let out = String(decoding: buildEnvelope(method: "logout", serviceNamespace: Namespace.phone,
                                                 scalars: [SoapField("sessionId", .string("SID"))]), as: UTF8.self)
        #expect(out.contains("xmlns:tns=\"http://xmlapi.alcatel.com/phone\""))
        #expect(out.contains("<tns:logout><sessionId xsi:type=\"xsd:string\">SID</sessionId></tns:logout>"))
        #expect(out.contains("soap:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\""))
    }

    @Test func structMultiRef() {
        let login = SoapStruct("UserLogin", Namespace.phoneTypes, [
            SoapField("loginName", .string("DEMOUSER")), SoapField("password", .string("DEMOPASS")),
        ])
        let out = String(decoding: buildEnvelope(method: "login", serviceNamespace: Namespace.phone,
                                                 structure: login), as: UTF8.self)
        #expect(out.contains("<invoke href=\"#id1\" /></tns:login>"))
        #expect(out.contains("<q:UserLogin id=\"id1\" xsi:type=\"q:UserLogin\" "
                             + "xmlns:q=\"http://xmlapi.alcatel.com/phone/types\">"))
        #expect(out.contains("<loginName xsi:type=\"xsd:string\">DEMOUSER</loginName>"))
    }

    @Test func nestedStructGetsSecondId() {
        let selector = SoapStruct("CallLogSelector", Namespace.phoneTypes, [
            SoapField("index", .int(0)), SoapField("nbItems", .int(20)), SoapField("filterActivated", .int(0)),
        ])
        let invoke = SoapStruct("GetCallLogInvoke", Namespace.phoneTypes, [
            SoapField("sessionId", .string("SID")), SoapField("selector", .structure(selector)),
        ])
        let out = String(decoding: buildEnvelope(method: "getCallLog", serviceNamespace: Namespace.phone,
                                                 structure: invoke), as: UTF8.self)
        #expect(out.contains("<selector href=\"#id2\" />"))
        #expect(out.contains("<q:CallLogSelector id=\"id2\""))
        #expect(out.contains("<nbItems xsi:type=\"xsd:int\">20</nbItems>"))
    }

    @Test func nilAndEscaping() {
        let invoke = SoapStruct("UserLogin", Namespace.phoneTypes, [
            SoapField("password", .string("a&b<c>\"d")), SoapField("businessCodeOrPIN", .null),
        ])
        let out = String(decoding: buildEnvelope(method: "login", serviceNamespace: Namespace.phone,
                                                 structure: invoke), as: UTF8.self)
        #expect(out.contains("a&amp;b&lt;c&gt;&quot;d"))
        #expect(out.contains("<businessCodeOrPIN xsi:nil=\"true\" />"))
    }
}

@Suite struct ParsingTests {
    @Test func rejectsDTD() {
        let evil = "<?xml version=\"1.0\"?><!DOCTYPE x [<!ENTITY a \"b\">]><x>&a;</x>"
        #expect(throws: (any Error).self) { try parseXML(Data(evil.utf8)) }
    }

    @Test func soapFault() {
        let fault = r63("<SOAP-ENV:Fault><faultcode>SOAP-ENV:Client</faultcode>"
                        + "<faultstring>boom</faultstring></SOAP-ENV:Fault>")
        #expect(throws: OxoError.soapFault("boom")) { try responseElement(Data(fault.utf8)) }
    }
}

@Suite struct ClientTests {
    @Test func loginStoresSession() async throws {
        let (client, transport) = try await loggedInClient()
        let logon = await client.logon
        #expect(await client.sessionId == "FAKE-SESSION-0001")
        #expect(logon?.name == "Muster M 51")
        #expect(logon?.lineNumber == "51")
        #expect(transport.sent.map(\.action) == ["privateOxo", "login"])
        #expect(transport.sent[1].service == "XmlPhone")
    }

    @Test func badPassword() async {
        let transport = FakeTransport(["privateOxo": Fixture.version, "login": Fixture.badPassword])
        let client = OxoClient(transport: transport)
        await #expect(throws: OxoError.badPassword) {
            try await client.login(line: "51", password: "x")
        }
        #expect(await client.sessionId == nil)
    }

    @Test func callLog() async throws {
        let (client, transport) = try await loggedInClient(["getCallLog": Fixture.callLog])
        let log = try await client.callLog(count: 50)
        #expect(log.total == 225)
        #expect(log.entries.count == 3)
        let missed = log.entries[0]
        #expect(missed.id == CallLogItemId(timeId: "1000000001", diffId: "101"))
        #expect(missed.number == "01230000001")
        #expect(missed.name == nil)
        #expect(missed.missed && !missed.acknowledged)
        #expect(missed.date != nil)
        #expect(missed.outcome == .normal)
        #expect(log.entries[1].name == "Beispiel B 19")
        #expect(!log.entries[1].incoming)
        #expect(log.entries[1].duration == 78)   // 1:18
        #expect(missed.duration == nil)
        #expect(missed.ringDuration == 6)
        #expect(log.entries[1].ringDuration == nil)
        let busy = log.entries[2]
        #expect(busy.number == nil && busy.dialled == "***" && busy.displayNumber == "***")
        #expect(busy.unreached && !busy.missed && busy.outcome == .busy)
        #expect(transport.sent.last!.body.contains("<nbItems xsi:type=\"xsd:int\">50</nbItems>"))
    }

    @Test func unansweredAndBadSession() async throws {
        let (client, transport) = try await loggedInClient(["getNbUnansweredCall": Fixture.unanswered])
        #expect(try await client.unansweredCount() == 125)
        transport.responses["getNbUnansweredCall"] = Fixture.badSession
        await #expect(throws: OxoError.badSession) { try await client.unansweredCount() }
    }

    @Test func acknowledgeBuildsEncodedArray() async throws {
        let (client, transport) = try await loggedInClient(["modifyCallLog": Fixture.modifyCallLog])
        try await client.acknowledge([CallLogItemId(timeId: "1000000001", diffId: "101"),
                                      CallLogItemId(timeId: "1", diffId: "2")])
        let body = transport.sent.last!.body
        #expect(body.contains("<content href=\"#id2\" />"))
        #expect(body.contains("<soapenc:Array id=\"id2\" xmlns:q=\"http://xmlapi.alcatel.com/phone/types\" "
                              + "soapenc:arrayType=\"q:ItemMod[2]\"><Item href=\"#id3\" /><Item href=\"#id5\" />"
                              + "</soapenc:Array>"))
        #expect(body.contains("<id href=\"#id4\" /><ack xsi:type=\"xsd:boolean\">true</ack>"))
        #expect(body.contains("<timeId xsi:type=\"xsd:long\">1000000001</timeId>"
                              + "<diffId xsi:type=\"xsd:long\">101</diffId>"))
    }

    @Test func phoneBook() async throws {
        let (client, transport) = try await loggedInClient(["getPhoneBook": Fixture.phoneBook])
        let book = try await client.phoneBook(name: "Bei")
        #expect(book.map(\.number) == ["19", "*600"])
        #expect(book[0].displayName == "Beispiel B 19")
        let body = transport.sent.last!.body
        #expect(body.contains("<q:Selector id=\"id2\""))
        #expect(body.contains("<name xsi:type=\"xsd:string\">Bei</name>"))
        #expect(body.contains("<nbItems xsi:type=\"xsd:int\">500</nbItems>"))
    }

    @Test func makeCall() async throws {
        let ok = r63("<ns2:makeCallResponse><result><code>0</code><label>OK</label></result></ns2:makeCallResponse>")
        let (client, transport) = try await loggedInClient(["makeCall": ok])
        try await client.makeCall("019")
        let body = transport.sent.last!.body
        #expect(body.contains("<callee xsi:type=\"xsd:string\">019</callee>"))
        #expect(body.contains("<businessCodeOrPIN xsi:nil=\"true\" />"))
    }

    @Test func hangupTargetsTheGivenCall() async throws {
        let ok = r63("<ns2:clearCallResponse><result><code>0</code><label>OK</label></result></ns2:clearCallResponse>")
        let (client, transport) = try await loggedInClient(["clearCall": ok])
        try await client.hangup(callRef: "5266")
        #expect(transport.sent.last!.action == "clearCall")
        let body = transport.sent.last!.body
        #expect(body.contains("<callRef xsi:type=\"xsd:long\">5266</callRef>"))
    }

    @Test func forwardState() async throws {
        let (client, transport) = try await loggedInClient(["getStaticState": Fixture.staticState])
        #expect(try await client.forwardState()
                    == ForwardState(kind: .immediate, targetNumber: "11", targetName: "Zentrale", toVoiceMail: false))
        #expect(transport.sent.last!.body.contains("<sessionId xsi:type=\"xsd:string\">FAKE-SESSION-0001</sessionId>"))

        transport.responses["getStaticState"] = Fixture.staticState.replacingOccurrences(of: "IMMEDIATE", with: "NO_FORWARD")
        transport.responses["getDynamicRouting"] = Fixture.noDynamicRouting
        #expect(try await client.forwardState() == .off)
    }

    /// A forward on no answer set as dynamic routing does not show
    /// in the static state.
    @Test func forwardStateFromDynamicRouting() async throws {
        let (client, transport) = try await loggedInClient([
            "getStaticState": Fixture.staticState.replacingOccurrences(of: "IMMEDIATE", with: "NO_FORWARD"),
            "getDynamicRouting": Fixture.dynamicRouting,
        ])
        #expect(try await client.forwardState()
                    == ForwardState(kind: .onNoAnswer, targetNumber: "729", targetName: nil, toVoiceMail: true))
        #expect(transport.sent.last!.action == "getDynamicRouting")

        transport.responses["getDynamicRouting"] = Fixture.dynamicRouting
            .replacingOccurrences(of: "<vmail>true", with: "<vmail>false").replacingOccurrences(of: "729", with: "28")
        #expect(try await client.forwardState()
                    == ForwardState(kind: .onNoAnswer, targetNumber: "28", targetName: nil, toVoiceMail: false))
    }

    /// One `pForwardState` parameter, no status in the answer.
    @Test func forward() async throws {
        let (client, transport) = try await loggedInClient(["setForwardState": Fixture.setForwardState])
        try await client.forward(to: "799")
        let (service, action, body) = transport.sent.last!
        #expect(service == "XmlPhone" && action == "setForwardState")
        #expect(body.contains("<tns:setForwardState><pForwardState href=\"#id1\" /></tns:setForwardState>"))
        let state: String = "<q:AlcForwardState id=\"id1\" xsi:type=\"q:AlcForwardState\" "
                              + "xmlns:q=\"http://xmlapi.alcatel.com/phone/types\">"
                              + "<sessionId xsi:type=\"xsd:string\">FAKE-SESSION-0001</sessionId>"
                              + "<type xsi:type=\"q:AlcForwardType\">IMMEDIATE</type>"
                              + "<targetNumber xsi:type=\"xsd:string\">799</targetNumber>"
                              + "<duration xsi:type=\"xsd:int\">0</duration>"
                              + "<firstName xsi:type=\"xsd:string\"></firstName>"
                              + "<name xsi:type=\"xsd:string\"></name>"
                              + "<targetType xsi:type=\"q:AlcForwardTargetType\">NUMBER</targetType>"
        #expect(body.contains(state))
    }

    /// `NO_FORWARD` leaves dynamic routing on: cancel that too.
    @Test func cancelForward() async throws {
        let (client, transport) = try await loggedInClient(["setForwardState": Fixture.setForwardState,
                                                            "cancelDynamicRouting": Fixture.cancelDynamicRouting])
        try await client.cancelForward()
        #expect(transport.sent.suffix(2).map(\.action) == ["setForwardState", "cancelDynamicRouting"])
        let body = transport.sent.dropLast().last!.body
        #expect(body.contains("<type xsi:type=\"q:AlcForwardType\">NO_FORWARD</type>"))
        #expect(body.contains("<targetNumber xsi:type=\"xsd:string\"></targetNumber>"))
        #expect(body.contains("<targetType xsi:type=\"q:AlcForwardTargetType\">NONE</targetType>"))
    }

    @Test func forwardWithInvalidSessionFails() async throws {
        let (client, _) = try await loggedInClient(["setForwardState": Fixture.badSession])
        await #expect(throws: OxoError.badSession) { try await client.forward(to: "799") }
    }

    @Test func userStateForDiagnosis() async throws {
        let (client, transport) = try await loggedInClient(["privateOxo:getOXOUserState": Fixture.userState])
        let state = try await client.userState(loginName: "51")
        #expect(state.find("forwardState")?.value("type") == "NO_FORWARD")
        let (service, action, body) = transport.sent.last!
        #expect(service == "XmlOxo" && action == "privateOxo")
        #expect(body.contains("<tns:getOXOUserState>"))
        #expect(body.contains("xmlns:q=\"xmlapi.alcatel.com/oxo/types\""))
    }

    @Test func emptyResponseIsAnError() async throws {
        let empty = r63("<ns2:makeCallResponse></ns2:makeCallResponse>")
        let (client, _) = try await loggedInClient(["makeCall": empty])
        await #expect(throws: OxoError.emptyResponse(operation: "makeCall")) {
            try await client.makeCall("28")
        }
    }

    @Test func logoutClearsSession() async throws {
        let (client, transport) = try await loggedInClient()
        await client.logout()
        #expect(await client.sessionId == nil)
        #expect(transport.sent.last!.action == "logout")
    }
}

/// Modelled on envelopes captured from an R63; numbers, ids and names are invented.
enum EventFixture {
    static let subscribed = r63("<ns2:startSubscribeAppResponse><result><status><code>0</code><label>OK</label>"
        + "</status><subscribeId>8764</subscribeId></result></ns2:startSubscribeAppResponse>")
    static let ringing = r63("<ns2:e_callStateResponse><e_callState><sessionId>SID</sessionId>"
        + "<content xsi:type=\"SOAP-ENC:Array\" SOAP-ENC:arrayType=\"ns3:Call[1]\"><item><callRef>5266</callRef>"
        + "<number>01230000001</number><name></name><state>ringingIncoming</state></item></content>"
        + "</e_callState></ns2:e_callStateResponse>")
    static let change = r63("<ns2:e_callChangeResponse><e_callChange><sessionId>SID</sessionId><callRef>5266</callRef>"
        + "<callIsPresent>true</callIsPresent><name></name><state>ringingIncoming</state><cause>none</cause>"
        + "<number>01230000001</number></e_callChange></ns2:e_callChangeResponse>")
    /// Group and redirect not yet seen on a real PBX.
    static let groupCall = r63("<ns2:e_callChangeResponse><e_callChange><sessionId>SID</sessionId>"
        + "<callRef>5270</callRef><callIsPresent>true</callIsPresent><name></name>"
        + "<callIsRedirect>true</callIsRedirect><state>ringingIncoming</state><cause>none</cause>"
        + "<number>01230000001</number><initialCalledNumber>10</initialCalledNumber>"
        + "<initialCalledName></initialCalledName><acdCalling><groupNumber>10</groupNumber>"
        + "<groupName>Zentrale</groupName></acdCalling><isCurrentCall>true</isCurrentCall>"
        + "</e_callChange></ns2:e_callChangeResponse>")
    static let idle = r63("<ns2:e_callStateResponse><e_callState><sessionId>SID</sessionId></e_callState>"
        + "</ns2:e_callStateResponse>")
    static let missed = r63("<ns2:e_unanswdCallNotifResponse><e_unanswdCallNotif><sessionId>SID</sessionId>"
        + "</e_unanswdCallNotif></ns2:e_unanswdCallNotifResponse>")
    /// Sent to the old session when another client logged in on the line (2026-10-15).
    static let newSession = """
        <?xml version="1.0" encoding="UTF-8"?><SOAP-ENV:Envelope \
        xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" \
        xmlns:SOAP-ENC="http://schemas.xmlsoap.org/soap/encoding/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema" \
        xmlns:ns3="xmlapi.alcatel.com/app/types" xmlns:ns2="http://xmlapi.alcatel.com/app">\
        <SOAP-ENV:Body SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">\
        <ns2:e_newSessionResponse><e_newSession><sessionId>SID</sessionId></e_newSession>\
        </ns2:e_newSessionResponse></SOAP-ENV:Body></SOAP-ENV:Envelope>
        """
    static let subscribeOK = r63("<ns2:subscribeResponse><result><code>0</code><label>OK</label></result>"
        + "</ns2:subscribeResponse>")
}

@Suite struct EventTests {
    @Test func splitterCutsConcatenatedEnvelopes() throws {
        var splitter = EnvelopeSplitter()
        var envelopes: [Data] = []
        for byte in Data((EventFixture.ringing + EventFixture.idle + "<?xml version").utf8) {
            if let envelope = try splitter.feed(byte) { envelopes.append(envelope) }
        }
        #expect(envelopes.count == 2)
        #expect(String(decoding: envelopes[1], as: UTF8.self).hasSuffix("</SOAP-ENV:Envelope>"))
    }

    /// A peer that never closes an envelope ends the stream – also with a run
    /// of `>`, which takes the path that looks for the closing tag.
    @Test(arguments: [UInt8(ascii: ">"), UInt8(ascii: "x")])
    func splitterRejectsOversizedEnvelope(filler: UInt8) throws {
        var splitter = EnvelopeSplitter()
        for _ in 0..<EnvelopeSplitter.maxEnvelope {
            _ = try splitter.feed(filler)
        }
        #expect(throws: OxoError.self) { _ = try splitter.feed(filler) }
    }

    @Test func splitterAcceptsEnvelopeUpToLimit() throws {
        let closer = Data("</SOAP-ENV:Envelope>".utf8)
        var splitter = EnvelopeSplitter()
        for _ in 0..<(EnvelopeSplitter.maxEnvelope - closer.count) {
            _ = try splitter.feed(UInt8(ascii: "x"))
        }
        var envelope: Data?
        for byte in closer { envelope = try splitter.feed(byte) }
        #expect(envelope?.count == EnvelopeSplitter.maxEnvelope)
    }

    @Test func decodeUnwrapsResponse() throws {
        let event = try parseEvent(Data(EventFixture.change.utf8))
        #expect(event.name == "e_callChange")
        #expect(event.payload.value("state") == "ringingIncoming")
        let empty = try parseEvent(Data(EventFixture.missed.utf8))
        #expect(empty.name == "e_unanswdCallNotif")
    }

    @Test func callStateSnapshot() throws {
        let ringing = ActiveCall.snapshot(try parseEvent(Data(EventFixture.ringing.utf8)))
        #expect(ringing == [ActiveCall(callRef: "5266", number: "01230000001", name: nil, state: .ringingIncoming)])
        #expect(ringing[0].isRinging)
        #expect(ActiveCall.snapshot(try parseEvent(Data(EventFixture.idle.utf8))).isEmpty)
    }

    @Test func callChangeDetails() throws {
        func event(_ xml: String) throws -> OxoEvent { try parseEvent(Data(xml.utf8)) }
        let plain = try #require(CallChange(try event(EventFixture.change)))
        #expect(plain.isPresent && !plain.redirected)
        #expect(plain.initialCalledNumber == nil && plain.groupName == nil)

        let change = try #require(CallChange(try event(EventFixture.groupCall)))
        #expect(change.callRef == "5270" && change.redirected)
        #expect(change.initialCalledNumber == "10" && change.initialCalledName == nil)
        #expect(change.groupName == "Zentrale")
        var call = ActiveCall(callRef: "5270", number: "01230000001", name: nil, state: .ringingIncoming)
        call.apply(change)
        #expect(call.groupName == "Zentrale" && call.redirected)

        #expect(CallChange(try event(EventFixture.ringing)) == nil)
    }

    @Test func newSessionMeansTakeOverOfThatSessionOnly() throws {
        let event = try parseEvent(Data(EventFixture.newSession.utf8))
        #expect(event.name == "e_newSession")
        #expect(event.isTakeOver(of: "SID"))
        #expect(!event.isTakeOver(of: "OTHER"))   // e.g. after our own re-login
        #expect(!event.isTakeOver(of: nil))
        let ringing = try parseEvent(Data(EventFixture.ringing.utf8))
        #expect(!ringing.isTakeOver(of: "SID"))
    }

    @Test func logoutReleasesEventBinding() async throws {
        let (client, transport) = try await loggedInClient(["subscribe": EventFixture.subscribeOK])
        try await client.subscribe(8764)
        await client.logout()
        #expect(transport.sent.suffix(2).map(\.action) == ["unsubscribe", "logout"])
    }

    @Test func streamSubscribesWithIdFromFirstEnvelope() async throws {
        let (client, transport) = try await loggedInClient(["subscribe": EventFixture.subscribeOK])
        transport.streamed = [EventFixture.subscribed, EventFixture.ringing, EventFixture.missed]
        var names: [String] = []
        for try await event in client.events() { names.append(event.name) }
        #expect(names == ["startSubscribeAppResponse", "e_callState", "e_unanswdCallNotif"])
        let subscribe = try #require(transport.sent.first { $0.action == "subscribe" })
        #expect(subscribe.body.contains("<subscribeId xsi:type=\"xsd:long\">8764</subscribeId>"))
        #expect(subscribe.body.contains("<sessionId xsi:type=\"xsd:string\">FAKE-SESSION-0001</sessionId>"))
    }

    @Test func trackerMergesChangesInEitherOrder() throws {
        func event(_ xml: String) throws -> OxoEvent { try parseEvent(Data(xml.utf8)) }
        let ringing = ActiveCall(callRef: "5266", number: "01230000001", name: nil, state: .ringingIncoming,
                                 isIncoming: true)

        var tracker = CallTracker()
        #expect(tracker.handle(try event(EventFixture.ringing)) == [.calls([ringing])])
        #expect(tracker.handle(try event(EventFixture.change)) == [])   // no new details

        // Details first, then the snapshot listing the call.
        var early = CallTracker()
        #expect(early.handle(try event(EventFixture.groupCall)) == [])
        let snapshot = EventFixture.ringing.replacingOccurrences(of: "5266", with: "5270")
        guard case .calls(let calls) = early.handle(try event(snapshot)).first else {
            Issue.record("expected calls")
            return
        }
        #expect(calls.map(\.groupName) == ["Zentrale"])
    }

    @Test func trackerKeepsRouteOnceAnswered() throws {
        func event(_ xml: String) throws -> OxoEvent { try parseEvent(Data(xml.utf8)) }
        let ringing = EventFixture.ringing.replacingOccurrences(of: "5266", with: "5270")
        var tracker = CallTracker()
        _ = tracker.handle(try event(ringing))
        _ = tracker.handle(try event(EventFixture.groupCall))
        // Answered: the snapshot says active, the change no longer names the group.
        _ = tracker.handle(try event(ringing.replacingOccurrences(of: "ringingIncoming", with: "active")))
        let answered = EventFixture.change.replacingOccurrences(of: "5266", with: "5270")
            .replacingOccurrences(of: "ringingIncoming", with: "active")
        _ = tracker.handle(try event(answered))
        let call = try #require(tracker.calls.first)
        #expect(call.isActive && call.isIncoming)
        #expect(call.groupName == "Zentrale" && call.redirected && call.initialCalledNumber == "10")

        // A call that never rang here (outgoing) is not incoming.
        var outgoing = CallTracker()
        _ = outgoing.handle(try event(EventFixture.ringing.replacingOccurrences(of: "ringingIncoming", with: "active")))
        #expect(outgoing.calls.first?.isIncoming == false)
    }

    @Test func trackerReportsEndedCallsAndMissedCalls() throws {
        func event(_ xml: String) throws -> OxoEvent { try parseEvent(Data(xml.utf8)) }
        var tracker = CallTracker()
        #expect(tracker.handle(try event(EventFixture.idle)) == [.calls([])])   // nothing ended
        _ = tracker.handle(try event(EventFixture.ringing))
        #expect(tracker.handle(try event(EventFixture.idle)) == [.calls([]), .callLogChanged])
        #expect(tracker.handle(try event(EventFixture.missed)) == [.callLogChanged])
        #expect(tracker.handle(try event(EventFixture.subscribeOK)) == [])
        let staticState = Fixture.staticState
            .replacingOccurrences(of: "getStaticStateResponse", with: "e_phoneStaticStateResponse")
            .replacingOccurrences(of: "getStaticStateReturn", with: "e_phoneStaticState")
        #expect(tracker.handle(try event(staticState)) == [.staticStateChanged])
    }

    @Test func lineEventsFromStream() async throws {
        let (client, transport) = try await loggedInClient(["subscribe": EventFixture.subscribeOK])
        let ownTakeOver = EventFixture.newSession.replacingOccurrences(of: "SID", with: "FAKE-SESSION-0001")
        transport.streamed = [EventFixture.subscribed, EventFixture.ringing, EventFixture.idle,
                              EventFixture.newSession, ownTakeOver]
        var events: [LineEvent] = []
        for try await event in client.lineEvents() { events.append(event) }
        let ringing = ActiveCall(callRef: "5266", number: "01230000001", name: nil, state: .ringingIncoming,
                                 isIncoming: true)
        // The first e_newSession names another session (e.g. after our own re-login).
        #expect(events == [.live, .calls([ringing]), .calls([]), .callLogChanged, .takenOver])
    }
}

@Suite struct DiagnosticsTests {
    /// Log kinds carry the kind and the PBX's status, never the error's free text.
    @Test func diagnosticKindOmitsFreeText() {
        #expect(OxoError.transport("192.168.1.10 unreachable").diagnosticKind == "transport")
        #expect(OxoError.soapFault("session FAKE-SESSION-0001").diagnosticKind == "soapFault")
        #expect(OxoError.invalidResponse("<x>0170…</x>").diagnosticKind == "invalidResponse")
        #expect(OxoError.status(operation: "subscribe", code: 4, label: "UnknownUser").diagnosticKind
                    == "status subscribe 4 UnknownUser")
        #expect(URLError(.timedOut).diagnosticKind == "url -1001")
        #expect(CancellationError().diagnosticKind == "cancelled")
    }
}
