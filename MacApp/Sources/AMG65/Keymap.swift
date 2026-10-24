import Foundation
import SwiftUI

// MARK: - Physical keys (from the original app's KeyboardLayout.xml)

struct PhysicalKey: Identifiable, Hashable {
    let slot: Int          // key_index = slot in the 0x11 key map
    let code: UInt8        // default HID usage
    let name: String
    let rect: CGRect       // in img_keyboard_kt84.png pixel coordinates
    var id: Int { slot }
    /// Fn and the volume knob aren't remappable here (Fn would lose its layer).
    var remappable: Bool { code != 0xAF && !isKnob }
    /// The volume knob is listed as two "keys" (vol +/−) with no light, drawn off the keyboard image.
    var isKnob: Bool { code == 0xE9 || code == 0xEA }
}

extension KeyboardLayout {
    /// Keys that have a backlight LED (everything except the knob).
    static var litKeys: [PhysicalKey] { keys.filter { !$0.isKnob } }
}

enum KeyboardLayout {
    static let keys: [PhysicalKey] = load()

    private static func load() -> [PhysicalKey] {
        let url = Bundle.main.resourceURL?.appendingPathComponent("KeyboardLayout.xml")
            ?? URL(fileURLWithPath: "../local/official-driver/extracted/app/KeyboardLayout.xml")
        guard let raw = try? Data(contentsOf: url),
              var text = String(data: raw, encoding: .utf8) ?? String(data: raw, encoding: .isoLatin1),
              let start = text.range(of: "<?xml") else { return [] }
        text = String(text[start.lowerBound...])   // file starts with a stray byte

        var keys: [PhysicalKey] = []
        let keyPattern = try! NSRegularExpression(pattern: "<key ([^/]*)/>")
        let attrPattern = try! NSRegularExpression(pattern: "(\\w+)=\"([^\"]*)\"")
        let ns = text as NSString
        for m in keyPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: m.range(at: 1)) as NSString
            var a: [String: String] = [:]
            for am in attrPattern.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                a[body.substring(with: am.range(at: 1))] = body.substring(with: am.range(at: 2))
            }
            guard let idx = a["key_index"].flatMap(Int.init),
                  let code = a["code"].flatMap({ UInt8($0.replacingOccurrences(of: "0x", with: "").replacingOccurrences(of: "0X", with: ""), radix: 16) }),
                  let x = a["rect_left"].flatMap(Double.init), let y = a["rect_top"].flatMap(Double.init),
                  let w = a["rect_width"].flatMap(Double.init), let h = a["rect_height"].flatMap(Double.init)
            else { continue }
            let name = decodeEntities(a["name"] ?? "?")
            keys.append(PhysicalKey(slot: idx, code: code, name: name, rect: CGRect(x: x, y: y, width: w, height: h)))
        }
        // "/?" is missing from the file: slot 74 is the gap, one key-pitch right of ".>".
        if let dot = keys.first(where: { $0.slot == 73 }), let comma = keys.first(where: { $0.slot == 72 }),
           !keys.contains(where: { $0.slot == 74 }) {
            let pitch = dot.rect.minX - comma.rect.minX
            keys.append(PhysicalKey(slot: 74, code: 0x38, name: "/?", rect: dot.rect.offsetBy(dx: pitch, dy: 0)))
        }
        return keys
    }

    private static func decodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - What a key can be remapped to

enum KeyAction: Codable, Hashable {
    /// Type 02: modifier bits + HID keyboard usage (confirmed on the keyboard).
    case key(modifiers: UInt8, code: UInt8)
    /// Type 03: HID consumer usage (decoded from the app, untested).
    case media(UInt16)
    /// Type 01 01: mouse button mask (decoded, untested).
    case mouseButton(UInt8)
    /// Type 01 03: wheel +1 / -1 (decoded, untested).
    case wheel(up: Bool)

    var slot: [UInt8] {
        switch self {
        case let .key(mods, code):
            if (0xE0...0xE7).contains(code) { return [0x02, mods | (1 << (code - 0xE0)), 0x00, 0x00] }
            return [0x02, mods, code, 0x00]
        case let .media(u): return [0x03, UInt8(u & 0xFF), UInt8(u >> 8), 0x00]
        case let .mouseButton(mask): return [0x01, 0x01, mask, 0x00]
        case let .wheel(up): return [0x01, 0x03, up ? 0x01 : 0xFF, 0x00]
        }
    }

    var title: String {
        switch self {
        case let .key(mods, code):
            let name = HIDKeys.name(code)
            let m = Modifier.allCases.filter { mods & $0.bit != 0 }.map(\.symbol).joined()
            return m.isEmpty ? name : "\(m) \(name)"
        case let .media(u): return MediaKeys.all.first { $0.usage == u }?.name ?? String(format: "Media %04X", u)
        case let .mouseButton(m): return MouseActions.buttons.first { $0.mask == m }?.name ?? "Mouse \(m)"
        case let .wheel(up): return up ? "Scroll up" : "Scroll down"
        }
    }

    var tested: Bool { if case .key = self { true } else { false } }
}

enum Modifier: CaseIterable {
    case control, shift, option, command
    var bit: UInt8 {
        switch self { case .control: 0x01; case .shift: 0x02; case .option: 0x04; case .command: 0x08 }
    }
    var symbol: String {
        switch self { case .control: "⌃"; case .shift: "⇧"; case .option: "⌥"; case .command: "⌘" }
    }
    var name: String {
        switch self { case .control: "Control"; case .shift: "Shift"; case .option: "Option / Alt"; case .command: "Command / Win" }
    }
}

enum HIDKeys {
    struct Entry: Identifiable { let code: UInt8; let name: String; var id: UInt8 { code } }

    static let groups: [(String, [Entry])] = [
        ("Letters", (0..<26).map { Entry(code: 0x04 + UInt8($0), name: String(UnicodeScalar(65 + $0)!)) }),
        ("Numbers", (1...10).map { Entry(code: 0x1D + UInt8($0), name: $0 == 10 ? "0" : "\($0)") }),
        ("Function", (1...12).map { Entry(code: 0x39 + UInt8($0), name: "F\($0)") }
            + (13...24).map { Entry(code: 0x5B + UInt8($0), name: "F\($0)") }),
        ("Editing", [
            .init(code: 0x29, name: "Esc"), .init(code: 0x2B, name: "Tab"), .init(code: 0x39, name: "Caps Lock"),
            .init(code: 0x2C, name: "Space"), .init(code: 0x28, name: "Enter"), .init(code: 0x2A, name: "Backspace"),
            .init(code: 0x4C, name: "Delete"), .init(code: 0x49, name: "Insert"),
        ]),
        ("Navigation", [
            .init(code: 0x4A, name: "Home"), .init(code: 0x4D, name: "End"), .init(code: 0x4B, name: "Page Up"),
            .init(code: 0x4E, name: "Page Down"), .init(code: 0x50, name: "←"), .init(code: 0x4F, name: "→"),
            .init(code: 0x52, name: "↑"), .init(code: 0x51, name: "↓"),
        ]),
        ("Symbols", [
            .init(code: 0x35, name: "`"), .init(code: 0x2D, name: "-"), .init(code: 0x2E, name: "="),
            .init(code: 0x2F, name: "["), .init(code: 0x30, name: "]"), .init(code: 0x31, name: "\\"),
            .init(code: 0x33, name: ";"), .init(code: 0x34, name: "'"), .init(code: 0x36, name: ","),
            .init(code: 0x37, name: "."), .init(code: 0x38, name: "/"),
        ]),
        ("Modifiers", [
            .init(code: 0xE0, name: "Left Ctrl"), .init(code: 0xE1, name: "Left Shift"), .init(code: 0xE2, name: "Left Alt/⌥"),
            .init(code: 0xE3, name: "Left Win/⌘"), .init(code: 0xE4, name: "Right Ctrl"), .init(code: 0xE5, name: "Right Shift"),
            .init(code: 0xE6, name: "Right Alt/⌥"), .init(code: 0xE7, name: "Right Win/⌘"),
        ]),
        ("Other", [
            .init(code: 0x46, name: "Print Screen"), .init(code: 0x47, name: "Scroll Lock"), .init(code: 0x48, name: "Pause"),
        ]),
    ]

    static func name(_ code: UInt8) -> String {
        for (_, list) in groups { if let e = list.first(where: { $0.code == code }) { return e.name } }
        return String(format: "Key %02X", code)
    }
}

enum MediaKeys {
    struct Entry: Identifiable { let usage: UInt16; let name: String; var id: UInt16 { usage } }
    static let all: [Entry] = [
        .init(usage: 0xCD, name: "Play / Pause"), .init(usage: 0xB5, name: "Next track"),
        .init(usage: 0xB6, name: "Previous track"), .init(usage: 0xB7, name: "Stop"),
        .init(usage: 0xE9, name: "Volume up"), .init(usage: 0xEA, name: "Volume down"),
        .init(usage: 0xE2, name: "Mute"),
    ]
}

enum MouseActions {
    struct Button: Identifiable { let mask: UInt8; let name: String; var id: UInt8 { mask } }
    static let buttons: [Button] = [
        .init(mask: 0x01, name: "Left click"), .init(mask: 0x02, name: "Right click"),
        .init(mask: 0x04, name: "Middle click"), .init(mask: 0x08, name: "Back"), .init(mask: 0x10, name: "Forward"),
    ]
}

// MARK: - Model

/// The remaps the user has set. The keyboard can't be read back, so the
/// last-applied map is remembered locally.
final class KeymapModel: ObservableObject {
    @Published var assignments: [Int: KeyAction] { didSet { save(Self.key, assignments) } }
    @Published private(set) var applied: [Int: KeyAction]?
    @Published var selectedSlot: Int?
    @Published private(set) var applying = false
    @Published private(set) var lastResult: TransactionResult?

    private static let key = "keymapAssignments"
    private static let appliedKey = "appliedKeymap"

    init() {
        assignments = Self.load(Self.key) ?? [:]
        applied = Self.load(Self.appliedKey)
    }

    var hasUnappliedChanges: Bool { assignments != (applied ?? [:]) }
    var selectedKey: PhysicalKey? { KeyboardLayout.keys.first { $0.slot == selectedSlot } }

    func assign(_ action: KeyAction?) {
        guard let slot = selectedSlot else { return }
        if let action, action != .key(modifiers: 0, code: selectedKey?.code ?? 0) {
            assignments[slot] = action
        } else {
            assignments[slot] = nil   // same as default → no remap
        }
    }

    func apply(using hid: KeyboardHID) {
        guard !applying else { return }
        applying = true
        let sent = assignments
        let finish: (TransactionResult) -> Void = { [weak self] result in
            guard let self else { return }
            self.applying = false
            self.lastResult = result
            if result.ok {
                self.applied = sent
                self.save(Self.appliedKey, sent)
            }
        }
        if hid.connection == .dongle {
            hid.sendDongle(DongleProtocol.keymap(sent.mapValues(\.slot)), label: "key map", completion: finish)
        } else {
            hid.send(AMG65Protocol.keymap(sent.mapValues(\.slot)), completion: finish)
        }
    }

    private func save(_ key: String, _ value: [Int: KeyAction]) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load(_ key: String) -> [Int: KeyAction]? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Int: KeyAction].self, from: $0) }
    }
}
