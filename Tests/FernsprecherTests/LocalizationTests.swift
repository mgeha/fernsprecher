import Foundation
import Testing

/// Checks the translation tables in Resources/*.lproj, which build-app.sh
/// copies into the app bundle (they are not part of the SwiftPM targets).
struct LocalizationTests {
    static let root = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let resources = root.appending(path: "Resources")
    static let languages = ["en", "de"]

    static func table(_ language: String, _ name: String = "Localizable") throws -> [String: String] {
        let url = resources.appending(path: "\(language).lproj/\(name).strings")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: String], "\(url.lastPathComponent) is no string table")
    }

    // MARK: - format specifiers

    struct FormatError: Error, CustomStringConvertible {
        let description: String
    }

    /// Argument index (1-based) → type, e.g. `lld` or `@`, for `%@`, `%lld`,
    /// `%2$@`. Positional and sequential arguments must not be mixed.
    static func arguments(_ format: String) throws -> [Int: String] {
        let pattern = /%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(hh|h|ll|l|q|z|t|j|L)?([@dDiuUxXoOfFeEgGcCsSpaA%])/
        var result: [Int: String] = [:]
        var next = 1
        var positional: Bool?
        for match in format.matches(of: pattern) {
            let type = (match.2.map(String.init) ?? "") + String(match.3)
            if type == "%" { continue }
            let index: Int
            if let position = match.1 {
                guard positional != false else { throw FormatError(description: "mixed arguments in \(format)") }
                positional = true
                index = Int(position)!
            } else {
                guard positional != true else { throw FormatError(description: "mixed arguments in \(format)") }
                positional = false
                index = next
                next += 1
            }
            if let seen = result[index], seen != type {
                throw FormatError(description: "argument \(index) used as \(seen) and \(type) in \(format)")
            }
            result[index] = type
        }
        return result
    }

    @Test func argumentsAreParsedByTypeAndPosition() throws {
        #expect(try Self.arguments("%@ failed: %lld %@") == [1: "@", 2: "lld", 3: "@"])
        #expect(try Self.arguments("%3$@ – %1$@ (%2$lld)") == [1: "@", 2: "lld", 3: "@"])
        #expect(try Self.arguments("100 %% sure") == [:])
        #expect(throws: FormatError.self) { try Self.arguments("%1$@ and %@") }
    }

    /// Same arguments with the same types; German may reorder them.
    @Test func translationsKeepTheArguments() throws {
        for language in Self.languages {
            for (key, value) in try Self.table(language) {
                let expected = try Self.arguments(key)
                let actual = try Self.arguments(value)
                #expect(actual == expected, "\(language): \"\(key)\" → \"\(value)\"")
            }
        }
    }

    // MARK: - tables

    @Test func tablesParse() throws {
        #expect(try Self.table("en").isEmpty)   // English: the keys are the texts
        #expect(try Self.table("de").count > 100)
    }

    @Test func infoPlistIsTranslated() throws {
        for language in Self.languages {
            let table = try Self.table(language, "InfoPlist")
            #expect(table["NSLocalNetworkUsageDescription"]?.isEmpty == false, "\(language)")
        }
    }

    // MARK: - lookups in an app-shaped bundle

    /// The layout build-app.sh produces: Info.plist plus the .lproj folders.
    struct AppBundle: ~Copyable {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let bundle: Bundle

        init() throws {
            let contents = root.appending(path: "Test.app/Contents")
            let resources = contents.appending(path: "Resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: LocalizationTests.resources.appending(path: "Info.plist"),
                                             to: contents.appending(path: "Info.plist"))
            for language in LocalizationTests.languages {
                try FileManager.default.copyItem(
                    at: LocalizationTests.resources.appending(path: "\(language).lproj"),
                    to: resources.appending(path: "\(language).lproj"))
            }
            bundle = try #require(Bundle(url: root.appending(path: "Test.app")))
        }

        /// Only the given language's table, like a process running in it.
        func language(_ code: String) throws -> Bundle {
            try #require(bundle.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:)))
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    @Test func germanLookups() throws {
        // A value with wrong specifiers would crash the formatting below
        // and take the whole test run with it; fail here instead.
        let table = try Self.table("de")
        for key in ["Connected as %@", "Load older (%lld of %lld)", "%@ failed: %lld %@", "%@ to %@ · %@"] {
            let value = try #require(table[key], "\(key)")
            try #require(try Self.arguments(value) == Self.arguments(key), "\(key) → \(value)")
        }
        let app = try AppBundle()
        let de = try app.language("de")
        let name = "Anna"
        let (shown, total) = (50, 152)
        let operation = "login"
        let label = "UnknownUser"
        #expect(String(localized: "No forward", bundle: de) == "Keine Umleitung")
        #expect(String(localized: "Connected as \(name)", bundle: de) == "Verbunden als Anna")
        #expect(String(localized: "Load older (\(shown) of \(total))", bundle: de) == "Ältere laden (50 von 152)")
        #expect(String(localized: "\(operation) failed: \(4) \(label)", bundle: de)
                    == "login fehlgeschlagen: 4 UnknownUser")
        #expect(String(localized: "\(label) to \(name) · \(operation)", bundle: de) == "UnknownUser auf Anna · login")
        #expect(String(localized: "Not in any table", bundle: de) == "Not in any table")   // English fallback
    }

    @Test func englishLookups() throws {
        let app = try AppBundle()
        let en = try app.language("en")
        let name = "Anna"
        #expect(String(localized: "No forward", bundle: en) == "No forward")
        #expect(String(localized: "Connected as \(name)", bundle: en) == "Connected as Anna")
    }

    /// What macOS picks from the user's preferred languages: the first one
    /// translated, else the development language (English).
    @Test func languageSelection() throws {
        let app = try AppBundle()
        #expect(Set(app.bundle.localizations) == ["en", "de"])
        #expect(app.bundle.developmentLocalization == "en")
        func pick(_ preferences: [String]) -> String? {
            Bundle.preferredLocalizations(from: app.bundle.localizations, forPreferences: preferences).first
        }
        #expect(pick(["de-DE"]) == "de")
        #expect(pick(["de"]) == "de")
        #expect(pick(["en-GB"]) == "en")
        #expect(pick(["fr-FR", "de-DE"]) == "de")
        #expect(pick(["fr-FR"]) == "en")
    }

    // MARK: - source scan

    /// Texts in the source that SwiftUI or `String(localized:)` look up, with
    /// interpolations as `%@`. An aid only: texts passed through variables or
    /// built in other ways are not found.
    static func sourceKeys() throws -> Set<String> {
        let sources = root.appending(path: "Sources/Fernsprecher")
        var files = [root.appending(path: "Sources/OxoKit/OxoError.swift")]
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        let call = #"(?:String\(localized:|\b(?:Text|Button|Label|Toggle|TextField|SecureField|Picker|LabeledContent|Section|Menu|Footnote)\(|\.help\()\s*"#
        let single = try Regex(call + #""((?:[^"\\\n]|\\.)*)""#)
        let quotes = String(repeating: "\"", count: 3)
        let multi = try Regex(call + quotes + #"\n((?s:.*?))\n([ ]*)"# + quotes)
        var keys = Set<String>()
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in text.matches(of: single) {
                keys.insert(literal(String(match.output[1].substring!)))
            }
            for match in text.matches(of: multi) {
                let indent = match.output[2].substring!.count
                let lines = match.output[1].substring!.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { String($0.dropFirst(indent)) }
                var joined = ""
                for line in lines {
                    joined += line.hasSuffix("\\") ? String(line.dropLast()) : line + "\n"
                }
                if joined.hasSuffix("\n") { joined.removeLast() }
                keys.insert(literal(joined))
            }
        }
        keys.remove("")
        return keys
    }

    /// A Swift string literal's content as the key it produces: escapes
    /// resolved, each interpolation `\(…)` as a placeholder.
    static func literal(_ source: String) -> String {
        var result = ""
        var characters = source.makeIterator()
        while let character = characters.next() {
            guard character == "\\", let escaped = characters.next() else {
                result.append(character)
                continue
            }
            switch escaped {
            case "n": result.append("\n")
            case "t": result.append("\t")
            case "(":
                var depth = 1
                while depth > 0, let inner = characters.next() {
                    if inner == "(" { depth += 1 } else if inner == ")" { depth -= 1 }
                }
                result.append("%@")
            default: result.append(escaped)
            }
        }
        return result
    }

    /// Placeholders of any type and position compare equal.
    static func normalized(_ key: String) -> String {
        key.replacing(/%(?:\d+\$)?(?:ll|l|q)?[@d]/, with: "%@")
    }

    @Test func literalsBecomeKeys() {
        #expect(Self.literal(#"Dialling \(name ?? number) …"#) == "Dialling %@ …")
        #expect(Self.literal(#"\(f(a, b(c)))\nnext \"quoted\""#) == "%@\nnext \"quoted\"")
    }

    @Test func sourceTextsAreTranslated() throws {
        let translated = Set(try Self.table("de").keys.map(Self.normalized))
        let used = Set(try Self.sourceKeys().map(Self.normalized))
        let missing = used.subtracting(translated).sorted()
        #expect(missing.isEmpty, "no German translation: \(missing)")
    }

    @Test func translationsAreUsed() throws {
        let used = Set(try Self.sourceKeys().map(Self.normalized))
        let unused = try Self.table("de").keys.filter { !used.contains(Self.normalized($0)) }.sorted()
        #expect(unused.isEmpty, "not found in the source: \(unused)")
    }
}
