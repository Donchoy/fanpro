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

/// Safely truncates a string to a specific visible terminal width, appending ellipses if truncated.
func truncateTo(_ s: String, width: Int) -> String {
    guard width > 0 else { return "" }
    let vis = visibleLength(s)
    if vis <= width { return s }

    let suffix = width >= 3 ? "..." : String(repeating: ".", count: width)
    let suffixWidth = visibleLength(suffix)
    
    var current = ""
    var currentVis = 0
    for char in s {
        let charStr = String(char)
        let charVis = visibleLength(charStr)
        if currentVis + charVis + suffixWidth > width {
            break
        }
        current.append(char)
        currentVis += charVis
    }
    return current + suffix
}

/// Truncate then pad a plain (non-ANSI) string to an exact terminal width.
func padOrTruncateVisible(_ s: String, width: Int) -> String {
    let truncated = truncateTo(s, width: width)
    let padLen = max(0, width - visibleLength(truncated))
    return truncated + String(repeating: " ", count: padLen)
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
        if t <= 55 { return green }  // Native Auto / 0 RPM Quiet Zone
        if t <= 65 { return cyan }   // Smooth Startup (0% -> 20%)
        if t <= 75 { return yellow } // Active Transition (20% -> 50%)
        if t <= 85 { return orange } // High Performance (50% -> 80%)
        return red                   // Overheat Recovery / Max Blast (> 85%)
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
func IOHIDEventSystemClientCopyServices(_ client: AnyObject) -> Unmanaged<CFArray>?

@_silgen_name("IOHIDServiceClientCopyProperty")
func IOHIDServiceClientCopyProperty(_ service: AnyObject, _ key: CFString) -> Unmanaged<AnyObject>?

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

    /// Number of fans reported by the SMC, or nil if the key cannot be read.
    func readFanCount() -> Int? {
        guard let d = read("FNum", size: 1) else { return nil }
        return Int(d.0)
    }

    /// Number of fans reported by the SMC.
    func fanCount() -> Int {
        readFanCount() ?? 0
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
}

/// Returns true when SMC can be opened and reports at least one physical fan.
/// This keeps fanless Macs out of the sudo path before the full dashboard starts.
func deviceHasFansForStartupProbe() -> Bool {
    let probe = SMCClient()
    guard probe.open() else { return true }
    defer { probe.close() }
    guard let count = probe.readFanCount() else { return true }
    return count > 0
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
    let shortName: String              // Precompiled short name to avoid high-frequency String allocation
    let group: SensorGroup
    let serviceRef: AnyObject          // IOHIDServiceClient opaque ref
    var temperature: Int? = nil        // Rounded °C, nil represents stale/invalid
    private var missedReads = 0
    private let maxTransientMisses = 2

    init(displayName: String, group: SensorGroup, serviceRef: AnyObject) {
        self.displayName = displayName
        self.group = group
        self.serviceRef = serviceRef
        
        var name = displayName
        name = name.replacingOccurrences(of: "Performance Core", with: "P-Core")
        name = name.replacingOccurrences(of: "Super Core", with: "S-Core")
        name = name.replacingOccurrences(of: "Efficiency Core", with: "E-Core")
        name = name.replacingOccurrences(of: "GPU Region", with: "GPU")
        self.shortName = name
    }

    /// Refreshes the temperature sensor by copying the latest HID thermal event.
    mutating func refresh() {
        guard let unmanagedEvent = IOHIDServiceClientCopyEvent(
            serviceRef, kIOHIDEventTypeTemperature, 0, 0
        ) else {
            markMissedRead()
            return
        }
        
        // Take ownership of the retained CoreFoundation object. Swift's ARC will
        // automatically handle releasing it when 'ev' goes out of scope, 
        // preventing a severe memory leak from this raw private C API.
        let ev = unmanagedEvent.takeRetainedValue()
        
        let raw = IOHIDEventGetFloatValue(ev, kIOHIDEventFieldBase)
        // Reject obviously invalid readings (disconnected/inactive sensors)
        if raw > -100.0 && raw < 200.0 {
            temperature = Int(raw.rounded())
            missedReads = 0
        } else {
            markMissedRead()
        }
    }

    private mutating func markMissedRead() {
        missedReads += 1
        if missedReads > maxTransientMisses {
            temperature = nil
        }
    }
}

struct FanInfo {
    let id: Int
    let name: String
    var currentRPM: Int = 0
    let minRPM: Int
    let maxRPM: Int
    var missedRPMReads: Int = 0

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

        // Prevent CoreFoundation memory leak by using takeRetainedValue() on the copied services array
        guard let unmanagedArr = IOHIDEventSystemClientCopyServices(client) else { return }
        let arr = unmanagedArr.takeRetainedValue() as [AnyObject]

        // Determine expected core/GPU counts for this chip
        let (pCount, sCount, gCount, useSuper) = Self.coreLayout(for: chipName)
        let isUltra = chipName.contains("Ultra")

        // Track how many times each raw sensor name has appeared.
        var seen: [String: Int] = [:]
        
        // Track which services were matched to avoid duplicates
        var addedRefs = Set<ObjectIdentifier>()
        
        func addSensor(_ s: ThermalSensor) {
            let refID = ObjectIdentifier(s.serviceRef)
            guard !addedRefs.contains(refID) else { return }
            sensors.append(s)
            addedRefs.insert(refID)
        }

        for svc in arr {
            guard let unmanagedProp = IOHIDServiceClientCopyProperty(svc, "Product" as CFString) else { continue }
            let prop = unmanagedProp.takeRetainedValue()
            let raw = String(describing: prop)
            let occurrence = seen[raw, default: 0]
            seen[raw] = occurrence + 1

            if raw.hasPrefix("PMU tdie") {
                guard let numStr = raw.components(separatedBy: "PMU tdie").last,
                      let num = Int(numStr) else { continue }

                if isUltra {
                    // Ultra dual-die core indexing configuration (each die has identical indices)
                    // occurrence 0, 1 -> Performance Cores on Die 0 & 1
                    // occurrence 2, 3 -> Efficiency / Super Cores on Die 0 & 1
                    // occurrence 4, 5 -> GPU Cores on Die 0 & 1
                    switch occurrence {
                    case 0, 1:
                        if num <= (pCount / 2) {
                            addSensor(ThermalSensor(
                                displayName: "P-Core D\(occurrence) \(num)",
                                group: .performanceCore, serviceRef: svc))
                        }
                    case 2, 3:
                        if num <= (sCount / 2) {
                            let die = occurrence - 2
                            addSensor(ThermalSensor(
                                displayName: useSuper ? "S-Core D\(die) \(num)" : "E-Core D\(die) \(num)",
                                group: useSuper ? .superCore : .efficiencyCore, serviceRef: svc))
                        }
                    case 4, 5:
                        if num <= (gCount / 2) {
                            let die = occurrence - 4
                            addSensor(ThermalSensor(
                                displayName: "GPU D\(die) \(num)",
                                group: .gpu, serviceRef: svc))
                        }
                    default:
                        break
                    }
                } else {
                    // Standard single-die layout
                    switch occurrence {
                    case 0 where num <= pCount:
                        addSensor(ThermalSensor(
                            displayName: "Performance Core \(num)",
                            group: .performanceCore, serviceRef: svc))
                    case 1 where num <= sCount:
                        addSensor(ThermalSensor(
                            displayName: useSuper ? "Super Core \(num)" : "Efficiency Core \(num)",
                            group: useSuper ? .superCore : .efficiencyCore, serviceRef: svc))
                    case 2 where num <= gCount:
                        addSensor(ThermalSensor(
                            displayName: "GPU Region \(num)",
                            group: .gpu, serviceRef: svc))
                    default:
                        break
                    }
                }
            } else if raw == "gas gauge battery", occurrence == 0 {
                addSensor(ThermalSensor(
                    displayName: "Battery", group: .system, serviceRef: svc))
            } else if raw == "NAND CH0 temp", occurrence == 0 {
                addSensor(ThermalSensor(
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

    /// Average CPU temperature (ignoring nil sensors)
    var cpuAverage: Int? {
        let cpuTemps = sensors.filter {
            $0.group == .performanceCore || $0.group == .superCore || $0.group == .efficiencyCore
        }.compactMap { $0.temperature }
        guard !cpuTemps.isEmpty else { return nil }
        return cpuTemps.reduce(0, +) / cpuTemps.count
    }

    /// Peak temperature across ALL sensors (used for display, ignoring nil)
    var maxTemp: Int? {
        guard let raw = sensors.compactMap({ $0.temperature }).max() else { return nil }
        return min(max(raw, 0), 120)
    }

    /// Peak temperature across CPU/GPU core sensors only (used for smart cooling logic, ignoring nil)
    var coolingPeakTemp: Int? {
        let coreTemps = sensors.filter {
            $0.group == .performanceCore || $0.group == .superCore || $0.group == .efficiencyCore || $0.group == .gpu
        }.compactMap { $0.temperature }
        guard let raw = coreTemps.max() else { return nil }
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
        case performance(currentPct: Int)
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
    var isPerformance: Bool {
        if case .performance = mode { return true }
        return false
    }
    var performancePct: Int {
        if case .performance(let pct) = mode { return pct }
        return 0
    }
    var hasFans: Bool {
        !fans.isEmpty
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

    private(set) var lastWriteFailed: Bool = false

    /// Refreshes dynamic status (current RPM only) to minimize SMC I/O latency.
    func refreshAll() {
        for i in fans.indices {
            let rpm = smc.fanActualRPM(fans[i].id)
            if rpm > 0 {
                fans[i].currentRPM = rpm
                fans[i].missedRPMReads = 0
            } else {
                fans[i].missedRPMReads += 1
                if fans[i].missedRPMReads > 2 {
                    fans[i].currentRPM = 0
                }
            }
        }
    }

    @discardableResult
    private func writeFanManualMode(_ id: Int, manual: Bool) -> Bool {
        let ok = smc.setFanManualMode(id, manual: manual)
        if ok { hasWrittenFanControl = true }
        return ok
    }

    @discardableResult
    private func writeFanTarget(_ id: Int, rpm: Int) -> Bool {
        let ok = smc.setFanTarget(id, rpm: rpm)
        if ok { hasWrittenFanControl = true }
        return ok
    }

    /// Sets all fans to a specific target percentage (0-100). Requires root.
    func setPercentage(_ pct: Int) -> Bool {
        guard !fans.isEmpty else { return false }
        guard pct >= 0, pct <= 100 else { return false }
        var ok = true
        for fan in fans {
            if !writeFanManualMode(fan.id, manual: true) { ok = false }
            
            // Protect against zero division or illogical limits
            let minR = fan.minRPM
            let maxR = fan.maxRPM > fan.minRPM ? fan.maxRPM : fan.minRPM + 100
            
            let target = minR + Int(Double(pct) / 100.0 * Double(maxR - minR))
            if !writeFanTarget(fan.id, rpm: target) { ok = false }
        }
        lastWriteFailed = !ok
        if ok {
            mode = .manual(pct: pct)
        }
        return ok
    }

    /// Restores all fans to automatic (system-managed) mode using cached fans to prevent missing channels.
    func restoreAuto() -> Bool {
        guard !fans.isEmpty else {
            lastWriteFailed = false
            mode = .auto
            return true
        }
        var ok = true
        for fan in fans {
            if !writeFanManualMode(fan.id, manual: false) { ok = false }
        }
        lastWriteFailed = !ok
        if ok { mode = .auto }
        return ok
    }

    /// Enables the performance cooling mode.
    func enablePerformanceMode() -> Bool {
        guard !fans.isEmpty else { return false }
        let ok = restoreAuto()
        if ok {
            mode = .performance(currentPct: 0)
            coolingDelayCounter = 0
        }
        return ok
    }

    /// Updates the performance cooling rules using a 5% step quantization and a constant 15-second hysteresis cooling delay.
    func updatePerformanceCooling(peakTemp: Int?, interval: Int) {
        guard case .performance(let currentPct) = mode else { return }
        guard let peakTemp else {
            coolingDelayCounter = 0
            return
        }

        // 1. Calculate raw target percentage based on standard Apple Silicon thermal profiles.
        let rawTargetPct: Int
        if peakTemp <= 55 {
            // Quiet Zone: fully delegate to native macOS management
            rawTargetPct = 0
        } else if peakTemp <= 65 {
            // Smooth Startup Zone (Slope: 2%/°C): 0% to 20% gentle climb
            rawTargetPct = (peakTemp - 55) * 2
        } else if peakTemp <= 75 {
            // Active Transition Zone (Slope: 3%/°C): 20% to 50% steady progression
            rawTargetPct = 20 + (peakTemp - 65) * 3
        } else if peakTemp <= 85 {
            // High Performance Zone (Slope: 3%/°C): 50% to 80% progression
            rawTargetPct = 50 + (peakTemp - 75) * 3
        } else if peakTemp <= 90 {
            // Thermal Wall Buffer Zone (Slope: 4%/°C): 80% to 100% rapid response
            rawTargetPct = 80 + (peakTemp - 85) * 4
        } else {
            // Critical Overheat Zone: max blast at 100%
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
            applyPerformanceTarget(targetPct)
            coolingDelayCounter = 0
        } else if targetPct < currentPct {
            // TEMPERATURE FALLING: Apply a constant 15-second delay to debounce fan speed ramp-down.
            coolingDelayCounter += 1
            
            // Calculate how many cycles represent a 15-second period.
            // Using ceiling division to guarantee at least 15 seconds of delay.
            let cooldownDelaySeconds = 15
            let requiredCycles = max(1, (cooldownDelaySeconds + interval - 1) / (interval > 0 ? interval : 1))
            
            if coolingDelayCounter >= requiredCycles {
                applyPerformanceTarget(targetPct)
                coolingDelayCounter = 0
            }
        } else {
            // Temperature is stable at this step range: reset cooling delay counter.
            coolingDelayCounter = 0
        }
    }

    /// Internal helper to write manual speed overrides or restore auto control under performance mode.
    @discardableResult
    private func applyPerformanceTarget(_ pct: Int) -> Bool {
        var ok = true
        if pct == 0 {
            for fan in fans {
                if !writeFanManualMode(fan.id, manual: false) { ok = false }
            }
        } else {
            for fan in fans {
                if !writeFanManualMode(fan.id, manual: true) { ok = false }
                let minR = fan.minRPM
                let maxR = fan.maxRPM > fan.minRPM ? fan.maxRPM : fan.minRPM + 100
                let targetRPM = minR + Int(Double(pct) / 100.0 * Double(maxR - minR))
                if !writeFanTarget(fan.id, rpm: targetRPM) { ok = false }
            }
        }
        lastWriteFailed = !ok
        if ok {
            mode = .performance(currentPct: pct)
        }
        return ok
    }
}

// ============================================================================
// MARK: - Terminal Raw Mode (termios)
// ============================================================================

enum InputMode {
    case normal
    case enteringInterval(buffer: String)
    case enteringManualPct(buffer: String)
}

private var savedTermios = termios()
private var forceReadonly = false
private var gInputMode: InputMode = .normal
private var hasWrittenFanControl = false

func enableRawMode() {
    guard isatty(STDIN_FILENO) != 0 else { return }
    guard tcgetattr(STDIN_FILENO, &savedTermios) == 0 else { return }
    var raw = savedTermios
    // Disable canonical mode and echo; keep ISIG so Ctrl-C still works.
    raw.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    // Non-blocking: VMIN=0, VTIME=0
    withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
        let cc = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: cc_t.self)
        cc[Int(VMIN)]  = 0
        cc[Int(VTIME)] = 0
    }
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else { return }

    // Enter alternate screen buffer, clear screen, and hide cursor
    print("\(ESC)?1049h\(ESC)2J\(ESC)H\(ESC)?25l", terminator: "")
    fflush(stdout)
    rawModeEnabled = true
}

func disableRawMode() {
    guard rawModeEnabled else { return }
    // Exit alternate screen buffer and restore cursor visibility
    print("\(ESC)?1049l\(ESC)?25h", terminator: "")
    fflush(stdout)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &savedTermios)
    rawModeEnabled = false
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

    private var W = 70                        // Outer frame border width

    /// Dynamically update terminal width to adapt width layout responsive layout.
    private func updateTerminalDimensions() {
        var w = WinSize(row: 0, col: 0, xpixel: 0, ypixel: 0)
        let TIOCGWINSZ = UInt(0x40087468)
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            self.W = min(70, max(45, Int(w.col)))
        } else {
            self.W = 70
        }
    }
    private let maxTempForBar: Double = 105   // Temperature corresponding to 100% bar

    init(temps: TemperatureMonitor, fans: FanController) {
        self.temps  = temps
        self.fans   = fans
        self.isRoot = (getuid() == 0 && !forceReadonly)
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
                    let colText: String
                    if let t = s.temperature {
                        let col = ANSI.colorForTemp(t)
                        let frac = Double(t) / maxTempForBar
                        let b = bar(fraction: frac, width: 8, color: col)
                        let namePad = padOrTruncateVisible(s.shortName, width: 10)
                        let tempStr = "\(col)\(ANSI.bold)\(String(format: "%3d", t))°C\(ANSI.reset)"
                        colText = "\(namePad) \(tempStr) \(b)" // Visible length: 10 + 1 + 5 + 1 + 8 = 25
                    } else {
                        let b = bar(fraction: 0, width: 8, color: ANSI.darkGray)
                        let namePad = padOrTruncateVisible(s.shortName, width: 10)
                        let tempStr = "\(ANSI.darkGray)\(ANSI.bold) --°C\(ANSI.reset)"
                        colText = "\(namePad) \(tempStr) \(b)" // Visible length: 10 + 1 + 5 + 1 + 8 = 25
                    }

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
        updateTerminalDimensions()
        var lines: [String] = []

        let hLine = String(repeating: "═", count: W - 2)
        let tLine = String(repeating: "─", count: W - 8)

        // 1. Header
        lines.append("\(ANSI.cyan)\(ANSI.bold)╔\(hLine)╗\(ANSI.reset)")
        
        let titleText = "⚡  F A N P R O  ·  Apple Silicon Thermal Command Center"
        let displayTitle = truncateTo(titleText, width: W - 4)
        let titleVisLen = visibleLength(displayTitle)
        let titlePad = max(0, (W - 2 - titleVisLen) / 2)
        let titleLeftPad = String(repeating: " ", count: titlePad)
        lines.append(boxLine(titleLeftPad + displayTitle, style: "\(ANSI.bold)\(ANSI.white)"))
        
        let displayChip = truncateTo(temps.chipName, width: max(15, W - 30))
        let subText = "\(displayChip) · \(temps.osVersionString) · ⏱ \(fmtInterval(interval))"
        let displaySub = truncateTo(subText, width: W - 4)
        let subVisLen = visibleLength(displaySub)
        let subPadLen = max(0, (W - 2 - subVisLen) / 2)
        let subLeftPad = String(repeating: " ", count: subPadLen)
        lines.append(boxLine(subLeftPad + displaySub, style: ANSI.gray))
        
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")

        // 2. Temperature Sections
        let groups = temps.grouped()
        let innerW = W - 2
        for (group, list) in groups {
            var header = "  \(group.icon)  \(ANSI.bold)\(ANSI.white)\(group.title)\(ANSI.reset)"
            if group != .system {
                let validTemps = list.compactMap { $0.temperature }
                if !validTemps.isEmpty {
                    let avg = validTemps.reduce(0, +) / validTemps.count
                    header += "  \(ANSI.gray)Avg \(ANSI.colorForTemp(avg))\(ANSI.bold)\(avg)°C\(ANSI.reset)"
                }
            }
            lines.append(boxLineRaw(header))
            lines.append(boxLine("    \(tLine)", style: ANSI.darkGray))

            // Two columns need 59 visible cells inside the border: 28 + 3 + 28.
            let cols = innerW >= 59 ? 2 : 1
            let gridLines = renderSensorGrid(list, cols: cols, innerWidth: innerW)
            lines.append(contentsOf: gridLines)
            lines.append(emptyBoxLine())
        }

        if groups.isEmpty {
            lines.append(boxLine("  ⚠️  No temperature sensors detected.", style: ANSI.yellow))
            lines.append(emptyBoxLine())
        }

        // 3. Fan Section (hidden on fanless devices)
        let hasFans = fans.hasFans
        if hasFans {
            lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")
            lines.append(boxLineRaw("  🌀  \(ANSI.bold)\(ANSI.white)Fans\(ANSI.reset)"))
            lines.append(boxLine("    \(tLine)", style: ANSI.darkGray))
            
            // Adaptive fan layout depending on terminal width
            let barW = W >= 60 ? 16 : 8
            let showRange = W >= 65 // Only show limits if we have enough columns to avoid truncation color bugs

            for f in fans.fans {
                let name = padOrTruncateVisible(f.name, width: 10)
                let col  = ANSI.colorForFan(f.utilization)
                let b    = bar(fraction: f.utilization, width: barW, color: col)
                let pct  = Int(f.utilization * 100)

                var rawFanText = "\(name) "
                    + "\(col)\(ANSI.bold)\(String(format: "%4d", f.currentRPM)) RPM\(ANSI.reset)  "
                    + "\(b) \(ANSI.gray)\(String(format: "%3d%%", pct))\(ANSI.reset)"
                
                if showRange {
                    rawFanText += "  \(ANSI.darkGray)\(String(format: "(%4d-%4d RPM)", f.minRPM, f.maxRPM))\(ANSI.reset)"
                }

                let fanVisLen = visibleLength(rawFanText)
                let fanPadLen = max(0, (W - 2 - fanVisLen) / 2)
                let fanLeftPad = String(repeating: " ", count: fanPadLen)
                lines.append(boxLineRaw(fanLeftPad + rawFanText))
            }
            
            lines.append(emptyBoxLine())
        }

        // 4. Status Bar
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")
        
        var modeDisplay: String?
        let isPerfMode = fans.isPerformance
        let pctVal = isPerfMode ? fans.performancePct : (fans.isManual ? fans.manualPct : 0)
        
        if hasFans {
            if W >= 65 {
                if isPerfMode {
                    modeDisplay = pctVal == 0 ? "Mode: Performance (Auto)" : "Mode: Performance (\(pctVal)%)"
                } else if fans.isManual {
                    modeDisplay = "Mode: Manual (\(pctVal)%)"
                } else {
                    modeDisplay = "Mode: Auto"
                }
            } else {
                // Under compact widths, use "Perf" instead of "Performance" to save 7 columns
                if isPerfMode {
                    modeDisplay = pctVal == 0 ? "Mode: Perf (Auto)" : "Mode: Perf (\(pctVal)%)"
                } else if fans.isManual {
                    modeDisplay = "Mode: Manual (\(pctVal)%)"
                } else {
                    modeDisplay = "Mode: Auto"
                }
            }
            
            if fans.lastWriteFailed {
                modeDisplay = (modeDisplay ?? "Mode") + " ⚠️ ERR"
            }
        }
        
        let cpu = temps.cpuAverage
        let mx  = temps.maxTemp
        let authText = isRoot ? "🔓 Root" : "🔒 Read-only"
        let cpuText = cpu.map { "CPU Avg: \($0)°C" } ?? "CPU Avg: --°C"
        let peakText = mx.map { "Peak: \($0)°C" } ?? "Peak: --°C"
        let peakShortText = mx.map { "Pk: \($0)°C" } ?? "Pk: --°C"
        
        struct StatusItem {
            let plain: String
            let colored: String
        }
        
        let modeItem = modeDisplay.map {
            StatusItem(
                plain: $0,
                colored: fans.lastWriteFailed ? "\(ANSI.red)\(ANSI.bold)\($0)\(ANSI.reset)" : "\(ANSI.yellow)\(ANSI.bold)\($0)\(ANSI.reset)"
            )
        }
        let coloredCpu = cpu.map {
            "\(ANSI.gray)CPU Avg: \(ANSI.colorForTemp($0))\(ANSI.bold)\($0)°C\(ANSI.reset)"
        } ?? "\(ANSI.gray)CPU Avg: \(ANSI.darkGray)\(ANSI.bold)--°C\(ANSI.reset)"
        let coloredPeak = mx.map {
            "\(ANSI.gray)Peak: \(ANSI.colorForTemp($0))\(ANSI.bold)\($0)°C\(ANSI.reset)"
        } ?? "\(ANSI.gray)Peak: \(ANSI.darkGray)\(ANSI.bold)--°C\(ANSI.reset)"
        let coloredPeakShort = mx.map {
            "\(ANSI.gray)Pk: \(ANSI.colorForTemp($0))\(ANSI.bold)\($0)°C\(ANSI.reset)"
        } ?? "\(ANSI.gray)Pk: \(ANSI.darkGray)\(ANSI.bold)--°C\(ANSI.reset)"
        let coloredAuth = "\(ANSI.gray)\(authText)\(ANSI.reset)"
        
        let cpuItem = StatusItem(plain: cpuText, colored: coloredCpu)
        let peakItem = StatusItem(plain: peakText, colored: coloredPeak)
        let peakShortItem = StatusItem(plain: peakShortText, colored: coloredPeakShort)
        let authItem = StatusItem(plain: authText, colored: coloredAuth)
        
        let initialLevel: Int
        if W >= 68 {
            initialLevel = 1
        } else if W >= 60 {
            initialLevel = 2
        } else if W >= 48 {
            initialLevel = 3
        } else {
            initialLevel = 4
        }
        
        var finalItems: [StatusItem] = []
        let statusEdgePadMax = 3
        let footerEdgePadMax = 2
        var finalEdgePad = statusEdgePadMax
        var finalSpaces: [Int] = []
        var isSingleItem = false
        
        for level in initialLevel...4 {
            let items: [StatusItem]
            switch level {
            case 1:
                items = [modeItem, cpuItem, peakItem, authItem].compactMap { $0 }
            case 2:
                items = [modeItem, peakItem, authItem].compactMap { $0 }
            case 3:
                if let modeItem {
                    items = [modeItem, peakShortItem]
                } else {
                    items = [peakShortItem, authItem]
                }
            default:
                items = modeItem.map { [$0] } ?? [peakShortItem]
            }
            
            let N = items.count
            if N == 1 {
                finalItems = items
                isSingleItem = true
                break
            }
            
            let totalItemLen = items.reduce(0) { $0 + visibleLength($1.plain) }
            var found = false
            for ep in (0...statusEdgePadMax).reversed() {
                let requiredLen = totalItemLen + (N - 1)
                let remainingSpace = W - 2 - (2 * ep) - requiredLen
                if remainingSpace >= 0 {
                    finalItems = items
                    finalEdgePad = ep
                    
                    let base = remainingSpace / (N - 1)
                    let rem = remainingSpace % (N - 1)
                    var spaces: [Int] = []
                    for i in 1...(N - 1) {
                        let extra = i <= rem ? 1 : 0
                        spaces.append(base + extra)
                    }
                    finalSpaces = spaces
                    found = true
                    break
                }
            }
            if found {
                break
            }
        }
        
        let coloredStatus: String
        
        if isSingleItem {
            let visLen = visibleLength(finalItems[0].plain)
            let totalPad = max(0, W - 2 - visLen)
            let leftPad = totalPad / 2
            let rightPad = totalPad - leftPad
            coloredStatus = String(repeating: " ", count: leftPad) + finalItems[0].colored + String(repeating: " ", count: rightPad)
        } else {
            var colored = String(repeating: " ", count: finalEdgePad) + finalItems[0].colored
            
            for i in 0..<(finalItems.count - 1) {
                let spaceCount = finalSpaces[i]
                let leftSpace = spaceCount / 2
                let rightSpace = spaceCount - leftSpace
                
                let coloredSep = String(repeating: " ", count: leftSpace) + "\(ANSI.darkGray)│\(ANSI.reset)" + String(repeating: " ", count: rightSpace)
                
                colored += coloredSep + finalItems[i + 1].colored
            }
            
            colored += String(repeating: " ", count: finalEdgePad)
            coloredStatus = colored
        }
        
        lines.append(boxLineRaw(coloredStatus))

        // 5. Hotkeys Footer
        lines.append("\(ANSI.cyan)\(ANSI.bold)╠\(hLine)╣\(ANSI.reset)")
        
        let coloredFooterText: String
        switch gInputMode {
        case .normal:
            let footerItems: [StatusItem]
            if !hasFans {
                footerItems = [
                    StatusItem(plain: "[Q] Quit", colored: "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)\(ANSI.white) Quit\(ANSI.reset)")
                ]
            } else if W >= 60 {
                if isRoot {
                    footerItems = [
                        StatusItem(plain: "[A] Auto Mode", colored: "\(ANSI.bold)\(ANSI.cyan)[A]\(ANSI.reset)\(ANSI.white) Auto Mode\(ANSI.reset)"),
                        StatusItem(plain: "[S] Performance Mode", colored: "\(ANSI.bold)\(ANSI.cyan)[S]\(ANSI.reset)\(ANSI.white) Performance Mode\(ANSI.reset)"),
                        StatusItem(plain: "[F] Fan Speed", colored: "\(ANSI.bold)\(ANSI.cyan)[F]\(ANSI.reset)\(ANSI.white) Fan Speed\(ANSI.reset)"),
                        StatusItem(plain: "[Q] Quit", colored: "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)\(ANSI.white) Quit\(ANSI.reset)")
                    ]
                } else {
                    footerItems = [
                        StatusItem(plain: "[A] sudo", colored: "\(ANSI.darkGray)[A] sudo\(ANSI.reset)"),
                        StatusItem(plain: "[S] sudo", colored: "\(ANSI.darkGray)[S] sudo\(ANSI.reset)"),
                        StatusItem(plain: "[F] sudo", colored: "\(ANSI.darkGray)[F] sudo\(ANSI.reset)"),
                        StatusItem(plain: "[Q] Quit", colored: "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)\(ANSI.white) Quit\(ANSI.reset)")
                    ]
                }
            } else {
                if isRoot {
                    footerItems = [
                        StatusItem(plain: "[A] Auto", colored: "\(ANSI.bold)\(ANSI.cyan)[A]\(ANSI.reset)Auto"),
                        StatusItem(plain: "[S] Perf", colored: "\(ANSI.bold)\(ANSI.cyan)[S]\(ANSI.reset)Perf"),
                        StatusItem(plain: "[F] Set", colored: "\(ANSI.bold)\(ANSI.cyan)[F]\(ANSI.reset)Set"),
                        StatusItem(plain: "[Q] Quit", colored: "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)Quit")
                    ]
                } else {
                    footerItems = [
                        StatusItem(plain: "[Q] Quit", colored: "\(ANSI.bold)\(ANSI.red)[Q]\(ANSI.reset)Quit")
                    ]
                }
            }
            
            let N = footerItems.count
            if N == 1 {
                let visLen = visibleLength(footerItems[0].plain)
                let totalPad = max(0, W - 2 - visLen)
                let leftPad = totalPad / 2
                let rightPad = totalPad - leftPad
                coloredFooterText = String(repeating: " ", count: leftPad) + footerItems[0].colored + String(repeating: " ", count: rightPad)
            } else {
                let totalItemLen = footerItems.reduce(0) { $0 + visibleLength($1.plain) }
                var finalFooterEdgePad = footerEdgePadMax
                var finalFooterSpaces: [Int] = []
                
                var found = false
                for ep in (0...footerEdgePadMax).reversed() {
                    let remainingSpace = W - 2 - (2 * ep) - totalItemLen
                    if remainingSpace >= 0 {
                        finalFooterEdgePad = ep
                        
                        let base = remainingSpace / (N - 1)
                        let rem = remainingSpace % (N - 1)
                        var spaces: [Int] = []
                        for i in 1...(N - 1) {
                            let extra = i <= rem ? 1 : 0
                            spaces.append(base + extra)
                        }
                        finalFooterSpaces = spaces
                        found = true
                        break
                    }
                }
                
                if !found {
                    finalFooterEdgePad = 0
                    let remainingSpace = max(0, W - 2 - totalItemLen)
                    let base = remainingSpace / (N - 1)
                    let rem = remainingSpace % (N - 1)
                    var spaces: [Int] = []
                    for i in 1...(N - 1) {
                        let extra = i <= rem ? 1 : 0
                        spaces.append(base + extra)
                    }
                    finalFooterSpaces = spaces
                }
                
                var colored = String(repeating: " ", count: finalFooterEdgePad) + footerItems[0].colored
                for i in 0..<(N - 1) {
                    let spaceCount = finalFooterSpaces[i]
                    let sep = String(repeating: " ", count: spaceCount)
                    colored += sep + footerItems[i + 1].colored
                }
                colored += String(repeating: " ", count: finalFooterEdgePad)
                coloredFooterText = colored
            }
            
        case .enteringInterval(let buf):
            if W >= 60 {
                coloredFooterText = "    ⌨️  \(ANSI.yellow)\(ANSI.bold)Interval (1-10s):\(ANSI.reset) \(buf)\(ANSI.bold)\(ANSI.yellow)█\(ANSI.reset)  \(ANSI.darkGray)[Esc]\(ANSI.reset)    "
            } else {
                coloredFooterText = "    \(ANSI.yellow)\(ANSI.bold)Int:\(ANSI.reset) \(buf)\(ANSI.bold)\(ANSI.yellow)█\(ANSI.reset)  \(ANSI.darkGray)Esc\(ANSI.reset)    "
            }
            
        case .enteringManualPct(let buf):
            if W >= 60 {
                coloredFooterText = "    ⌨️  \(ANSI.yellow)\(ANSI.bold)Fan Speed (0-100%):\(ANSI.reset) \(buf)\(ANSI.bold)\(ANSI.yellow)█\(ANSI.reset)  \(ANSI.darkGray)[Esc]\(ANSI.reset)    "
            } else {
                coloredFooterText = "    \(ANSI.yellow)\(ANSI.bold)Fan:\(ANSI.reset) \(buf)\(ANSI.bold)\(ANSI.yellow)█\(ANSI.reset)  \(ANSI.darkGray)Esc\(ANSI.reset)    "
            }
        }
        
        lines.append(boxLineRaw(coloredFooterText))
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
                let warningText = W >= 60 ? "  ⚠️   Terminal too short; some sensors hidden" : "  ⚠️   Terminal too short"
                lines.append(boxLineRaw("\(ANSI.red)\(warningText)\(ANSI.reset)"))
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

private var gShouldExit: sig_atomic_t = 0
private var rawModeEnabled = false
private var cleanExitCalled = false

/// Restores fans to auto, disables raw mode, and safely shuts down SMC.
func cleanExit(_ code: Int32 = 0) -> Never {
    // Idempotency guard to prevent nested exit calls during fatal signal termination
    if cleanExitCalled {
        exit(code)
    }
    cleanExitCalled = true

    var attemptedFanRestore = false
    var restoredFans = false
    if let fans = gFans, hasWrittenFanControl {
        attemptedFanRestore = true
        restoredFans = fans.restoreAuto()
        if !restoredFans {
            fputs("\n\(ANSI.red)\(ANSI.bold)WARNING:\(ANSI.reset) Failed to restore fans to automatic control! Please reboot your Mac to guarantee hardware safety.\n", stderr)
            fflush(stderr)
        }
    }
    
    if rawModeEnabled {
        disableRawMode()
    }
    
    // Reset console colors to default
    print(ANSI.reset, terminator: "")
    if code == 0 {
        if attemptedFanRestore && restoredFans {
            print("\n\(ANSI.green)\(ANSI.bold)FanPro:\(ANSI.reset) Exited, fans restored to system default automatic mode. ✅")
        } else if attemptedFanRestore {
            print("\n\(ANSI.yellow)\(ANSI.bold)FanPro:\(ANSI.reset) Exited, but fan auto-restore failed. Please reboot to guarantee hardware safety. ⚠️")
        } else {
            print("\n\(ANSI.green)\(ANSI.bold)FanPro:\(ANSI.reset) Exited. ✅")
        }
    } else {
        if attemptedFanRestore && restoredFans {
            print("\n\(ANSI.red)\(ANSI.bold)FanPro:\(ANSI.reset) Terminated abnormally (exit code \(code)). Restored terminal and fans. ⚠️")
        } else if attemptedFanRestore {
            print("\n\(ANSI.red)\(ANSI.bold)FanPro:\(ANSI.reset) Terminated abnormally (exit code \(code)). Fan auto-restore failed. Please reboot to guarantee hardware safety. ⚠️")
        } else {
            print("\n\(ANSI.red)\(ANSI.bold)FanPro:\(ANSI.reset) Terminated abnormally (exit code \(code)). Restored terminal. ⚠️")
        }
    }
    fflush(stdout)
    gSMC?.close()
    exit(code)
}

// ============================================================================
// MARK: - Entry Point
// ============================================================================

// Check child privilege bypass
if CommandLine.arguments.contains("--is-sudo-child") {
    if getuid() != 0 {
        // Child failed to acquire root, exit immediately to signal parent for fallback
        exit(100)
    }
}

/// Resolve the absolute file path of this executing command or script.
private func getSelfPath() -> String? {
    let arg0 = CommandLine.arguments[0]
    var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
    if realpath(arg0, &resolved) != nil {
        return String(cString: resolved)
    }
    return Bundle.main.executablePath
}

/// Spawns a child process with sudo using posix_spawn and waits for it.
/// Returns true if child successfully executed and exited with code 0.
private func runWithSudo(exePath: String, originalArgs: [String]) -> Bool {
    var newArgs = ["sudo", exePath, "--is-sudo-child"]
    let filteredOriginal = originalArgs.filter { $0 != "--readonly" && $0 != "--is-sudo-child" }
    if filteredOriginal.count > 1 {
        newArgs.append(contentsOf: filteredOriginal.suffix(from: 1))
    }
    
    let cArgs = newArgs.map { $0.withCString(strdup) }
    var argsForSpawn = cArgs + [nil]
    
    let env = ProcessInfo.processInfo.environment
    let cEnv = env.map { "\($0.key)=\($0.value)".withCString(strdup) }
    var envForSpawn = cEnv + [nil]
    
    defer {
        for ptr in cArgs { free(ptr) }
        for ptr in cEnv { free(ptr) }
    }
    
    fflush(stdout)
    fflush(stderr)
    
    // Ignore SIGINT in the parent process while waitpid is blocking on sudo child.
    // This guarantees the parent won't be killed by Ctrl-C inside the password prompt.
    let oldIntHandler = signal(SIGINT, SIG_IGN)
    
    var pid: pid_t = 0
    let spawnStatus = posix_spawn(&pid, "/usr/bin/sudo", nil, nil, &argsForSpawn, &envForSpawn)
    if spawnStatus != 0 {
        signal(SIGINT, oldIntHandler)
        return false
    }
    
    var status: Int32 = 0
    let waitResult = waitpid(pid, &status, 0)
    
    // Restore signal handlers immediately after waitpid returns
    signal(SIGINT, oldIntHandler)
    
    guard waitResult == pid else { return false }
    
    func WIFEXITED(_ status: Int32) -> Bool { return (status & 0x7F) == 0 }
    func WEXITSTATUS(_ status: Int32) -> Int32 { return (status >> 8) & 0xFF }
    
    if WIFEXITED(status) {
        let code = WEXITSTATUS(status)
        if code == 0 {
            exit(0) // Child executed and finished successfully
        }
    }
    return false // Sudo execution failed or canceled by user
}

// 0. Verify struct size (compile-time sanity check)
assert(MemoryLayout<SMCParamStruct>.stride == 80,
       "SMCParamStruct stride is \(MemoryLayout<SMCParamStruct>.stride), expected 80")

// Determine if we should force readonly mode
forceReadonly = CommandLine.arguments.contains("--readonly")
let startupHasFans = deviceHasFansForStartupProbe()
if getuid() != 0 && !forceReadonly && startupHasFans {
    if let selfPath = getSelfPath() {
        let originalArgs = CommandLine.arguments
        // Attempt to run with sudo
        let success = runWithSudo(exePath: selfPath, originalArgs: originalArgs)
        if !success {
            // Sudo cancelled or failed, fallback to readonly mode
            forceReadonly = true
        }
    } else {
        forceReadonly = true
    }
}

// 1. Signal handlers for clean exit on Ctrl-C / kill / crashes
signal(SIGINT)  { _ in gShouldExit = 1 }
signal(SIGTERM) { _ in gShouldExit = 1 }

// Fatal handlers avoid Swift runtime work: restore the default handler and re-raise.
private func fatalSignalHandler(sig: Int32) {
    signal(sig, SIG_DFL)
    raise(sig)
}

signal(SIGSEGV) { fatalSignalHandler(sig: $0) }
signal(SIGBUS)  { fatalSignalHandler(sig: $0) }
signal(SIGILL)  { fatalSignalHandler(sig: $0) }
signal(SIGFPE)  { fatalSignalHandler(sig: $0) }
signal(SIGABRT) { fatalSignalHandler(sig: $0) }

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
let canControlFans = getuid() == 0 && !forceReadonly && fanCtrl.hasFans

// 4. Print launch banner (will be replaced by TUI on first render)
if getuid() != 0 && fanCtrl.hasFans {
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
var lastRefresh = Date(timeIntervalSince1970: 0) // Force immediate refresh on start
var needRender = true

while running {
    if gShouldExit != 0 {
        break
    }
    
    // Determine if we need to refresh data from SMC & IOHID based on the user-defined interval
    let now = Date()
    if now.timeIntervalSince(lastRefresh) >= Double(dash.interval) {
        tempMon.refreshAll()
        // RPM readings only require SMC read capability (no root needed), so refresh in all modes
        fanCtrl.refreshAll()
        
        if canControlFans {
            if fanCtrl.isPerformance {
                fanCtrl.updatePerformanceCooling(peakTemp: tempMon.coolingPeakTemp, interval: dash.interval)
            }
        }
        lastRefresh = now
        needRender = true
    }
    
    if needRender {
        dash.render()
        needRender = false
    }
    
    let pollTimeout: Int32
    switch gInputMode {
    case .normal:
        let elapsed = Date().timeIntervalSince(lastRefresh)
        let remainingMs = max(0, Int((Double(dash.interval) - elapsed) * 1000))
        pollTimeout = Int32(min(1000, max(50, remainingMs)))
    default:
        pollTimeout = 100
    }
    
    // Poll for key presses while sleeping until the next scheduled refresh.
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    let pr = poll(&pfd, 1, pollTimeout)
    
    if pr < 0 {
        if errno == EINTR {
            // Signal interruption (e.g. SIGWINCH on window resize).
            // We need to re-render the dashboard because winsize might have changed.
            needRender = true
            // Yield CPU briefly to prevent high-frequency tight spin loops.
            Thread.sleep(forTimeInterval: 0.02)
        }
        continue
    }
    
    guard pr > 0, (pfd.revents & Int16(POLLIN)) != 0 else {
        continue
    }
    
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else {
        continue
    }
    
    // Process input based on state machine
    switch gInputMode {
    case .normal:
        let char = Character(UnicodeScalar(byte))
        switch char {
        case "q", "Q":
            running = false

        case "i", "I":
            gInputMode = .enteringInterval(buffer: "")
            needRender = true

        case "f", "F":
            if canControlFans {
                gInputMode = .enteringManualPct(buffer: "")
            } else {
                break
            }
            needRender = true
        case "s", "S":
            if canControlFans {
                _ = fanCtrl.enablePerformanceMode()
                // Force immediate refresh and application of performance cooling
                tempMon.refreshAll()
                fanCtrl.refreshAll()
                fanCtrl.updatePerformanceCooling(peakTemp: tempMon.coolingPeakTemp, interval: dash.interval)
                lastRefresh = Date()
            }
            needRender = true
        case "a", "A":
            if canControlFans {
                _ = fanCtrl.restoreAuto()
                // Force immediate refresh
                tempMon.refreshAll()
                fanCtrl.refreshAll()
                lastRefresh = Date()
            }
            needRender = true
        default:
            break
        }
        
    case .enteringInterval(var buf):
        needRender = true
        switch byte {
        case 10, 13: // Enter key
            if let val = Int(buf), val >= 1, val <= 10 {
                dash.interval = val
            }
            gInputMode = .normal
        case 27: // Escape key
            gInputMode = .normal
        case 127, 8: // Backspace
            if !buf.isEmpty {
                buf.removeLast()
                gInputMode = .enteringInterval(buffer: buf)
            }
        case 48...57: // Only allow digits '0'-'9' for interval
            if buf.count < 5 { // Avoid buffer overflow
                buf.append(Character(UnicodeScalar(byte)))
                gInputMode = .enteringInterval(buffer: buf)
            }
        default:
            break
        }
        
    case .enteringManualPct(var buf):
        needRender = true
        switch byte {
        case 10, 13: // Enter key
            if let pct = Int(buf), pct >= 0, pct <= 100 {
                _ = fanCtrl.setPercentage(pct)
                // Force immediate refresh
                tempMon.refreshAll()
                fanCtrl.refreshAll()
                lastRefresh = Date()
            }
            gInputMode = .normal
        case 27: // Escape key
            gInputMode = .normal
        case 127, 8: // Backspace
            if !buf.isEmpty {
                buf.removeLast()
                gInputMode = .enteringManualPct(buffer: buf)
            }
        case 48...57: // Only allow digits '0'-'9'
            if buf.count < 3 { // Percentage is at most 3 digits
                buf.append(Character(UnicodeScalar(byte)))
                gInputMode = .enteringManualPct(buffer: buf)
            }
        default:
            break
        }
    }
}

cleanExit()
