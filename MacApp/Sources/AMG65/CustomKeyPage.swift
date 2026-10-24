import SwiftUI

struct CustomKeyPage: View {
    @EnvironmentObject var keymap: KeymapModel

    var body: some View {
        VStack(spacing: 10) {
            KeyboardPicker()
                .frame(height: 300)
            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                HStack(alignment: .top, spacing: 0) {
                    SelectedKeyPanel().frame(width: 230)
                    panelDivider
                    ActionPicker().frame(maxWidth: .infinity)
                    panelDivider
                    KeymapApplyPanel().frame(width: 190)
                }
                .padding(.top, 22).padding(.horizontal, 26).padding(.bottom, 18)
            }
            .frame(width: 1060, height: 360)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

private var panelDivider: some View {
    Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.horizontal, 20).padding(.vertical, 6)
}

// MARK: - Keyboard with clickable keys

struct KeyboardPicker: View {
    @EnvironmentObject var keymap: KeymapModel
    private let crop = CGRect(x: 0, y: 0, width: 880, height: 400)
    private let width: CGFloat = 700

    var body: some View {
        let scale = width / crop.width
        ZStack(alignment: .topLeading) {
            Image(nsImage: Skin.crop("keyboard/img_keyboard_kt84.png", crop))
                .resizable().frame(width: width, height: crop.height * scale)
            ForEach(KeyboardLayout.keys) { key in
                KeyCapOverlay(key: key,
                              selected: keymap.selectedSlot == key.slot,
                              action: keymap.assignments[key.slot])
                    .frame(width: key.rect.width * scale, height: key.rect.height * scale)
                    .offset(x: key.rect.minX * scale, y: key.rect.minY * scale)
                    .onTapGesture { if key.remappable { keymap.selectedSlot = key.slot } }
            }
        }
        .frame(width: width, height: crop.height * scale)
    }
}

struct KeyCapOverlay: View {
    let key: PhysicalKey
    let selected: Bool
    let action: KeyAction?
    @State private var hover = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(action != nil ? Palette.accent.opacity(0.35) : Color.white.opacity(hover && key.remappable ? 0.12 : 0.001))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(selected ? Palette.accent : (action != nil ? Palette.accent.opacity(0.7) : .clear), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .help(key.remappable
                  ? "\(key.name)\(action.map { " → \($0.title)" } ?? "")"
                  : "\(key.name) can't be remapped here")
    }
}

// MARK: - Left: the selected key

struct SelectedKeyPanel: View {
    @EnvironmentObject var keymap: KeymapModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Selected Key")
            if let key = keymap.selectedKey {
                Text(key.name).font(.openSans(28, .semibold)).foregroundStyle(Palette.text)
                Text("Sends").font(.openSans(12)).foregroundStyle(Palette.dim)
                Text(keymap.assignments[key.slot]?.title ?? "Default (\(key.name))")
                    .font(.openSans(16, .semibold))
                    .foregroundStyle(keymap.assignments[key.slot] == nil ? Palette.dim : Palette.accent)
                if let a = keymap.assignments[key.slot], !a.tested {
                    Text("This kind of action is decoded but not yet tested on the keyboard.")
                        .font(.openSans(11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                SpriteButton(sprite: "btn_apply.png", enabled: keymap.assignments[key.slot] != nil,
                             action: { keymap.assign(nil) }) {
                    Text("Reset key").font(.openSans(13, .semibold))
                }
            } else {
                Text("Click a key on the keyboard above to change what it does.")
                    .font(.openSans(13)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Middle: choose the new action

enum ActionCategory: String, CaseIterable, Identifiable {
    case keyboard = "Keyboard", media = "Media", mouse = "Mouse"
    var id: String { rawValue }
}

struct ActionPicker: View {
    @EnvironmentObject var keymap: KeymapModel
    @State private var category: ActionCategory = .keyboard
    @State private var modifiers: UInt8 = 0
    @State private var group = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(ActionCategory.allCases) { c in
                    Text(c.rawValue).font(.openSans(13, category == c ? .semibold : .regular))
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Capsule().fill(category == c ? Palette.accent.opacity(0.85) : .white.opacity(0.08)))
                        .foregroundStyle(Palette.text)
                        .contentShape(Capsule())
                        .onTapGesture { category = c }
                }
                if category != .keyboard {
                    Text("untested").font(.openSans(10)).foregroundStyle(.orange)
                }
            }
            Group {
                switch category {
                case .keyboard: keyboardChoices
                case .media: mediaChoices
                case .mouse: mouseChoices
                }
            }
            .disabled(keymap.selectedKey == nil)
            .opacity(keymap.selectedKey == nil ? 0.35 : 1)
        }
        .onChange(of: keymap.selectedSlot) { syncModifiers() }
        .onAppear { syncModifiers() }
    }

    private func syncModifiers() {
        if let slot = keymap.selectedSlot, case let .key(m, _)? = keymap.assignments[slot] { modifiers = m } else { modifiers = 0 }
    }

    private var current: KeyAction? { keymap.selectedSlot.flatMap { keymap.assignments[$0] } }

    private var keyboardChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Text("Hold").font(.openSans(12)).foregroundStyle(Palette.dim)
                ForEach(Modifier.allCases, id: \.bit) { m in
                    SkinCheckbox(title: "\(m.symbol) \(m.name)", checked: modifiers & m.bit != 0) {
                        modifiers ^= m.bit
                        if case let .key(_, code)? = current { keymap.assign(.key(modifiers: modifiers, code: code)) }
                    }
                }
            }
            HStack(spacing: 12) {
                ForEach(HIDKeys.groups.indices, id: \.self) { i in
                    Text(HIDKeys.groups[i].0)
                        .font(.openSans(12, group == i ? .semibold : .regular))
                        .foregroundStyle(group == i ? Palette.accent : Palette.dim)
                        .contentShape(Rectangle())
                        .onTapGesture { group = i }
                }
            }
            .padding(.top, 2)
            FlowChips(items: HIDKeys.groups[group].1.map { ($0.name, KeyAction.key(modifiers: modifiers, code: $0.code)) },
                      current: current) { keymap.assign($0) }
        }
    }

    private var mediaChoices: some View {
        FlowChips(items: MediaKeys.all.map { ($0.name, KeyAction.media($0.usage)) }, current: current) { keymap.assign($0) }
    }

    private var mouseChoices: some View {
        FlowChips(items: MouseActions.buttons.map { ($0.name, KeyAction.mouseButton($0.mask)) }
                    + [("Scroll up", KeyAction.wheel(up: true)), ("Scroll down", KeyAction.wheel(up: false))],
                  current: current) { keymap.assign($0) }
    }
}

struct FlowChips: View {
    let items: [(String, KeyAction)]
    let current: KeyAction?
    let pick: (KeyAction) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { name, action in
                let on = current == action
                Text(name).font(.openSans(12, on ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 4).fill(on ? Palette.accent.opacity(0.85) : .white.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.12)))
                    .foregroundStyle(Palette.text)
                    .contentShape(Rectangle())
                    .onTapGesture { pick(action) }
            }
        }
    }
}

/// Checkbox from btn_checkbox.png (frames 0–3 unchecked, 4–7 checked).
struct SkinCheckbox: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    var body: some View {
        HStack(spacing: 5) {
            Image(nsImage: Skin.sprite("btn_checkbox.png", frames: 8, index: checked ? 4 : 0))
                .resizable().frame(width: 16, height: 16)
            Text(title).font(.openSans(12)).foregroundStyle(Palette.text)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
}

// MARK: - Right: apply

struct KeymapApplyPanel: View {
    @EnvironmentObject var keymap: KeymapModel
    @EnvironmentObject var hid: KeyboardHID
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Key Map")
            Text("\(keymap.assignments.count) key\(keymap.assignments.count == 1 ? "" : "s") remapped")
                .font(.openSans(13)).foregroundStyle(Palette.dim)
            Spacer(minLength: 0)
            SpriteButton(sprite: "btn_apply.png", enabled: !keymap.assignments.isEmpty,
                         action: { keymap.assignments = [:] }) {
                Text("Reset all").font(.openSans(13, .semibold))
            }
            SpriteButton(sprite: "btn_apply.png", enabled: hid.connection != .none && !keymap.applying,
                         action: { keymap.apply(using: hid) }) {
                Text(keymap.applying ? "Applying…" : "Apply").font(.openSans(13, .semibold))
            }
            Group {
                if hid.connection == .none {
                    Text("Keyboard not connected").foregroundStyle(.orange)
                } else if let r = keymap.lastResult, !keymap.hasUnappliedChanges || !r.ok {
                    Button { details.toggle() } label: {
                        Text(r.ok ? "✓ Applied · keyboard confirmed" : "✗ Failed · details")
                            .foregroundStyle(r.ok ? Color.green : Color.red)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $details) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(r.lines, id: \.self) { Text($0).font(.system(size: 11, design: .monospaced)) }
                        }.padding(12)
                    }
                } else if keymap.hasUnappliedChanges {
                    Text("Changes not applied yet").foregroundStyle(Palette.dim)
                }
            }
            .font(.openSans(12))
        }
    }
}
