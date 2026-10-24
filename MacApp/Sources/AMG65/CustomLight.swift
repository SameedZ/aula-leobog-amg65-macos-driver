import SwiftUI

struct RGB: Codable, Hashable {
    var r: UInt8, g: UInt8, b: UInt8
    static let off = RGB(r: 0, g: 0, b: 0)
    var color: Color { Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }
    var isOff: Bool { r == 0 && g == 0 && b == 0 }
}

/// Per-key colours (Custom Light tab). Keys without a colour are off.
final class CustomLightModel: ObservableObject {
    @Published var colors: [Int: RGB] { didSet { save() } }
    @Published var brush = RGB(r: 255, g: 0, b: 0)
    @Published var erasing = false
    @Published var brightness: UInt8 = 5 { didSet { UserDefaults.standard.set(Int(brightness), forKey: "customLightBrightness") } }
    @Published private(set) var appliedColors: [Int: RGB]?
    @Published private(set) var appliedBrightness: UInt8?
    @Published private(set) var applying = false
    @Published private(set) var lastResult: TransactionResult?

    /// `preview` (for snapshots) is shown without being saved.
    init(preview: [Int: RGB]? = nil) {
        let d = UserDefaults.standard
        colors = preview ?? d.data(forKey: "customLightColors").flatMap { try? JSONDecoder().decode([Int: RGB].self, from: $0) } ?? [:]
        if d.object(forKey: "customLightBrightness") != nil { brightness = UInt8(d.integer(forKey: "customLightBrightness")) }
    }

    var hasUnappliedChanges: Bool { colors != appliedColors || brightness != appliedBrightness }

    func paint(_ slot: Int) {
        if erasing { colors[slot] = nil } else { colors[slot] = brush }
    }

    func fillAll() {
        var all: [Int: RGB] = [:]
        for k in KeyboardLayout.litKeys { all[k.slot] = brush }
        colors = all
    }

    func apply(using hid: KeyboardHID) {
        guard !applying else { return }
        applying = true
        let sentColors = colors, sentBrightness = brightness
        if hid.connection == .dongle {
            // Dongle: custom-mode packet first, then the table in 0x14 chunks (0x435f40).
            hid.sendDongle(DongleProtocol.customLight(sentColors, brightness: sentBrightness), label: "custom colours") { [weak self] r in
                self?.finish(r, r.ok ? (sentColors, sentBrightness) : nil)
            }
            return
        }
        // 1) upload the colour table, 2) switch lighting to the custom mode — like the Windows app.
        hid.send(AMG65Protocol.customColorTable(sentColors)) { [weak self] first in
            guard let self else { return }
            guard first.ok else { self.finish(first, nil) ; return }
            hid.send(AMG65Protocol.customLightMode(brightness: sentBrightness)) { second in
                let merged = TransactionResult(ok: second.ok, lines: first.lines + ["— custom mode —"] + second.lines)
                self.finish(merged, second.ok ? (sentColors, sentBrightness) : nil)
            }
        }
    }

    private func finish(_ result: TransactionResult, _ applied: ([Int: RGB], UInt8)?) {
        applying = false
        lastResult = result
        if let applied { appliedColors = applied.0; appliedBrightness = applied.1 }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(colors) { UserDefaults.standard.set(data, forKey: "customLightColors") }
    }
}

// MARK: - Page

struct CustomLightPage: View {
    @EnvironmentObject var model: CustomLightModel

    var body: some View {
        VStack(spacing: 10) {
            KeyboardPainter().frame(height: 300)
            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                HStack(alignment: .top, spacing: 0) {
                    BrushPanel().frame(width: 360)
                    divider
                    ToolsPanel().frame(width: 260)
                    divider
                    CustomLightApplyPanel().frame(maxWidth: .infinity)
                }
                .padding(.top, 22).padding(.horizontal, 26).padding(.bottom, 18)
            }
            .frame(width: 1060, height: 360)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.horizontal, 20).padding(.vertical, 6)
    }
}

/// Keyboard image with each key tinted its colour; click or drag to paint.
struct KeyboardPainter: View {
    @EnvironmentObject var model: CustomLightModel
    private let crop = CGRect(x: 0, y: 0, width: 880, height: 400)
    private let width: CGFloat = 700

    var body: some View {
        let scale = width / crop.width
        ZStack(alignment: .topLeading) {
            Image(nsImage: Skin.crop("keyboard/img_keyboard_kt84.png", crop))
                .resizable().frame(width: width, height: crop.height * scale)
                .opacity(0.8)
            ForEach(KeyboardLayout.litKeys) { key in
                KeyTint(color: model.colors[key.slot])
                    .frame(width: key.rect.width * scale, height: key.rect.height * scale)
                    .offset(x: key.rect.minX * scale, y: key.rect.minY * scale)
            }
        }
        .frame(width: width, height: crop.height * scale)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            let p = CGPoint(x: g.location.x / scale, y: g.location.y / scale)
            if let key = KeyboardLayout.litKeys.first(where: { $0.rect.contains(p) }) { model.paint(key.slot) }
        })
    }
}

/// One key's colour overlay (dark when the key is off).
struct KeyTint: View {
    let color: RGB?

    var body: some View {
        let fill: Color = color?.color.opacity(0.6) ?? Color.black.opacity(0.35)
        let edge: Color = color?.color ?? .clear
        let glow: Color = color?.color.opacity(0.7) ?? .clear
        return RoundedRectangle(cornerRadius: 4)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(edge, lineWidth: 1))
            .shadow(color: glow, radius: 4)
            .allowsHitTesting(false)
    }
}

struct BrushPanel: View {
    @EnvironmentObject var model: CustomLightModel
    private let presets: [RGB] = [
        .init(r: 255, g: 0, b: 0), .init(r: 255, g: 120, b: 0), .init(r: 255, g: 220, b: 0),
        .init(r: 0, g: 255, b: 0), .init(r: 0, g: 220, b: 255), .init(r: 0, g: 0, b: 255),
        .init(r: 170, g: 0, b: 255), .init(r: 255, g: 0, b: 160), .init(r: 255, g: 255, b: 255),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            ColorWheel(color: Binding(get: { (model.brush.r, model.brush.g, model.brush.b) },
                                      set: { model.brush = RGB(r: $0.r, g: $0.g, b: $0.b); model.erasing = false }),
                       size: 150)
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "Colour")
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 8), count: 3), spacing: 8) {
                    ForEach(presets, id: \.self) { c in
                        Circle().fill(c.color).frame(width: 26, height: 26)
                            .overlay(Circle().stroke(.white, lineWidth: model.brush == c && !model.erasing ? 2 : 0))
                            .onTapGesture { model.brush = c; model.erasing = false }
                    }
                }
                Text(String(format: "R %d  G %d  B %d", model.brush.r, model.brush.g, model.brush.b))
                    .font(.openSans(11)).foregroundStyle(Palette.dim)
            }
        }
    }
}

struct ToolsPanel: View {
    @EnvironmentObject var model: CustomLightModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Tool")
            SkinRadio(title: "Paint keys", checked: !model.erasing) { model.erasing = false }
            SkinRadio(title: "Turn keys off", checked: model.erasing) { model.erasing = true }
            HStack(spacing: 10) {
                SpriteButton(sprite: "btn_apply.png", action: { model.fillAll() }) {
                    Text("Fill all").font(.openSans(13, .semibold))
                }
                SpriteButton(sprite: "btn_apply.png", enabled: !model.colors.isEmpty, action: { model.colors = [:] }) {
                    Text("Clear").font(.openSans(13, .semibold))
                }
            }
            .padding(.top, 4)
            SectionTitle(text: "Brightness").padding(.top, 6)
            SkinSlider(value: $model.brightness, range: 1...5, width: 200)
        }
    }
}

struct CustomLightApplyPanel: View {
    @EnvironmentObject var model: CustomLightModel
    @EnvironmentObject var hid: KeyboardHID
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Custom Light")
            Text("\(model.colors.count) of \(KeyboardLayout.litKeys.count) keys lit")
                .font(.openSans(13)).foregroundStyle(Palette.dim)
            Text("Click or drag across keys to paint them. Applying switches the keyboard to this custom layout; pick an effect in Lighting to go back.")
                .font(.openSans(11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            SpriteButton(sprite: "btn_apply.png", enabled: hid.connection != .none && !model.applying,
                         action: { model.apply(using: hid) }) {
                Text(model.applying ? "Applying…" : "Apply").font(.openSans(13, .semibold))
            }
            Group {
                if hid.connection == .none {
                    Text("Keyboard not connected").foregroundStyle(.orange)
                } else if let r = model.lastResult, !model.hasUnappliedChanges || !r.ok {
                    Button { details.toggle() } label: {
                        Text(r.ok ? "✓ Applied · keyboard confirmed" : "✗ Failed · details")
                            .foregroundStyle(r.ok ? Color.green : Color.red)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $details) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(r.lines.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11, design: .monospaced)) }
                        }.padding(12)
                    }
                } else if model.hasUnappliedChanges {
                    Text("Changes not applied yet").foregroundStyle(Palette.dim)
                }
            }
            .font(.openSans(12))
        }
    }
}
