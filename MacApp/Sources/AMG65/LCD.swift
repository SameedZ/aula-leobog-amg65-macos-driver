import AppKit
import CLibUSB
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Format (cmd 0x72) — confirmed on the keyboard

enum LCDFormat {
    static let width = 240, height = 135
    static let header = 256          // [0] frame count, [1+i] delay of frame i in 2 ms units
    static let maxFrames = 130
    static let block = 4096
    static let slot: UInt8 = 1       // the only slot tested so far
}

/// Frames ready for the LCD (already scaled to 240×135).
struct LCDAnimation {
    var frames: [CGImage]
    var delaysMs: [Int]
    var name: String

    var truncated: Bool { frames.count > LCDFormat.maxFrames }
    var uploadFrames: [CGImage] { Array(frames.prefix(LCDFormat.maxFrames)) }

    /// Whole upload buffer: FF-filled, header, RGB565 little-endian frames, padded to 4 KB blocks.
    func buffer() -> (bytes: [UInt8], blocks: Int) {
        let frames = uploadFrames
        let frameBytes = LCDFormat.width * LCDFormat.height * 2
        let size = LCDFormat.header + frames.count * frameBytes
        let blocks = (size + LCDFormat.block - 1) / LCDFormat.block
        var buf = [UInt8](repeating: 0xFF, count: blocks * LCDFormat.block)
        buf[0] = UInt8(frames.count)
        for (i, d) in delaysMs.prefix(frames.count).enumerated() { buf[1 + i] = UInt8(max(1, min(255, d / 2))) }
        for (i, frame) in frames.enumerated() {
            let px = LCDAnimation.rgba(frame)
            var o = LCDFormat.header + i * frameBytes
            for p in stride(from: 0, to: px.count, by: 4) {
                let v = (UInt16(px[p] & 0xF8) << 8) | (UInt16(px[p + 1] & 0xFC) << 3) | UInt16(px[p + 2] >> 3)
                buf[o] = UInt8(v & 0xFF); buf[o + 1] = UInt8(v >> 8)
                o += 2
            }
        }
        return (buf, blocks)
    }

    static func rgba(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: LCDFormat.width * LCDFormat.height * 4)
        let ctx = CGContext(data: &px, width: LCDFormat.width, height: LCDFormat.height, bitsPerComponent: 8,
                            bytesPerRow: LCDFormat.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: LCDFormat.width, height: LCDFormat.height))
        return px
    }

    /// Loads a GIF / PNG / JPEG and scales every frame to 240×135 (fill = crop to cover, else fit with black bars).
    static func load(_ url: URL, fill: Bool) -> LCDAnimation? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let count = CGImageSourceGetCount(src)
        var frames: [CGImage] = [], delays: [Int] = []
        for i in 0..<count {
            guard let img = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            frames.append(scaled(img, fill: fill))
            let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [CFString: Any]
            let gif = props?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let d = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
            delays.append(max(20, Int(d * 1000)))
        }
        return frames.isEmpty ? nil : LCDAnimation(frames: frames, delaysMs: delays, name: url.lastPathComponent)
    }

    static func scaled(_ img: CGImage, fill: Bool) -> CGImage {
        let w = CGFloat(LCDFormat.width), h = CGFloat(LCDFormat.height)
        let ctx = CGContext(data: nil, width: LCDFormat.width, height: LCDFormat.height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        let iw = CGFloat(img.width), ih = CGFloat(img.height)
        let s = fill ? max(w / iw, h / ih) : min(w / iw, h / ih)
        let dw = iw * s, dh = ih * s
        ctx.draw(img, in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
        return ctx.makeImage()!
    }
}

// MARK: - Bulk channel (interface 3, endpoint 0x06) via libusb

final class LCDBulkChannel {
    private var ctx: OpaquePointer?
    private var handle: OpaquePointer?

    init() throws {
        guard libusb_init(&ctx) == 0 else { throw LCDError.usb("libusb init failed") }
        handle = libusb_open_device_with_vid_pid(ctx, 0x0C45, 0x800A)
        guard handle != nil else { throw LCDError.usb("wired AMG65 not found") }
        let r = libusb_claim_interface(handle, 3)
        guard r == 0 else { throw LCDError.usb("can't claim LCD interface (\(r))") }
    }

    func write(_ data: [UInt8]) throws {
        var bytes = data
        var sent: Int32 = 0
        let r = libusb_interrupt_transfer(handle, 0x06, &bytes, Int32(bytes.count), &sent, 2000)
        guard r == 0, sent == Int32(bytes.count) else { throw LCDError.usb("block write failed (\(r))") }
    }

    deinit {
        if let handle { libusb_release_interface(handle, 3); libusb_close(handle) }
        if let ctx { libusb_exit(ctx) }
    }
}

enum LCDError: Error, CustomStringConvertible {
    case usb(String)
    var description: String { if case let .usb(s) = self { return s }; return "error" }
}

// MARK: - Model

final class ScreenModel: ObservableObject {
    @Published var animation: LCDAnimation?
    @Published var fill = true { didSet { reload() } }
    @Published private(set) var uploading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var lastResult: TransactionResult?
    @Published private(set) var lastTimeSync: TransactionResult?
    private var sourceURL: URL?

    init(preload: URL? = nil) {
        if let preload { load(preload) }
    }

    func load(_ url: URL) {
        sourceURL = url
        animation = LCDAnimation.load(url, fill: fill)
        lastResult = nil
    }

    private func reload() { if let sourceURL { load(sourceURL) } }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.gif, .png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url) }
    }

    func upload(using hid: KeyboardHID) {
        guard let animation, !uploading else { return }
        uploading = true
        progress = 0
        let (bytes, blocks) = animation.buffer()
        hid.uploadLCD(bytes, blocks: blocks, slot: LCDFormat.slot,
                      progress: { [weak self] p in self?.progress = p }) { [weak self] result in
            self?.uploading = false
            self?.lastResult = result
        }
    }

    func syncTime(using hid: KeyboardHID) {
        hid.send(AMG65Protocol.timeSync(Date(), view: LCDFormat.slot)) { [weak self] r in self?.lastTimeSync = r }
    }
}

// MARK: - Page

struct ScreenPage: View {
    @EnvironmentObject var model: ScreenModel
    @EnvironmentObject var hid: KeyboardHID
    @State private var dropHover = false

    var body: some View {
        VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 26) {
                LCDPreview(animation: model.animation)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropHover ? Palette.accent : .clear, lineWidth: 2))
                    .onDrop(of: [.fileURL], isTargeted: $dropHover) { providers in
                        _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DispatchQueue.main.async { model.load(url) } }
                        }
                        return true
                    }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(text: "LCD Animation")
                    Text("The small colour screen on the right of the keyboard (240 × 135).")
                        .font(.openSans(12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
                    if let a = model.animation {
                        Text(a.name).font(.openSans(15, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                        Text("\(min(a.frames.count, LCDFormat.maxFrames)) frames · \(String(format: "%.1f", Double(a.delaysMs.prefix(LCDFormat.maxFrames).reduce(0, +)) / 1000)) s loop")
                            .font(.openSans(12)).foregroundStyle(Palette.dim)
                        if a.truncated {
                            UntestedNote(text: "The GIF has \(a.frames.count) frames; only the first \(LCDFormat.maxFrames) fit on the keyboard.")
                        }
                    } else {
                        Text("Drop a GIF or image on the preview, or choose one.").font(.openSans(13)).foregroundStyle(Palette.dim)
                    }
                    Spacer().frame(height: 4)
                    SpriteButton(sprite: "btn_apply.png", action: { model.chooseFile() }) {
                        Text("Choose…").font(.openSans(13, .semibold))
                    }
                    HStack(spacing: 16) {
                        SkinRadio(title: "Fill (crop)", checked: model.fill) { model.fill = true }.frame(width: 110)
                        SkinRadio(title: "Fit", checked: !model.fill) { model.fill = false }.frame(width: 70)
                    }
                }
                .frame(width: 330, alignment: .leading)
            }
            .padding(.top, 20)

            ZStack(alignment: .topLeading) {
                Image(nsImage: Skin.image("img_bottom_area.png")).resizable()
                HStack(alignment: .top, spacing: 0) {
                    uploadColumn.frame(width: 560)
                    Rectangle().fill(.white.opacity(0.10)).frame(width: 1).padding(.horizontal, 22).padding(.vertical, 6)
                    clockColumn.frame(maxWidth: .infinity)
                }
                .padding(.top, 22).padding(.horizontal, 28).padding(.bottom, 18)
            }
            .frame(width: 1060, height: 250)
            Spacer(minLength: 0)
        }
    }

    private var uploadColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Upload to Keyboard")
            Text("Replaces the animation currently on the LCD. Large GIFs take a while (about 6 blocks a second).")
                .font(.openSans(12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            UploadBar(progress: model.uploading ? model.progress : (model.lastResult?.ok == true ? 1 : 0))
            HStack(spacing: 14) {
                SpriteButton(sprite: "btn_apply.png",
                             enabled: hid.connection == .wired && model.animation != nil && !model.uploading,
                             action: { model.upload(using: hid) }) {
                    Text(model.uploading ? "Uploading…" : "Upload").font(.openSans(13, .semibold))
                }
                ResultLabel(result: model.lastResult, busy: model.uploading,
                            busyText: "\(Int(model.progress * 100))%", needsCable: hid.connection != .wired,
                            okText: "✓ Uploaded · keyboard confirmed every block")
            }
        }
    }

    private var clockColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(text: "Clock")
            Text("Sets the keyboard's clock to this Mac's time (the Windows app's Time Sync).")
                .font(.openSans(12)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 14) {
                SpriteButton(sprite: "btn_apply.png", enabled: hid.connection == .wired,
                             action: { model.syncTime(using: hid) }) {
                    Text("Sync time").font(.openSans(13, .semibold))
                }
                ResultLabel(result: model.lastTimeSync, busy: false, busyText: "", needsCable: hid.connection != .wired,
                            okText: "✓ Sent")
            }
        }
    }
}

/// The LCD in a bezel, playing the animation at its own frame delays.
struct LCDPreview: View {
    let animation: LCDAnimation?

    var body: some View {
        TimelineView(.animation) { ctx in
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.15), lineWidth: 1))
                if let a = animation, let frame = currentFrame(a, at: ctx.date) {
                    Image(decorative: frame, scale: 1).resizable().interpolation(.high)
                        .frame(width: 480, height: 270)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Text("Drop a GIF here").font(.openSans(14)).foregroundStyle(Palette.dim)
                }
            }
            .frame(width: 512, height: 302)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func currentFrame(_ a: LCDAnimation, at date: Date) -> CGImage? {
        let frames = a.uploadFrames
        guard !frames.isEmpty else { return nil }
        let delays = a.delaysMs.prefix(frames.count)
        let total = max(1, delays.reduce(0, +))
        var t = Int(date.timeIntervalSinceReferenceDate * 1000) % total
        for (i, d) in delays.enumerated() {
            if t < d { return frames[i] }
            t -= d
        }
        return frames.last
    }
}

struct UploadBar: View {
    let progress: Double
    var body: some View {
        let width: CGFloat = 480
        ZStack(alignment: .leading) {
            Image(nsImage: Skin.crop("img_slider_back.png", CGRect(x: 0, y: 13, width: 290, height: 13)))
                .resizable().frame(width: width, height: 6).clipShape(Capsule())
            Image(nsImage: Skin.crop("img_slider_back.png", CGRect(x: 0, y: 0, width: 290, height: 13)))
                .resizable().frame(width: width, height: 6)
                .mask(alignment: .leading) { Capsule().frame(width: max(0, width * progress)) }
        }
        .frame(width: width, height: 10)
    }
}

struct ResultLabel: View {
    let result: TransactionResult?
    let busy: Bool
    let busyText: String
    let needsCable: Bool
    let okText: String
    @State private var details = false

    var body: some View {
        Group {
            if needsCable {
                Text("Needs the USB cable").foregroundStyle(.orange)
            } else if busy {
                Text(busyText).foregroundStyle(Palette.dim)
            } else if let r = result {
                Button { details.toggle() } label: {
                    Text(r.ok ? okText : "✗ Failed · details").foregroundStyle(r.ok ? Color.green : Color.red)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $details) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(r.lines.enumerated()), id: \.offset) { Text($0.element).font(.system(size: 11, design: .monospaced)) }
                    }.padding(12)
                }
            }
        }
        .font(.openSans(12))
    }
}
