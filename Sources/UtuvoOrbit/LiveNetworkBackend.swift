import Darwin
import Foundation
import Network
import OrbitCore

// MARK: - LiveNetworkBackend
//
// Reads the active route through NWPathMonitor (picked by `usesInterfaceType`,
// not `availableInterfaces.first`) and the matching byte counters from
// `getifaddrs(3)`. Counter reads are gated on the active interface being
// non-nil — we never sum all interfaces — and on `ifa_data` being present.

public final class LiveNetworkBackend: NetworkBackend, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.utuvo.orbit.network", qos: .utility)
    private let state = Box<PathState>(PathState())

    public init() {
        monitor.pathUpdateHandler = { [state] path in
            let connection: Connection
            if path.status != .satisfied {
                connection = .offline
            } else if path.usesInterfaceType(.wiredEthernet) {
                connection = .ethernet
            } else if path.usesInterfaceType(.wifi) {
                connection = .wifi
            } else if path.usesInterfaceType(.cellular) {
                connection = .other
            } else {
                connection = .other
            }
            let interfaceName = Self.preferredInterfaceName(for: path)
            state.mutate { snapshot in
                snapshot.interfaceName = interfaceName
                snapshot.connection = connection
            }
        }
        monitor.start(queue: queue)
    }

    public func currentReading() -> NetworkReading {
        let path = state.read { $0 }
        let counters = InterfaceCounters.snapshot(interfaceName: path.interfaceName)
        let ip = LocalIPLookup.currentIPv4(interfaceName: path.interfaceName)
        let reachable = path.connection != .offline && path.connection != .checking
        return NetworkReading(
            interfaceName: path.interfaceName,
            interfaceType: path.connection,
            localIPv4: ip,
            isReachable: reachable,
            receivedBytes: counters.receivedBytes,
            sentBytes: counters.sentBytes,
            timestamp: Date(),
            monotonicSeconds: MonotonicClock.now(),
            // Offline/checking are inherently counter-less regardless of
            // what a stale getifaddrs read might return; otherwise validity
            // comes straight from whether the read actually found the
            // target interface's link-layer counters.
            countersValid: reachable && counters.valid)
    }

    private struct PathState {
        var interfaceName: String?
        var connection: Connection = .checking
    }

    /// Pick the interface name reported by NWPathMonitor using
    /// `usesInterfaceType` so Ethernet never shows up as Wi-Fi. Falls back to
    /// `availableInterfaces.first` only when the path is satisfied but no
    /// typed interface matches — this preserves the original v0.1 behaviour
    /// for uncommon types (VPN, bridge).
    private static func preferredInterfaceName(for path: NWPath) -> String? {
        if path.usesInterfaceType(.wiredEthernet) {
            return path.availableInterfaces.first(where: { $0.type == .wiredEthernet })?.name
                ?? path.availableInterfaces.first?.name
        }
        if path.usesInterfaceType(.wifi) {
            return path.availableInterfaces.first(where: { $0.type == .wifi })?.name
                ?? path.availableInterfaces.first?.name
        }
        if path.usesInterfaceType(.cellular) {
            return path.availableInterfaces.first(where: { $0.type == .cellular })?.name
                ?? path.availableInterfaces.first?.name
        }
        return path.availableInterfaces.first?.name
    }
}

// MARK: - InterfaceCounters
//
// Reads `struct if_data` for the requested interface only — never sums
// across interfaces. Guards on non-nil `ifa_data` so a half-initialised
// routing table cannot corrupt the throughput calc.

enum InterfaceCounters {
    struct Snapshot {
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        /// True only once we actually located `target` in the `getifaddrs`
        /// list with a link-layer address and non-nil `ifa_data` and read
        /// its counters. `getifaddrs` failure, a target that never appears,
        /// or every matching entry lacking `ifa_data` all leave this false —
        /// `receivedBytes`/`sentBytes` stay at their `0` default, which must
        /// NOT be read as "confirmed zero traffic".
        var valid = false
    }

    static func snapshot(interfaceName: String?) -> Snapshot {
        var snapshot = Snapshot()
        guard let target = interfaceName, !target.isEmpty else { return snapshot }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return snapshot }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let ifa = pointer.pointee
            let name = String(cString: ifa.ifa_name)
            guard name == target else { cursor = ifa.ifa_next; continue }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else {
                cursor = ifa.ifa_next; continue
            }
            guard let rawData = ifa.ifa_data else {
                cursor = ifa.ifa_next; continue
            }
            let data = rawData.assumingMemoryBound(to: if_data.self)
            snapshot.receivedBytes &+= UInt64(data.pointee.ifi_ibytes)
            snapshot.sentBytes &+= UInt64(data.pointee.ifi_obytes)
            snapshot.valid = true
            cursor = ifa.ifa_next
        }
        return snapshot
    }
}

// MARK: - LocalIPLookup
//
// Best-effort lookup of the IPv4 address bound to the active interface. No
// SSID, no location services, no external network calls.

enum LocalIPLookup {
    static func currentIPv4(interfaceName: String?) -> String? {
        guard let target = interfaceName, !target.isEmpty else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = cursor {
            let ifa = pointer.pointee
            let name = String(cString: ifa.ifa_name)
            guard name == target else { cursor = ifa.ifa_next; continue }
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else {
                cursor = ifa.ifa_next; continue
            }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                     &host, socklen_t(host.count),
                                     nil, 0, NI_NUMERICHOST)
            if result == 0 {
                let trimmed = String(cString: host)
                return trimmed.isEmpty ? nil : trimmed
            }
            cursor = ifa.ifa_next
        }
        return nil
    }
}

// MARK: - MonotonicClock
//
// Uses `mach_continuous_time`, NOT `mach_absolute_time`, so the delta math is
// robust against wall-clock jumps (NTP, manual clock change, DST) AND keeps
// counting through system sleep. `mach_absolute_time` freezes for the
// duration of sleep, so a reading taken right before sleep and one taken
// right after wake would report an interval near zero (correctly triggering
// `NetworkMath.delta`'s reset guard by accident) instead of the real elapsed
// gap that `delta`'s explicit >10s upper bound is meant to catch.

enum MonotonicClock {
    static func now() -> Double {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // Widen to Double before multiplying — ticks * numer as UInt64 could
        // in principle overflow on a long-uptime Intel Mac where numer/denom
        // isn't 1:1; Double has ample range for a seconds-since-boot value.
        let ticks = Double(mach_continuous_time())
        return ticks * Double(timebase.numer) / Double(timebase.denom) / 1e9
    }
}