import SwiftUI

@main
enum Entry {
    static func main() {
        // Dev aid: `AMG65 --snapshot out.png [home|lighting]` renders the UI to a PNG.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Skin.registerFonts()
            let tab = (i + 2 < args.count ? Tab(rawValue: args[i + 2]) : nil) ?? .lighting
            MainActor.assumeIsolated { Snapshot.render(to: args[i + 1], tab: tab) }
            return
        }
        // Dev aid: `AMG65 --apply mode=7 speed=5 …` sends via the app's HID code and prints replies.
        if let i = args.firstIndex(of: "--apply") {
            HeadlessApply.run(Array(args[(i + 1)...]))
            return
        }
        AMG65App.main()
    }
}

enum HeadlessApply {
    static func run(_ kv: [String]) {
        var s = LightingSettings()
        for pair in kv {
            let p = pair.split(separator: "=")
            guard p.count == 2, let v = UInt8(p[1]) else { continue }
            switch p[0] {
            case "mode": s.mode = v
            case "r": s.red = v
            case "g": s.green = v
            case "b": s.blue = v
            case "colorful": s.colorful = v != 0
            case "brightness": s.brightness = v
            case "speed": s.speed = v
            case "direction": s.direction = v
            default: break
            }
        }
        let hid = KeyboardHID()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        // `--apply keymap-reset` sends the all-default key map instead of lighting.
        var ks = KeyboardSettings()
        if let v = kv.first(where: { $0.hasPrefix("screen=") }).flatMap({ UInt8($0.dropFirst(7)) }) { ks.screenBrightness = v }
        // `--apply dongle mode=1 r=0 g=255 b=0` → lighting via the dongle; `--apply dongle keymap-reset` → default key map.
        if kv.contains("dongle") {
            let packets = kv.contains("keymap-reset") ? DongleProtocol.keymap([:]) : DongleProtocol.lighting(s)
            print("connection: \(hid.connection), \(packets.count) dongle packet(s)")
            var result: TransactionResult?
            hid.sendDongle(packets, label: kv.contains("keymap-reset") ? "key map" : "lighting") { result = $0 }
            while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            result!.lines.forEach { print($0) }
            print(result!.ok ? "RESULT: OK" : "RESULT: FAILED")
            return
        }
        // `--apply strip-test` uploads scrolling "HELLO FROM MAC" through the app's strip code.
        if kv.contains("strip-test") {
            let m = StripModel()
            if let d = kv.first(where: { $0.hasPrefix("delay=") }).flatMap({ UInt8($0.dropFirst(6)) }) { m.delay = d }
            var done = false
            m.upload(using: hid)
            while m.lastResult == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            m.lastResult!.lines.forEach { print($0) }
            print(m.lastResult!.ok ? "RESULT: OK" : "RESULT: FAILED"); done = true; _ = done
            return
        }
        // `--apply lcd-test` uploads 3 frames (magenta, yellow, cyan) through the app's LCD code.
        if kv.contains("lcd-test") {
            let frames: [CGImage] = [(1.0, 0.0, 1.0), (1.0, 1.0, 0.0), (0.0, 1.0, 1.0)].map { c in
                let ctx = CGContext(data: nil, width: 240, height: 135, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 240, height: 135))
                return ctx.makeImage()!
            }
            let (bytes, blocks) = LCDAnimation(frames: frames, delaysMs: [500, 500, 500], name: "test").buffer()
            var result: TransactionResult?
            hid.uploadLCD(bytes, blocks: blocks, slot: 1, progress: { _ in }) { result = $0 }
            while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            result!.lines.forEach { print($0) }
            print(result!.ok ? "RESULT: OK" : "RESULT: FAILED")
            return
        }
        // `--apply customlight-test` re-sends the confirmed test pattern (blue, red Esc, green WASD).
        if kv.contains("customlight-test") {
            var colors: [Int: RGB] = [:]
            for k in KeyboardLayout.litKeys { colors[k.slot] = RGB(r: 0, g: 0, b: 255) }
            colors[0] = RGB(r: 255, g: 0, b: 0)
            for s in [34, 49, 50, 51] { colors[s] = RGB(r: 0, g: 255, b: 0) }
            let m = CustomLightModel(preview: colors)
            m.brightness = 5
            var done = false
            m.apply(using: hid)
            while m.lastResult == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            m.lastResult!.lines.forEach { print($0) }
            print(m.lastResult!.ok ? "RESULT: OK" : "RESULT: FAILED"); done = true
            _ = done
            return
        }
        let steps = kv.contains("keymap-reset") ? AMG65Protocol.keymap([:])
            : kv.contains("settings") ? AMG65Protocol.settings(ks) : AMG65Protocol.lighting(s)
        print("connection: \(hid.connection)  " + (kv.contains("keymap-reset") ? "key map: all default" : "settings: \(s)"))
        var done = false
        hid.send(steps) { r in
            r.lines.forEach { print($0) }
            print(r.ok ? "RESULT: OK" : "RESULT: FAILED")
            done = true
        }
        while !done { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}

enum Snapshot {
    @MainActor
    static func render(to path: String, tab: Tab) {
        let hid = KeyboardHID()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))   // let device discovery publish
        let view = RootView(tab: tab)
            .environmentObject(hid)
            .environmentObject(LightingModel())
            .environmentObject({ let k = KeymapModel(); k.selectedSlot = 48; return k }())  // preview: Caps Lock selected
            .environmentObject(SettingsModel())
            .environmentObject(CustomLightModel(preview: Dictionary(uniqueKeysWithValues: KeyboardLayout.litKeys.map { k in (k.slot, [0: RGB(r: 255, g: 0, b: 0), 34: RGB(r: 0, g: 255, b: 0), 49: RGB(r: 0, g: 255, b: 0), 50: RGB(r: 0, g: 255, b: 0), 51: RGB(r: 0, g: 255, b: 0)][k.slot] ?? RGB(r: 0, g: 0, b: 255)) })))  // preview
            .environmentObject(ScreenModel(preload: Bundle.main.resourceURL?.appendingPathComponent("DefaultLCD.gif")))
            .environmentObject(StripModel())
            .environmentObject(LiveStripController())
            .frame(width: 1200, height: 760)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let cg = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("snapshot failed"); return
        }
        try? data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
    }
}

struct AMG65App: App {
    @StateObject private var hid = KeyboardHID()
    @StateObject private var lighting = LightingModel()
    @StateObject private var keymap = KeymapModel()
    @StateObject private var settings = SettingsModel()
    @StateObject private var customLight = CustomLightModel()
    @StateObject private var screen = ScreenModel()
    @StateObject private var strip = StripModel()
    @StateObject private var live = LiveStripController()

    init() {
        Skin.registerFonts()
    }

    var body: some Scene {
        WindowGroup("LEOBOG AMG65") {
            RootView()
                .environmentObject(hid)
                .environmentObject(lighting)
                .environmentObject(keymap)
                .environmentObject(settings)
                .environmentObject(customLight)
                .environmentObject(screen)
                .environmentObject(strip)
                .environmentObject(live)
                .frame(width: 1200, height: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

enum Tab: String, CaseIterable, Identifiable {
    case home, lighting, customLight, customKey, macro, music, screen, ledStrip, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Home"
        case .lighting: "Lighting"
        case .customLight: "Custom Light"
        case .customKey: "Custom Key"
        case .macro: "Macro"
        case .music: "Music"
        case .screen: "Screen"
        case .ledStrip: "LED Strip"
        case .settings: "Settings"
        }
    }

    /// Original tab icon sprite (3 frames: normal, hover, selected).
    var icon: String {
        switch self {
        case .home: "icon/tab_home.png"
        case .lighting: "icon/tab_light.png"
        case .customLight: "icon/tab_customlight.png"
        case .customKey: "icon/tab_customkey.png"
        case .macro: "icon/tab_macro.png"
        case .music: "icon/tab_music.png"
        case .screen: "icon/tab_tft.png"
        case .ledStrip: "icon/tab_led.png"
        case .settings: "icon/tab_config.png"
        }
    }

    var available: Bool { self != .macro && self != .music }
}

struct RootView: View {
    @State var tab: Tab = .lighting

    var body: some View {
        ZStack {
            Image(nsImage: Skin.image("keyboard_bkg.png"))
                .resizable().aspectRatio(contentMode: .fill)
                .frame(width: 1200, height: 760).clipped()
            HStack(spacing: 0) {
                TabColumn(selection: $tab)
                VStack(spacing: 0) {
                    TopBar()
                    Group {
                        switch tab {
                        case .home: HomePage(tab: $tab)
                        case .customKey: CustomKeyPage()
                        case .customLight: CustomLightPage()
                        case .screen: ScreenPage()
                        case .ledStrip: LEDStripPage()
                        case .settings: SettingsPage()
                        default: LightingPage()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .ignoresSafeArea()
    }
}

struct TabColumn: View {
    @Binding var selection: Tab

    var body: some View {
        VStack(spacing: 22) {
            Spacer().frame(height: 58)   // room for the window buttons
            ForEach(Tab.allCases) { t in TabButton(tab: t, selected: selection == t) { selection = t } }
            Spacer()
        }
        .frame(width: 97)
        .frame(maxHeight: .infinity)
        .background(Image(nsImage: Skin.image("tab_area.png")).resizable())
    }
}

struct TabButton: View {
    let tab: Tab
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: Skin.sprite(tab.icon, frames: 3, index: selected ? 2 : (hover ? 1 : 0)))
            Text(tab.title)
                .font(.openSans(11, selected ? .semibold : .regular))
                .foregroundStyle(selected ? Palette.text : Palette.dim)
        }
        .frame(width: 97)
        .overlay(alignment: .leading) {
            if selected { Rectangle().fill(Palette.accent).frame(width: 3, height: 34) }
        }
        .contentShape(Rectangle())
        .opacity(tab.available ? 1 : 0.35)
        .onHover { hover = $0 && tab.available }
        .onTapGesture { if tab.available { action() } }
        .help(tab.available ? tab.title : "\(tab.title) — not available on Mac yet")
    }
}

struct TopBar: View {
    @EnvironmentObject var hid: KeyboardHID

    var body: some View {
        HStack {
            Image(nsImage: Skin.image("logo/logo.png"))
            Text("AMG65").font(.openSans(18, .light)).foregroundStyle(Palette.text).padding(.leading, 6)
            Spacer()
            ConnectionPill(connection: hid.connection)
        }
        .padding(.horizontal, 32)
        .frame(height: 70)
    }
}

struct ConnectionPill: View {
    let connection: Connection

    var body: some View {
        let (text, color): (String, Color) = switch connection {
        case .wired: ("Connected · USB cable", .green)
        case .dongle: ("Connected · 2.4 GHz dongle", .green)
        case .none: ("Keyboard not connected", .red)
        }
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.openSans(12)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
    }
}

struct HomePage: View {
    @Binding var tab: Tab
    @EnvironmentObject var hid: KeyboardHID

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(nsImage: Skin.image("keyboard/home_keyboard.png"))
                .opacity(hid.connection == .none ? 0.4 : 1)
            Text("LEOBOG AMG65").font(.openSans(26, .semibold)).foregroundStyle(Palette.text)
            Text(hid.connection == .wired ? "Ready — connected by USB cable."
                 : hid.connection == .dongle ? "Ready over the 2.4 GHz dongle. Screen, LED Strip and Settings need the USB cable."
                 : "Connect the keyboard with the USB cable or the 2.4 GHz dongle.")
                .font(.openSans(14)).foregroundStyle(Palette.dim)
            SpriteButton(sprite: "btn_apply.png", action: { tab = .lighting }) {
                Text("Lighting").font(.openSans(13, .semibold))
            }
            Spacer()
        }
    }
}
