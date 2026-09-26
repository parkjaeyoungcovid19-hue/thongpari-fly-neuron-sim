// LabLocalization.swift — English / Korean interface text for the Lab window.
//
// Every user-facing string is written in place as L("English", "한국어"), so
// both texts sit next to the code that shows them. The Korean text is written
// for non-specialists (plain words first, the technical name in parentheses),
// not as a word-for-word translation. Wire values, log lines and file formats
// stay English regardless of the choice.

import Cocoa

enum LabLanguage: String, CaseIterable {
    case english = "en"
    case korean = "ko"

    private static let defaultsKey = "VirtualFlyLabLanguage"
    /// Regression suites compare English strings; they pin the language
    /// without touching the user's saved choice.
    private static var testOverride: LabLanguage?

    static var current: LabLanguage {
        get {
            if let testOverride { return testOverride }
            if let raw = UserDefaults.standard.string(forKey: defaultsKey),
               let saved = LabLanguage(rawValue: raw) { return saved }
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("ko") ? .korean : .english
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .labLanguageChanged, object: nil)
        }
    }

    static func pinEnglishForTests() { testOverride = .english }

    /// Shown in the language's own script so either reader can find it.
    var menuTitle: String {
        switch self {
        case .english: return "English"
        case .korean: return "한국어"
        }
    }
}

extension Notification.Name {
    static let labLanguageChanged = Notification.Name("VirtualFlyLabLanguageChanged")
}

/// The interface text for the current language.
func L(_ english: String, _ korean: String) -> String {
    LabLanguage.current == .korean ? korean : english
}

/// Target for the menu-bar Language items (the menu has no window to route to).
final class LabLanguageMenu: NSObject {
    static let shared = LabLanguageMenu()

    @objc func choose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = LabLanguage(rawValue: raw), language != LabLanguage.current else { return }
        LabLanguage.current = language
    }
}
