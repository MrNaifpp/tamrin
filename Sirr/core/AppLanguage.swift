import SwiftUI

/// The language the whole UI runs in: Arabic, unless the person picked English
/// for Tamrin in iOS Settings.
///
/// iOS picks an app's language by matching the device's preferred languages
/// against the localizations the bundle ships, so once `en.lproj` exists an
/// English iPhone would open Tamrin in English on first launch. `bootstrap()`
/// pins Arabic before anything reads the bundle, and steps aside as soon as
/// iOS has recorded a choice of its own (Settings › Tamrin › Language writes
/// the same `AppleLanguages` key into the app's domain, then relaunches it).
///
/// The language never changes while the app runs, so everything here is
/// resolved once.
nonisolated enum AppLanguage: String {
    case arabic = "ar"
    case english = "en"

    /// Must run before the first localized lookup, which is why it is called
    /// from `main.swift` ahead of `SirrApp.main()`.
    static func bootstrap() {
        let key = "AppleLanguages"
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier ?? ""
        let recorded = defaults.persistentDomain(forName: domain)?[key] as? [String]
        if recorded?.isEmpty ?? true {
            defaults.set([AppLanguage.arabic.rawValue], forKey: key)
        }
    }

    static let current: AppLanguage = {
        let code = Bundle.main.preferredLocalizations.first ?? arabic.rawValue
        return code.hasPrefix(english.rawValue) ? .english : .arabic
    }()

    static var isArabic: Bool { current == .arabic }

    /// Western digits in both languages. Plain `ar` renders ٠١٢٣, which this
    /// app never shows; `numbers=latn` keeps Arabic month and weekday names
    /// while pinning the numerals.
    var locale: Locale {
        switch self {
        case .arabic: Locale(identifier: "ar_SA@numbers=latn")
        case .english: Locale(identifier: "en_US")
        }
    }

    var layoutDirection: LayoutDirection {
        self == .arabic ? .rightToLeft : .leftToRight
    }

    /// The language's own name, so the settings row reads the same to someone
    /// who does not read the other one.
    var nativeName: String {
        switch self {
        case .arabic: "العربية"
        case .english: "English"
        }
    }
}

extension LayoutDirection {
    /// The direction of the app's language. Views that pin a direction pin
    /// this one, never a literal `.rightToLeft`.
    static var tamrin: LayoutDirection { AppLanguage.current.layoutDirection }
}
