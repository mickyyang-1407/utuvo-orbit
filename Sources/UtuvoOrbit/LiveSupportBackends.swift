import AppKit
import CoreWLAN
import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import OrbitCore

// LiveNetworkBackend lives in LiveNetworkBackend.swift (InterfaceCounters and
// LocalIPLookup helpers moved with it).

// MARK: - LiveSystemBackend

public final class LiveSystemBackend: SystemBackend, @unchecked Sendable {
    private let previousCPU = Box<CPUTicks?>(nil)
    private let history = Box<[Double]>([])
    private let capacity: Int
    private let queue = DispatchQueue(label: "com.utuvo.orbit.system", qos: .utility)

    public init(historyCapacity: Int = 60) { self.capacity = historyCapacity }

    public func metrics(historyCapacity: Int) -> SystemMetrics {
        let cap = max(1, historyCapacity)
        let evidence = hardwareEvidence()
        let model = modelIdentifier()
        let (used, total) = Self.memoryUsage()
        let ticks = Self.readCPU()
        // Single-locked capture: read the previous CPU ticks, compute the
        // delta, store the new ticks — all inside one critical section. The
        // previous implementation called Box.read while already holding the
        // lock from Box.mutate, which deadlocks an NSLock. NSRecursiveLock
        // prevents the hang, but transform keeps everything in one acquisition
        // so we never depend on the recursive behaviour.
        let cpuUsage: Double? = previousCPU.transform { previous, newValue in
            guard let ticks else {
                // A failed read must also clear the baseline — otherwise
                // the NEXT successful read computes its delta across
                // whatever interval the failure spanned (silently averaged
                // in as if it were a normal, uninterrupted sample) instead
                // of correctly starting fresh with an "unknown" first
                // sample, exactly like a real wake reset.
                newValue = nil
                return nil
            }
            let value: Double? = previous.flatMap { ticks.usage(since: $0) }
            newValue = ticks
            return value
        }
        let newHistory: [Double] = history.transform { current, newValue in
            let next = CPUHistory.append(current, sample: cpuUsage, capacity: cap)
            newValue = next
            return next
        }
        let battery = Self.readBattery()
        return SystemMetrics(cpuUsage: cpuUsage, cpuHistory: newHistory,
                             usedBytes: used, totalBytes: total, battery: battery,
                             machine: evidence.kind, model: model)
    }

    public func modelIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 1 else { return "未知 Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "未知 Mac" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    public func hardwareEvidence() -> HardwareEvidence {
        let model = modelIdentifier()
        let power = Self.readPower()
        let lid = Self.readLid()
        return HardwareEvidence(model: model, hasInternalBattery: power.present, hasLid: lid.hasLid,
                                powerReadSucceeded: power.succeeded, registryReadSucceeded: lid.succeeded)
    }

    /// Clears the cached previous CPU ticks so the next `metrics(historyCapacity:)`
    /// call treats it as a first sample (nil usage) instead of computing a
    /// delta across a real sleep — actually wired from `SystemMonitor`'s wake
    /// observer now, not the previously-unused local variable it reset before.
    public func reset() {
        previousCPU.mutate { $0 = nil }
        // Wake must clear the CPU trend history too, not just the delta
        // baseline — leaving stale pre-sleep samples in `history` would
        // keep showing them in the sparkline right alongside the fresh
        // post-wake ones as if they were a single continuous interval.
        history.mutate { $0 = [] }
    }

    // MARK: - Helpers

    private static func readCPU() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let t = info.cpu_ticks
        return CPUTicks(busy: UInt64(t.0) + UInt64(t.1) + UInt64(t.3), idle: UInt64(t.2))
    }

    private static func memoryUsage() -> (UInt64?, UInt64?) {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return (nil, nil) }
        let pageSize = UInt64(Darwin.sysconf(Darwin._SC_PAGESIZE))
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active &+ wired &+ compressed
        let total = ProcessInfo.processInfo.physicalMemory
        return (used, total)
    }

    private static func readPower() -> (present: Bool, succeeded: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, false)
        }
        var descriptions = [[String: Any]]()
        for source in sources {
            // IOPSGetPowerSourceDescription's returned CFDictionary is owned
            // by `info` (IOPSCopyPowerSourcesInfo) — takeUnretainedValue,
            // not takeRetainedValue, or this over-releases the description
            // on hardware with real power sources.
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                return (false, false)
            }
            descriptions.append(d)
        }
        let result = PowerTelemetry.internalBattery(in: descriptions)
        return (result.present, true)
    }

    private static func readLid() -> (hasLid: Bool, succeeded: Bool) {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return (false, false) }
        defer { IOObjectRelease(root) }
        let property = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (property != nil, true)
    }

    private static func readBattery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        var descriptions = [[String: Any]]()
        for source in sources {
            // Same ownership rule as readPower() above.
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return nil }
            descriptions.append(d)
        }
        return PowerTelemetry.internalBattery(in: descriptions).reading
    }
}

// MARK: - Live Awake assertion driver + scheduler
//
// Uses the real `import IOKit.pwr_mgt` overlay — IOPMAssertionCreateWithProperties
// plus the real kIOPMAssertion*Key constants — instead of hand-typed
// dictionary key strings. The previous implementation used "Name"/"Type"/
// "Level"/"Timeout" which are not the real IOPM keys (verified against the
// SDK overlay: kIOPMAssertionNameKey == "AssertName", kIOPMAssertionTypeKey
// == "AssertType", kIOPMAssertionLevelKey == "AssertLevel",
// kIOPMAssertionTimeoutKey == "TimeoutSeconds"); those calls have always
// failed against the real API. We attach kIOPMAssertionTimeoutKey +
// kIOPMAssertionTimeoutActionKey = Release so the OS itself enforces a
// finite lifetime even if this process is killed before the in-process
// timer fires.

public final class LiveIOPMAssertionDriver: AwakeAssertionDriver, @unchecked Sendable {
    public init() {}

    public func createAssertion(name: String, type: String, level: UInt32,
                                timeoutSeconds: UInt32, timeoutAction: String) -> (status: Int32, id: UInt32) {
        let properties: [String: Any] = [
            kIOPMAssertionNameKey as String: name as CFString,
            kIOPMAssertionTypeKey as String: type as CFString,
            kIOPMAssertionLevelKey as String: NSNumber(value: level),
            kIOPMAssertionTimeoutKey as String: NSNumber(value: timeoutSeconds),
            kIOPMAssertionTimeoutActionKey as String: timeoutAction as CFString
        ]
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
        return (status, id)
    }

    public func releaseAssertion(_ id: UInt32) -> Int32 {
        IOPMAssertionRelease(IOPMAssertionID(id))
    }
}

/// Real `Timer` + `RunLoop.main` scheduler. Independent of the popover/panel
/// being open — the timer lives on the controller, not on any view.
public final class LiveAwakeScheduler: AwakeScheduler, @unchecked Sendable {
    public init() {}

    public func schedule(after seconds: TimeInterval, _ fire: @escaping @Sendable () -> Void) -> AnyObject {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in fire() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    public func cancel(_ token: AnyObject) {
        (token as? Timer)?.invalidate()
    }
}

public func makeLiveAwakeBackend() -> AwakeBackend {
    AwakeController(driver: LiveIOPMAssertionDriver(), scheduler: LiveAwakeScheduler())
}
