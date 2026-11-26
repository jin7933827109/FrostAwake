import Foundation
import ServiceManagement

enum InterfaceLanguage: String {
    case chinese = "zh-Hans"
    case english = "en"

    func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
}

struct FrostAwakePreferences {
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["AutoFrostEnabled": true, "ClearModeHours": 5])
    }

    var language: InterfaceLanguage {
        get { defaults.string(forKey: "InterfaceLanguage").flatMap(InterfaceLanguage.init) ?? .chinese }
        nonmutating set { defaults.set(newValue.rawValue, forKey: "InterfaceLanguage") }
    }

    var autoFrostEnabled: Bool {
        get { defaults.bool(forKey: "AutoFrostEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "AutoFrostEnabled") }
    }

    var islandEnabled: Bool {
        get { defaults.bool(forKey: "IslandEnabled") }
        nonmutating set { defaults.set(newValue, forKey: "IslandEnabled") }
    }

    static let durations = [1, 2, 3, 5, 8, 12]

    var clearHours: Int {
        get {
            let saved = defaults.integer(forKey: "ClearModeHours")
            return Self.durations.contains(saved) ? saved : 5
        }
        nonmutating set { defaults.set(newValue, forKey: "ClearModeHours") }
    }

    var requiresTouchID: Bool {
        get { defaults.string(forKey: "PrivacyExitMethod") == "touchID" }
        nonmutating set { defaults.set(newValue ? "touchID" : "shortcut", forKey: "PrivacyExitMethod") }
    }

    var idleInterval: Int {
        get {
            let saved = defaults.integer(forKey: "ReviewActivityInterval")
            return ScreenKeepAwake.intervalRange.contains(saved) ? saved : ScreenKeepAwake.defaultInterval
        }
        nonmutating set { defaults.set(newValue, forKey: "ReviewActivityInterval") }
    }

    func shortcut(_ key: String, fallback: ReviewShortcut) -> ReviewShortcut {
        guard let data = defaults.data(forKey: key),
              let shortcut = try? JSONDecoder().decode(ReviewShortcut.self, from: data) else { return fallback }
        return shortcut
    }

    func saveShortcut(_ shortcut: ReviewShortcut, for key: String) {
        if let data = try? JSONEncoder().encode(shortcut) { defaults.set(data, forKey: key) }
    }

    func initializeLoginItem() throws {
        guard !defaults.bool(forKey: "LoginItemConfigured") else { return }
        try setLoginItem(enabled: true)
    }

    func setLoginItem(enabled: Bool) throws {
        let service = SMAppService.mainApp
        switch (enabled, service.status) {
        case (true, .enabled), (true, .requiresApproval), (false, .notRegistered), (false, .notFound):
            break
        case (true, _):
            try service.register()
        case (false, _):
            try service.unregister()
        }
        defaults.set(true, forKey: "LoginItemConfigured")
    }
}
