import Foundation
import Testing
@testable import Fernsprecher

/// All numbers are invented (`012x…`, `55555`, `9000xx`); internal ones are
/// short PBX extensions.
struct AddressBookTests {
    @Test func formattingDoesNotMatter() {
        var book = AddressBook()
        book.set(name: "Steuerbüro", for: "0120 001-234")
        #expect(book.name(for: "0120001234") == "Steuerbüro")
        #expect(book.name(for: "(0120) 0012/34") == "Steuerbüro")
        #expect(book.entries.map(\.number) == ["0120001234"])
        #expect(book.name(for: "0120001235") == nil)
    }

    @Test func renameAndRemove() {
        var book = AddressBook()
        book.set(name: "  Meier ", for: "0120001234")
        #expect(book.name(for: "0120001234") == "Meier")
        book.set(name: "Müller", for: "0120 001234")
        #expect(book.entries == [AddressBookEntry(number: "0120001234", name: "Müller")])
        book.set(name: " ", for: "0120001234")   // empty name removes
        #expect(book.entries.isEmpty)
        book.set(name: "Meier", for: "0120001234")
        book.remove(number: "0120-001234")
        #expect(book.entries.isEmpty)
    }

    @Test func numbersMatchExactly() {
        var book = AddressBook()
        book.set(name: "Handy", for: "01230000001")         // as the call log reports it
        #expect(book.name(for: "0123 0000001") == "Handy")
        #expect(book.name(for: "001230000001") == nil)      // with trunk prefix: not the PBX's form
        #expect(book.name(for: "1230000001") == nil)
        book.set(name: "Zuhause", for: "55555")             // local
        #expect(book.name(for: "055555") == nil)            // national 05555, not the same number
        book.set(name: "Fernbereich", for: "05555512")
        #expect(book.name(for: "5555512") == nil)
        book.set(name: "Halle", for: "1001")
        #expect(book.name(for: "01001") == nil)
        book.remove(number: "055555")                       // not an entry
        #expect(book.entries.count == 4)
        book.remove(number: "55555")
        #expect(book.name(for: "55555") == nil)
    }

    @Test func sortedByName() {
        var book = AddressBook()
        book.set(name: "zeller", for: "1")
        book.set(name: "Ärztehaus", for: "2")
        book.set(name: "Bauer", for: "3")
        #expect(book.entries.map(\.name) == ["Ärztehaus", "Bauer", "zeller"])
    }

    @Test func searchByNameOrNumber() {
        var book = AddressBook()
        book.set(name: "Steuerbüro Meier", for: "0120001234")
        book.set(name: "Autohaus", for: "0121001234")
        book.set(name: "Halle", for: "900001")
        book.set(name: "B2B Webinar", for: "0129000003")
        #expect(book.search("meier").map(\.name) == ["Steuerbüro Meier"])
        #expect(book.search("0120 0").map(\.name) == ["Steuerbüro Meier"])
        #expect(book.search("(0120) 001-234").map(\.name) == ["Steuerbüro Meier"])
        #expect(book.search("1234").map(\.name) == ["Autohaus", "Steuerbüro Meier"])   // anywhere in the number
        #expect(book.search("00120001234").map(\.name) == ["Steuerbüro Meier"])   // with trunk prefix
        #expect(book.search("").count == 4)
    }

    @Test func digitsInNamesAreNoNumberQuery() {
        var book = AddressBook()
        book.set(name: "Halle", for: "900001")
        book.set(name: "Hotel", for: "900002")
        book.set(name: "B2B Webinar", for: "0129000003")
        #expect(book.search("Halle 9").isEmpty)
        #expect(book.search("B2B").map(\.name) == ["B2B Webinar"])
        #expect(book.search("9").count == 3)
    }

    @Test func dialStringAddsTrunkPrefixToExternalNumbers() {
        #expect(AddressBook.dialString("01230000002", trunkPrefix: "0") == "001230000002")
        #expect(AddressBook.dialString("55555", trunkPrefix: "0") == "055555")   // local
        #expect(AddressBook.dialString("0043 664 1", trunkPrefix: "0") == "000436641")
        #expect(AddressBook.dialString("+43 664 1", trunkPrefix: "0") == "000436641")
        #expect(AddressBook.dialString("51", trunkPrefix: "0") == "51")          // internal
        #expect(AddressBook.dialString("9999", trunkPrefix: "0") == "9999")
        #expect(AddressBook.dialString("*565", trunkPrefix: "0") == "*565")
        #expect(AddressBook.dialString("55555", trunkPrefix: "") == "55555")
    }

    @Test func withoutTrunkPrefixReversesDialString() {
        #expect(AddressBook.withoutTrunkPrefix("001230000002", trunkPrefix: "0") == "01230000002")
        #expect(AddressBook.withoutTrunkPrefix("055555", trunkPrefix: "0") == "55555")   // local
        #expect(AddressBook.withoutTrunkPrefix("000436641", trunkPrefix: "0") == "00436641")
        #expect(AddressBook.withoutTrunkPrefix("051", trunkPrefix: "0") == "051")        // too short
        #expect(AddressBook.withoutTrunkPrefix("***", trunkPrefix: "0") == "***")
        #expect(AddressBook.withoutTrunkPrefix("955555", trunkPrefix: "9") == "55555")
        #expect(AddressBook.withoutTrunkPrefix("055555", trunkPrefix: "") == "055555")
    }

    @Test func numberKey() {
        #expect(AddressBook.numberKey(" 0123 / 000-00 02 ") == "01230000002")
        #expect(AddressBook.numberKey("+43 (664) 1") == "+436641")
        #expect(AddressBook.numberKey("**21#") == "**21#")
        #expect(AddressBook.numberKey("Halle 9") == nil)
        #expect(AddressBook.numberKey(" - ") == nil)
    }

    @Test func fileRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "Fernsprecher/addressbook.json")

        #expect(try AddressBook.load(from: url) == AddressBook())   // missing file: empty

        var book = AddressBook()
        book.set(name: "Meier", for: "0120001234")
        try book.save(to: url)
        #expect(try AddressBook.load(from: url) == book)

        try Data("{ kaputt".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AddressBook.load(from: url) }
    }
}
