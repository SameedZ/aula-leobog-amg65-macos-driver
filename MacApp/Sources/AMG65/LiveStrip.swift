import Accelerate
import AVFoundation
import Darwin
import SwiftUI

// MARK: - Live frame (cmd 0x35) — confirmed on the keyboard (~20 fps max over the cable)

extension AMG65Protocol {
    /// One live strip frame: 04 18 · 04 35 [8]=15 · 15 × 64-byte data · 04 02 (0x434ed0).
    static func liveFrame(_ pixels: [RGB]) -> [Step] {
        var buf = [UInt8](repeating: 0, count: 960)
        for (i, c) in pixels.prefix(StripFormat.leds).enumerated() {
            let o = 3 * StripFormat.position[i]
            buf[o] = c.r; buf[o + 1] = c.g; buf[o + 2] = c.b
        }
        buf[945] = 0xAA; buf[946] = 0x55
        var steps = [Step(label: "begin", bytes: begin), Step(label: "live header", bytes: packet([0x04, 0x35], [8: 15]))]
        for i in 0..<15 { steps.append(Step(label: "live data \(i + 1)", bytes: Array(buf[i * 64..<(i + 1) * 64]))) }
        steps.append(Step(label: "end", bytes: end))
        return steps
    }
}

// MARK: - Sources

/// Mac CPU usage from host tick counters.
final class CPUMeter {
    private var last: [UInt32]?

    func usage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let t = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]  // user, system, idle, nice
        defer { last = t }
        guard let l = last else { return 0 }
        let d = zip(t, l).map { Double($0 &- $1) }
        let total = d.reduce(0, +)
        return total > 0 ? (d[0] + d[1] + d[3]) / total : 0
    }
}

/// Microphone spectrum: 63 bands, 0…1.
final class AudioSpectrum {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var bands = [Float](repeating: 0, count: StripFormat.width)
    private(set) var running = false
    private let n = 1024
    private lazy var fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(n))), radix: .radix2, ofType: DSPSplitComplex.self)!

    func start() {
        guard !running else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(n), format: format) { [weak self] buf, _ in
            self?.process(buf)
        }
        do { try engine.start(); running = true } catch { input.removeTap(onBus: 0) }
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    func current() -> [Float] { lock.lock(); defer { lock.unlock() }; return bands }

    private func process(_ buf: AVAudioPCMBuffer) {
        guard let ch = buf.floatChannelData?[0], Int(buf.frameLength) >= n else { return }
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        var samples = [Float](repeating: 0, count: n)
        vDSP_vmul(ch, 1, window, 1, &samples, 1, vDSP_Length(n))
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                samples.withUnsafeBufferPointer { sp in
                    sp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        // 63 log-spaced bands from ~60 Hz to ~12 kHz (bins of sampleRate / n).
        let rate = Float(buf.format.sampleRate)
        var out = [Float](repeating: 0, count: StripFormat.width)
        for b in 0..<StripFormat.width {
            let f0 = 60 * powf(200, Float(b) / Float(StripFormat.width))
            let f1 = 60 * powf(200, Float(b + 1) / Float(StripFormat.width))
            let i0 = max(1, Int(f0 / rate * Float(n))), i1 = max(i0 + 1, Int(f1 / rate * Float(n)))
            let slice = mags[min(i0, n / 2 - 1)..<min(i1, n / 2)]
            let level = slice.isEmpty ? 0 : (slice.max() ?? 0)
            out[b] = max(0, min(1, (20 * log10f(level + 1e-6) + 10) / 50))   // dB → 0…1
        }
        lock.lock()
        for i in 0..<out.count { bands[i] = max(out[i], bands[i] * 0.75) }   // fall-off
        lock.unlock()
    }
}

// MARK: - Controller

final class LiveStripController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case off = "Off", clock = "Clock", cpu = "CPU", music = "Music"
        var id: String { rawValue }
    }

    @Published var mode: Mode = .off { didSet { modeChanged() } }
    @Published var color = RGB(r: 0, g: 200, b: 255)
    @Published private(set) var preview: [RGB]? = nil
    @Published private(set) var status = ""

    private weak var hid: KeyboardHID?
    private var timer: Timer?
    private var inFlight = false
    private let cpu = CPUMeter()
    private let audio = AudioSpectrum()
    private var cpuSmoothed = 0.0

    func attach(_ hid: KeyboardHID) { self.hid = hid }

    private func modeChanged() {
        timer?.invalidate(); timer = nil
        if mode != .music { audio.stop() }
        guard mode != .off else { preview = nil; status = ""; return }
        if mode == .music {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted { self.audio.start() } else { self.status = "Microphone access denied (System Settings › Privacy)" }
                }
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    private func tick() {
        let px = render()
        preview = px
        guard let hid, hid.connection == .wired else { status = "Live modes need the USB cable"; return }
        guard !inFlight else { return }   // drop frames rather than queue them
        inFlight = true
        hid.send(AMG65Protocol.liveFrame(px)) { [weak self] r in
            self?.inFlight = false
            self?.status = r.ok ? "Streaming to the strip" : "Keyboard didn't accept a frame"
        }
    }

    private func render() -> [RGB] {
        var px = [RGB](repeating: .off, count: StripFormat.leds)
        func text(_ s: String, at x0: Int, _ c: RGB) {
            for (i, col) in TinyFont.columns(s).enumerated() where x0 + i >= 0 && x0 + i < StripFormat.width {
                for y in 0..<5 where col & (1 << y) != 0 { px[y * StripFormat.width + x0 + i] = c }
            }
        }
        switch mode {
        case .off:
            break
        case .clock:
            let s = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
            let w = TinyFont.columns(s).count
            text(s, at: (StripFormat.width - w) / 2, color)
        case .cpu:
            cpuSmoothed = cpuSmoothed * 0.6 + cpu.usage() * 0.4
            let pct = Int((cpuSmoothed * 100).rounded())
            text("CPU", at: 0, color)
            text("\(pct)%", at: 49, color)
            let barStart = 13, barWidth = 34
            let filled = Int(Double(barWidth) * cpuSmoothed)
            for x in 0..<barWidth {
                let lit = x < filled
                let heat = Double(x) / Double(barWidth)
                let c = RGB(r: UInt8(255 * heat), g: UInt8(255 * (1 - heat)), b: 40)
                for y in 1..<4 { px[y * StripFormat.width + barStart + x] = lit ? c : RGB(r: 12, g: 12, b: 12) }
            }
        case .music:
            for (x, level) in audio.current().enumerated() {
                let h = Int((level * 5).rounded())
                for k in 0..<h {
                    let y = 4 - k
                    let c = k >= 4 ? RGB(r: 255, g: 40, b: 40) : k >= 3 ? RGB(r: 255, g: 200, b: 0) : RGB(r: 0, g: 220, b: 120)
                    px[y * StripFormat.width + x] = c
                }
            }
        }
        return px
    }
}

// MARK: - View

struct LiveStripPanel: View {
    @EnvironmentObject var live: LiveStripController
    @EnvironmentObject var hid: KeyboardHID

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Live from this Mac")
            HStack(spacing: 14) {
                ForEach(LiveStripController.Mode.allCases) { m in
                    SkinRadio(title: m.rawValue, checked: live.mode == m) { live.mode = m }.frame(width: 80)
                }
            }
            Text(live.mode == .music ? "Uses the microphone. Runs while this app is open."
                 : "Draws on the strip about 10 times a second while this app is open (cable only).")
                .font(.openSans(11)).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            if !live.status.isEmpty {
                Text(live.status).font(.openSans(12))
                    .foregroundStyle(live.status.hasPrefix("Streaming") ? Color.green : Color.orange)
            }
        }
        .onAppear { live.attach(hid) }
    }
}
