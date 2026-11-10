import Foundation
import Testing
@testable import Fernsprecher

func permissions(_ url: URL) throws -> Int {
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int
}

/// A store in a fresh temporary folder, removed again after the test.
struct TemporaryStore: ~Copyable {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    var store: PinStore { PinStore(url: root.appending(path: "Fernsprecher/pins.json")) }

    deinit { try? FileManager.default.removeItem(at: root) }
}

struct PinStoreTests {
    @Test func roundTripPerAccount() throws {
        let temp = TemporaryStore()
        let store = temp.store
        #expect(store.pin(account: "51@pbx") == nil)   // missing file
        try store.setPin("1234", account: "51@pbx")
        try store.setPin("9999", account: "19@pbx")
        #expect(store.pin(account: "51@pbx") == "1234")
        #expect(store.pin(account: "19@pbx") == "9999")
        try store.setPin("4321", account: "51@pbx")
        #expect(store.pin(account: "51@pbx") == "4321")
    }

    @Test func onlyTheUserCanRead() throws {
        let temp = TemporaryStore()
        let store = temp.store
        try store.setPin("1234", account: "51@pbx")
        #expect(try permissions(store.url) == 0o600)
        #expect(try permissions(store.url.deletingLastPathComponent()) == 0o700)
    }

    @Test func tightensLooserPermissions() throws {
        let temp = TemporaryStore()
        let store = temp.store
        let dir = store.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        FileManager.default.createFile(atPath: store.url.path, contents: Data("{}".utf8),
                                       attributes: [.posixPermissions: 0o644])
        try store.setPin("1234", account: "51@pbx")
        #expect(try permissions(store.url) == 0o600)
        #expect(try permissions(dir) == 0o700)
    }

    @Test func damagedFileIsNotOverwritten() throws {
        let temp = TemporaryStore()
        let store = temp.store
        try store.setPin("9999", account: "19@pbx")
        let damaged = Data("{\"19@pbx\": \"99".utf8)
        try damaged.write(to: store.url)
        #expect(store.pin(account: "19@pbx") == nil)
        #expect(throws: PinStore.Failure.self) { try store.setPin("1234", account: "51@pbx") }
        #expect(try Data(contentsOf: store.url) == damaged)
    }

    @Test func writeFailureIsReported() throws {
        let temp = TemporaryStore()
        // A file where the folder should be: the folder cannot be created.
        try FileManager.default.createDirectory(at: temp.root, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: temp.root.appending(path: "Fernsprecher").path, contents: nil)
        #expect(throws: PinStore.Failure.self) { try temp.store.setPin("1234", account: "51@pbx") }
    }
}
