import SwiftUI

struct LightingPage: View {
    @EnvironmentObject var lighting: LightingModel
    @EnvironmentObject var hid: KeyboardHID

    var body: some View {
        VStack(spacing: 14) {
            KeyboardPreview(settings: lighting.settings)
                .frame(height: 300)
            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                HStack(alignment: .top, spacing: 0) {
                    EffectList()
                        .frame(width: 420)
                    divider
                    ColourSection()
                        .frame(width: 250)
                    divider
                    ParameterSection()
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 22).padding(.horizontal, 26).padding(.bottom, 18)
            }
            .frame(width: 1060, height: 350)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.horizontal, 22).padding(.vertical, 6)
    }
}

// MARK: - Sections

struct EffectList: View {
    @EnvironmentObject var lighting: LightingModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .leading), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "Light Effect Mode")
            LazyVGrid(columns: columns, alignment: .leading, spacing: 11) {
                ForEach(lightingModes) { m in
                    SkinRadio(title: m.name, checked: lighting.settings.mode == m.id,
                              note: m.confirmed ? "Confirmed on the keyboard" : "Mode \(m.id) — name inferred, not yet tested") {
                        lighting.settings.mode = m.id
                    }
                }
            }
        }
    }
}

struct ColourSection: View {
    @EnvironmentObject var lighting: LightingModel

    var body: some View {
        let off = lighting.settings.mode == 20
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Colour")
            ColorWheel(color: lighting.color, size: 170, enabled: !off && !lighting.settings.colorful)
                .frame(maxWidth: .infinity)
            HStack {
                Text("Colourful").font(.openSans(13)).foregroundStyle(Palette.text)
                Spacer()
                SkinSwitch(isOn: $lighting.settings.colorful)
            }
            .opacity(off ? 0.35 : 1)
            Text(lighting.settings.colorful
                 ? "Rainbow colours"
                 : String(format: "R %d   G %d   B %d", lighting.settings.red, lighting.settings.green, lighting.settings.blue))
                .font(.openSans(12)).foregroundStyle(Palette.dim)
        }
    }
}

struct ParameterSection: View {
    @EnvironmentObject var lighting: LightingModel
    @EnvironmentObject var hid: KeyboardHID

    var body: some View {
        let mode = lighting.mode
        let off = mode.id == 20
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Brightness")
            SkinSlider(value: $lighting.settings.brightness, range: 1...5, enabled: !off)
            SectionTitle(text: "Speed")
            SkinSlider(value: $lighting.settings.speed, range: 1...5, enabled: mode.usesSpeed)
            HStack(spacing: 6) {
                SectionTitle(text: "Direction")
                Text("untested").font(.openSans(10)).foregroundStyle(Palette.dim)
            }
            DirectionPicker(value: $lighting.settings.direction)
                .disabled(!mode.usesSpeed)
                .opacity(mode.usesSpeed ? 1 : 0.35)
            Spacer(minLength: 4)
            HStack(spacing: 14) {
                SpriteButton(sprite: "btn_apply.png", enabled: hid.connection != .none && !lighting.applying,
                             action: { lighting.apply(using: hid) }) {
                    Text(lighting.applying ? "Applying…" : "Apply").font(.openSans(13, .semibold))
                }
                ApplyStatus()
            }
        }
    }
}

struct DirectionPicker: View {
    @Binding var value: UInt8
    // Value mapping is a guess (direction is untested on the keyboard).
    // Note: the original files are named oddly — "right" draws ← and "left" draws →.
    private let items: [(String, UInt8)] = [
        ("img_direction_right.png", 0), ("img_direction_left.png", 1),
        ("img_direction_top.png", 2), ("img_direction_bottom.png", 3),
    ]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.1) { name, v in
                Image(nsImage: Skin.sprite(name, frames: 8, index: value == v ? 5 : 0))
                    .resizable().frame(width: 30, height: 30)
                    .contentShape(Rectangle())
                    .onTapGesture { value = v }
            }
        }
    }
}

struct ApplyStatus: View {
    @EnvironmentObject var lighting: LightingModel
    @EnvironmentObject var hid: KeyboardHID
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if hid.connection == .none {
                Text("Keyboard not connected").font(.openSans(12)).foregroundStyle(.orange)
            } else if let r = lighting.lastResult, !lighting.hasUnappliedChanges || !r.ok {
                Button { showDetails.toggle() } label: {
                    Text(r.ok ? "✓ Applied · keyboard confirmed" : "✗ Failed · details")
                        .font(.openSans(12)).foregroundStyle(r.ok ? Color.green : Color.red)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r.lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                    }
                    .padding(12)
                }
            } else if lighting.hasUnappliedChanges {
                Text("Changes not applied yet").font(.openSans(12)).foregroundStyle(Palette.dim)
            }
        }
    }
}

// MARK: - Keyboard preview

/// The original grey keyboard render, tinted to roughly show the chosen lighting.
struct KeyboardPreview: View {
    let settings: LightingSettings

    var body: some View {
        TimelineView(.animation(paused: settings.mode != 7)) { ctx in
            let level = intensity(at: ctx.date)
            let base = Image(nsImage: Skin.crop("keyboard/img_keyboard_kt84.png", CGRect(x: 0, y: 0, width: 860, height: 400)))
                .resizable().aspectRatio(contentMode: .fit)
            ZStack {
                base.opacity(0.45)
                tinted(base).opacity(level)
            }
            .shadow(color: glow.opacity(0.35 * level), radius: 30)
        }
    }

    private var glow: Color {
        settings.colorful ? .purple
            : Color(red: Double(settings.red) / 255, green: Double(settings.green) / 255, blue: Double(settings.blue) / 255)
    }

    @ViewBuilder
    private func tinted(_ base: some View) -> some View {
        if settings.colorful {
            base.overlay(
                LinearGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink],
                               startPoint: .leading, endPoint: .trailing)
                    .blendMode(.multiply)
            )
            .mask(base)
        } else {
            base.colorMultiply(glow)
        }
    }

    private func intensity(at date: Date) -> Double {
        if settings.mode == 20 { return 0 }
        let bright = 0.35 + 0.65 * Double(settings.brightness) / 5
        guard settings.mode == 7 else { return bright }   // Breath: pulse with speed
        let hz = 0.15 + 0.12 * Double(settings.speed)
        let t = date.timeIntervalSinceReferenceDate
        return bright * (0.5 + 0.5 * sin(t * 2 * .pi * hz))
    }
}
