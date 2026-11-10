import Foundation

// Probes for oxoctl: operations the app does not use (yet), to try them
// against a real PBX.
extension OxoClient {
    /// Any XmlPhone operation that takes just the session id.
    public func probe(_ method: String) async throws -> XMLNode {
        try await phone(method, scalars: [SoapField("sessionId", .string(try sid()))])
    }

    /// `setForwardState` with any type/targetType (IMMEDIATE, ON_BUSY, …; NUMBER, VOICE_MAIL).
    public func probeForward(type: String, number: String, targetType: String) async throws {
        try await setForwardState(type: type, number: number, targetType: targetType)
    }

    public func probeDoNotDisturb(_ on: Bool) async throws -> XMLNode {
        try await phone("setDoNotDisturbState", scalars: [
            SoapField("sessionId", .string(try sid())),
            SoapField("pDoNotDisturbActivated", .bool(on)),
        ])
    }

    public func probeDynamicRouting(toVM: Bool, number: String, delay: Int) async throws -> XMLNode {
        try await phone("activateDynamicRouting", structure: SoapStruct("ActivateDynamicRoutingInvoke", Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("toVM", .bool(toVM)),
            SoapField("number", .string(number)),
            SoapField("delay", .int(delay)),
        ]))
    }

    /// Operations taking `{sessionId, callRef}` (takeCall, clearCall, holdCall, reconnectCall, …).
    public func probeCall(_ method: String, type: String, callRef: String) async throws -> XMLNode {
        try await phone(method, structure: SoapStruct(type, Namespace.phoneTypes, [
            SoapField("sessionId", .string(try sid())),
            SoapField("callRef", .long(callRef)),
        ]))
    }
}
