import SwiftUI

struct SettingsPage: View {
    @EnvironmentObject var model: SettingsModel
    @EnvironmentObject var hid: KeyboardHID

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: Skin.image("keyboard/home_keyboard.png"))
                .resizable().aspectRatio(contentMode: .fit).frame(height: 210)
            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                HStack(alignment: .top, spacing: 0) {
                    screenColumn.frame(width: 330)
                    divider
                    fnAndSleepColumn.frame(width: 300)
                    divider
                    gameColumn.frame(maxWidth: .infinity)
                }
                .padding(.top, 24).padding(.horizontal, 28).padding(.bottom, 20)
            }
            .frame(width: 1060, height: 450)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.horizontal, 22).padding(.vertical, 6)
    }

    // MARK: Columns

    private var screenColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Screen Brightness")
            Text("Brightness of the dot-matrix screen on top.")
                .font(.openSans(12)).foregroundStyle(Palette.dim)
            HStack(spacing: 14) {
                SkinSlider(value: $model.settings.screenBrightness, range: 1...7, width: 230)
                Text("\(model.settings.screenBrightness)")
                    .font(.openSans(18, .semibold)).foregroundStyle(Palette.text).frame(width: 24)
            }
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                SpriteButton(sprite: "btn_apply.png", enabled: hid.connection == .wired && !model.applying,
                             action: { model.apply(using: hid) }) {
                    Text(model.applying ? "Applying…" : "Apply").font(.openSans(13, .semibold))
                }
                SettingsStatus()
            }
        }
    }

    private var fnAndSleepColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Light Sleep Time")
            ForEach([(UInt8(0), "Never"), (1, "1 minute"), (2, "5 minutes"), (3, "30 minutes")], id: \.0) { v, name in
                SkinRadio(title: name, checked: model.settings.sleep == v) { model.settings.sleep = v }
                    .frame(width: 200)
            }
            UntestedNote(text: "No effect seen on the USB cable — likely only applies on battery.")
            SectionTitle(text: "Fn Key").padding(.top, 8)
            SkinRadio(title: "Hold Fn (normal)", checked: !model.settings.fnToggle) { model.settings.fnToggle = false }
                .frame(width: 200)
            SkinRadio(title: "Tap Fn to toggle", checked: model.settings.fnToggle) { model.settings.fnToggle = true }
                .frame(width: 200)
            UntestedNote(text: "No effect seen in testing.")
        }
    }

    private var gameColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "Game Mode")
                Spacer()
                SkinSwitch(isOn: $model.settings.gameMode)
            }
            Group {
                SkinCheckbox(title: "Block Alt + Tab", checked: model.settings.blockAltTab) { model.settings.blockAltTab.toggle() }
                SkinCheckbox(title: "Block Alt + F4", checked: model.settings.blockAltF4) { model.settings.blockAltF4.toggle() }
                SkinCheckbox(title: "Block Windows / ⌘ key", checked: model.settings.blockWindowsKey) { model.settings.blockWindowsKey.toggle() }
            }
            .disabled(!model.settings.gameMode)
            .opacity(model.settings.gameMode ? 1 : 0.4)
            UntestedNote(text: "No effect seen on macOS: ⌘ still worked with all blocks on. May only apply on Windows.")
        }
    }
}

struct UntestedNote: View {
    let text: String
    var body: some View {
        Text(text).font(.openSans(11)).foregroundStyle(.orange.opacity(0.9))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct SettingsStatus: View {
    @EnvironmentObject var model: SettingsModel
    @EnvironmentObject var hid: KeyboardHID
    @State private var details = false

    var body: some View {
        Group {
            if hid.connection != .wired {
                Text("Needs the USB cable").foregroundStyle(.orange)
            } else if let r = model.lastResult, !model.hasUnappliedChanges || !r.ok {
                Button { details.toggle() } label: {
                    Text(r.ok ? "✓ Applied" : "✗ Failed · details").foregroundStyle(r.ok ? Color.green : Color.red)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $details) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(r.lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                    }.padding(12)
                }
            } else if model.hasUnappliedChanges {
                Text("Not applied yet").foregroundStyle(Palette.dim)
            }
        }
        .font(.openSans(12))
    }
}
