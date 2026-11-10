import Foundation

public struct Status: Sendable, Equatable {
    public var code: Int?
    public var label: String?

    public var ok: Bool { code == 0 }

    /// Depth-first lookup of `code`/`label`.
    init(_ node: XMLNode) {
        code = node.find("code").flatMap { Int($0.text) }
        label = node.find("label")?.text
    }
}

public struct LogonResult: Sendable {
    public var sessionId: String
    public var userName: String?
    /// Display name as configured in the PBX, e.g. "Muster M 51".
    public var name: String?
    public var firstName: String?
    public var lineNumber: String?
}

/// Identifies a call-log entry for `modifyCallLog`; opaque outside OxoKit.
public struct CallLogItemId: Sendable, Hashable {
    var timeId: String
    var diffId: String

    init(timeId: String, diffId: String) {
        self.timeId = timeId
        self.diffId = diffId
    }
}

public struct CallLogEntry: Sendable, Identifiable, Equatable {
    public var id: CallLogItemId
    /// Local PBX time of the call start.
    public var date: Date?
    /// The other party's number in the PBX's form, i.e. external numbers
    /// without the trunk prefix.
    public var number: String?
    /// What was dialled, for outgoing calls without a resolved ``number``
    /// (seen: `***` with cause `busy`). Shown, but not offered for redial.
    public var dialled: String?
    public var name: String?
    public var incoming: Bool
    public var answered: Bool
    public var acknowledged: Bool
    public var outcome: CallOutcome
    /// Where the call went instead (forwarded, picked up), if anywhere.
    public var newDestNumber: String?
    /// Talk time of an answered call (`dateOfConvers` to `dateOfEnd`).
    public var duration: TimeInterval?
    /// How long an unanswered call rang (`dateOfBegin` to `dateOfConvers`;
    /// on an R63, `dateOfConvers` equals `dateOfEnd` for such calls).
    public var ringDuration: TimeInterval?

    public var missed: Bool { incoming && !answered }
    public var unreached: Bool { !incoming && !answered }

    public var displayNumber: String? { number ?? dialled }
}

/// What happened to a logged call, from the PBX's `CallCause`.
public enum CallOutcome: Sendable, Equatable {
    /// `none` or no cause: answered, missed or unreached as such.
    case normal
    case busy
    case voiceMail
    /// Someone else picked the call up (`pickupVictim`).
    case pickedUpElsewhere
    /// This line picked up a call for someone else (`pickupIncoming`).
    case pickedUp
    case forwarded
    case transferred
    /// A cause whose meaning is unclear.
    case other(String)

    init(cause: String?) {
        switch cause {
        case nil, "none": self = .normal
        case "busy", "trunksBusy": self = .busy
        case "voiceMail": self = .voiceMail
        case "pickupVictim": self = .pickedUpElsewhere
        case "pickupIncoming": self = .pickedUp
        case "redirectedTo", "redirectedOutgoing", "forward", "forwardAlways", "forwardBusy", "forwardNoAnswer":
            self = .forwarded
        case "transfer", "singleStepTransfer": self = .transferred
        case let cause?: self = .other(cause)
        }
    }
}

public struct PhoneBookEntry: Sendable, Identifiable, Equatable, Hashable {
    public var number: String
    public var lastName: String
    public var firstName: String?

    public var id: String { number + "|" + lastName }

    /// The OXO puts the whole display name ("Beispiel B 19") into `lastName`.
    public var displayName: String {
        [lastName, firstName].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

/// `dateOfBegin` comes as local PBX time without zone, e.g. `2026-10-14T20:54:44`.
let pbxDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
    return formatter
}()

extension CallLogEntry {
    init?(_ node: XMLNode) {
        guard let itemId = node.child("itemId"),
              let timeId = itemId.value("timeId"),
              let diffId = itemId.value("diffId") else { return nil }
        id = CallLogItemId(timeId: timeId, diffId: diffId)
        date = node.value("dateOfBegin").flatMap { pbxDateFormatter.date(from: $0) }
        number = node.child("corrNumber")?.value("number")
        let names = [node.value("corrName"), node.value("corrFirstName")].compactMap { $0 }
        name = names.isEmpty ? nil : names.joined(separator: " ")
        let callType = node.child("calltype")
        incoming = callType?.bool("incoming") ?? false
        answered = callType?.bool("answered") ?? false
        acknowledged = node.bool("acknowledged")
        outcome = CallOutcome(cause: node.value("cause"))
        newDestNumber = node.value("newDestNumber")
        dialled = incoming || number != nil ? nil : node.child("initialNumber")?.value("number")
        let convers = node.value("dateOfConvers").flatMap { pbxDateFormatter.date(from: $0) }
        if answered {
            if let convers, let end = node.value("dateOfEnd").flatMap({ pbxDateFormatter.date(from: $0) }),
               end >= convers {
                duration = end.timeIntervalSince(convers)
            }
        } else if let date, let convers, convers >= date {
            ringDuration = convers.timeIntervalSince(date)
        }
    }
}

extension PhoneBookEntry {
    init?(_ node: XMLNode) {
        guard let number = node.value("dirNumber") else { return nil }
        self.number = number
        lastName = node.value("lastName") ?? ""
        firstName = node.value("firstName")
    }
}

/// `CallState` of the PBX. Seen on an R63 so far: `ringingIncoming`, `active`.
public enum CallState: String, Sendable {
    case initiating = "init"
    case dialing, ringingIncoming, ringingOutgoing, active, held, conferenced, recording, waiting, releasing
    case unknown
}

/// A call currently present on the line, from the `e_callState` snapshot,
/// enriched by `e_callChange`.
public struct ActiveCall: Sendable, Identifiable, Equatable {
    public var callRef: String
    public var number: String?
    public var name: String?
    public var state: CallState
    /// The call was redirected to this line (forward, overflow).
    public var redirected = false
    /// The number the caller dialled, if not this line, e.g. a group or a
    /// colleague forwarding here.
    public var initialCalledNumber: String?
    public var initialCalledName: String?
    /// ACD/hunt group the call came through.
    public var groupName: String?
    /// The call rang in on this line; stays true once answered.
    public var isIncoming = false

    public var id: String { callRef }
    public var isRinging: Bool { state == .ringingIncoming }
    public var isActive: Bool { state == .active }

    mutating func apply(_ change: CallChange) {
        redirected = change.redirected
        initialCalledNumber = change.initialCalledNumber
        initialCalledName = change.initialCalledName
        groupName = change.groupName
    }
}

/// The details `e_callChange` reports for one call beyond the snapshot.
struct CallChange: Sendable, Equatable {
    var callRef: String
    /// False once the call is gone.
    var isPresent: Bool
    var redirected: Bool
    var initialCalledNumber: String?
    var initialCalledName: String?
    var groupName: String?

    init?(_ event: OxoEvent) {
        let payload = event.payload
        guard event.name == "e_callChange", let callRef = payload.value("callRef") else { return nil }
        self.callRef = callRef
        isPresent = payload.bool("callIsPresent")
        redirected = payload.bool("callIsRedirect")
        initialCalledNumber = payload.value("initialCalledNumber")
        initialCalledName = payload.value("initialCalledName")
        let group = payload.child("acdCalling")
        groupName = group?.value("groupName") ?? group?.value("groupNumber")
    }

    /// Keeps what `earlier` said about how the call came in where this
    /// change is silent, e.g. on answering.
    mutating func keepRoute(of earlier: CallChange) {
        redirected = redirected || earlier.redirected
        initialCalledNumber = initialCalledNumber ?? earlier.initialCalledNumber
        initialCalledName = initialCalledName ?? earlier.initialCalledName
        groupName = groupName ?? earlier.groupName
    }
}

extension ActiveCall {
    init?(_ node: XMLNode) {
        guard let callRef = node.value("callRef") else { return nil }
        self.callRef = callRef
        number = node.value("number")
        name = node.value("name")
        state = node.value("state").flatMap(CallState.init(rawValue:)) ?? .unknown
    }

    /// All calls in an `e_callState` event; an empty event means no calls.
    static func snapshot(_ event: OxoEvent) -> [ActiveCall] {
        (event.payload.child("content")?.children(named: "item") ?? []).compactMap(ActiveCall.init)
    }
}

/// `AlcForwardType`: which forward is set on the line.
public enum ForwardKind: Sendable, Equatable {
    case none, immediate, onBusy, onNoAnswer
}

/// The line's forward from `getStaticState` (`AlcForwardState`) or
/// `getDynamicRouting`, whether set here, on the desk phone or by another client.
public struct ForwardState: Sendable, Equatable {
    public var kind: ForwardKind
    public var targetNumber: String?
    public var targetName: String?
    public var toVoiceMail: Bool

    public static let off = ForwardState(kind: .none, targetNumber: nil, targetName: nil, toVoiceMail: false)

    public init(kind: ForwardKind, targetNumber: String?, targetName: String?, toVoiceMail: Bool) {
        self.kind = kind
        self.targetNumber = targetNumber
        self.targetName = targetName
        self.toVoiceMail = toVoiceMail
    }

    public var isActive: Bool { kind != .none }
}

extension ForwardState {
    /// `staticState`: the `AlcStaticState` (return value of `getStaticState`).
    init(staticState: XMLNode) {
        guard let node = staticState.child("forwardState") else {
            self = .off
            return
        }
        let kind: ForwardKind = switch node.value("type") {
        case "IMMEDIATE": .immediate
        case "ON_BUSY": .onBusy
        case "ON_NO_ANSWER": .onNoAnswer
        default: .none
        }
        guard kind != .none else {
            self = .off
            return
        }
        let name = [node.value("firstName"), node.value("name")].compactMap { $0 }.joined(separator: " ")
        self.init(kind: kind, targetNumber: node.value("targetNumber"), targetName: name.isEmpty ? nil : name,
                  toVoiceMail: node.value("targetType") == "VOICE_MAIL")
    }

    /// `routing`: the result of `getDynamicRouting` (`dynamicRoutingState`,
    /// `number`, `delay`, `vmail`). The PBX names no target.
    init(dynamicRouting routing: XMLNode) {
        guard routing.bool("dynamicRoutingState") else {
            self = .off
            return
        }
        let number = routing.value("number")
        self.init(kind: .onNoAnswer, targetNumber: number?.isEmpty == false ? number : nil, targetName: nil,
                  toVoiceMail: routing.bool("vmail"))
    }
}
