import Foundation

/// AMG65 USB HID protocol (see docs/protocol/PROTOCOL.md). Every packet is 64 bytes.
enum AMG65Protocol {
    static let packetLength = 64

    static func packet(_ head: [UInt8], _ at: [Int: UInt8] = [:]) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: packetLength)
        for (i, b) in head.enumerated() { buf[i] = b }
        for (i, b) in at { buf[i] = b }
        return buf
    }

    static let begin = packet([0x04, 0x18])
    static let end = packet([0x04, 0x02])
    static let apply = packet([0x04, 0xF0])

    struct Step {
        let label: String
        let bytes: [UInt8]
        /// Data packets are summed by the keyboard (end-reply checksum). Marked
        /// explicitly: lighting mode 4's data packet also starts with 0x04.
        var isData = false
    }

    /// The exact sequence the Windows app sends for a lighting change.
    static func lighting(_ s: LightingSettings) -> [Step] {
        let header = packet([0x04, 0x13], [8: 0x01])   // 1 data packet follows
        let data = packet([s.mode, s.red, s.green, s.blue], [
            8: s.colorful ? 1 : 0,
            9: s.brightness,
            10: s.speed,
            11: s.direction,
            14: 0xAA, 15: 0x55,
        ])
        return [
            Step(label: "begin", bytes: begin),
            Step(label: "lighting header", bytes: header),
            Step(label: "lighting data", bytes: data, isData: true),
            Step(label: "end", bytes: end),
            Step(label: "apply", bytes: apply),
        ]
    }

    /// Keyboard settings (cmd 0x17), as the Windows app sends it (no 04 F0).
    static func settings(_ s: KeyboardSettings) -> [Step] {
        let game: UInt8 = s.gameMode ? 1 : 0
        let data = packet([
            0x00, game,
            game & (s.blockAltTab ? 1 : 0), game & (s.blockAltF4 ? 1 : 0), game & (s.blockWindowsKey ? 1 : 0),
            s.fnToggle ? 1 : 0, s.sleep, s.screenBrightness,
        ], [62: 0xAA, 63: 0x55])
        return [
            Step(label: "begin", bytes: begin),
            Step(label: "settings header", bytes: packet([0x04, 0x17, 0x01], [8: 0x01])),   // profile 1
            Step(label: "settings data", bytes: data, isData: true),
            Step(label: "end", bytes: end),
        ]
    }

    /// Time Sync (cmd 0x28), as the Windows app's button sends it (0x42ab10): time only.
    /// [1] = LCD item to show (list index + 1). The keyboard doesn't echo a checksum for 0x28.
    static func timeSync(_ date: Date, view: UInt8) -> [Step] {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
        let data = packet([
            0x00, view, 0x5A, UInt8((c.year ?? 2000) % 2000), UInt8(c.month ?? 1), UInt8(c.day ?? 1),
            UInt8(c.hour ?? 0), UInt8(c.minute ?? 0), UInt8(c.second ?? 0), 0x00, UInt8((c.weekday ?? 1) - 1),
        ], [62: 0xAA, 63: 0x55])
        return [
            Step(label: "begin", bytes: begin),
            Step(label: "screen header", bytes: packet([0x04, 0x28], [8: 0x01])),
            Step(label: "time data", bytes: data),   // not summed by the keyboard
            Step(label: "end", bytes: end),
        ]
    }

    /// Per-key colour table (cmd 0x23): slot n = [n, R, G, B], 8 data packets.
    /// Confirmed on the keyboard. Shown once lighting mode 0x80 is selected.
    static func customColorTable(_ colors: [Int: RGB]) -> [Step] {
        var buf = [UInt8](repeating: 0, count: 512)
        for (i, c) in colors where (0..<128).contains(i) {
            buf[i * 4] = UInt8(i); buf[i * 4 + 1] = c.r; buf[i * 4 + 2] = c.g; buf[i * 4 + 3] = c.b
        }
        var steps = [
            Step(label: "begin", bytes: begin),
            Step(label: "colour table header", bytes: packet([0x04, 0x23], [8: 0x08])),
        ]
        for i in 0..<8 {
            steps.append(Step(label: "colour data \(i + 1)/8", bytes: Array(buf[i * 64..<(i + 1) * 64]), isData: true))
        }
        steps += [Step(label: "end", bytes: end), Step(label: "apply", bytes: apply)]
        return steps
    }

    /// Lighting command selecting the custom per-key mode (0x80), as 0x43b900 sends it.
    static func customLightMode(brightness: UInt8) -> [Step] {
        let data = packet([0x80, 0, 0, 0], [9: brightness, 10: 0x0F, 11: 0x0F, 14: 0xAA, 15: 0x55])
        return [
            Step(label: "begin", bytes: begin),
            Step(label: "lighting header", bytes: packet([0x04, 0x13], [8: 0x01])),
            Step(label: "lighting data (custom mode)", bytes: data, isData: true),
            Step(label: "end", bytes: end),
            Step(label: "apply", bytes: apply),
        ]
    }

    /// Key map (cmd 0x11): 128 slots × 4 bytes, AA 55 at the end, sent as 8 data
    /// packets. An all-zero slot = the key's factory default.
    static func keymap(_ slots: [Int: [UInt8]]) -> [Step] {
        var buf = [UInt8](repeating: 0, count: 512)
        for (index, slot) in slots where (0..<127).contains(index) {
            for (i, b) in slot.prefix(4).enumerated() { buf[index * 4 + i] = b }
        }
        buf[510] = 0xAA
        buf[511] = 0x55
        var steps = [
            Step(label: "begin", bytes: begin),
            Step(label: "keymap header", bytes: packet([0x04, 0x11], [8: 0x08])),
        ]
        for i in 0..<8 {
            steps.append(Step(label: "keymap data \(i + 1)/8", bytes: Array(buf[i * 64..<(i + 1) * 64]), isData: true))
        }
        steps += [Step(label: "end", bytes: end), Step(label: "apply", bytes: apply)]
        return steps
    }

    /// 16-bit sum of all data bytes; the keyboard echoes it in the end reply [4..5].
    static func checksum(_ steps: [Step]) -> UInt16 {
        var sum = 0
        for s in steps where s.isData { sum += s.bytes.reduce(0) { $0 + Int($1) } }
        return UInt16(sum & 0xFFFF)
    }
}

struct LightingSettings: Codable, Equatable {
    var mode: UInt8 = 1
    var red: UInt8 = 255
    var green: UInt8 = 255
    var blue: UInt8 = 255
    var colorful = false
    var brightness: UInt8 = 5
    var speed: UInt8 = 3
    var direction: UInt8 = 0
}

struct LightingMode: Identifiable {
    let id: UInt8
    let name: String
    let confirmed: Bool
    var usesSpeed: Bool { id != 1 && id != 20 }
    var usesDirection: Bool { id == 10 }
}

/// Mode n = the app's string ID 199+n (confirmed for 1 = Static and 7 = Breath).
let lightingModes: [LightingMode] = [
    .init(id: 1, name: "Static", confirmed: true),
    .init(id: 2, name: "Single On", confirmed: false),
    .init(id: 3, name: "Single Off", confirmed: false),
    .init(id: 4, name: "Glittering", confirmed: false),
    .init(id: 5, name: "Falling", confirmed: false),
    .init(id: 6, name: "Colourful", confirmed: false),
    .init(id: 7, name: "Breath", confirmed: true),
    .init(id: 8, name: "Spectrum", confirmed: false),
    .init(id: 9, name: "Outward", confirmed: false),
    .init(id: 10, name: "Scrolling", confirmed: false),
    .init(id: 11, name: "Rolling", confirmed: false),
    .init(id: 12, name: "Rotating", confirmed: false),
    .init(id: 13, name: "Explode", confirmed: false),
    .init(id: 14, name: "Launch", confirmed: false),
    .init(id: 15, name: "Ripples", confirmed: false),
    .init(id: 16, name: "Flowing", confirmed: false),
    .init(id: 17, name: "Pulsating", confirmed: false),
    .init(id: 18, name: "Tilt", confirmed: false),
    .init(id: 19, name: "Shuttle", confirmed: false),
    .init(id: 20, name: "Backlight Off", confirmed: false),
]

// MARK: - 2.4 GHz dongle (interface 3, 0xFF60) — decoded from 0x468790 and its callers

enum DongleProtocol {
    /// [cmd, length, index, payload…], byte 31 = sum of bytes 0…30.
    static func packet(_ cmd: UInt8, length: UInt8, index: UInt8, _ payload: [UInt8]) -> [UInt8] {
        var d = [UInt8](repeating: 0, count: 32)
        d[0] = cmd; d[1] = length; d[2] = index
        for (i, b) in payload.prefix(28).enumerated() { d[3 + i] = b }
        d[31] = UInt8(d[0..<31].reduce(0) { $0 + Int($1) } & 0xFF)
        return d
    }

    /// Splits a table into 28-byte chunks (the last one shorter), like 0x41b8e0 / 0x435f40.
    static func chunks(_ cmd: UInt8, _ table: [UInt8]) -> [[UInt8]] {
        stride(from: 0, to: table.count, by: 28).enumerated().map { i, start in
            let part = Array(table[start..<min(start + 28, table.count)])
            return packet(cmd, length: UInt8(part.count), index: UInt8(i), part)
        }
    }

    /// Lighting (cmd 05): the wired data fields behind 05 10 00. Confirmed.
    static func lighting(_ s: LightingSettings) -> [[UInt8]] {
        [packet(0x05, length: 0x10, index: 0, [
            s.mode, s.red, s.green, s.blue, 0, 0, 0, 0,
            s.colorful ? 1 : 0, s.brightness, s.speed, s.direction, 0, 0, 0xAA, 0x55,
        ])]
    }

    /// Custom per-key colours: custom-mode lighting packet, then a 576-byte table
    /// (slot n = [n, R, G, B], AA 55 at 574) as cmd 0x14 chunks. Confirmed.
    static func customLight(_ colors: [Int: RGB], brightness: UInt8) -> [[UInt8]] {
        var table = [UInt8](repeating: 0, count: 576)
        for (i, c) in colors where (0..<144).contains(i) {
            table[i * 4] = UInt8(i); table[i * 4 + 1] = c.r; table[i * 4 + 2] = c.g; table[i * 4 + 3] = c.b
        }
        table[574] = 0xAA; table[575] = 0x55
        let mode = packet(0x05, length: 0x10, index: 0, [0x80, 0, 0, 0, 0, 0, 0, 0, 0, brightness, 0, 0, 0, 0, 0xAA, 0x55])
        return [mode] + chunks(0x14, table)
    }

    /// Key map (cmd 0x10): the same 512-byte table as the cable, in 19 chunks. Decoded; echo-tested.
    static func keymap(_ slots: [Int: [UInt8]]) -> [[UInt8]] {
        var table = [UInt8](repeating: 0, count: 512)
        for (i, slot) in slots where (0..<127).contains(i) {
            for (j, b) in slot.prefix(4).enumerated() { table[i * 4 + j] = b }
        }
        table[510] = 0xAA; table[511] = 0x55
        return chunks(0x10, table)
    }
}
