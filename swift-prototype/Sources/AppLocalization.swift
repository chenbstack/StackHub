import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let storageKey = "stackhub.app.language"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .autoupdatingCurrent
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var menuTitle: String {
        switch self {
        case .system:
            return L("系统默认")
        case .simplifiedChinese:
            return L("简体中文")
        case .english:
            return "English"
        }
    }

    static var selected: AppLanguage {
        let rawValue = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.system.rawValue
        return AppLanguage(rawValue: rawValue) ?? .system
    }
}

enum AppLocalization {
    private static var resourceBundle: Bundle {
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
            return .main
        }
        return .module
    }

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard language != .system else { return resourceBundle }
        guard let path = resourceBundle.path(forResource: language.rawValue, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return resourceBundle
        }
        return localizedBundle
    }

    static func string(_ key: String) -> String {
        bundle(for: AppLanguage.selected).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func format(_ key: String, arguments: [CVarArg]) -> String {
        String(format: string(key), locale: AppLanguage.selected.locale, arguments: arguments)
    }
}

func L(_ key: String) -> String {
    AppLocalization.string(key)
}

func LF(_ key: String, _ arguments: CVarArg...) -> String {
    AppLocalization.format(key, arguments: arguments)
}
