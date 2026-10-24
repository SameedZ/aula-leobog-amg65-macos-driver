import Foundation

/// Fields of the 0x17 settings packet. The keyboard always receives all of them.
struct KeyboardSettings: Codable, Equatable {
    /// Dot-matrix screen brightness — confirmed (1 dim … 7 = app default).
    var screenBrightness: UInt8 = 7
    /// 0 never, 1 = 1 min, 2 = 5 min, 3 = 30 min (from the app). No effect seen on the cable.
    var sleep: UInt8 = 0
    /// Fn as a toggle instead of hold. No effect seen on the cable.
    var fnToggle = false
    /// Game Mode and its blocks. No effect seen (tested on macOS).
    var gameMode = false
    var blockAltTab = false
    var blockAltF4 = false
    var blockWindowsKey = false
}

final class SettingsModel: ObservableObject {
    @Published var settings: KeyboardSettings { didSet { save(Self.key, settings) } }
    @Published private(set) var applied: KeyboardSettings?
    @Published private(set) var applying = false
    @Published private(set) var lastResult: TransactionResult?

    private static let key = "keyboardSettings"
    private static let appliedKey = "appliedKeyboardSettings"

    init() {
        settings = Self.load(Self.key) ?? KeyboardSettings()
        applied = Self.load(Self.appliedKey)
    }

    var hasUnappliedChanges: Bool { settings != applied }

    func apply(using hid: KeyboardHID) {
        guard !applying else { return }
        applying = true
        let sent = settings
        hid.send(AMG65Protocol.settings(sent)) { [weak self] result in
            guard let self else { return }
            self.applying = false
            self.lastResult = result
            if result.ok {
                self.applied = sent
                self.save(Self.appliedKey, sent)
            }
        }
    }

    private func save(_ key: String, _ value: KeyboardSettings) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load(_ key: String) -> KeyboardSettings? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(KeyboardSettings.self, from: $0) }
    }
}
