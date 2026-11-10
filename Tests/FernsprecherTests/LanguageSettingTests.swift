import Foundation
import Testing
@testable import Fernsprecher

struct LanguageSettingTests {
    /// A preferences domain of its own, removed again after the test.
    struct TemporaryDefaults: ~Copyable {
        let name = "fernsprecher.test.\(UUID().uuidString)"
        var setting: LanguageSetting { LanguageSetting(defaults: UserDefaults(suiteName: name)!, domain: name) }

        deinit { UserDefaults.standard.removePersistentDomain(forName: name) }
    }

    @Test func codes() {
        #expect(AppLanguage(code: "de") == .german)
        #expect(AppLanguage(code: "de-AT") == .german)
        #expect(AppLanguage(code: "en-GB") == .english)
        #expect(AppLanguage(code: "fr") == .system)   // not translated
        #expect(AppLanguage(code: "system") == .system)
    }

    @Test func defaultFollowsTheSystem() {
        let defaults = TemporaryDefaults()
        // The system-wide AppleLanguages are visible through these defaults
        // too, but are no choice of the user for this app.
        #expect(defaults.setting.current == .system)
    }

    @Test func choiceIsStoredAsAppleLanguages() {
        let defaults = TemporaryDefaults()
        let setting = defaults.setting
        setting.set(.english)
        #expect(setting.current == .english)
        #expect(UserDefaults(suiteName: defaults.name)!.persistentDomain(forName: defaults.name)?["AppleLanguages"]
                    as? [String] == ["en"])
        setting.set(.german)
        #expect(setting.current == .german)
        setting.set(.system)
        #expect(setting.current == .system)
        #expect(UserDefaults(suiteName: defaults.name)!.persistentDomain(forName: defaults.name)?["AppleLanguages"] == nil)
    }

    /// Set in System Settings → Language & Region → Applications.
    @Test func regionalCodeFromMacOS() {
        let defaults = TemporaryDefaults()
        UserDefaults(suiteName: defaults.name)!.set(["de-DE"], forKey: "AppleLanguages")
        #expect(defaults.setting.current == .german)
    }
}
