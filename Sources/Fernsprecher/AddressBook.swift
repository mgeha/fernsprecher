import Foundation

struct AddressBookEntry: Codable, Sendable, Equatable, Identifiable {
    /// Normalized with ``AddressBook/key(_:)``.
    var number: String
    var name: String

    var id: String { number }
}

/// The user's own names for numbers (one file per Mac). Numbers come from the
/// call log, so they are in the PBX's format already; only formatting
/// characters are ignored when matching.
struct AddressBook: Codable, Sendable, Equatable {
    private(set) var version = 1
    /// Sorted by name.
    private(set) var entries: [AddressBookEntry] = []

    /// Digits plus `*`, `#`, `+`, so "0120 001-234" and "0120001234" match.
    static func key(_ number: String) -> String {
        number.filter { $0.isNumber || "*#+".contains($0) }
    }

    /// For searching only: a typed external number finds entries with or
    /// without a leading `0` (`0123` and `123`). Shorter queries get no
    /// variants: internal numbers have at most 4 digits. Never used to match
    /// a name to a number: the trunk prefix `0` is the same digit as the
    /// national prefix, so `05555512` (national) and `5555512` (local) are
    /// different numbers.
    static func variants(_ key: String) -> [String] {
        guard key.allSatisfy(\.isNumber), key.drop(while: { $0 == "0" }).count >= 5 else { return [key] }
        return key.hasPrefix("0") ? [key, "0" + key, String(key.dropFirst())] : [key, "0" + key]
    }

    /// What to dial for a number in the PBX's own form (call log, address
    /// book: `0123…`, `55555`, `0043…`): external numbers get the trunk
    /// prefix, `+…` becomes `00…`. Internal numbers (at most 4 digits) and
    /// codes with `*`/`#` stay as they are.
    static func dialString(_ number: String, trunkPrefix: String) -> String {
        let key = Self.key(number)
        if key.hasPrefix("+"), key.count > 1 { return trunkPrefix + "00" + key.dropFirst() }
        guard key.count >= 5, key.allSatisfy(\.isNumber) else { return number }
        return trunkPrefix + key
    }

    /// The reverse for a number as dialled (`00123…`, `055555`): external
    /// numbers lose the trunk prefix and are back in the PBX's form. Anything
    /// else stays as it is.
    static func withoutTrunkPrefix(_ number: String, trunkPrefix: String) -> String {
        let key = Self.key(number)
        guard !trunkPrefix.isEmpty, key.hasPrefix(trunkPrefix) else { return number }
        let rest = key.dropFirst(trunkPrefix.count)
        guard rest.count >= 5, rest.allSatisfy(\.isNumber) else { return number }
        return String(rest)
    }

    func entry(for number: String?) -> AddressBookEntry? {
        guard let number else { return nil }
        let key = Self.key(number)
        guard !key.isEmpty else { return nil }
        // Entries are stored in the PBX's form (`0123…`, `55555`), as the
        // call log reports them, so `dialString` adds the trunk prefix once.
        return entries.first { $0.number == key }
    }

    func name(for number: String?) -> String? {
        entry(for: number)?.name
    }

    /// Add or rename; an empty name removes the entry.
    mutating func set(name: String, for number: String) {
        let key = Self.key(number)
        guard !key.isEmpty else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        entries.removeAll { $0.number == key }
        if !name.isEmpty {
            entries.append(AddressBookEntry(number: key, name: name))
            entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    mutating func remove(number: String) {
        let key = Self.key(number)
        entries.removeAll { $0.number == key }
    }

    /// The query as a number key if it is a number (digits, `*#+`, spaces,
    /// dashes, slashes, brackets); nil for anything with letters.
    static func numberKey(_ query: String) -> String? {
        let cleaned = query.filter { !" -/()".contains($0) }
        guard !cleaned.isEmpty, cleaned.allSatisfy({ $0.isNumber || "*#+".contains($0) }) else { return nil }
        return cleaned
    }

    /// Search match for a number: `key` (from ``numberKey(_:)``) occurs
    /// anywhere in it, with or without the trunk prefix `0`.
    static func number(_ number: String, contains key: String) -> Bool {
        let number = Self.key(number)
        return variants(key).contains { number.contains($0) }
    }

    /// Name contains the query, or the query is a number found in the entry's.
    func search(_ query: String) -> [AddressBookEntry] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return entries }
        let key = Self.numberKey(needle)
        return entries.filter { entry in
            entry.name.localizedCaseInsensitiveContains(needle)
                || key.map { Self.number(entry.number, contains: $0) } == true
        }
    }

    // MARK: - file

    /// A missing file is an empty address book; an unreadable one throws.
    static func load(from url: URL) throws -> AddressBook {
        guard FileManager.default.fileExists(atPath: url.path) else { return AddressBook() }
        return try JSONDecoder().decode(AddressBook.self, from: Data(contentsOf: url))
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
