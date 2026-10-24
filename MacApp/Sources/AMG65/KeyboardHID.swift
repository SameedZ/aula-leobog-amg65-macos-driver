import Foundation
import IOKit
import IOKit.hid

enum Connection: Equatable {
    case none, dongle, wired
}

struct TransactionResult {
    var ok: Bool
    var lines: [String]
}

/// Finds the AMG65 and talks to its vendor HID channel.
/// Wired: 0C45:800A, interface 2, usage page 0xFF68 (confirmed protocol).
/// Dongle: 05AC:024F, interface 3, usage page 0xFF60, 32-byte packets with a checksum,
/// acknowledged by an echo of the first 3 bytes (confirmed for lighting and custom colours).
final class KeyboardHID: ObservableObject {
    @Published private(set) var connection: Connection = .none

    private var manager: IOHIDManager!
    private var wired: IOHIDDevice?
    private var dongle: IOHIDDevice?
    private let lock = NSLock()
    private var replies: [[UInt8]] = []
    private let replySignal = DispatchSemaphore(value: 0)
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let dongleBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let ioQueue = DispatchQueue(label: "amg65.io")
    private var thread: Thread?

    init() {
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [unowned self] in
            self.setUpManager()
            ready.signal()
            // Keep the run loop alive even if no device is present.
            let keepAlive = Timer(timeInterval: 3600, repeats: true) { _ in }
            RunLoop.current.add(keepAlive, forMode: .default)
            RunLoop.current.run()
        }
        t.name = "AMG65 HID"
        t.start()
        thread = t
        ready.wait()
    }

    // MARK: Device discovery (runs on the HID thread)

    private func setUpManager() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Any]] = [
            [kIOHIDVendorIDKey: 0x0C45, kIOHIDProductIDKey: 0x800A, kIOHIDPrimaryUsagePageKey: 0xFF68],
            [kIOHIDVendorIDKey: 0x05AC, kIOHIDProductIDKey: 0x024F, kIOHIDPrimaryUsagePageKey: 0xFF60],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue().added(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue().removed(device)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func intProperty(_ device: IOHIDDevice, _ key: String) -> Int {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? -1
    }

    private func added(_ device: IOHIDDevice) {
        let vid = intProperty(device, kIOHIDVendorIDKey)
        lock.lock()
        if vid == 0x0C45 {
            wired = device
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { ctx, _, _, _, _, report, length in
                Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue()
                    .gotReport(Array(UnsafeBufferPointer(start: report, count: length)))
            }, ctx)
        } else {
            dongle = device
            let ctx = Unmanaged.passUnretained(self).toOpaque()
            IOHIDDeviceRegisterInputReportCallback(device, dongleBuffer, 64, { ctx, _, _, _, _, report, length in
                Unmanaged<KeyboardHID>.fromOpaque(ctx!).takeUnretainedValue()
                    .gotReport(Array(UnsafeBufferPointer(start: report, count: length)))
            }, ctx)
        }
        lock.unlock()
        publish()
    }

    private func removed(_ device: IOHIDDevice) {
        lock.lock()
        if let w = wired, CFEqual(w, device) { wired = nil }
        if let d = dongle, CFEqual(d, device) { dongle = nil }
        lock.unlock()
        publish()
    }

    private func gotReport(_ bytes: [UInt8]) {
        lock.lock()
        replies.append(bytes)
        lock.unlock()
        replySignal.signal()
    }

    private func publish() {
        lock.lock()
        let state: Connection = wired != nil ? .wired : (dongle != nil ? .dongle : .none)
        lock.unlock()
        DispatchQueue.main.async { self.connection = state }
    }

    // MARK: Sending (runs on ioQueue, never on the HID or main thread)

    private func exchange(_ packet: [UInt8]) -> [UInt8]? {
        lock.lock()
        let device = wired
        replies.removeAll()
        lock.unlock()
        while replySignal.wait(timeout: .now()) == .success {}   // drop stale signals
        guard let device else { return nil }

        var buf = packet
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &buf, buf.count)
        guard result == kIOReturnSuccess else { return nil }
        guard replySignal.wait(timeout: .now() + .milliseconds(200)) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? nil : replies.removeFirst()
    }

    /// Dongle: send one 32-byte packet and wait for a reply echoing its first 3 bytes (0x468790).
    private func exchangeDongle(_ packet: [UInt8]) -> Bool {
        lock.lock()
        let device = dongle
        replies.removeAll()
        lock.unlock()
        while replySignal.wait(timeout: .now()) == .success {}
        guard let device else { return false }
        var buf = packet
        guard IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &buf, buf.count) == kIOReturnSuccess else { return false }
        for _ in 0..<20 {
            guard replySignal.wait(timeout: .now() + .milliseconds(50)) == .success else { continue }
            lock.lock()
            let r = replies.isEmpty ? nil : replies.removeFirst()
            lock.unlock()
            if let r, r.count >= 3, Array(r.prefix(3)) == Array(packet.prefix(3)) { return true }
        }
        return false
    }

    /// Sends dongle packets in order; stops at the first one the keyboard doesn't echo.
    func sendDongle(_ packets: [[UInt8]], label: String, completion: @escaping (TransactionResult) -> Void) {
        ioQueue.async {
            var lines: [String] = []
            var ok = true
            for (i, p) in packets.enumerated() {
                let echoed = self.exchangeDongle(p)
                lines.append("\(echoed ? "✓" : "✗") \(label) \(i + 1)/\(packets.count): " +
                             p.prefix(4).map { String(format: "%02X", $0) }.joined(separator: " "))
                if !echoed {
                    ok = false
                    lines.append("No reply through the dongle — the keyboard may be asleep. Press a key and try again.")
                    break
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            DispatchQueue.main.async { completion(TransactionResult(ok: ok, lines: lines)) }
        }
    }

    /// Waits for the next reply with byte [3] = 0x01 (up to `tries` × `timeoutMs`), like 0x468650.
    private func waitForOK(tries: Int = 100, timeoutMs: Int = 600) -> [UInt8]? {
        for _ in 0..<tries {
            guard replySignal.wait(timeout: .now() + .milliseconds(timeoutMs)) == .success else { continue }
            lock.lock()
            let r = replies.isEmpty ? nil : replies.removeFirst()
            lock.unlock()
            if let r, r[safe: 3] == 0x01 { return r }
        }
        return nil
    }

    private func drainReplies() {
        lock.lock(); replies.removeAll(); lock.unlock()
        while replySignal.wait(timeout: .now()) == .success {}
    }

    /// LCD upload (cmd 0x72): header on the command channel, 4 KB blocks on interface 3
    /// (libusb), each acknowledged on the command channel. Mirrors 0x42a1d0.
    func uploadLCD(_ bytes: [UInt8], blocks: Int, slot: UInt8,
                   progress: @escaping (Double) -> Void,
                   completion: @escaping (TransactionResult) -> Void) {
        uploadBulk(bytes, blocks: blocks,
                   header: AMG65Protocol.packet([0x04, 0x72, slot], [8: UInt8(blocks & 0xFF), 9: UInt8(blocks >> 8)]),
                   headerLabel: "upload header (slot \(slot), \(blocks) blocks)", applyAfter: false,
                   progress: progress, completion: completion)
    }

    /// Shared bulk upload (LCD 0x72, strip 0x33 / 0x31): header on the command channel,
    /// 4 KB blocks on interface 3, each acknowledged; then end (and apply for the strip).
    func uploadBulk(_ bytes: [UInt8], blocks: Int, header: [UInt8], headerLabel: String, applyAfter: Bool,
                    progress: @escaping (Double) -> Void,
                    completion: @escaping (TransactionResult) -> Void) {
        ioQueue.async {
            var lines: [String] = []
            func done(_ ok: Bool) { DispatchQueue.main.async { completion(TransactionResult(ok: ok, lines: lines)) } }
            func step(_ label: String, _ packet: [UInt8]) -> Bool {
                let r = self.exchange(packet)
                let ok = r?[safe: 3] == 0x01
                lines.append("\(ok ? "✓" : "✗") \(label): " + (r.map { $0.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ") } ?? "no reply"))
                return ok
            }
            guard step("begin", AMG65Protocol.begin), step(headerLabel, header) else { return done(false) }
            let bulk: LCDBulkChannel
            do { bulk = try LCDBulkChannel() } catch {
                lines.append("✗ \(error)")
                return done(false)
            }
            for i in 0..<blocks {
                self.drainReplies()
                do { try bulk.write(Array(bytes[i * LCDFormat.block..<(i + 1) * LCDFormat.block])) } catch {
                    lines.append("✗ block \(i + 1): \(error)")
                    return done(false)
                }
                Thread.sleep(forTimeInterval: 0.005)
                guard self.waitForOK() != nil else {
                    lines.append("✗ block \(i + 1)/\(blocks): no OK reply")
                    return done(false)
                }
                if i == 0 { Thread.sleep(forTimeInterval: 0.5) }
                let p = Double(i + 1) / Double(blocks)
                DispatchQueue.main.async { progress(p) }
            }
            lines.append("✓ \(blocks) blocks acknowledged")
            guard step("end", AMG65Protocol.end) else { return done(false) }
            done(applyAfter ? step("apply", AMG65Protocol.apply) : true)
        }
    }

    /// Sends a command sequence like the Windows app: each packet must come back
    /// with byte [3] = 0x01; 0xFF (busy) is retried once; the end reply carries the
    /// data checksum.
    func send(_ steps: [AMG65Protocol.Step], completion: @escaping (TransactionResult) -> Void) {
        ioQueue.async {
            let expected = AMG65Protocol.checksum(steps)
            let hasData = steps.contains { $0.isData }
            var lines: [String] = []
            var ok = true
            for step in steps {
                var reply = self.exchange(step.bytes)
                if reply?[safe: 3] == 0xFF { reply = self.exchange(step.bytes) }
                guard let r = reply else {
                    lines.append("✗ \(step.label): no reply")
                    ok = false
                    break
                }
                var line = "\(r[safe: 3] == 0x01 ? "✓" : "✗") \(step.label): " +
                    r.prefix(6).map { String(format: "%02X", $0) }.joined(separator: " ")
                if r[safe: 3] != 0x01 { ok = false }
                if hasData && step.bytes == AMG65Protocol.end, r.count > 5 {
                    let got = UInt16(r[4]) | UInt16(r[5]) << 8
                    line += got == expected ? "  checksum ✓" : "  checksum ✗ (expected \(String(format: "%04X", expected)))"
                    if got != expected { ok = false }
                }
                lines.append(line)
                if !ok { break }
            }
            DispatchQueue.main.async { completion(TransactionResult(ok: ok, lines: lines)) }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
