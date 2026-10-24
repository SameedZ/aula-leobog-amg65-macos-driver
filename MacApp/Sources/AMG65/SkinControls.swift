import AppKit
import SwiftUI

/// Button drawn from a 4-frame sprite strip: normal, hover, pressed, disabled.
struct SpriteButton<Label: View>: View {
    let sprite: String
    var frames = 4
    var enabled = true
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var hover = false
    @State private var pressed = false

    var body: some View {
        let frame = !enabled ? 3 : pressed ? 2 : hover ? 1 : 0
        ZStack {
            Image(nsImage: Skin.sprite(sprite, frames: frames, index: frame))
            label().foregroundStyle(frame == 2 ? Color.black : Color.white)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if enabled { pressed = true } }
            .onEnded { _ in
                if pressed && enabled { action() }
                pressed = false
            })
        .opacity(enabled ? 1 : 0.6)
    }
}

/// Radio button from btn_radiobox.png (frames 0–3 unchecked, 4–7 checked).
struct SkinRadio: View {
    let title: String
    let checked: Bool
    var note: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: Skin.sprite("btn_radiobox.png", frames: 8, index: (checked ? 4 : 0) + (hover ? 1 : 0)))
                .resizable().frame(width: 18, height: 18)
            Text(title).font(.openSans(13, checked ? .semibold : .regular))
                .foregroundStyle(checked ? Palette.text : Palette.text.opacity(hover ? 0.95 : 0.75))
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: action)
        .help(note ?? "")
    }
}

/// On/off switch from img_switch_on.png / img_switch_off.png.
struct SkinSwitch: View {
    @Binding var isOn: Bool
    @State private var hover = false
    var body: some View {
        Image(nsImage: Skin.sprite(isOn ? "img_switch_on.png" : "img_switch_off.png", frames: 4, index: hover ? 1 : 0))
            .onHover { hover = $0 }
            .onTapGesture { isOn.toggle() }
    }
}

/// Stepped slider from img_slider_back.png (top half = blue fill, bottom = track)
/// and img_thumb.png.
struct SkinSlider: View {
    @Binding var value: UInt8
    let range: ClosedRange<UInt8>
    var enabled = true
    var width: CGFloat = 230

    private var fraction: CGFloat {
        CGFloat(value - range.lowerBound) / CGFloat(range.upperBound - range.lowerBound)
    }

    var body: some View {
        let track = Skin.crop("img_slider_back.png", CGRect(x: 0, y: 13, width: 290, height: 13))
        let fill = Skin.crop("img_slider_back.png", CGRect(x: 0, y: 0, width: 290, height: 13))
        ZStack(alignment: .leading) {
            Image(nsImage: track).resizable().frame(width: width, height: 6).clipShape(Capsule())
            Image(nsImage: fill).resizable().frame(width: width, height: 6)
                .mask(alignment: .leading) { Capsule().frame(width: max(6, width * fraction)) }
            Image(nsImage: Skin.sprite("img_thumb.png", frames: 4, index: 0))
                .offset(x: width * fraction - 9, y: 10)
        }
        .frame(width: width, height: 30)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            guard enabled else { return }
            let steps = CGFloat(range.upperBound - range.lowerBound)
            let v = (g.location.x / width * steps).rounded()
            value = range.lowerBound + UInt8(min(max(v, 0), steps))
        })
        .opacity(enabled ? 1 : 0.35)
    }
}

/// The original colour ring (img_circlepalette.png); picks the pixel under the cursor.
struct ColorWheel: View {
    @Binding var color: (r: UInt8, g: UInt8, b: UInt8)
    var size: CGFloat = 180
    var enabled = true
    @State private var marker: CGPoint? = nil

    private static let bitmap: NSBitmapImageRep? = {
        guard let cg = Skin.image("img_circlepalette.png").cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return NSBitmapImageRep(cgImage: cg)
    }()

    var body: some View {
        ZStack {
            Image(nsImage: Skin.image("img_circlepalette.png")).resizable().frame(width: size, height: size)
            Circle()
                .fill(Color(red: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255))
                .frame(width: size * 0.42, height: size * 0.42)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 1))
            if let m = marker {
                Circle().stroke(.white, lineWidth: 2).frame(width: 12, height: 12)
                    .shadow(radius: 2).position(m)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in pick(at: g.location) })
        .opacity(enabled ? 1 : 0.35)
    }

    private func pick(at p: CGPoint) {
        guard enabled, let bmp = Self.bitmap else { return }
        let scale = CGFloat(bmp.pixelsWide) / size
        let x = Int(p.x * scale), y = Int(p.y * scale)
        guard x >= 0, y >= 0, x < bmp.pixelsWide, y < bmp.pixelsHigh,
              let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.6 else { return }
        color = (UInt8(c.redComponent * 255), UInt8(c.greenComponent * 255), UInt8(c.blueComponent * 255))
        marker = p
    }
}

/// Section heading in the original style.
struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.openSans(15, .semibold)).foregroundStyle(Palette.text)
    }
}
