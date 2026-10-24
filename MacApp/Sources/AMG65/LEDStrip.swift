import AppKit
import ImageIO
import SwiftUI

// MARK: - Format (cmd 0x33 animation / 0x31 boot animation) — confirmed on the keyboard

enum StripFormat {
    static let width = 63, height = 5, leds = 315

    /// Row-major pixel → LED index (4 panels of 14 × 5, then one of 7 × 5). Same as the app's table at 0x59c7f0.
    static let position: [Int] = (0..<height).flatMap { r in
        (0..<width).map { c in c < 56 ? 70 * (c / 14) + 14 * r + c % 14 : 280 + 7 * r + (c - 56) }
    }
}

enum StripTarget: String, CaseIterable, Identifiable {
    case animation = "Animation", boot = "Boot animation"
    var id: String { rawValue }
    var command: UInt8 { self == .animation ? 0x33 : 0x31 }
    var maxFrames: Int { self == .animation ? 260 : 200 }
}

/// Frames of 63 × 5 RGB pixels (row-major).
struct StripAnimation {
    var frames: [[RGB]]
    var name: String

    func buffer(delay: UInt16, brightness: Double, target: StripTarget) -> (bytes: [UInt8], blocks: Int) {
        let frames = Array(self.frames.prefix(target.maxFrames))
        let end = 4 + frames.count * StripFormat.leds * 3
        let blocks = (end + 2 + 4095) / 4096
        var buf = [UInt8](repeating: 0, count: blocks * 4096)
        buf[0] = UInt8(frames.count & 0xFF); buf[1] = UInt8(frames.count >> 8)
        buf[2] = UInt8(delay & 0xFF); buf[3] = UInt8(delay >> 8)
        let k = max(0, min(1, brightness))
        for (f, frame) in frames.enumerated() {
            for (i, c) in frame.enumerated() where i < StripFormat.leds {
                let o = 4 + 3 * (f * StripFormat.leds + StripFormat.position[i])
                buf[o] = UInt8(Double(c.r) * k); buf[o + 1] = UInt8(Double(c.g) * k); buf[o + 2] = UInt8(Double(c.b) * k)
            }
        }
        buf[end] = 0xAA; buf[end + 1] = 0x55
        return (buf, blocks)
    }

    /// GIF / image → frames scaled to 63 × 5.
    static func load(_ url: URL) -> StripAnimation? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var frames: [[RGB]] = []
        for i in 0..<CGImageSourceGetCount(src) {
            if let img = CGImageSourceCreateImageAtIndex(src, i, nil) { frames.append(pixels(img)) }
        }
        return frames.isEmpty ? nil : StripAnimation(frames: frames, name: url.lastPathComponent)
    }

    static func pixels(_ img: CGImage) -> [RGB] {
        let w = StripFormat.width, h = StripFormat.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return stride(from: 0, to: px.count, by: 4).map { RGB(r: px[$0], g: px[$0 + 1], b: px[$0 + 2]) }
    }

    /// Text scrolling right-to-left in a 3 × 5 pixel font.
    static func scrollingText(_ text: String, color: RGB) -> StripAnimation {
        let columns = TinyFont.columns(text.uppercased())
        let total = columns.count + StripFormat.width
        var frames: [[RGB]] = []
        for shift in 0..<total {
            var f = [RGB](repeating: .off, count: StripFormat.leds)
            for x in 0..<StripFormat.width {
                let col = x + shift - StripFormat.width
                guard col >= 0, col < columns.count else { continue }
                for y in 0..<5 where columns[col] & (1 << y) != 0 { f[y * StripFormat.width + x] = color }
            }
            frames.append(f)
        }
        return StripAnimation(frames: frames, name: "“\(text)”")
    }
}

/// 3 × 5 pixel font. Each glyph = 3 columns; bit y (0 = top) set = lit.
enum TinyFont {
    private static let rows: [Character: [String]] = [
        "A": ["010", "101", "111", "101", "101"], "B": ["110", "101", "110", "101", "110"],
        "C": ["011", "100", "100", "100", "011"], "D": ["110", "101", "101", "101", "110"],
        "E": ["111", "100", "110", "100", "111"], "F": ["111", "100", "110", "100", "100"],
        "G": ["011", "100", "101", "101", "011"], "H": ["101", "101", "111", "101", "101"],
        "I": ["111", "010", "010", "010", "111"], "J": ["001", "001", "001", "101", "010"],
        "K": ["101", "101", "110", "101", "101"], "L": ["100", "100", "100", "100", "111"],
        "M": ["101", "111", "111", "101", "101"], "N": ["110", "101", "101", "101", "101"],
        "O": ["010", "101", "101", "101", "010"], "P": ["110", "101", "110", "100", "100"],
        "Q": ["010", "101", "101", "110", "011"], "R": ["110", "101", "110", "101", "101"],
        "S": ["011", "100", "010", "001", "110"], "T": ["111", "010", "010", "010", "010"],
        "U": ["101", "101", "101", "101", "111"], "V": ["101", "101", "101", "101", "010"],
        "W": ["101", "101", "111", "111", "101"], "X": ["101", "101", "010", "101", "101"],
        "Y": ["101", "101", "010", "010", "010"], "Z": ["111", "001", "010", "100", "111"],
        "0": ["111", "101", "101", "101", "111"], "1": ["010", "110", "010", "010", "111"],
        "2": ["110", "001", "010", "100", "111"], "3": ["110", "001", "010", "001", "110"],
        "4": ["101", "101", "111", "001", "001"], "5": ["111", "100", "110", "001", "110"],
        "6": ["011", "100", "111", "101", "111"], "7": ["111", "001", "010", "010", "010"],
        "8": ["111", "101", "111", "101", "111"], "9": ["111", "101", "111", "001", "110"],
        "!": ["010", "010", "010", "000", "010"], "?": ["110", "001", "010", "000", "010"],
        ".": ["000", "000", "000", "000", "010"], ",": ["000", "000", "000", "010", "100"],
        ":": ["000", "010", "000", "010", "000"], "-": ["000", "000", "111", "000", "000"],
        "+": ["000", "010", "111", "010", "000"], "'": ["010", "010", "000", "000", "000"],
        "/": ["001", "001", "010", "100", "100"], "#": ["101", "111", "101", "111", "101"],
        "<": ["001", "010", "100", "010", "001"], ">": ["100", "010", "001", "010", "100"],
        "%": ["101", "001", "010", "100", "101"], "=": ["000", "111", "000", "111", "000"],
        " ": ["000", "000", "000", "000", "000"],
    ]

    static func columns(_ text: String) -> [UInt8] {
        var out: [UInt8] = []
        for ch in text {
            let g = rows[ch] ?? rows["?"]!
            for c in 0..<3 {
                var bits: UInt8 = 0
                for y in 0..<5 where Array(g[y])[c] == "1" { bits |= 1 << y }
                out.append(bits)
            }
            out.append(0)   // 1-column gap
        }
        return out
    }
}

// MARK: - Model

final class StripModel: ObservableObject {
    enum Source: String, CaseIterable, Identifiable { case text = "Text", image = "GIF / image"; var id: String { rawValue } }

    @Published var source: Source = .text { didSet { rebuild() } }
    @Published var text = "HELLO FROM MAC" { didSet { rebuild() } }
    @Published var textColor = RGB(r: 0, g: 200, b: 255) { didSet { rebuild() } }
    @Published var delay: UInt8 = 10          // frame delay word; ≈ 75 ms + 2.2 ms × delay per frame (measured)

    /// Estimated time per frame on the keyboard, from user timings (delay 20 ≈ 118 ms, 80 ≈ 250 ms).
    static func frameMs(_ delay: UInt8) -> Double { 75 + 2.2 * Double(delay) }
    @Published var brightness: UInt8 = 5      // 1…5 → 20…100 %
    @Published var target: StripTarget = .animation
    @Published private(set) var animation: StripAnimation?
    @Published private(set) var uploading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var lastResult: TransactionResult?
    private var imageAnimation: StripAnimation?

    init() { rebuild() }

    func rebuild() {
        animation = source == .text ? StripAnimation.scrollingText(text, color: textColor) : imageAnimation
    }

    func load(_ url: URL) {
        imageAnimation = StripAnimation.load(url)
        source = .image
        rebuild()
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .image]
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func upload(using hid: KeyboardHID) {
        guard let animation, !uploading else { return }
        uploading = true; progress = 0
        let (bytes, blocks) = animation.buffer(delay: UInt16(delay), brightness: Double(brightness) / 5, target: target)
        hid.uploadBulk(bytes, blocks: blocks,
                       header: AMG65Protocol.packet([0x04, target.command], [8: UInt8(blocks & 0xFF), 9: UInt8(blocks >> 8)]),
                       headerLabel: "strip header (04 \(String(format: "%02X", target.command)), \(blocks) blocks)",
                       applyAfter: true,
                       progress: { [weak self] p in self?.progress = p }) { [weak self] r in
            self?.uploading = false; self?.lastResult = r
        }
    }
}

// MARK: - Page

struct LEDStripPage: View {
    @EnvironmentObject var model: StripModel
    @EnvironmentObject var hid: KeyboardHID
    @EnvironmentObject var live: LiveStripController
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 14) {
            StripPreview(animation: live.preview.map { StripAnimation(frames: [$0], name: "live") } ?? model.animation,
                         delay: model.delay, brightness: live.preview == nil ? model.brightness : 5)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(dropHover ? Palette.accent : .clear, lineWidth: 2))
                .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
                    _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                        if let url { DispatchQueue.main.async { model.load(url) } }
                    }
                    return true
                }
                .padding(.top, 18)
            if let a = model.animation {
                Text("\(a.name) · \(min(a.frames.count, model.target.maxFrames)) frame\(a.frames.count == 1 ? "" : "s")"
                     + (a.frames.count > model.target.maxFrames ? " (first \(model.target.maxFrames) uploaded)" : ""))
                    .font(.openSans(12)).foregroundStyle(Palette.dim)
            }
            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                HStack(alignment: .top, spacing: 0) {
                    sourceColumn.frame(width: 400)
                    divider
                    optionsColumn.frame(width: 250)
                    divider
                    uploadColumn.frame(maxWidth: .infinity)
                }
                .padding(.top, 22).padding(.horizontal, 26).padding(.bottom, 18)
            }
            .frame(width: 1060, height: 300)
            .opacity(live.mode == .off ? 1 : 0.45)
            .disabled(live.mode != .off)
            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                LiveStripPanel().padding(.top, 18).padding(.horizontal, 26)
            }
            .frame(width: 1060, height: 140)
            Spacer(minLength: 0)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.horizontal, 20).padding(.vertical, 6)
    }

    private var sourceColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Source")
            HStack(spacing: 18) {
                ForEach(StripModel.Source.allCases) { s in
                    SkinRadio(title: s.rawValue, checked: model.source == s) { model.source = s }.frame(width: 130)
                }
            }
            if model.source == .text {
                TextField("Text to scroll", text: $model.text)
                    .textFieldStyle(.plain).font(.openSans(14)).foregroundStyle(Palette.text)
                    .padding(8).background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.15)))
                Text("Letters, numbers and common symbols, 3 × 5 pixel font.")
                    .font(.openSans(11)).foregroundStyle(Palette.dim)
                HStack(spacing: 8) {
                    ForEach([RGB(r: 255, g: 255, b: 255), RGB(r: 255, g: 0, b: 0), RGB(r: 255, g: 140, b: 0),
                             RGB(r: 255, g: 230, b: 0), RGB(r: 0, g: 255, b: 0), RGB(r: 0, g: 200, b: 255),
                             RGB(r: 0, g: 0, b: 255), RGB(r: 200, g: 0, b: 255)], id: \.self) { c in
                        Circle().fill(c.color).frame(width: 24, height: 24)
                            .overlay(Circle().stroke(.white, lineWidth: model.textColor == c ? 2 : 0))
                            .onTapGesture { model.textColor = c }
                    }
                }
            } else {
                Text("Drop a GIF or image on the strip preview, or choose one. It's scaled to 63 × 5.")
                    .font(.openSans(12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                SpriteButton(sprite: "btn_apply.png", action: { model.chooseFile() }) {
                    Text("Choose…").font(.openSans(13, .semibold))
                }
            }
        }
    }

    private var optionsColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Upload as")
            ForEach(StripTarget.allCases) { t in
                SkinRadio(title: t.rawValue, checked: model.target == t) { model.target = t }.frame(width: 200)
            }
            SectionTitle(text: "Brightness").padding(.top, 6)
            SkinSlider(value: $model.brightness, range: 1...5, width: 200)
            HStack(spacing: 6) {
                SectionTitle(text: "Frame delay")
                Text("\(model.delay) · ≈\(Int(StripModel.frameMs(model.delay))) ms/frame").font(.openSans(12)).foregroundStyle(Palette.dim)
            }
            SkinSlider(value: $model.delay, range: 1...200, width: 200)
            Text("Lower is faster. The strip needs ≈75 ms per frame even at the minimum (estimate from timing).")
                .font(.openSans(11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var uploadColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "LED Strip")
            Text("Uploading switches the strip to this animation.")
                .font(.openSans(12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            UploadBar(progress: model.uploading ? model.progress : (model.lastResult?.ok == true ? 1 : 0))
                .frame(width: 220, alignment: .leading).clipped()
            SpriteButton(sprite: "btn_apply.png",
                         enabled: hid.connection == .wired && model.animation != nil && !model.uploading,
                         action: { model.upload(using: hid) }) {
                Text(model.uploading ? "Uploading…" : "Upload").font(.openSans(13, .semibold))
            }
            ResultLabel(result: model.lastResult, busy: model.uploading, busyText: "\(Int(model.progress * 100))%",
                        needsCable: hid.connection != .wired, okText: "✓ Uploaded · keyboard confirmed")
        }
    }
}

/// 63 × 5 LED dots playing the animation.
struct StripPreview: View {
    let animation: StripAnimation?
    let delay: UInt8
    let brightness: UInt8
    private let dot: CGFloat = 13, gap: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { ctx in
            let frame = currentFrame(at: ctx.date)
            Canvas { g, _ in
                for y in 0..<StripFormat.height {
                    for x in 0..<StripFormat.width {
                        let c = frame?[y * StripFormat.width + x] ?? .off
                        let rect = CGRect(x: 10 + CGFloat(x) * (dot + gap), y: 10 + CGFloat(y) * (dot + gap), width: dot, height: dot)
                        let lit = !c.isOff
                        let k = Double(brightness) / 5
                        g.fill(Path(ellipseIn: rect),
                               with: .color(lit ? c.color.opacity(0.35 + 0.65 * k) : Color.white.opacity(0.06)))
                    }
                }
            }
            .frame(width: 20 + CGFloat(StripFormat.width) * (dot + gap) - gap, height: 20 + 5 * (dot + gap) - gap)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.15)))
        }
    }

    private func currentFrame(at date: Date) -> [RGB]? {
        guard let a = animation, !a.frames.isEmpty else { return nil }
        // Plays at the keyboard's estimated speed (≈ 75 ms + 2.2 ms × delay per frame).
        let i = Int(date.timeIntervalSinceReferenceDate * 1000 / StripModel.frameMs(delay)) % a.frames.count
        return a.frames[i]
    }
}
