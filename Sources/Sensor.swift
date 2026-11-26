import Foundation
import IOKit.hid

final class LidSensor {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private let queue = DispatchQueue(label: "hingefrost.sensor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lastAttempt: TimeInterval = 0
    private var filtered: Double?
    private var lastTime: TimeInterval = 0
    var onSample: ((Double?, Double?, String) -> Void)?

    private func connect() -> Bool {
        disconnect()
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match = [kIOHIDVendorIDKey: 0x05ac, kIOHIDDeviceUsagePageKey: 0x20, kIOHIDDeviceUsageKey: 0x8a] as CFDictionary
        IOHIDManagerSetDeviceMatching(m, match)
        guard IOHIDManagerOpen(m, 0) == kIOReturnSuccess else { return false }
        manager = m
        guard let devices = IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice> else { return false }
        for d in devices {
            if IOHIDDeviceOpen(d, 0) == kIOReturnSuccess {
                if Self.read(d) != nil { device = d; return true }
                IOHIDDeviceClose(d, 0)
            }
        }
        return false
    }

    private static func read(_ device: IOHIDDevice) -> Double? {
        var bytes = [UInt8](repeating: 0, count: 16)
        var count = bytes.count
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &count)
        guard result == kIOReturnSuccess, count >= 3, bytes[0] == 1 else { return nil }
        let angle = Int(bytes[1]) | (Int(bytes[2]) << 8)
        return (0...180).contains(angle) ? Double(angle) : nil
    }

    func probe() -> Double? {
        guard connect(), let d = device else { disconnect(); return nil }
        let value = Self.read(d)
        disconnect()
        return value
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.poll() }
        timer = t
        t.resume()
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if device == nil {
            if now - lastAttempt < 3 { return }
            lastAttempt = now
            if !connect() { publish(nil, raw: nil, "无法读取铰链传感器 · 每 3 秒重试"); return }
        }
        guard let d = device, let raw = Self.read(d) else {
            disconnect(); filtered = nil
            publish(nil, raw: nil, "铰链信号中断 · 已撤掉桌面效果")
            return
        }
        let dt = now - lastTime
        if let old = filtered, dt < 0.5 {
            filtered = old + (raw - old) * (1 - exp(-dt / 0.06))
        } else { filtered = raw }
        lastTime = now
        publish(filtered, raw: raw, "真实 HID 铰链 · 原始 \(Int(raw))°")
    }

    private func publish(_ angle: Double?, raw: Double?, _ message: String) {
        // Deliver samples during native menu tracking as well as normal events.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            self?.onSample?(angle, raw, message)
        }
    }

    private func disconnect() {
        if let d = device { IOHIDDeviceClose(d, 0) }
        if let m = manager { IOHIDManagerClose(m, 0) }
        device = nil; manager = nil
    }

    func stop() {
        timer?.cancel(); timer = nil
        queue.sync { disconnect() }
    }
}
