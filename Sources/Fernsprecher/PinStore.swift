import Foundation

/// The PIN lives in a file only the user can read
/// (~/Library/Application Support/Fernsprecher/pins.json, 0600 in a 0700 folder).
/// Not the keychain: without a Developer ID, keychain access is tied to the
/// ad-hoc signature, and macOS would keep asking for the keychain password.
struct PinStore {
    static let standard = PinStore(url: URL.applicationSupportDirectory.appending(path: "Fernsprecher/pins.json"))

    let url: URL

    enum Failure: LocalizedError {
        /// The file exists but cannot be read or decoded; saving would
        /// overwrite the PINs of all other lines, so it is left alone.
        case unreadable(URL)
        case notSaved(Error)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url):
                String(localized: "The PIN file is damaged or unreadable (\(url.path)). Please delete it and save again.")
            case .notSaved(let error):
                String(localized: "PIN could not be saved: \(error.localizedDescription)")
            }
        }
    }

    /// Only a missing file counts as empty.
    private func load() throws(Failure) -> [String: String] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return [:]
        } catch {
            throw .unreadable(url)
        }
        do {
            return try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw .unreadable(url)
        }
    }

    /// `nil` also when the file is unreadable; ``setPin(_:account:)`` reports that.
    func pin(account: String) -> String? {
        (try? load())?[account]
    }

    func setPin(_ pin: String, account: String) throws(Failure) {
        var pins = try load()
        pins[account] = pin
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try JSONEncoder().encode(pins).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw .notSaved(error)
        }
    }
}
