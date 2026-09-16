import Foundation
import IOKit
import OrbitCore

// MARK: - LivePeripheralBackend
//
// Best-effort, read-only peripheral battery reporting via
// `AppleDeviceManagementHIDEventService` — this is NOT a guaranteed-stable
// public API contract (confirmed on-device via `ioreg -a -r -c
// AppleDeviceManagementHIDEventService`, which exposed `Product`/
// `BatteryPercent`/`Transport` for a trackpad and keyboard on this
// machine). Our actual devices expose vendor-specific
// PrimaryUsagePage=65280/PrimaryUsage=11 — ambiguous, not absent — so
// `classify` genuinely falls through to the name heuristic for them; that
// is not a bug to "fix" by guessing at an undocumented vendor page. Never
// infers charging from `BatteryStatusFlags` bit patterns or from
// USB-vs-Bluetooth transport — charging is always `.unknown` here, since
// nothing observed on this machine's registry reliably exposes it. No
// private frameworks, no CoreBluetooth/TCC, no synthetic AirPods/iPhone
// entries.
//
// Charging (ORBIT-004 C): enriches a CURRENT HID entry's `charging` field
// by exact-matching its own `SerialNumber` against `pmset -g accps -xml`'s
// `Accessory Identifier` — see `AccessoryChargingSource.swift` for the full
// evidence and matching rules. `DeviceAddress` was deliberately NOT added
// as a second candidate token: root's evidence only confirmed a
// `SerialNumber` match on this machine, and "implement only verified
// mapping" means not extending the token set on an unverified guess.
public final class LivePeripheralBackend: PeripheralBackend, @unchecked Sendable {
    private let statusBox = Box(PeripheralReadStatus(available: true))
    private let chargingExecutor: AccessoryChargingExecutor

    public convenience init() {
        self.init(chargingExecutor: PMSetAccessoryChargingExecutor())
    }

    /// Test-only injection point — a fake executor never launches a real
    /// process.
    init(chargingExecutor: AccessoryChargingExecutor) {
        self.chargingExecutor = chargingExecutor
    }

    /// `currentPeripherals()` performs a COMPLETE, consistent read —
    /// including a fresh charging fetch when the throttle says it's due —
    /// and returns ONE full result, never a stale placeholder that gets
    /// "published later" behind the caller's back. Root's own review:
    /// a previous fire-and-forget background design meant `--diagnose`
    /// (which constructs a backend, calls this ONCE, and exits) could
    /// never observe real charging at all, and the live coordinator would
    /// show 30s of `.unknown` on every launch even when truly charging.
    /// This DOES mean a call that lands on the throttle boundary can block
    /// the CALLING thread for up to the executor's own timeout — callers
    /// on the main actor (`SystemMonitor`) are responsible for invoking
    /// this off-main; `--diagnose`'s one-shot CLI path may call it
    /// synchronously, since it already has its own bounded watchdog.
    public func currentPeripherals() -> [Peripheral] {
        guard let matching = IOServiceMatching("AppleDeviceManagementHIDEventService") else {
            statusBox.mutate { $0 = PeripheralReadStatus(available: false, errorNote: "IOServiceMatching 建立失敗") }
            return []
        }
        var iterator: io_iterator_t = 0
        // `IOServiceGetMatchingServices` is a "Get" in name only — IOKit
        // hands back an iterator YOU own; despite the name it is not a
        // borrowed reference. Always released below.
        let matchResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard matchResult == KERN_SUCCESS else {
            statusBox.mutate { $0 = PeripheralReadStatus(available: false, errorNote: "IOServiceGetMatchingServices 失敗 (\(matchResult))") }
            return []
        }
        defer { IOObjectRelease(iterator) }

        let chargingRecords = currentChargingRecords()
        var results: [Peripheral] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            // Every object handed back by `IOIteratorNext` is likewise
            // owned by the caller and must be released once done with it —
            // regardless of what happens in `parse`.
            if let peripheral = Self.parse(service: service, chargingRecords: chargingRecords) {
                results.append(peripheral)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        // Matching itself succeeded (even if it found zero devices, or
        // devices that didn't parse) — this is a truthful empty result, not
        // a source failure, and must read as `available` to `--diagnose`.
        statusBox.mutate { $0 = PeripheralReadStatus(available: true) }
        return results
    }

    public func readStatus() -> PeripheralReadStatus { statusBox.read { $0 } }

    /// No cache and no throttle of its own: scheduling is entirely the
    /// coordinator's job (`SystemMonitor.refreshPeripheralsIfDue`, ~30s,
    /// forced on wake), so every read here is a fresh, bounded one. A
    /// second throttle on this side made a forced wake refresh return the
    /// pre-sleep records, and two independent clocks could stretch the
    /// effective refresh to ~60s. A failed read yields no records — never
    /// a remembered older value.
    /// `internal` (not `private`) so tests can exercise it with a fake
    /// executor, without `currentPeripherals()`'s real IOKit matching.
    func currentChargingRecords() -> [AccessoryChargingRecord] {
        guard let data = chargingExecutor.run(timeout: 2) else { return [] }
        return AccessoryChargingParser.parseAccessories(data)
    }

    /// `IORegistryEntryCreateCFProperty` follows the real CF ownership rule
    /// (`Create` = retained, `takeRetainedValue()`), unlike the io_object_t
    /// handles above.
    private static func copyProperty(_ service: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func parse(service: io_registry_entry_t, chargingRecords: [AccessoryChargingRecord]) -> Peripheral? {
        var entryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { return nil }
        let raw = RawPeripheralProperties(
            product: copyProperty(service, "Product"),
            batteryPercent: copyProperty(service, "BatteryPercent"),
            transport: copyProperty(service, "Transport"),
            usagePage: copyProperty(service, "PrimaryUsagePage"),
            usage: copyProperty(service, "PrimaryUsage"),
            serialNumber: copyProperty(service, "SerialNumber")
        )
        return parsePure(id: "hid-\(entryID)", raw: raw, chargingRecords: chargingRecords)
    }

    // MARK: - Pure raw-property parser
    //
    // Extracted so the SAME parsing logic the live IOKit backend uses is
    // exercised directly by tests with synthetic inputs (missing/wrong-type/
    // Boolean/nonfinite/out-of-range/unknown values) — not a separate
    // reimplementation that could silently drift from what `parse` actually
    // does.

    struct RawPeripheralProperties {
        var product: Any?
        var batteryPercent: Any?
        var transport: Any?
        var usagePage: Any?
        var usage: Any?
        /// The device's own stable identity token, matched EXACTLY (after
        /// normalization) against pmset's `Accessory Identifier` to
        /// resolve `charging` — never surfaced in any `Peripheral` field,
        /// UI, or log.
        var serialNumber: Any?
    }

    /// `Bool` freely bridges to `NSNumber` in Swift/Foundation, and so does
    /// CFBoolean — a bare `as? NSNumber` cast cannot tell "true" apart from
    /// a real numeric `1` (proven: `(true as Any) as? NSNumber` succeeds
    /// with `.doubleValue == 1`). Checked via the actual underlying CF type
    /// ID, not `objCType` — a genuine `Int8`-backed NSNumber also reports
    /// objCType `"c"`, identical to a boxed `Bool`, so that alone can't
    /// distinguish them either.
    static func numericValue(_ any: Any?) -> NSNumber? {
        guard let any else { return nil }
        let ref = any as CFTypeRef
        guard CFGetTypeID(ref) != CFBooleanGetTypeID() else { return nil }
        return any as? NSNumber
    }

    /// Missing, wrong-type/Boolean, and finite-but-out-of-range battery
    /// values are all rejected (never guessed at), but with DIFFERENT notes
    /// — a finite invalid value (e.g. a corrupt `140`) is a distinct,
    /// explainable failure from a genuinely absent key.
    static func parseBatteryPercent(_ any: Any?) -> (fraction: Double?, note: String?) {
        guard let any else { return (nil, "缺少電量欄位") }
        guard let number = numericValue(any) else { return (nil, "電量欄位型別錯誤") }
        let value = number.doubleValue / 100.0
        guard value.isFinite, value >= 0, value <= 1 else { return (nil, "電量數值超出範圍") }
        return (value, nil)
    }

    static func parsePure(id: String, raw: RawPeripheralProperties, chargingRecords: [AccessoryChargingRecord] = []) -> Peripheral? {
        guard let product = raw.product as? String, !product.isEmpty else { return nil }
        let (fraction, statusNote) = parseBatteryPercent(raw.batteryPercent)
        let transport = (raw.transport as? String) ?? "unknown"
        let usagePage = numericValue(raw.usagePage)?.intValue
        let usage = numericValue(raw.usage)?.intValue
        let kind = classify(name: product, usagePage: usagePage, usage: usage)
        let serial = raw.serialNumber as? String
        let charging = AccessoryChargingMatcher.resolve(candidateTokens: serial.map { [$0] } ?? [], records: chargingRecords)
        return Peripheral(id: id, name: product, kind: kind, fraction: fraction,
                          charging: charging, source: "AppleDeviceManagementHIDEventService(\(transport))",
                          statusNote: statusNote)
    }

    /// Prefers the HID usage page/usage codes (standard, documented in the
    /// USB HID Usage Tables) over a name heuristic when both are present;
    /// falls back to matching known product-name substrings; genuinely
    /// ambiguous devices (including this machine's own vendor-specific
    /// page 65280/usage 11 — present, just not one of the standard pages
    /// checked here) become `.other` rather than a guess.
    static func classify(name: String, usagePage: Int?, usage: Int?) -> PeripheralKind {
        if usagePage == 0x01 { // Generic Desktop page
            if usage == 0x06 { return .keyboard }
            if usage == 0x02 { return .mouse }
        }
        if usagePage == 0x0D, usage == 0x05 { return .trackpad } // Digitizer page, Touch Pad
        let lower = name.lowercased()
        if lower.contains("airpods") { return .airpods }
        if lower.contains("iphone") { return .iphone }
        if lower.contains("trackpad") { return .trackpad }
        if lower.contains("keyboard") { return .keyboard }
        if lower.contains("mouse") { return .mouse }
        return .other
    }
}
