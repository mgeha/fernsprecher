import Foundation

/// A minimal, lenient element tree keyed by local names: namespaces and
/// prefixes are ignored.
public final class XMLNode: @unchecked Sendable {
    public let name: String
    public internal(set) var text: String = ""
    public internal(set) var children: [XMLNode] = []

    init(name: String) {
        self.name = name
    }

    public func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    public func children(named name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }

    public func find(_ name: String) -> XMLNode? {
        if self.name == name { return self }
        for child in children {
            if let hit = child.find(name) { return hit }
        }
        return nil
    }

    /// Trimmed text of a direct child, `nil` when missing or empty.
    public func value(_ name: String) -> String? {
        guard let text = child(name)?.text, !text.isEmpty else { return nil }
        return text
    }

    public func bool(_ name: String) -> Bool { value(name) == "true" }
}

enum XMLTreeError: Error {
    case rejectedDTD
    case malformed(String)
}

private final class TreeBuilder: NSObject, XMLParserDelegate {
    var stack: [XMLNode] = []
    var root: XMLNode?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
        let node = XMLNode(name: local)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if let node = stack.popLast() {
            node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// Responses come from the PBX, so they are only semi-trusted: any DOCTYPE or
/// ENTITY declaration is rejected before parsing (no entity expansion).
func parseXML(_ data: Data) throws -> XMLNode {
    let probe = String(decoding: data, as: UTF8.self).uppercased()
    if probe.contains("<!DOCTYPE") || probe.contains("<!ENTITY") {
        throw XMLTreeError.rejectedDTD
    }
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    let builder = TreeBuilder()
    parser.delegate = builder
    guard parser.parse(), let root = builder.root else {
        throw XMLTreeError.malformed(parser.parserError?.localizedDescription ?? "no root")
    }
    return root
}
