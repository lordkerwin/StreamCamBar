import AppKit
import CoreMediaIO
import Foundation
import IOKit
import ServiceManagement

let targetVendorID = 0x046d  // Logitech
let targetProductID = 0x0893 // StreamCam

@MainActor
final class CameraModel: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var name = "StreamCam"
    @Published private(set) var status = "Searching…"
    @Published private(set) var values: [String: Int] = [:]
    @Published private(set) var ranges: [String: UVCRange] = [:]
    @Published var restoreSettings: Bool {
        didSet { UserDefaults.standard.set(restoreSettings, forKey: "restoreSettings") }
    }

    private var device: UVCDevice?
    private var autoExposureValue = 8
    private let io = DispatchQueue(label: "uvc.io")
    private var notifyPort: IONotificationPortRef?
    private var reconnectWork: DispatchWorkItem?
    private var cmioDevice: CMIOObjectID = 0
    private var wasRunning = false

    private var saved: [String: Int] {
        get { UserDefaults.standard.dictionary(forKey: "saved") as? [String: Int] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "saved") }
    }

    // Auto modes must be applied before the manual values that depend on them.
    private static let applyOrder: [UVCControlSpec] =
        [.autoExposureMode, .autoWhiteBalance, .autoFocus] +
        UVCControlSpec.all.filter { ![.autoExposureMode, .autoWhiteBalance, .autoFocus].contains($0) }

    init() {
        restoreSettings = UserDefaults.standard.object(forKey: "restoreSettings") as? Bool ?? true
        watchUSB()
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleReconnect(after: 3) }
        }
        scheduleReconnect(after: 0)
    }

    // MARK: - Connection

    func scheduleReconnect(after delay: TimeInterval) {
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.connect() } }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func connect() {
        io.async {
            let result = Result { try UVCDevice.find(vendorID: targetVendorID, productID: targetProductID) }
            var ranges: [String: UVCRange] = [:]
            var values: [String: Int] = [:]
            var autoAE = 8
            if case .success(let dev) = result {
                for spec in UVCControlSpec.all {
                    guard let cur = try? dev.get(spec) else { continue }
                    values[spec.key] = cur
                    if let r = try? dev.range(spec) { ranges[spec.key] = r }
                }
                // GET_RES on AE mode is a bitmap of supported modes. Prefer aperture priority, then full auto.
                if let modes = try? dev.get(.autoExposureMode, .getRes) {
                    autoAE = modes & 8 != 0 ? 8 : modes & 2 != 0 ? 2 : modes & 4 != 0 ? 4 : 8
                }
            }
            DispatchQueue.main.async {
                switch result {
                case .success(let dev):
                    self.device = dev
                    self.name = dev.name
                    self.connected = true
                    self.status = "Connected"
                    self.ranges = ranges
                    self.values = values
                    self.autoExposureValue = autoAE
                    self.watchStreaming()
                    if self.restoreSettings { self.reapply() }
                case .failure(let error):
                    self.device = nil
                    self.connected = false
                    self.values = [:]
                    self.status = "\(error)"
                }
            }
        }
    }

    private func watchUSB() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for type in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            let match = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
            match["idVendor"] = targetVendorID
            match["idProduct"] = targetProductID
            var iter: io_iterator_t = 0
            IOServiceAddMatchingNotification(port, type, match, { refcon, iter in
                drain(iter)
                let model = Unmanaged<CameraModel>.fromOpaque(refcon!).takeUnretainedValue()
                MainActor.assumeIsolated { model.scheduleReconnect(after: 1.5) }
            }, refcon, &iter)
            drain(iter) // arm the notification
        }
    }

    // Some apps reset UVC controls when they start the stream; re-apply when the camera goes live.
    private func watchStreaming() {
        let id = findCMIODevice()
        guard id != 0, id != cmioDevice else { return }
        cmioDevice = id
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
        CMIOObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.streamingChanged() }
        }
        wasRunning = isRunning(id)
    }

    private func streamingChanged() {
        let running = isRunning(cmioDevice)
        defer { wasRunning = running }
        guard running, !wasRunning, restoreSettings else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reapply() }
    }

    // MARK: - Controls

    func supports(_ spec: UVCControlSpec) -> Bool { values[spec.key] != nil }
    func range(_ spec: UVCControlSpec) -> UVCRange? { ranges[spec.key] }
    func value(_ spec: UVCControlSpec) -> Int { values[spec.key] ?? 0 }

    var autoExposure: Bool { value(.autoExposureMode) != 1 }

    func setAutoExposure(_ on: Bool) {
        set(.autoExposureMode, on ? autoExposureValue : 1)
        refresh(after: 0.3)
    }

    func setAuto(_ spec: UVCControlSpec, _ on: Bool) {
        set(spec, on ? 1 : 0)
        refresh(after: 0.3)
    }

    func set(_ spec: UVCControlSpec, _ value: Int) {
        values[spec.key] = value
        saved[spec.key] = value
        guard let device else { return }
        io.async { try? device.set(spec, value) }
    }

    func refresh(after delay: TimeInterval = 0) {
        guard let device else { return }
        io.asyncAfter(deadline: .now() + delay) {
            var fresh: [String: Int] = [:]
            for spec in UVCControlSpec.all { fresh[spec.key] = try? device.get(spec) }
            DispatchQueue.main.async { self.values.merge(fresh.compactMapValues { $0 }) { $1 } }
        }
    }

    func reapply() {
        guard let device else { return }
        let saved = self.saved
        let order = Self.applyOrder
        io.async {
            for spec in order {
                if let v = saved[spec.key] { try? device.set(spec, v) }
            }
        }
        refresh(after: 0.3)
    }

    func resetToDefaults() {
        guard let device else { return }
        saved = [:]
        let ranges = self.ranges
        let autoAE = autoExposureValue
        io.async {
            try? device.set(.autoExposureMode, autoAE)
            try? device.set(.autoWhiteBalance, 1)
            try? device.set(.autoFocus, 1)
            for spec in UVCControlSpec.all where ![.autoExposureMode, .autoWhiteBalance, .autoFocus].contains(spec) {
                if let def = ranges[spec.key]?.def { try? device.set(spec, def) }
            }
        }
        refresh(after: 0.3)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            objectWillChange.send()
            try? newValue ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
        }
    }
}

private func drain(_ iter: io_iterator_t) {
    while case let s = IOIteratorNext(iter), s != 0 { IOObjectRelease(s) }
}

private func findCMIODevice() -> CMIOObjectID {
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == 0 else { return 0 }
    var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
    var used: UInt32 = 0
    guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &ids) == 0 else { return 0 }
    // CMIO model UIDs embed the USB IDs, e.g. "UVC Camera VendorID_1133 ProductID_2195".
    let needle = "VendorID_\(targetVendorID) ProductID_\(targetProductID)"
    for id in ids {
        var modelAddr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyModelUID),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var model: Unmanaged<CFString>?
        var got: UInt32 = 0
        let ok = withUnsafeMutablePointer(to: &model) {
            CMIOObjectGetPropertyData(id, &modelAddr, 0, nil, UInt32(MemoryLayout<CFString?>.size), &got, $0)
        }
        if ok == 0, let m = model?.takeRetainedValue() as String?, m.contains(needle) { return id }
    }
    return 0
}

private func isRunning(_ id: CMIOObjectID) -> Bool {
    guard id != 0 else { return false }
    var addr = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
    var running: UInt32 = 0
    var got: UInt32 = 0
    CMIOObjectGetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running)
    return running != 0
}
