#if DEBUG
import Foundation
import OxoKit

// Demo mode (`scripts/demo.sh`, debug builds only): the app runs against a
// fake PBX with invented data, to try it or to take screenshots without an
// OXO. Phone numbers are from the UK ranges reserved for fiction.

extension AppEnvironment {
    /// Settings and files of their own, set up anew on every launch; nothing
    /// of the real app is read or written.
    @MainActor static func demo(incomingCall: Bool) -> AppEnvironment {
        let host = "pbx.example.com"
        let suite = "de.1lov.fernsprecher.demo"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defaults.register(defaults: [
            "host": host,
            "line": DemoPBX.line,
            "certificateFingerprint": CertificateFingerprint.sha256(Data("Fernsprecher demo".utf8)),
        ])
        let folder = FileManager.default.temporaryDirectory.appending(path: "Fernsprecher-demo")
        try? FileManager.default.removeItem(at: folder)
        let pins = PinStore(url: folder.appending(path: "pins.json"))
        try? pins.setPin("0000", account: "\(DemoPBX.line)@\(host)")
        var book = AddressBook()
        for (number, name) in DemoPBX.ownNames {
            book.set(name: name, for: number)
        }
        let addressBookURL = folder.appending(path: "addressbook.json")
        try? book.save(to: addressBookURL)
        let pbx = DemoPBX(incomingCall: incomingCall)
        return AppEnvironment(defaults: defaults, pins: pins, addressBookURL: addressBookURL) { _ in
            OxoClient(transport: DemoTransport(pbx: pbx))
        }
    }
}

struct DemoTransport: SoapTransport {
    let pbx: DemoPBX

    func post(service: String, soapAction: String, body: Data) async throws -> Data {
        Data(await pbx.answer(soapAction, String(decoding: body, as: UTF8.self)).utf8)
    }

    func stream(service: String, soapAction: String, body: Data) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let id = UUID()
            Task { await pbx.open(id, continuation) }
            continuation.onTermination = { _ in
                Task { await pbx.close(id) }
            }
        }
    }
}

/// Answers the requests of one line the way an R63 does, from a call log,
/// directory and forward kept in memory.
actor DemoPBX {
    static let line = "12"
    static let directory = [
        ("10", "Reception"), ("11", "Dana Reyes"), ("12", "Alex Morgan"), ("13", "Priya Shah"),
        ("14", "Tom Becker"), ("15", "Workshop"), ("16", "Meeting room"), ("17", "Sam Carter"),
    ]
    /// The user's own address book.
    static let ownNames = [
        ("02079460123", "Northwind Supplies"), ("07700900321", "Jordan Lee"),
        ("01134960456", "Harbour Print"), ("02079460188", "Kestrel Accounting"),
    ]

    private struct LogEntry {
        var id: Int
        var number: String
        var incoming: Bool
        var answered: Bool
        var acknowledged = true
        var begin: Date
        /// Seconds until answered, or until the caller gave up.
        var ring: TimeInterval
        var talk: TimeInterval = 0
        var cause = "none"
    }

    private struct Call {
        var ref: Int
        var number: String
        var state: String
        var incoming: Bool
        var begin = Date.now
        var answeredAt: Date?
    }

    /// Newest first.
    private var log: [LogEntry]
    private var forwardTarget: String?
    private var call: Call?
    private var nextRef = 7000
    private var incomingCall: Bool
    private var listeners: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    /// `incomingCall`: ring once, a few seconds after the app subscribed.
    init(incomingCall: Bool) {
        self.incomingCall = incomingCall
        func ago(_ minutes: Double) -> Date { Date.now.addingTimeInterval(-minutes * 60) }
        let day = 1440.0
        log = [
            LogEntry(id: 114, number: "07700900321", incoming: true, answered: false, acknowledged: false,
                     begin: ago(9), ring: 21),
            LogEntry(id: 113, number: "11", incoming: true, answered: true, begin: ago(34), ring: 5, talk: 222),
            LogEntry(id: 112, number: "02079460123", incoming: false, answered: true, begin: ago(58), ring: 9,
                     talk: 725),
            LogEntry(id: 111, number: "01614960789", incoming: true, answered: false, acknowledged: false,
                     begin: ago(96), ring: 8),
            LogEntry(id: 110, number: "14", incoming: false, answered: false, begin: ago(131), ring: 2,
                     cause: "busy"),
            LogEntry(id: 109, number: "01134960456", incoming: true, answered: true, begin: ago(175), ring: 4,
                     talk: 377),
            LogEntry(id: 108, number: "02079460142", incoming: true, answered: false, begin: ago(242), ring: 11,
                     cause: "pickupVictim"),
            LogEntry(id: 107, number: "13", incoming: false, answered: true, begin: ago(day + 35), ring: 6,
                     talk: 78),
            LogEntry(id: 106, number: "10", incoming: true, answered: false, begin: ago(day + 120), ring: 14),
            LogEntry(id: 105, number: "07700900654", incoming: true, answered: true, begin: ago(day + 200),
                     ring: 7, talk: 330),
            LogEntry(id: 104, number: "02079460188", incoming: false, answered: true, begin: ago(day + 290),
                     ring: 12, talk: 524),
            LogEntry(id: 103, number: "17", incoming: true, answered: true, begin: ago(2 * day + 60), ring: 3,
                     talk: 47),
            LogEntry(id: 102, number: "01134960456", incoming: false, answered: false, begin: ago(2 * day + 150),
                     ring: 25),
            LogEntry(id: 101, number: "02079460123", incoming: true, answered: true, begin: ago(2 * day + 260),
                     ring: 6, talk: 129),
        ]
    }

    // MARK: - requests

    func answer(_ action: String, _ body: String) -> String {
        func field(_ tag: String) -> String? { Self.fields(tag, in: body).first }
        switch action {
        case "privateOxo":
            return Self.envelope("<nsOxo2:getAPIVersionResponse><result>2.0.0</result></nsOxo2:getAPIVersionResponse>")
        case "login":
            return Self.envelope("<ns2:loginResponse><loginResult>\(Self.ok)<sessionId>\(Self.session)</sessionId>"
                + "<userName>\(Self.line)</userName><name>\(Self.name(Self.line))</name><firstName></firstName>"
                + "<lineNumber>\(Self.line)</lineNumber></loginResult></ns2:loginResponse>")
        case "getNbUnansweredCall":
            let count = log.filter { $0.incoming && !$0.answered && !$0.acknowledged }.count
            return Self.result(action, "<nbUCall>\(count)</nbUCall>")
        case "getCallLog":
            let index = field("index").flatMap(Int.init) ?? 0
            let count = field("nbItems").flatMap(Int.init) ?? 50
            let items = log.dropFirst(index).prefix(count).map(Self.item).joined()
            return Self.result(action, "<total>\(log.count)</total><content>\(items)</content>")
        case "modifyCallLog":
            let ids = Set(Self.fields("timeId", in: body).compactMap(Int.init))
            for index in log.indices where ids.contains(log[index].id) {
                log[index].acknowledged = true
            }
        case "getStaticState":
            let forward = forwardTarget.map {
                "<type>IMMEDIATE</type><targetNumber>\($0)</targetNumber><firstName></firstName>"
                    + "<name>\(Self.name($0))</name><targetType>NUMBER</targetType>"
            } ?? "<type>NO_FORWARD</type><targetNumber></targetNumber><firstName></firstName><name></name>"
                + "<targetType>NONE</targetType>"
            return Self.envelope("<ns2:getStaticStateResponse><getStaticStateReturn><campOnActivated>false"
                + "</campOnActivated><doNotDisturbActivated>false</doNotDisturbActivated><forwardState>\(forward)"
                + "</forwardState><locked>false</locked><overflowType>NO_OVERFLOW</overflowType>"
                + "</getStaticStateReturn></ns2:getStaticStateResponse>")
        case "getDynamicRouting":
            return Self.result(action, "<dynamicRoutingState>false</dynamicRoutingState><number></number>"
                + "<delay>20</delay><vmail>false</vmail>")
        case "setForwardState":
            forwardTarget = field("type") == "IMMEDIATE" ? field("targetNumber") : nil
            return Self.envelope("<ns2:setForwardStateResponse></ns2:setForwardStateResponse>")
        case "getPhoneBook":
            let prefix = field("name") ?? ""
            let items = Self.directory.filter { $0.1.lowercased().hasPrefix(prefix.lowercased()) }.map {
                "<item><dirNumber>\($0.0)</dirNumber><firstName></firstName><lastName>\($0.1)</lastName></item>"
            }
            return Self.result(action, "<total>\(items.count)</total><content>\(items.joined())</content>")
        case "subscribe":
            emitCalls()
            if incomingCall {
                incomingCall = false
                after(5) { $0.ring() }
            }
        case "makeCall":
            if call == nil, let callee = field("callee") {
                // The app dials external numbers with the trunk prefix.
                let external = callee.count > 5 && callee.hasPrefix("0")
                start(Call(ref: nextRef, number: external ? String(callee.dropFirst()) : callee,
                           state: "ringingOutgoing", incoming: false))
                let ref = nextRef
                after(3) { $0.connect(ref) }
            }
        case "takeCall":
            connect(field("callRef").flatMap(Int.init))
        case "clearCall":
            if let call, field("callRef").flatMap(Int.init) == call.ref {
                end(call)
            }
        default:
            break   // logout, unsubscribe, cancelDynamicRouting
        }
        return Self.envelope("<ns2:\(action)Response><result><code>0</code><label>OK</label></result>"
            + "</ns2:\(action)Response>")
    }

    // MARK: - calls

    private func ring() {
        guard call == nil else { return }
        start(Call(ref: nextRef, number: "02079460123", state: "ringingIncoming", incoming: true))
    }

    private func start(_ call: Call) {
        nextRef += 1
        self.call = call
        emitCalls()
    }

    private func connect(_ ref: Int?) {
        guard var call, call.ref == ref, call.answeredAt == nil else { return }
        call.state = "active"
        call.answeredAt = .now
        self.call = call
        emitCalls()
    }

    private func end(_ call: Call) {
        let answered = call.answeredAt != nil
        log.insert(LogEntry(id: 1000 + call.ref, number: call.number, incoming: call.incoming, answered: answered,
                            acknowledged: !call.incoming || answered, begin: call.begin,
                            ring: (call.answeredAt ?? .now).timeIntervalSince(call.begin),
                            talk: call.answeredAt.map { Date.now.timeIntervalSince($0) } ?? 0), at: 0)
        self.call = nil
        emitCalls()
        if call.incoming, !answered {
            emit("<ns2:e_unanswdCallNotifResponse><e_unanswdCallNotif><sessionId>\(Self.session)</sessionId>"
                + "</e_unanswdCallNotif></ns2:e_unanswdCallNotifResponse>")
        }
    }

    private func after(_ seconds: Int, _ action: @escaping @Sendable (isolated DemoPBX) -> Void) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            action(self)
        }
    }

    // MARK: - events

    func open(_ id: UUID, _ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        listeners[id] = continuation
        emit("<ns2:startSubscribeAppResponse><result>\(Self.ok)<subscribeId>1</subscribeId></result>"
            + "</ns2:startSubscribeAppResponse>")
    }

    func close(_ id: UUID) {
        listeners[id] = nil
    }

    private func emitCalls() {
        let content = call.map {
            "<content><item><callRef>\($0.ref)</callRef><number>\($0.number)</number>"
                + "<name>\($0.number.count <= 4 ? Self.name($0.number) : "")</name><state>\($0.state)</state>"
                + "</item></content>"
        } ?? ""
        emit("<ns2:e_callStateResponse><e_callState><sessionId>\(Self.session)</sessionId>\(content)"
            + "</e_callState></ns2:e_callStateResponse>")
    }

    private func emit(_ event: String) {
        let data = Data(Self.envelope(event).utf8)
        for listener in listeners.values {
            listener.yield(data)
        }
    }

    // MARK: - XML

    private static let session = "DEMO-SESSION"
    private static let ok = "<status><code>0</code><label>OK</label></status>"

    private static func name(_ number: String) -> String {
        directory.first { $0.0 == number }?.1 ?? ""
    }

    private static func result(_ action: String, _ content: String) -> String {
        envelope("<ns2:\(action)Response><result>\(ok)\(content)</result></ns2:\(action)Response>")
    }

    private static func envelope(_ inner: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><SOAP-ENV:Envelope "
            + "xmlns:SOAP-ENV=\"http://schemas.xmlsoap.org/soap/envelope/\" "
            + "xmlns:ns2=\"http://xmlapi.alcatel.com/phone\" xmlns:nsOxo2=\"http://xmlapi.alcatel.com/oxo\">"
            + "<SOAP-ENV:Body>\(inner)</SOAP-ENV:Body></SOAP-ENV:Envelope>"
    }

    private static let dateFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    private static func item(_ entry: LogEntry) -> String {
        func date(_ offset: TimeInterval) -> String { dateFormat.string(from: entry.begin.addingTimeInterval(offset)) }
        let external = entry.number.count > 4
        return "<item><itemId><timeId>\(entry.id)</timeId><diffId>\(entry.id)</diffId></itemId>"
            + "<dirNumber>\(line)</dirNumber><corrNumber><number>\(entry.number)</number><type>none</type>"
            + "</corrNumber><corrName>\(external ? "" : name(entry.number))</corrName><corrFirstName></corrFirstName>"
            + "<calltype><incoming>\(entry.incoming)</incoming><external>\(external)</external>"
            + "<redirected>false</redirected><answered>\(entry.answered)</answered></calltype>"
            + "<dateOfBegin>\(date(0))</dateOfBegin><dateOfConvers>\(date(entry.ring))</dateOfConvers>"
            + "<dateOfEnd>\(date(entry.ring + entry.talk))</dateOfEnd><cause>\(entry.cause)</cause>"
            + "<acknowledged>\(entry.acknowledged)</acknowledged></item>"
    }

    /// The text of every `<tag …>text</tag>` in a request, in order.
    private static func fields(_ tag: String, in body: String) -> [String] {
        var result: [String] = []
        var rest = body[...]
        while let open = rest.range(of: "<\(tag) "),
              let start = rest[open.upperBound...].firstIndex(of: ">"),
              let close = rest[start...].range(of: "</\(tag)>") {
            result.append(String(rest[rest.index(after: start)..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return result
    }
}
#endif
