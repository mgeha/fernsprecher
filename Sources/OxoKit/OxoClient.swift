import Foundation

/// The response element (`…Response`) or a SOAP fault, from a raw envelope.
func responseElement(_ data: Data) throws -> XMLNode {
    let root: XMLNode
    do {
        root = try parseXML(data)
    } catch {
        throw OxoError.invalidResponse("\(error)")
    }
    guard let body = root.find("Body"), let first = body.children.first else {
        throw OxoError.invalidResponse("empty SOAP body")
    }
    if first.name == "Fault" {
        throw OxoError.soapFault(first.value("faultstring") ?? "unknown")
    }
    return first
}

/// The RPC return value. The OXO names the wrapper inconsistently (`result`,
/// `loginResult`, `getStaticStateReturn`), so take the response element's
/// single child whatever it is called.
func resultNode(_ response: XMLNode) -> XMLNode {
    if response.children.count == 1, let only = response.children.first, !only.children.isEmpty {
        return only
    }
    return response
}

/// Talks to one OXO node.
///
/// The OXO allows one session per line: a second login invalidates the first
/// and every call on the old session fails with ``OxoError/badSession``.
public actor OxoClient {
    nonisolated let transport: SoapTransport
    public private(set) var sessionId: String?
    public private(set) var logon: LogonResult?
    /// Whether `subscribe` bound this session to an event stream.
    var eventsBound = false

    public init(transport: SoapTransport) {
        self.transport = transport
    }

    public init(host: String, port: Int = 443, trust: TrustPolicy = .system) {
        self.init(transport: HTTPSTransport(host: host, port: port, trust: trust))
    }

    /// SHA-256 of the certificate the PBX presented (HTTPS only, once
    /// connected).
    public nonisolated var certificateFingerprint: String? {
        (transport as? HTTPSTransport)?.certificateFingerprint
    }

    // MARK: - low level

    func call(_ service: String, action: String, method: String, namespace: String,
                      scalars: [SoapField] = [], structure: SoapStruct? = nil) async throws -> XMLNode {
        let body = buildEnvelope(method: method, serviceNamespace: namespace,
                                 scalars: scalars, structure: structure)
        let data = try await transport.post(service: service, soapAction: action, body: body)
        return try responseElement(data)
    }

    @discardableResult
    func requireStatus(_ response: XMLNode, _ operation: String) throws -> Status {
        if response.children.isEmpty {
            throw OxoError.emptyResponse(operation: operation)
        }
        let status = Status(response)
        if let code = status.code, code != 0 {
            switch code {
            case 55: throw OxoError.badSession
            case 8: throw OxoError.badPassword
            default: throw OxoError.status(operation: operation, code: code,
                                           label: status.label ?? "")
            }
        }
        return status
    }

    func sid() throws -> String {
        guard let sessionId else { throw OxoError.notLoggedIn }
        return sessionId
    }

    func phone(_ method: String, scalars: [SoapField] = [],
                       structure: SoapStruct? = nil) async throws -> XMLNode {
        try await call("XmlPhone", action: method, method: method, namespace: Namespace.phone,
                       scalars: scalars, structure: structure)
    }

    private func sessionScalar() throws -> [SoapField] {
        [SoapField("sessionId", .string(try sid()))]
    }

    // MARK: - session

    public func apiVersion() async throws -> String? {
        let response = try await call("XmlOxo", action: "privateOxo", method: "getAPIVersion",
                                      namespace: Namespace.oxo,
                                      scalars: [SoapField("sessionId", .string(sessionId ?? ""))])
        let text = response.value("result") ?? response.text
        return text.isEmpty ? nil : text
    }

    @discardableResult
    public func login(line: String, password: String) async throws -> LogonResult {
        _ = try? await apiVersion()   // advisory probe
        let structure = SoapStruct("UserLogin", Namespace.phoneTypes, [
            SoapField("loginName", .string(line)),
            SoapField("password", .string(password)),
        ])
        let response = try await phone("login", structure: structure)
        let result = resultNode(response)
        guard let session = result.value("sessionId") else {
            try requireStatus(response, "login")
            throw OxoError.invalidResponse("no sessionId")
        }
        let logon = LogonResult(sessionId: session,
                                userName: result.value("userName"),
                                name: result.value("name"),
                                firstName: result.value("firstName"),
                                lineNumber: result.value("lineNumber") ?? line)
        sessionId = session
        self.logon = logon
        return logon
    }

    /// Release the event binding, then the session (both best effort).
    public func logout() async {
        guard let sessionId else { return }
        let bound = eventsBound
        self.sessionId = nil
        logon = nil
        eventsBound = false
        let scalars = [SoapField("sessionId", .string(sessionId))]
        if bound {
            _ = try? await phone("unsubscribe", scalars: scalars)
        }
        _ = try? await phone("logout", scalars: scalars)
    }

    // MARK: - telephony

    public func makeCall(_ callee: String) async throws {
        let structure = SoapStruct("MakeCallInvoke", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("callee", .string(callee)),
            SoapField("mode", .string("normal")),
            SoapField("businessCodeOrPIN", .null),
        ])
        try requireStatus(try await phone("makeCall", structure: structure), "makeCall")
    }

    /// Answer the given ringing call – on the desk phone, hands-free.
    public func answer(callRef: String) async throws {
        try await callOperation("takeCall", type: "TakeCallInvoke", callRef: callRef)
    }

    /// Hang up the given call (active, held or ringing).
    public func hangup(callRef: String) async throws {
        try await callOperation("clearCall", type: "ClearCallInvoke", callRef: callRef)
    }

    /// The `…CurrentCall` variants act on whichever call the PBX deems
    /// current, which is not necessarily the one the user clicked.
    private func callOperation(_ operation: String, type: String, callRef: String) async throws {
        guard Int64(callRef) != nil else { throw OxoError.invalidResponse("callRef \(callRef)") }
        let structure = SoapStruct(type, Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("callRef", .long(callRef)),
        ])
        try requireStatus(try await phone(operation, structure: structure), operation)
    }

    // MARK: - call log

    public func callLog(index: Int = 0, count: Int = 50) async throws -> (total: Int?, entries: [CallLogEntry]) {
        let selector = SoapStruct("CallLogSelector", Namespace.phoneTypes, [
            SoapField("index", .int(index)),
            SoapField("nbItems", .int(count)),
            SoapField("filterActivated", .int(0)),
        ])
        let structure = SoapStruct("GetCallLogInvoke", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("selector", .structure(selector)),
        ])
        let response = try await phone("getCallLog", structure: structure)
        try requireStatus(response, "getCallLog")
        let result = resultNode(response)
        let items = result.child("content")?.children(named: "item") ?? []
        return (result.value("total").flatMap(Int.init), items.compactMap(CallLogEntry.init))
    }

    /// Missed calls not yet acknowledged, across the whole call log.
    public func unansweredCount() async throws -> Int {
        let response = try await phone("getNbUnansweredCall", scalars: try sessionScalar())
        try requireStatus(response, "getNbUnansweredCall")
        guard let count = resultNode(response).value("nbUCall").flatMap(Int.init) else {
            throw OxoError.invalidResponse("nbUCall missing")
        }
        return count
    }

    /// Mark call-log entries as seen; acknowledged missed calls no longer
    /// count in ``unansweredCount()``.
    public func acknowledge(_ ids: [CallLogItemId], ack: Bool = true) async throws {
        guard !ids.isEmpty else { return }
        let items = ids.map { id in
            SoapStruct("ItemMod", Namespace.phoneTypes, [
                SoapField("id", .structure(SoapStruct("ItemId", Namespace.phoneTypes, [
                    SoapField("timeId", .long(id.timeId)),
                    SoapField("diffId", .long(id.diffId)),
                ]))),
                SoapField("ack", .bool(ack)),
            ])
        }
        let structure = SoapStruct("ModifyCallLog", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("content", .array(SoapArray("ItemMod", Namespace.phoneTypes, items))),
        ])
        try requireStatus(try await phone("modifyCallLog", structure: structure), "modifyCallLog")
    }

    // MARK: - forward

    /// The line's forward (`getStaticState`), else a forward on no answer set
    /// as dynamic routing (`getDynamicRouting`), as other clients set it. The
    /// static state does not show that one, and the PBX sends no event for it
    /// (observed on an R63).
    public func forwardState() async throws -> ForwardState {
        let response = try await phone("getStaticState", scalars: try sessionScalar())
        try requireStatus(response, "getStaticState")
        let state = ForwardState(staticState: resultNode(response))
        if state.isActive { return state }
        let routing = try await phone("getDynamicRouting", scalars: try sessionScalar())
        try requireStatus(routing, "getDynamicRouting")
        return ForwardState(dynamicRouting: resultNode(routing))
    }

    /// Forward all calls to `number`, dialled as given (`XmlPhone
    /// setForwardState`). The R63 answers `activateForward` but ignores it.
    /// `setOXOUserState` works too, but rewrites the whole user state (names,
    /// barring) and takes effect later.
    public func forward(to number: String) async throws {
        try await setForwardState(type: "IMMEDIATE", number: number, targetType: "NUMBER")
    }

    /// Cancels both: `NO_FORWARD` leaves dynamic routing on (observed on an
    /// R63). `cancelDynamicRouting` answers OK even when none is set.
    public func cancelForward() async throws {
        try await setForwardState(type: "NO_FORWARD", number: "", targetType: "NONE")
        try requireStatus(try await phone("cancelDynamicRouting", scalars: try sessionScalar()),
                          "cancelDynamicRouting")
    }

    /// The PBX answers without a status (the method returns `void`); whether
    /// it took effect shows in ``forwardState()``.
    func setForwardState(type: String, number: String, targetType: String) async throws {
        let state = SoapStruct("AlcForwardState", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("type", .scalar(type, xsd: "q:AlcForwardType")),
            SoapField("targetNumber", .string(number)),
            SoapField("duration", .int(0)),
            SoapField("firstName", .string("")),
            SoapField("name", .string("")),
            SoapField("targetType", .scalar(targetType, xsd: "q:AlcForwardTargetType")),
        ])
        let response = try await phone("setForwardState", scalars: [SoapField("pForwardState", .structure(state))])
        let status = Status(response)
        if let code = status.code, code != 0 {
            throw code == 55 ? OxoError.badSession
                : OxoError.status(operation: "setForwardState", code: code, label: status.label ?? "")
        }
    }

    /// The user's state (`XmlOxo getOXOUserState`): names, barring, static
    /// state with the forward, nomadic state. Returns the result with `status`
    /// and `oxoUserState`. For diagnosis only.
    public func userState(loginName: String) async throws -> XMLNode {
        let structure = SoapStruct("GetOXOUserStateInvoke", Namespace.oxoTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("loginName", .string(loginName)),
        ])
        let response = try await call("XmlOxo", action: "privateOxo", method: "getOXOUserState",
                                      namespace: Namespace.oxo, structure: structure)
        try requireStatus(response, "getOXOUserState")
        return resultNode(response)
    }

    // MARK: - phone book

    /// Internal PBX directory; `name` is a prefix search, empty returns all.
    public func phoneBook(name: String = "", count: Int = 500) async throws -> [PhoneBookEntry] {
        let selector = SoapStruct("Selector", Namespace.phoneTypes, [
            SoapField("name", .string(name)),
            SoapField("index", .int(0)),
            SoapField("nbItems", .int(count)),
        ])
        let structure = SoapStruct("GetPhoneBookInvoke", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("selector", .structure(selector)),
        ])
        let response = try await phone("getPhoneBook", structure: structure)
        try requireStatus(response, "getPhoneBook")
        let items = resultNode(response).child("content")?.children(named: "item") ?? []
        return items.compactMap(PhoneBookEntry.init)
    }
}
