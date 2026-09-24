import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

// COM UUIDs that are C macros and don't import into Swift.
private let kUSBDeviceUserClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
    0x9d, 0xc7, 0xb7, 0x80, 0x9e, 0xc0, 0x11, 0xD4, 0xa5, 0x4f, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)
private let kCFPlugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
    0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4, 0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
private let kUSBDeviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
    0x5c, 0x81, 0x87, 0xd0, 0x9e, 0xf3, 0x11, 0xD4, 0x8b, 0x45, 0x00, 0x0a, 0x27, 0x05, 0x28, 0x61)

enum UVCUnit { case camera, processing }

enum UVCRequest: UInt8 {
    case setCur = 0x01, getCur = 0x81, getMin = 0x82, getMax = 0x83, getRes = 0x84, getInfo = 0x86, getDef = 0x87
}

struct UVCControlSpec: Hashable {
    let key: String
    let name: String
    let unit: UVCUnit
    let selector: UInt8
    let size: Int
    let signed: Bool

    // Camera Terminal
    static let autoExposureMode = UVCControlSpec(key: "aeMode", name: "Auto Exposure", unit: .camera, selector: 0x02, size: 1, signed: false)
    static let exposureTime     = UVCControlSpec(key: "exposure", name: "Exposure", unit: .camera, selector: 0x04, size: 4, signed: false)
    static let focus            = UVCControlSpec(key: "focus", name: "Focus", unit: .camera, selector: 0x06, size: 2, signed: false)
    static let autoFocus        = UVCControlSpec(key: "autoFocus", name: "Autofocus", unit: .camera, selector: 0x08, size: 1, signed: false)
    static let zoom             = UVCControlSpec(key: "zoom", name: "Zoom", unit: .camera, selector: 0x0B, size: 2, signed: false)
    // Processing Unit
    static let backlight        = UVCControlSpec(key: "backlight", name: "Backlight Comp.", unit: .processing, selector: 0x01, size: 2, signed: false)
    static let brightness       = UVCControlSpec(key: "brightness", name: "Brightness", unit: .processing, selector: 0x02, size: 2, signed: true)
    static let contrast         = UVCControlSpec(key: "contrast", name: "Contrast", unit: .processing, selector: 0x03, size: 2, signed: false)
    static let gain             = UVCControlSpec(key: "gain", name: "Gain", unit: .processing, selector: 0x04, size: 2, signed: false)
    static let powerLine        = UVCControlSpec(key: "powerLine", name: "Anti-flicker", unit: .processing, selector: 0x05, size: 1, signed: false)
    static let saturation       = UVCControlSpec(key: "saturation", name: "Saturation", unit: .processing, selector: 0x07, size: 2, signed: false)
    static let sharpness        = UVCControlSpec(key: "sharpness", name: "Sharpness", unit: .processing, selector: 0x08, size: 2, signed: false)
    static let whiteBalance     = UVCControlSpec(key: "wb", name: "White Balance", unit: .processing, selector: 0x0A, size: 2, signed: false)
    static let autoWhiteBalance = UVCControlSpec(key: "autoWB", name: "Auto White Balance", unit: .processing, selector: 0x0B, size: 1, signed: false)

    static let all: [UVCControlSpec] = [
        .autoExposureMode, .exposureTime, .focus, .autoFocus, .zoom,
        .backlight, .brightness, .contrast, .gain, .powerLine, .saturation, .sharpness, .whiteBalance, .autoWhiteBalance,
    ]
}

struct UVCRange {
    let min: Int, max: Int, res: Int, def: Int
}

enum UVCError: Error, CustomStringConvertible {
    case notFound, plugin(Int32), queryInterface(Int32), noDescriptor, noVideoControl, request(Int32)
    var description: String {
        switch self {
        case .notFound: return "Camera not found"
        case .plugin(let r): return "IOCreatePlugInInterfaceForService failed (\(String(format: "0x%08x", r)))"
        case .queryInterface(let r): return "QueryInterface failed (\(r))"
        case .noDescriptor: return "No configuration descriptor"
        case .noVideoControl: return "No UVC VideoControl interface"
        case .request(let r): return "USB request failed (\(String(format: "0x%08x", r)))"
        }
    }
}

typealias USBDeviceRef = UnsafeMutablePointer<UnsafeMutablePointer<IOUSBDeviceInterface>?>

final class UVCDevice: @unchecked Sendable {
    let name: String
    private let device: USBDeviceRef
    private var vcInterface: UInt8 = 0
    private var cameraTerminalID: UInt8 = 1
    private var processingUnitID: UInt8 = 2

    static func find(vendorID: Int, productID: Int) throws -> UVCDevice {
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            guard let match = IOServiceMatching(className) as NSMutableDictionary? else { continue }
            match["idVendor"] = vendorID
            match["idProduct"] = productID
            let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
            if service != 0 {
                defer { IOObjectRelease(service) }
                return try UVCDevice(service: service)
            }
        }
        throw UVCError.notFound
    }

    init(service: io_service_t) throws {
        name = (IORegistryEntryCreateCFProperty(service, "USB Product Name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String) ?? "Camera"

        var plugin: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        let kr = IOCreatePlugInInterfaceForService(service, kUSBDeviceUserClientTypeID, kCFPlugInInterfaceID, &plugin, &score)
        guard kr == KERN_SUCCESS, let plugin else { throw UVCError.plugin(kr) }
        defer { _ = plugin.pointee?.pointee.Release(plugin) }

        var devPtr: USBDeviceRef?
        let hr = withUnsafeMutablePointer(to: &devPtr) {
            $0.withMemoryRebound(to: LPVOID?.self, capacity: 1) {
                plugin.pointee!.pointee.QueryInterface(plugin, CFUUIDGetUUIDBytes(kUSBDeviceInterfaceID), $0)
            }
        }
        guard hr == S_OK, let devPtr else { throw UVCError.queryInterface(hr) }
        device = devPtr
        try parseDescriptors()
    }

    deinit { _ = device.pointee?.pointee.Release(device) }

    private func parseDescriptors() throws {
        var desc: IOUSBConfigurationDescriptorPtr?
        guard device.pointee!.pointee.GetConfigurationDescriptorPtr(device, 0, &desc) == KERN_SUCCESS, let desc else {
            throw UVCError.noDescriptor
        }
        let total = Int(UInt16(littleEndian: desc.pointee.wTotalLength))
        let bytes = UnsafeRawPointer(desc).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        var inVideoControl = false
        var found = false
        while offset + 2 <= total {
            let len = Int(bytes[offset]), type = bytes[offset + 1]
            if len == 0 { break }
            if type == 0x04, offset + 7 <= total { // INTERFACE
                inVideoControl = bytes[offset + 5] == 0x0E && bytes[offset + 6] == 0x01
                if inVideoControl { vcInterface = bytes[offset + 2]; found = true }
            } else if type == 0x24, inVideoControl, len >= 4 { // CS_INTERFACE
                let subtype = bytes[offset + 2]
                if subtype == 0x02, len >= 6 { // INPUT_TERMINAL
                    let termType = UInt16(bytes[offset + 4]) | UInt16(bytes[offset + 5]) << 8
                    if termType == 0x0201 { cameraTerminalID = bytes[offset + 3] }
                } else if subtype == 0x05 { // PROCESSING_UNIT
                    processingUnitID = bytes[offset + 3]
                }
            }
            offset += len
        }
        if !found { throw UVCError.noVideoControl }
    }

    private func request(_ req: UVCRequest, _ spec: UVCControlSpec, data: inout [UInt8]) throws {
        let unitID = spec.unit == .camera ? cameraTerminalID : processingUnitID
        let rc = data.withUnsafeMutableBytes { buf -> IOReturn in
            var r = IOUSBDevRequest(
                bmRequestType: req == .setCur ? 0x21 : 0xA1,
                bRequest: req.rawValue,
                wValue: UInt16(spec.selector) << 8,
                wIndex: UInt16(unitID) << 8 | UInt16(vcInterface),
                wLength: UInt16(buf.count),
                pData: buf.baseAddress,
                wLenDone: 0)
            return device.pointee!.pointee.DeviceRequest(device, &r)
        }
        if rc != kIOReturnSuccess { throw UVCError.request(rc) }
    }

    func get(_ spec: UVCControlSpec, _ req: UVCRequest = .getCur) throws -> Int {
        var data = [UInt8](repeating: 0, count: req == .getInfo ? 1 : spec.size)
        try request(req, spec, data: &data)
        var raw: UInt64 = 0
        for (i, b) in data.enumerated() { raw |= UInt64(b) << (8 * UInt64(i)) }
        if spec.signed && req != .getRes && req != .getInfo {
            let bits = UInt64(spec.size * 8)
            if raw & (1 << (bits - 1)) != 0 { return Int(Int64(bitPattern: raw | ~((1 << bits) - 1))) }
        }
        return Int(raw)
    }

    func set(_ spec: UVCControlSpec, _ value: Int) throws {
        let raw = UInt64(bitPattern: Int64(value))
        var data = (0..<spec.size).map { UInt8(truncatingIfNeeded: raw >> (8 * UInt64($0))) }
        try request(.setCur, spec, data: &data)
    }

    func range(_ spec: UVCControlSpec) throws -> UVCRange {
        UVCRange(min: try get(spec, .getMin), max: try get(spec, .getMax),
                 res: (try? get(spec, .getRes)) ?? 1, def: (try? get(spec, .getDef)) ?? 0)
    }
}
