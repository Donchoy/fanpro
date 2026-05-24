#!/usr/bin/env swift
// ╔═══════════════════════════════════════════════════════════════════════╗
// ║  F A N P R O  ·  Apple Silicon Thermal Command Center               ║
// ║  Real-time temperature monitoring & fan control for M-series Macs    ║
// ║                                                                       ║
// ║  Usage:                                                               ║
// ║    chmod +x mac-thermal.swift                                         ║
// ║    ./mac-thermal.swift             # Read-only (temps + fan speeds)   ║
// ║    sudo ./mac-thermal.swift        # Full control (+ set fan speed)  ║
// ║                                                                       ║
// ║  Or compile:                                                          ║
// ║    swiftc -O mac-thermal.swift -o fanpro                              ║
// ║    ./fanpro       |  sudo ./fanpro                                    ║
// ╚═══════════════════════════════════════════════════════════════════════╝

import Foundation
import IOKit
import Darwin

// ============================================================================
// MARK: - ANSI Terminal Escape Helpers
// ============================================================================

private let ESC = "\u{001B}["

/// Precompiled ANSI escape sequence regular expression to avoid recompilation on each visibleLength() call.
private let ansiEscapeRegex = try! NSRegularExpression(
    pattern: "\u{001B}\\[[0-9;]*[a-zA-Z]", options: []
)

/// Calculates the visible width of a string in a terminal (ignoring ANSI escape codes).
func visibleLength(_ s: String) -> Int {
    let ns = s as NSString
    let clean = ansiEscapeRegex.stringByReplacingMatches(
        in: s, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: ""
    )
    var width = 0
    for scalar in clean.unicodeScalars {
        let v = scalar.value
        // Zero-width characters: variation selectors, ZWJ, skin tone modifiers, etc.
        if v == 0xFE0F || v == 0xFE0E ||
           (v >= 0x200B && v <= 0x200D) ||
           (v >= 0xE0100 && v <= 0xE01EF) ||
           (v >= 0x1F3FB && v <= 0x1F3FF) {
            continue
        }
        // Double-width characters: Emoji, CJK Ideographs, and miscellaneous symbols.
        if v >= 0x1F000 ||                          // Emoticons, Supplemental Symbols
           (v >= 0x2600 && v <= 0x27BF) ||           // Misc Symbols + Dingbats (⚡⚠☕ etc.)
           (v >= 0x2300 && v <= 0x23FF) ||           // Misc Technical (⏱⌚ etc.)
           (v >= 0x2B50 && v <= 0x2B55) ||           // Stars, circles
           (v >= 0x4E00 && v <= 0x9FFF) ||           // CJK Unified Ideographs
           (v >= 0x3400 && v <= 0x4DBF) ||           // CJK Extension A
           (v >= 0xF900 && v <= 0xFAFF) ||           // CJK Compatibility
           (v >= 0x20000 && v <= 0x2FA1F) {          // CJK Extensions B-F
            width += 2
        } else {
            width += 1
        }
    }
    return width
}

enum ANSI {
    static let reset       = "\(ESC)0m"
    static let bold        = "\(ESC)1m"
    static let dim         = "\(ESC)2m"

    static let red         = "\(ESC)38;5;203m"
    static let orange      = "\(ESC)38;5;208m"
    static let yellow      = "\(ESC)38;5;220m"
    static let green       = "\(ESC)38;5;114m"
    static let cyan        = "\(ESC)38;5;80m"
    static let blue        = "\(ESC)38;5;75m"
    static let magenta     = "\(ESC)38;5;176m"
    static let white       = "\(ESC)38;5;255m"
    static let gray        = "\(ESC)38;5;245m"
    static let darkGray    = "\(ESC)38;5;238m"

    static let clearScreen = "\(ESC)2J\(ESC)H"
    static let hideCursor  = "\(ESC)?25l"
    static let showCursor  = "\(ESC)?25h"
    static let home        = "\(ESC)H"
    static let clearEnd    = "\(ESC)J"
    static let clearLineEnd = "\(ESC)K"

    /// Returns a color string based on temperature (°C).
    static func colorForTemp(_ t: Int) -> String {
        if t < 40 { return green }
        if t < 55 { return cyan }
        if t < 70 { return yellow }
        if t < 85 { return orange }
        return red
    }

    /// Returns a color string based on fan utilization (0.0 – 1.0).
    static func colorForFan(_ pct: Double) -> String {
        if pct < 0.30 { return green }
        if pct < 0.60 { return cyan }
        if pct < 0.80 { return yellow }
        return red
    }
}

// ============================================================================
// MARK: - IOHIDEventSystem Private API (Temperature Sensors)
// ============================================================================

// These symbols live in IOKit.framework but are not in the public headers.
// @_silgen_name lets us call them by their linker symbol name directly.

@_silgen_name("IOHIDEventSystemClientCreate")
func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> AnyObject?

@_silgen_name("IOHIDEventSystemClientSetMatching")
func IOHIDEventSystemClientSetMatching(_ client: AnyObject, _ match: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> AnyObject?

@_silgen_name("IOHIDServiceClientCopyEvent")
func IOHIDServiceClientCopyEvent(_ service: AnyObject,
                                  _ type: Int32,
                                  _ flags: UInt32,
                                  _ options: UInt32) -> Unmanaged<AnyObject>?

@_silgen_name("IOHIDEventGetFloatValue")
func IOHIDEventGetFloatValue(_ event: AnyObject, _ field: UInt32) -> Double

/// HID Event type 15 = Temperature
private let kIOHIDEventTypeTemperature: Int32 = 15
/// Field selector for the base float value
private let kIOHIDEventFieldBase: UInt32 = 0xf0000

// ============================================================================
// MARK: - SMC Data Structures (must be exactly 80 bytes)
// ============================================================================

/// 32-byte data payload exchanged with AppleSMC.
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// The kernel-level struct used by IOConnectCallStructMethod selector 2.
struct SMCParamStruct {
    /// Operation selectors written into `data8`.
    enum Selector: UInt8 {
        case kSMCHandleYPCEvent  = 2
        case kSMCReadKey         = 5
        case kSMCWriteKey        = 6
        case kSMCGetKeyFromIndex = 8
        case kSMCGetKeyInfo      = 9
    }

    struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                           0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

// ============================================================================
// MARK: - Low-Level Helpers
// ============================================================================

/// Convert a 4-character ASCII string to a UInt32 FourCharCode.
func fourCC(_ s: String) -> UInt32 {
    precondition(s.utf8.count == 4, "FourCharCode must be exactly 4 ASCII bytes")
    return s.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}

/// A zeroed-out 32-byte tuple.
func zeroBytes() -> SMCBytes {
    (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
     0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}

/// Decode a 4-byte **little-endian** IEEE 754 float from SMCBytes → Int RPM.
/// On Apple Silicon, fan keys (F{id}Ac, F{id}Mn, F{id}Mx, F{id}Tg) are
/// type `flt` (4 bytes, LE) instead of the Intel-era `fpe2` (2 bytes, BE).
func decodeFloatLE(_ b: SMCBytes) -> Float {
    let bits = UInt32(b.3) << 24 | UInt32(b.2) << 16 | UInt32(b.1) << 8 | UInt32(b.0)
    return Float(bitPattern: bits)
}

/// Encode a Float as 4 little-endian bytes into an SMCBytes tuple.
func encodeFloatLE(_ value: Float) -> SMCBytes {
    let bits = value.bitPattern
    var b = zeroBytes()
    b.0 = UInt8( bits        & 0xFF)
    b.1 = UInt8((bits >>  8) & 0xFF)
    b.2 = UInt8((bits >> 16) & 0xFF)
    b.3 = UInt8((bits >> 24) & 0xFF)
    return b
}

// ============================================================================
// MARK: - SMC Client
// ============================================================================

/// Communicates with the AppleSMC kernel extension through IOKit.
final class SMCClient {
    private var conn: io_connect_t = 0
    private(set) var isOpen = false

    /// Opens a connection to AppleSMC. Returns `false` on failure.
    func open() -> Bool {
        if isOpen { return true }
        let service = IOServiceGetMatchingService(
            0, // kIOMainPortDefault
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let kr = IOServiceOpen(service, mach_task_self_, 0, &conn)
        isOpen = (kr == kIOReturnSuccess)
        return isOpen
    }

    func close() {
        guard isOpen else { return }
        IOServiceClose(conn)
        isOpen = false
    }

    deinit {
        close()
    }

    // MARK: Raw driver call

    /// Send a SMCParamStruct to the driver via selector 2 and receive the reply.
    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        let inSize  = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride

        let kr = IOConnectCallStructMethod(
            conn,
            UInt32(SMCParamStruct.Selector.kSMCHandleYPCEvent.rawValue),
            &input, inSize,
            &output, &outSize
        )
        guard kr == kIOReturnSuccess, output.result == 0 else { return nil }
        return output
    }

    // MARK: High-level read / write

    /// Read a key's raw bytes from the SMC.
    func read(_ key: String, size: UInt32) -> SMCBytes? {
        var p = SMCParamStruct()
        p.key = fourCC(key)
        p.keyInfo.dataSize = size
        p.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        return call(&p)?.bytes
    }

    /// Write raw bytes to a key.
    func write(_ key: String, size: UInt32, bytes: SMCBytes) -> Bool {
        var p = SMCParamStruct()
        p.key = fourCC(key)
        p.keyInfo.dataSize = size
        p.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        p.bytes = bytes
        return call(&p) != nil
    }

    // MARK: Fan convenience methods (Apple Silicon: flt / LE float format)

    /// Number of fans reported by the SMC.
    func fanCount() -> Int {
        guard let d = read("FNum", size: 1) else { return 0 }
        return Int(d.0)
    }

    /// Current fan speed in RPM (key F{id}Ac, type flt, 4-byte LE float).
    func fanActualRPM(_ id: Int) -> Int {
        guard let d = read("F\(id)Ac", size: 4) else { return 0 }
        return Int(decodeFloatLE(d).rounded())
    }

    /// Minimum RPM (F{id}Mn, type flt).
    func fanMinRPM(_ id: Int) -> Int {
        guard let d = read("F\(id)Mn", size: 4) else { return 0 }
        return Int(decodeFloatLE(d).rounded())
    }

    /// Maximum RPM (F{id}Mx, type flt).
    func fanMaxRPM(_ id: Int) -> Int {
        guard let d = read("F\(id)Mx", size: 4) else { return 0 }
        return Int(decodeFloatLE(d).rounded())
    }

    /// Fan name — F{id}ID does not exist on Apple Silicon.
    /// Use a built-in mapping based on typical MacBook Pro layout.
    func fanName(_ id: Int) -> String {
        // Standard MacBook Pro: fan 0 = Left, fan 1 = Right
        let defaultNames = ["Left Fan", "Right Fan", "Fan 2", "Fan 3"]
        return id < defaultNames.count ? defaultNames[id] : "Fan \(id)"
    }

    /// Set the target RPM for a fan (F{id}Tg, type flt, 4-byte LE float).
    func setFanTarget(_ id: Int, rpm: Int) -> Bool {
        let b = encodeFloatLE(Float(rpm))
        return write("F\(id)Tg", size: 4, bytes: b)
    }

    /// Set a single fan into manual mode (F{id}md = 1) or auto mode (= 0).
    /// On Apple Silicon, per-fan `F{id}md` (ui8) replaces the Intel-era `FS!` bitmask.
    func setFanManualMode(_ id: Int, manual: Bool) -> Bool {
        var b = zeroBytes()
        b.0 = manual ? 1 : 0
        return write("F\(id)md", size: 1, bytes: b)
    }

    /// Restore all fans to automatic mode.
    func setAllFansAuto() -> Bool {
        let count = fanCount()
        var ok = true
        for i in 0..<count {
            if !setFanManualMode(i, manual: false) { ok = false }
        }
        return ok
    }
}

// ============================================================================
// MARK: - Sensor / Fan Data Models
// ============================================================================

/// Logical category for display grouping.
enum SensorGroup: Int, Comparable {
    case performanceCore = 0
    case superCore       = 1
    case efficiencyCore  = 2
    case gpu             = 3
    case system          = 4

    static func < (lhs: SensorGroup, rhs: SensorGroup) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .performanceCore: return "CPU Performance Cores"
        case .superCore:       return "CPU Super Cores"
        case .efficiencyCore:  return "CPU Efficiency Cores"
        case .gpu:             return "GPU"
        case .system:          return "System"
        }
    }

    var icon: String {
        switch self {
        case .performanceCore, .superCore, .efficiencyCore: return "🎛️"
        case .gpu:    return "🎮"
        case .system: return "💻"
        }
    }
}

struct ThermalSensor {
    let displayName: String
    let group: SensorGroup
    let serviceRef: AnyObject          // IOHIDServiceClient opaque ref
    var temperature: Int = 0           // Rounded °C

    /// Refreshes the temperature sensor by copying the latest HID thermal event.
    mutating func refresh() {
        guard let unmanagedEvent = IOHIDServiceClientCopyEvent(
            serviceRef, kIOHIDEventTypeTemperature, 0, 0
        ) else { return }
        
        // Take ownership of the retained CoreFoundation object. Swift's ARC will
        // automatically handle releasing it when 'ev' goes out of scope, 
        // preventing a severe memory leak from this raw private C API.
        let ev = unmanagedEvent.takeRetainedValue()
        
        let raw = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldBase)
        // Reject obviously invalid readings (disconnected/inactive sensors)
        if raw > -100.0 && raw < 200.0 {
            temperature = Int(raw.rounded())
        }
    }
}

struct FanInfo {
    let id: Int
    let name: String
    var currentRPM: Int = 0
    let minRPM: Int
    let maxRPM: Int

    /// Calculates fan utilization fraction between 0.0 and 1.0.
    var utilization: Double {
        guard maxRPM > minRPM else { return 0 }
        return min(max(Double(currentRPM - minRPM) / Double(maxRPM - minRPM), 0), 1)
    }
}

// ============================================================================
// MARK: - Temperature Monitor (IOHID-based)
// ============================================================================

final class TemperatureMonitor {
    private(set) var sensors: [ThermalSensor] = []
    let chipName: String
    let modelID: String
    let osVersionString: String

    // IMPORTANT: The IOHID client must be kept alive for the entire lifetime
    // of this object.  Service references returned by CopyServices are only
    // valid while the parent client exists.  Letting ARC release it causes a
    // bus-error when we later call IOHIDServiceClientCopyEvent.
    private var hidClient: AnyObject?

    init() {
        chipName = Self.sysctl("machdep.cpu.brand_string")
        modelID  = Self.sysctl("hw.model")

        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.patchVersion == 0 {
            osVersionString = "macOS \(os.majorVersion).\(os.minorVersion)"
        } else {
            osVersionString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        }

        discoverSensors()
    }

    // MARK: Sensor discovery

    private func discoverSensors() {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return }
        hidClient = client   // ← retain the client for the object's lifetime

        let match: NSDictionary = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage":     0x0005
        ]
        IOHIDEventSystemClientSetMatching(client, match)

        guard let arr = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else { return }

        // Determine expected core/GPU counts for this chip
        let (pCount, sCount, gCount, useSuper) = Self.coreLayout(for: chipName)

        // Track how many times each raw sensor name has appeared.
        // On Apple Silicon the same PMU sensor name repeats once per
        // PMU instance (typically 3 instances → P-cluster, S/E-cluster, GPU).
        var seen: [String: Int] = [:]

        for svc in arr {
            guard let prop = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) else { continue }
            let raw = String(describing: prop)
            let occurrence = seen[raw, default: 0]
            seen[raw] = occurrence + 1

            if raw.hasPrefix("PMU tdie") {
                guard let numStr = raw.components(separatedBy: "PMU tdie").last,
                      let num = Int(numStr) else { continue }

                switch occurrence {
                case 0 where num <= pCount:
                    sensors.append(ThermalSensor(
                        displayName: "Performance Core \(num)",
                        group: .performanceCore, serviceRef: svc))
                case 1 where num <= sCount:
                    sensors.append(ThermalSensor(
                        displayName: useSuper ? "Super Core \(num)" : "Efficiency Core \(num)",
                        group: useSuper ? .superCore : .efficiencyCore, serviceRef: svc))
                case 2 where num <= gCount:
                    sensors.append(ThermalSensor(
                        displayName: "GPU Region \(num)",
                        group: .gpu, serviceRef: svc))
                default:
                    break
                }
            } else if raw == "gas gauge battery", occurrence == 0 {
                sensors.append(ThermalSensor(
                    displayName: "Battery", group: .system, serviceRef: svc))
            } else if raw == "NAND CH0 temp", occurrence == 0 {
                sensors.append(ThermalSensor(
                    displayName: "SSD", group: .system, serviceRef: svc))
            }
        }

        // Sort by group then by name (natural ordering so Core 2 < Core 10)
        sensors.sort {
            if $0.group != $1.group { return $0.group < $1.group }
            return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    // MARK: Refresh all temperatures

    func refreshAll() {
        for i in sensors.indices { sensors[i].refresh() }
    }

    // MARK: Grouped output

    func grouped() -> [(SensorGroup, [ThermalSensor])] {
        var result: [(SensorGroup, [ThermalSensor])] = []
        var curGroup: SensorGroup? = nil
        var curList: [ThermalSensor] = []
        for s in sensors {
            if s.group != curGroup {
                if let g = curGroup, !curList.isEmpty { result.append((g, curList)) }
                curGroup = s.group
                curList = [s]
            } else {
                curList.append(s)
            }
        }
        if let g = curGroup, !curList.isEmpty { result.append((g, curList)) }
        return result
    }

    // MARK: Aggregates

    var cpuAverage: Int {
        let cpu = sensors.filter {
            $0.group == .performanceCore || $0.group == .superCore || $0.group == .efficiencyCore
        }
        guard !cpu.isEmpty else { return 0 }
        return cpu.reduce(0) { $0 + $1.temperature } / cpu.count
    }

    /// Peak temperature, clamped to [0, 120] to guard against anomalous sensor readings.
    var maxTemp: Int {
        let raw = sensors.map(\.temperature).max() ?? 0
        return min(max(raw, 0), 120)
    }

    // MARK: Helpers

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "Unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Returns (pCoreCount, sCoreCount, gpuRegionCount, usesSuperCoreNaming).
    private static func coreLayout(for chip: String) -> (Int, Int, Int, Bool) {
        // M5 series
        if chip.contains("M5 Ultra")  { return (24, 10, 8, true)  }
        if chip.contains("M5 Max")    { return (12,  5, 5, true)  }
        if chip.contains("M5 Pro")    { return (10,  5, 4, true)  }
        if chip.contains("M5")        { return ( 6,  4, 4, true)  }
        // M4 series
        if chip.contains("M4 Ultra")  { return (24,  8, 8, true)  }
        if chip.contains("M4 Max")    { return (12,  4, 5, true)  }
        if chip.contains("M4 Pro")    { return (10,  4, 4, true)  }
        if chip.contains("M4")        { return ( 6,  4, 4, true)  }
        // M3 series
        if chip.contains("M3 Ultra")  { return (20,  8, 8, false) }
        if chip.contains("M3 Max")    { return (10,  4, 5, false) }
        if chip.contains("M3 Pro")    { return ( 6,  6, 4, false) }
        if chip.contains("M3")        { return ( 4,  4, 4, false) }
        // M2 series
        if chip.contains("M2 Ultra")  { return (16,  8, 8, false) }
        if chip.contains("M2 Max")    { return ( 8,  4, 5, false) }
        if chip.contains("M2 Pro")    { return ( 8,  4, 4, false) }
        if chip.contains("M2")        { return ( 4,  4, 4, false) }
        // M1 series
        if chip.contains("M1 Ultra")  { return (16,  4, 8, false) }
        if chip.contains("M1 Max")    { return ( 8,  2, 5, false) }
        if chip.contains("M1 Pro")    { return ( 6,  2, 4, false) }
        if chip.contains("M1")        { return ( 4,  4, 4, false) }
        // Fallback
        return (8, 4, 4, false)
    }
}

// ============================================================================
// MARK: - Fan Controller (SMC-based)
// ============================================================================

final class FanController {
    enum CoolingMode: Equatable {
        case auto
        case manual(pct: Int)
        case smart(currentPct: Int)
    }

    private let smc: SMCClient
    private(set) var fans: [FanInfo] = []
    private(set) var mode: CoolingMode = .auto

    /// Opaque counter to delay fan speed ramp-down (cooling) for noise and SMC lifespan optimization.
    private var coolingDelayCounter: Int = 0

    /// Helper attributes to maintain backwards compatibility with existing Dashboard code.
    var isManual: Bool {
        if case .manual = mode { return true }
        return false
    }
    var manualPct: Int {
        if case .manual(let pct) = mode { return pct }
        return 0
    }
    var isSmart: Bool {
        if case .smart = mode { return true }
        return false
    }
    var smartPct: Int {
        if case .smart(let pct) = mode { return pct }
        return 0
    }

    /// Initializes the controller by fetching and caching static hardware properties of all fans.
    init(smc: SMCClient) {
        self.smc = smc
        let count = smc.fanCount()
        for i in 0..<count {
            let id = i
            let name = smc.fanName(i)
            
            // Query physical limits from AppleSMC once
            var minR = smc.fanMinRPM(id)
            var maxR = smc.fanMaxRPM(id)
            
            // Safety boundary validation: if reading returns zero or invalid limits, fall back to safe Apple defaults.
            if maxR <= minR || maxR < 1000 {
                minR = 1200
                maxR = 6000
            }
            
            fans.append(FanInfo(id: id, name: name, currentRPM: minR, minRPM: minR, maxRPM: maxR))
        }
    }

    /// Refreshes dynamic status (current RPM only) to minimize SMC I/O latency.
    func refreshAll() {
        for i in fans.indices {
            fans[i].currentRPM = smc.fanActualRPM(fans[i].id)
        }
    }

    /// Sets all fans to a specific target percentage (0-100). Requires root.
    func setPercentage(_ pct: Int) -> Bool {
        guard pct >= 0, pct <= 100 else { return false }
        var ok = true
        for fan in fans {
            if !smc.setFanManualMode(fan.id, manual: true) { ok = false }
            
            // Protect against zero division or illogical limits
            let minR = fan.minRPM
            let maxR = fan.maxRPM > fan.minRPM ? fan.maxRPM : fan.minRPM + 100
            
            let target = minR + Int(Double(pct) / 100.0 * Double(maxR - minR))
            if !smc.setFanTarget(fan.id, rpm: target) { ok = false }
        }
        if ok { mode = .manual(pct: pct) }
        return ok
    }

    /// Restores all fans to automatic (system-managed) mode.
    func restoreAuto() -> Bool {
        let ok = smc.setAllFansAuto()
        if ok { mode = .auto }
        return ok
    }

    /// Enables the smart cooling mode.
    func enableSmartMode() -> Bool {
        let ok = smc.setAllFansAuto()
        if ok {
            mode = .smart(currentPct: 0)
            coolingDelayCounter = 0
        }
        return ok
    }

    /// Updates the smart cooling rules using a 5% step quantization and a constant 10-second hysteresis cooling delay.
    func updateSmartCooling(peakTemp: Int, interval: Int) {
        guard case .smart(let currentPct) = mode else { return }

        // 1. Calculate raw target percentage based on standard Apple Silicon thermal profiles.
        let rawTargetPct: Int
        if peakTemp <= 55 {
            // Quiet Zone: fully delegate to native macOS management
            rawTargetPct = 0
        } else if peakTemp <= 70 {
            // Warm-up Defense Zone: 30% to 50% linear progression
            let ratio = Double(peakTemp - 55) / 15.0
            rawTargetPct = 30 + Int(ratio * 20.0)
        } else if peakTemp <= 85 {
            // Active Performance Zone: 50% to 90% linear progression
            let ratio = Double(peakTemp - 70) / 15.0
            rawTargetPct = 50 + Int(ratio * 40.0)
        } else {
            // Thermal Wall Prevention Zone: max blast at 100%
            rawTargetPct = 100
        }

        // 2. Quantize target percentage to 5% steps to prevent fine-grained fluctuations.
        let targetPct: Int
        if rawTargetPct == 0 {
            targetPct = 0
        } else {
            targetPct = min(100, ((rawTargetPct + 4) / 5) * 5)
        }

        // 3. Process changes with speed-up urgency and cooling delay protection.
        if targetPct > currentPct {
            // TEMPERATURE RISING: React immediately to suppress heating and avoid thermal throttling.
            applySmartTarget(targetPct)
            coolingDelayCounter = 0
        } else if targetPct < currentPct {
            // TEMPERATURE FALLING: Apply a constant 10-second delay to debounce fan speed ramp-down.
            coolingDelayCounter += 1
            
            // Calculate how many cycles represent a 10-second period.
            // Using ceiling division to guarantee at least 10 seconds of delay.
            let requiredCycles = max(1, (10 + interval - 1) / (interval > 0 ? interval : 1))
            
            if coolingDelayCounter >= requiredCycles {
                applySmartTarget(targetPct)
                coolingDelayCounter = 0
            }
        } else {
            // Temperature is stable at this step range: reset cooling delay counter.
            coolingDelayCounter = 0
        }
    }

    /// Internal helper to write manual speed overrides or restore auto control under smart mode.
    private func applySmartTarget(_ pct: Int) {
        if pct == 0 {
            _ = smc.setAllFansAuto()
        } else {
            for fan in fans {
                _ = smc.setFanManualMode(fan.id, manual: true)
                let minR = fan.minRPM
                let maxR = fan.maxRPM > fan.minRPM ? fan.maxRPM : fan.minRPM + 100
                let targetRPM = minR + Int(Double(pct) / 100.0 * Double(maxR - minR))
                _ = smc.setFanTarget(fan.id, rpm: targetRPM)
            }
        }
        mode = .smart(currentPct: pct)
    }
}

// ============================================================================
// MARK: - Terminal Raw Mode (termios)
// ============================================================================

private var savedTermios = termios()

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    // Disable canonical mode and echo; keep ISIG so Ctrl-C still works.
    raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    // Non-blocking: VMIN=0, VTIME=0
    withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
        let cc = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: cc_t.self)
        cc[Int(VMIN)]  = 0
        cc[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)

    // Enter alternate screen buffer, clear screen, and hide cursor
    print("\(ESC)?1049h\(ESC)2J\(ESC)H\(ESC)?25l", terminator: "")
    fflush(stdout)
}

func disableRawMode() {
    // Exit alternate screen buffer and restore cursor visibility
    print("\(ESC)?1049l\(ESC)?25h", terminator: "")
    fflush(stdout)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
}

/// Read a line of user input while in raw mode, manually echoing chars.
/// Returns `nil` if the user presses Escape.
func readLineRaw(prompt: String) -> String? {
    print(prompt, terminator: "")
    fflush(stdout)
    var buf = ""
    while true {
        var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
        let pr = poll(&pfd, 1, 30_000) // 30-second timeout to prevent Smart mode thermal logic from blocking indefinitely
        guard pr > 0, (pfd.revents & Int16(POLLIN)) != 0 else { return nil }

        var c: UInt8 = 0
        guard read(STDIN_FILENO, &c, 1) == 1 else { return nil }
        switch c {
        case 10, 13:          // Enter
            print(); return buf
        case 27:              // Escape → cancel
            print(); return nil
        case 127, 8:          // Backspace / Delete
            if !buf.isEmpty {
                buf.removeLast()
                print("\u{8} \u{8}", terminator: "")
                fflush(stdout)
            }
        case 32...126:        // Printable ASCII
            buf.append(Character(UnicodeScalar(c)))
            var byte = c
            Darwin.write(STDOUT_FILENO, &byte, 1)
        default: break
        }
    }
}

// ============================================================================
// MARK: - Progress Bar Renderer
// ============================================================================

/// Render a Unicode block progress bar: █░
func bar(fraction: Double, width: Int, color: String) -> String {
    let clamped = min(max(fraction, 0), 1)
    let filled  = Int(clamped * Double(width))
    let empty   = width - filled
    return "\(color)\(String(repeating: "█", count: filled))"
         + "\(ANSI.darkGray)\(String(repeating: "░", count: empty))\(ANSI.reset)"
}

// ============================================================================
// MARK: - Dashboard Renderer
// ============================================================================

struct WinSize {
    var row: UInt16
    var col: UInt16
    var xpixel: UInt16
    var ypixel: UInt16
}

final class Dashboard {
    let temps: TemperatureMonitor
    let fans:  FanController
    let isRoot: Bool
    var interval: Int = 3

    private let W = 70                        // Outer frame border width
    private let maxTempForBar: Double = 105   // Temperature corresponding to 100% bar

    init(temps: TemperatureMonitor, fans: FanController) {
        self.temps  = temps
        self.fans   = fans
        self.isRoot = (getuid() == 0)
    }

    /// Fetches the actual number of visible terminal rows with a safe minimum bound.
    private func getTerminalRows() -> Int {
        var w = WinSize(row: 0, col: 0, xpixel: 0, ypixel: 0)
        let TIOCGWINSZ = UInt(0x40087468)
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            return max(15, Int(w.row))
        }
        return 24 // Fallback default
    }

    /// Places the right border ║ firmly at column W using ANSI cursor positioning (CSI n G),
    /// completely preventing right-border offset errors caused by emoji/unicode width mismatches.
    private func boxLine(_ text: String, style: String) -> String {
        return "\(ANSI.cyan)\(ANSI.bold)║\(ANSI.reset)\(style)\(text)\(ANSI.reset)\(ESC)K\(ESC)\(W)G\(ANSI.cyan)\(ANSI.bold)║\(ANSI.reset)"
    }

    private func boxLineRaw(_ text: String) -> String {
        return "\(ANSI.cyan)\(ANSI.bold)║\(ANSI.reset)\(text)\(ANSI.reset)\(ESC)K\(ESC)\(W)G\(ANSI.cyan)\(ANSI.bold)║\(ANSI.reset)"
    }

    private func emptyBoxLine() -> String {
        return "\(ANSI.cyan)\(ANSI.bold)║\(ANSI.reset)\(ESC)K\(ESC)\(W)G\(ANSI.cyan)\(ANSI.bold)║\(ANSI.reset)"
    }

    /// Formats the refresh interval into a standard string representation.
    private func fmtInterval(_ s: Int) -> String {
        return "\(s)s"
    }

    /// Renders the sensor array into a multi-column grid centered horizontally within the inner width.
    private func renderSensorGrid(_ sensors: [ThermalSensor], cols: Int, innerWidth: Int) -> [String] {
        var result: [String] = []
        let count = sensors.count
        guard count > 0 else { return [] }

        let targetColW = 28 // Fixed column display width
        let joint = " \(ANSI.darkGray)│\(ANSI.reset) "
        
        // Calculate the total visible width of this row combined (e.g. 2 cols: 28 + 3 + 28 = 59)
        let totalVisibleW = cols * targetColW + (cols - 1) * 3
        let leftPadLen = max(0, (innerWidth - totalVisibleW) / 2)
        let leftPad = String(repeating: " ", count: leftPadLen)

        let rowCount = Int(ceil(Double(count) / Double(cols)))
        for r in 0..<rowCount {
            var rowParts: [String] = []
            for c in 0..<cols {
                let idx = r + c * rowCount
                if idx < count {
                    let s = sensors[idx]
                    let t = s.temperature
                    let col = ANSI.colorForTemp(t)
                    let frac = Double(t) / maxTempForBar
                    let b = bar(fraction: frac, width: 8, color: col)

                    // Compress sensor names to fit nicely
                    var name = s.displayName
                    name = name.replacingOccurrences(of: "Performance Core", with: "P-Core")
                    name = name.replacingOccurrences(of: "Super Core", with: "S-Core")
                    name = name.replacingOccurrences(of: "Efficiency Core", with: "E-Core")
                    name = name.replacingOccurrences(of: "GPU Region", with: "GPU")

                    let namePad = name.padding(toLength: 10, withPad: " ", startingAt: 0)
                    let tempStr = "\(col)\(ANSI.bold)\(String(format: "%3d", t))°C\(ANSI.reset)"
                    let colText = "\(namePad) \(tempStr) \(b)" // Visible length: 10 + 1 + 5 + 1 + 8 = 25

                    let visibleLen = 25
                    let padLen = max(0, targetColW - visibleLen)
                    let padding = String(repeating: " ", count: padLen)

                    rowParts.append(colText + padding)
                } else {
                    rowParts.append(String(repeating: " ", count: targetColW))
                }
            }
            // Apply horizontal centering padding to each row of the grid
            result.append(boxLineRaw(leftPad + rowParts.joined(separator: joint)))
        }
        return result
    }

    func render() {
        var lines: [String] = []

        let hLine = String(repeating: "═", count: W - 2)
        let tLine = String(repeating: "─", count: W - 8)

        // 1. Header
        lines.append("\(ANSI.cyan)\(ANSI.bold)╔\(hLine)╗\(ANSI.reset)")
        
        // Center the main title - use visibleLength to precisely calculate width containing emoji
        let titleText = "⚡  F A N P R O  ·  Apple Silicon Thermal Command Center"
        let titleVisLen = visibleLength(titleText)
        let titlePad = max(0, (W - 2 - titleVisLen) / 2)
        let titleLeftPad = String(repeating: " ", count: titlePad)
        lines.append(boxLine(titleLeftPad + titleText, style: "\(ANSI.bold)\(ANSI.white)"))
        
        // Center the subtitle - use visibleLength to precisely calculate width
        let subText = "\(temps.chipName) · \(temps.osVersionString) · ⏱ \(fmtInterval(interval))"
        let subVisLen = visibleLength(subText)
        let subPadLen = max(0, (W - 2 - subVisLen) / 2)
        let subLeftPad = String(repeating: " ", count: subPadLen)
        lines.append(boxLine(subLeftPad + subText, style: ANSI.gray))
        
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")

        // 2. Temperature Sections
        let groups = temps.grouped()
        for (group, list) in groups {
            var header = "  \(group.icon)  \(ANSI.bold)\(ANSI.white)\(group.title)\(ANSI.reset)"
            if group != .system, !list.isEmpty {
                let avg = list.reduce(0) { $0 + $1.temperature } / list.count
                header += "  \(ANSI.gray)Avg \(ANSI.colorForTemp(avg))\(ANSI.bold)\(avg)°C\(ANSI.reset)"
            }
            lines.append(boxLineRaw(header))
            lines.append(boxLine("    \(tLine)", style: ANSI.darkGray))

            let innerW = W - 2
            let gridLines = renderSensorGrid(list, cols: 2, innerWidth: innerW)
            lines.append(contentsOf: gridLines)
            lines.append(emptyBoxLine())
        }

        if groups.isEmpty {
            lines.append(boxLine("  ⚠️  No temperature sensors detected.", style: ANSI.yellow))
            lines.append(emptyBoxLine())
        }

        // 3. Fan Section
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")
        lines.append(boxLineRaw("  🌀  \(ANSI.bold)\(ANSI.white)Fans\(ANSI.reset)"))
        lines.append(boxLine("    \(tLine)", style: ANSI.darkGray))

        if fans.fans.isEmpty {
            lines.append(boxLine("    No fans detected (MacBook Air / passive cooling).", style: ANSI.gray))
        } else {
            // Keep fan layout aligned with temperature grid (59 visible chars)
            // name(10) + 1 + RPM(8) + 2 + bar(16) + 1 + pct(4) + 2 + range(15) = 59
            let fanContentW = 59
            let fanPadLen = max(0, (W - 2 - fanContentW) / 2)
            let fanLeftPad = String(repeating: " ", count: fanPadLen)

            for f in fans.fans {
                let name = f.name.padding(toLength: 10, withPad: " ", startingAt: 0)
                let col  = ANSI.colorForFan(f.utilization)
                let b    = bar(fraction: f.utilization, width: 16, color: col)
                let pct  = Int(f.utilization * 100)

                let rawFanText = "\(name) "
                    + "\(col)\(ANSI.bold)\(String(format: "%4d", f.currentRPM)) RPM\(ANSI.reset)  "
                    + "\(b) \(ANSI.gray)\(String(format: "%3d%%", pct))\(ANSI.reset)  "
                    + "\(ANSI.darkGray)\(String(format: "(%4d-%4d RPM)", f.minRPM, f.maxRPM))\(ANSI.reset)"

                lines.append(boxLineRaw(fanLeftPad + rawFanText))
            }
        }
        lines.append(emptyBoxLine())

        // 4. Status Bar
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")
        
        let modeDisplay: String
        if fans.isSmart {
            if fans.smartPct == 0 {
                modeDisplay = "Mode: Smart (Auto)"
            } else {
                modeDisplay = "Mode: Smart (\(fans.smartPct)%)"
            }
        } else if fans.isManual {
            modeDisplay = "Mode: Manual (\(fans.manualPct)%)"
        } else {
            modeDisplay = "Mode: Auto"
        }
        
        let cpu = temps.cpuAverage
        let mx  = temps.maxTemp
        
        let authText = isRoot ? "🔓 Root" : "🔒 Read-only"
        
        // Add status bar spacing with wide separator "  │  " (5 visible chars)
        let wideSep = "  │  "
        let plainStatus = modeDisplay + wideSep + "CPU Avg: \(cpu)°C" + wideSep + "Peak: \(mx)°C" + wideSep + authText
        let plainVisLen = visibleLength(plainStatus)
        
        let statusPad = max(0, (W - 2 - plainVisLen) / 2)
        let statusLeftPad = String(repeating: " ", count: statusPad)
        
        let coloredMode = "\(ANSI.yellow)\(ANSI.bold)\(modeDisplay)\(ANSI.reset)"
        let coloredCpu = "\(ANSI.gray)CPU Avg: \(ANSI.colorForTemp(cpu))\(ANSI.bold)\(cpu)°C\(ANSI.reset)"
        let coloredPeak = "\(ANSI.gray)Peak: \(ANSI.colorForTemp(mx))\(ANSI.bold)\(mx)°C\(ANSI.reset)"
        let coloredAuth = "\(ANSI.gray)\(authText)\(ANSI.reset)"
        let coloredSep = "\(ANSI.darkGray)  │  \(ANSI.reset)"
        
        let statusText = statusLeftPad + coloredMode + coloredSep + coloredCpu + coloredSep + coloredPeak + coloredSep + coloredAuth
        
        lines.append(boxLineRaw(statusText))

        // 5. Hotkeys Footer
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")
        
        let footerText: String
        if isRoot {
            footerText = "\(ANSI.bold)\(ANSI.cyan)[A]\(ANSI.reset)\(ANSI.white) Auto Mode "
                       + "\(ANSI.bold)\(ANSI.cyan)[S]\(ANSI.reset)\(ANSI.white) Smart Mode "
                       + "\(ANSI.bold)\(ANSI.cyan)[F]\(ANSI.reset)\(ANSI.white) Fan Speed "
                       + "\(ANSI.bold)\(ANSI.cyan)[I]\(ANSI.reset)\(ANSI.white) Interval "
                       + "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)\(ANSI.white) Quit\(ANSI.reset)"
        } else {
            footerText = "\(ANSI.darkGray)[A] sudo "
                       + "[S] sudo "
                       + "[F] sudo \(ANSI.reset)"
                       + "\(ANSI.bold)\(ANSI.cyan)[I]\(ANSI.reset)\(ANSI.white) Interval "
                       + "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)\(ANSI.white) Quit\(ANSI.reset)"
        }
        
        let footerVisLen = visibleLength(footerText)
        let footerPad = max(0, (W - 2 - footerVisLen) / 2)
        let footerLeftPad = String(repeating: " ", count: footerPad)
        lines.append(boxLineRaw(footerLeftPad + footerText))
        lines.append("\(ANSI.cyan)\(ANSI.bold)╚\(hLine)╝\(ANSI.reset)")

        // 6. Prevent screen overflow by folding contents (consistent with top layout)
        let maxRows = getTerminalRows()
        if lines.count > maxRows {
            let reservedFooterCount = 3 // bottom border + hotkeys + divider
            let headerCount = 4 // top border + title + subtitle + divider
            
            if maxRows > (headerCount + reservedFooterCount + 2) {
                let keepBodyCount = maxRows - headerCount - reservedFooterCount - 1
                let headerPart = lines.prefix(headerCount)
                let bodyPart = lines[headerCount..<(headerCount + keepBodyCount)]
                let footerPart = lines.suffix(reservedFooterCount)
                
                lines = Array(headerPart) + Array(bodyPart)
                lines.append(boxLineRaw("  \(ANSI.red)⚠️ Terminal height insufficient, some sensors collapsed... (Please resize window)\(ANSI.reset)"))
                lines += Array(footerPart)
            } else {
                // Truncate fallback if window is extremely small
                lines = Array(lines.prefix(maxRows))
            }
        }

        // 7. Output to screen: render in-place, clear line ends, and avoid newlines at the end to prevent automatic scrolling
        let out = ANSI.home + ANSI.hideCursor + lines.joined(separator: "\(ANSI.clearLineEnd)\n") + ANSI.clearLineEnd + ANSI.clearEnd
        print(out, terminator: "")
        fflush(stdout)
    }
}

// ============================================================================
// MARK: - Global State & Cleanup
// ============================================================================

private var gSMC: SMCClient?
private var gFans: FanController?

/// Restores fans to auto, disables raw mode, and safely shuts down SMC.
func cleanExit(_ code: Int32 = 0) -> Never {
    _ = gFans?.restoreAuto()
    disableRawMode()
    // Reset console colors to default
    print(ANSI.reset, terminator: "")
    if code == 0 {
        print("\n\(ANSI.green)\(ANSI.bold)FanPro:\(ANSI.reset) Exited, fans restored to system default automatic mode. ✅")
    } else {
        print("\n\(ANSI.red)\(ANSI.bold)FanPro:\(ANSI.reset) Terminated abnormally (exit code \(code)). Restored terminal and fans. ⚠️")
    }
    fflush(stdout)
    gSMC?.close()
    exit(code)
}

// ============================================================================
// MARK: - Entry Point
// ============================================================================

// 0. Verify struct size (compile-time sanity check)
assert(MemoryLayout<SMCParamStruct>.stride == 80,
       "SMCParamStruct stride is \(MemoryLayout<SMCParamStruct>.stride), expected 80")

// If not running as root, attempt to re-execute itself with sudo to acquire root permissions for fan control
if getuid() != 0 && !CommandLine.arguments.contains("--readonly") {
    if let absoluteExePath = Bundle.main.executablePath {
        let argv = CommandLine.arguments
        var newArgs = ["sudo", absoluteExePath]
        if argv.count > 1 {
            newArgs.append(contentsOf: argv.suffix(from: 1))
        }
        
        let cArgs = newArgs.map { $0.withCString(strdup) }
        var argsForExec = cArgs + [nil]
        
        // Flush stdout and stderr buffers before executing process substitution
        fflush(stdout)
        fflush(stderr)
        
        // Use execvp to run sudo and relaunch the current executable, replacing this process
        execvp("sudo", &argsForExec)
        
        // If password entry is canceled or sudo fails, free allocated memory and fall back to standard read-only mode
        for arg in cArgs { free(arg) }
    }
}

// 1. Signal handlers for clean exit on Ctrl-C / kill / crashes
signal(SIGINT)  { _ in cleanExit(0) }
signal(SIGTERM) { _ in cleanExit(0) }
signal(SIGSEGV) { _ in cleanExit(11) }
signal(SIGBUS)  { _ in cleanExit(10) }
signal(SIGILL)  { _ in cleanExit(4) }
signal(SIGFPE)  { _ in cleanExit(8) }
signal(SIGABRT) { _ in cleanExit(6) }

// 2. Open SMC
let smc = SMCClient()
gSMC = smc
guard smc.open() else {
    fputs("""
    \(ANSI.red)\(ANSI.bold)Error:\(ANSI.reset) Failed to connect to AppleSMC driver.
    Please confirm this Mac uses an Apple Silicon chip and the macOS version is supported.\n
    """, stderr)
    exit(1)
}

// 3. Discover sensors & fans
let tempMon = TemperatureMonitor()
let fanCtrl = FanController(smc: smc)
gFans = fanCtrl

let dash = Dashboard(temps: tempMon, fans: fanCtrl)

// 4. Print launch banner (will be replaced by TUI on first render)
if getuid() != 0 {
    fputs("""
    \(ANSI.yellow)\(ANSI.bold)Note:\(ANSI.reset) Running as a standard user; fan control is unavailable.
    To control fans, please run with sudo (e.g., sudo fanpro).\n
    """, stderr)
    Thread.sleep(forTimeInterval: 1.2)
}

// 5. Enter raw mode
enableRawMode()

// 6. Main run loop
var running = true
while running {
    // Refresh hardware data - dynamic currentRPM must be loaded. Static limits are already cached during initialization.
    tempMon.refreshAll()
    fanCtrl.refreshAll()

    // If in Smart cooling mode, dynamically adjust fan speed based on peak temperature
    if fanCtrl.isSmart {
        fanCtrl.updateSmartCooling(peakTemp: tempMon.maxTemp, interval: dash.interval)
    }

    // Draw TUI
    dash.render()

    // Wait for input or timeout
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let ms  = Int32(dash.interval * 1000)
    let pr  = poll(&pfd, 1, ms)

    guard pr > 0, (pfd.revents & Int16(POLLIN)) != 0 else { continue }

    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { continue }

    switch Character(UnicodeScalar(byte)) {

    // ── Quit ─────────────────────────────────────────────────────
    case "q", "Q":
        running = false

    // ── Change refresh interval ──────────────────────────────────
    case "i", "I":
        if let s = readLineRaw(prompt:
            "\(ANSI.clearScreen)\(ANSI.cyan)\(ANSI.bold)"
          + "Enter new refresh interval (seconds, 1 - 10): \(ANSI.reset)")
        {
            if let v = Int(s), v >= 1, v <= 10 {
                dash.interval = v
            }
        }

    // ── Set fan speed ────────────────────────────────────────────
    case "f", "F":
        guard getuid() == 0 else {
            print("\(ANSI.clearScreen)\(ANSI.yellow)Sudo privileges required to control fans.\(ANSI.reset)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.2)
            continue
        }
        if let s = readLineRaw(prompt:
            "\(ANSI.clearScreen)\(ANSI.cyan)\(ANSI.bold)"
          + "Enter target fan speed percentage (0 - 100): \(ANSI.reset)")
        {
            if let pct = Int(s), pct >= 0, pct <= 100 {
                if !fanCtrl.setPercentage(pct) {
                    print("\(ANSI.red)Failed to set fan target speed.\(ANSI.reset)")
                    fflush(stdout)
                    Thread.sleep(forTimeInterval: 1.0)
                }
            }
        }

    // ── Enable smart cooling mode ────────────────────────────────
    case "s", "S":
        guard getuid() == 0 else {
            print("\(ANSI.clearScreen)\(ANSI.yellow)Sudo privileges required to enable Smart mode.\(ANSI.reset)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.2)
            continue
        }
        if !fanCtrl.enableSmartMode() {
            print("\(ANSI.red)Failed to enable Smart mode.\(ANSI.reset)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
        }

    // ── Restore auto mode ────────────────────────────────────────
    case "a", "A":
        guard getuid() == 0 else {
            print("\(ANSI.clearScreen)\(ANSI.yellow)Sudo privileges required to restore Auto mode.\(ANSI.reset)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.2)
            continue
        }
        if !fanCtrl.restoreAuto() {
            print("\(ANSI.red)Failed to restore Auto mode.\(ANSI.reset)")
            fflush(stdout)
            Thread.sleep(forTimeInterval: 1.0)
        }

    default:
        break
    }
}

cleanExit()
