import Foundation

/// SOAP 1.1 RPC/encoded envelope builder in the form the OXO's XML API
/// expects (as read on the wire).
///
/// * scalar parameters are written inline inside the method element;
/// * struct parameters become a multi-ref `<invoke href="#idN"/>` plus a typed
///   block carrying `id="idN"`; nested structs and arrays get their own id.
public enum SoapValue: Sendable {
    /// A simple value with its XSD type (`string`, `int`, `long`, `boolean`)
    /// or a prefixed enum type such as `q:ForwardType`.
    case scalar(String, xsd: String = "string")
    case null
    case structure(SoapStruct)
    case array(SoapArray)

    public static func string(_ value: String) -> SoapValue { .scalar(value) }
    public static func int(_ value: Int) -> SoapValue { .scalar(String(value), xsd: "int") }
    public static func long(_ value: String) -> SoapValue { .scalar(value, xsd: "long") }
    public static func bool(_ value: Bool) -> SoapValue {
        .scalar(value ? "true" : "false", xsd: "boolean")
    }
}

public struct SoapField: Sendable {
    public var name: String
    public var value: SoapValue

    public init(_ name: String, _ value: SoapValue) {
        self.name = name
        self.value = value
    }
}

public struct SoapStruct: Sendable {
    public var typeName: String
    public var typesNamespace: String
    public var fields: [SoapField]

    public init(_ typeName: String, _ typesNamespace: String, _ fields: [SoapField]) {
        self.typeName = typeName
        self.typesNamespace = typesNamespace
        self.fields = fields
    }
}

/// A SOAP-encoded array of structs, in the form read on the wire:
/// `<soapenc:Array soapenc:arrayType="q:ItemMod[n]">` with `<Item href=…/>`.
public struct SoapArray: Sendable {
    public var itemType: String
    public var typesNamespace: String
    public var items: [SoapStruct]

    public init(_ itemType: String, _ typesNamespace: String, _ items: [SoapStruct]) {
        self.itemType = itemType
        self.typesNamespace = typesNamespace
        self.items = items
    }
}

enum Namespace {
    static let envelope = "http://schemas.xmlsoap.org/soap/envelope/"
    static let encoding = "http://schemas.xmlsoap.org/soap/encoding/"
    static let phone = "http://xmlapi.alcatel.com/phone"
    static let phoneTypes = phone + "/types"
    static let oxo = "http://xmlapi.alcatel.com/oxo"
    /// Without `http://`; the OXO expects this namespace exactly so (as read on the wire).
    static let oxoTypes = "xmlapi.alcatel.com/oxo/types"
    static let app = "http://xmlapi.alcatel.com/app"
}

func xmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func qualify(_ xsd: String) -> String {
    xsd.contains(":") ? xsd : "xsd:\(xsd)"
}

private final class EnvelopeBuilder {
    private var nextId = 1
    private var trailing: [String] = []

    private func newId() -> String {
        defer { nextId += 1 }
        return "id\(nextId)"
    }

    private func member(_ field: SoapField) -> String {
        switch field.value {
        case .scalar(let value, let xsd):
            return "<\(field.name) xsi:type=\"\(qualify(xsd))\">\(xmlEscape(value))</\(field.name)>"
        case .null:
            return "<\(field.name) xsi:nil=\"true\" />"
        case .structure(let inner):
            return "<\(field.name) href=\"#\(emit(inner))\" />"
        case .array(let array):
            return "<\(field.name) href=\"#\(emit(array))\" />"
        }
    }

    func emit(_ structure: SoapStruct) -> String {
        let ident = newId()
        var parts = ["<q:\(structure.typeName) id=\"\(ident)\" xsi:type=\"q:\(structure.typeName)\" "
                     + "xmlns:q=\"\(structure.typesNamespace)\">"]
        for field in structure.fields {
            parts.append(member(field))
        }
        parts.append("</q:\(structure.typeName)>")
        trailing.append(parts.joined())
        return ident
    }

    func emit(_ array: SoapArray) -> String {
        let ident = newId()
        let refs = array.items.map { emit($0) }
        let items = refs.map { "<Item href=\"#\($0)\" />" }.joined()
        trailing.append("<soapenc:Array id=\"\(ident)\" xmlns:q=\"\(array.typesNamespace)\" "
                        + "soapenc:arrayType=\"q:\(array.itemType)[\(refs.count)]\">"
                        + "\(items)</soapenc:Array>")
        return ident
    }

    func build(method: String, serviceNamespace: String,
               scalars: [SoapField], structure: SoapStruct?) -> Data {
        var inner: [String] = []
        if let structure {
            inner.append("<invoke href=\"#\(emit(structure))\" />")
        }
        for field in scalars {
            inner.append(member(field))
        }
        let body = "<tns:\(method)>\(inner.joined())</tns:\(method)>" + trailing.joined()
        let envelope = "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
            + "<soap:Envelope xmlns:soap=\"\(Namespace.envelope)\" xmlns:soapenc=\"\(Namespace.encoding)\" "
            + "xmlns:tns=\"\(serviceNamespace)\" "
            + "xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" "
            + "xmlns:xsd=\"http://www.w3.org/2001/XMLSchema\">"
            + "<soap:Body soap:encodingStyle=\"\(Namespace.encoding)\">\(body)</soap:Body>"
            + "</soap:Envelope>"
        return Data(envelope.utf8)
    }
}

/// Uses a fresh id counter per call.
public func buildEnvelope(method: String, serviceNamespace: String,
                          scalars: [SoapField] = [], structure: SoapStruct? = nil) -> Data {
    EnvelopeBuilder().build(method: method, serviceNamespace: serviceNamespace,
                            scalars: scalars, structure: structure)
}
