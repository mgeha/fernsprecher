import Foundation

/// The app's language: the system's choice, or one the user picked.
enum AppLanguage: String, CaseIterable {
    /// macOS picks from the user's preferred languages; English if none of
    /// them is translated (`CFBundleDevelopmentRegion`).
    case system
    case german = "de"
    case english = "en"

    /// The language a code like `de`, `de-DE` or `en-GB` stands for.
    init(code: String) {
        let base = code.split(separator: "-").first.map(String.init) ?? code
        self = AppLanguage(rawValue: base).flatMap { $0 == .system ? nil : $0 } ?? .system
    }
}

/// Stores the choice as the app's own `AppleLanguages`, the key macOS
/// itself uses for a per-app language. Bundles read it at launch, so a change
/// takes effect after a restart.
struct LanguageSetting {
    static let key = "AppleLanguages"

    let defaults: UserDefaults
    /// The app's preferences domain; only an override there counts, not the
    /// system-wide list that `defaults` also returns.
    let domain: String

    /// A language this app has no translation for counts as `.system`.
    var current: AppLanguage {
        let languages = defaults.persistentDomain(forName: domain)?[Self.key] as? [String]
        return languages?.first.map(AppLanguage.init(code:)) ?? .system
    }

    func set(_ language: AppLanguage) {
        switch language {
        case .system: defaults.removeObject(forKey: Self.key)
        case .german, .english: defaults.set([language.rawValue], forKey: Self.key)
        }
    }
}
