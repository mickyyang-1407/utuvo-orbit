import Combine
import Foundation
import OrbitCore

struct ReminderSettings: Codable, Equatable {
    var macLow = true
    var charged = true
    var peripheralLow = true
    var networkLost = true
    var threshold = 20
    var chargedThreshold = 95
    var valid: Bool { (5...50).contains(threshold) && (80...100).contains(chargedThreshold) }
}

struct ReminderEvent: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let body: String
}

/// Edge-triggered, rearmed only after recovery. Unknown telemetry never invents an edge.
struct ReminderEngine {
    private var lowMac = false
    private var fullMac = false
    private var lowDevices = Set<String>()
    private var lastConnection: Connection?
    mutating func consume(_ snapshot: StatusSnapshot, peripherals: [Peripheral], settings: ReminderSettings, copy c: ToolCopy) -> [String] {
        var output: [String] = []
        if snapshot.machine == .laptop, let battery = snapshot.battery, let fraction = battery.fraction, fraction.isFinite, (0...1).contains(fraction) {
            let low = !battery.onAC && !battery.charging && fraction <= Double(settings.threshold) / 100
            if low && !lowMac && settings.macLow { output.append(c("Mac 電量偏低", "Mac battery is low") + " · \(Int(fraction * 100))%") }
            if battery.onAC || battery.charging || fraction > Double(settings.threshold + 5) / 100 { lowMac = false }
            if low { lowMac = true }
            let full = battery.onAC && fraction >= Double(settings.chargedThreshold) / 100
            if full && !fullMac && settings.charged { output.append(c("Mac 已充電至", "Mac charged to") + " \(Int(fraction * 100))%") }
            if !battery.onAC || fraction < Double(settings.chargedThreshold - 5) / 100 { fullMac = false }
            if full { fullMac = true }
        }
        for device in peripherals {
            guard let fraction = device.fraction else { continue }
            let low = fraction <= Double(settings.threshold) / 100 && device.charging != .charging
            if low, !lowDevices.contains(device.id), settings.peripheralLow { output.append(device.name + " · " + c("電量偏低", "Low battery") + " \(Int(fraction * 100))%") }
            if low { lowDevices.insert(device.id) }
            else if device.charging == .charging || fraction > Double(settings.threshold + 5) / 100 { lowDevices.remove(device.id) }
        }
        // Keep disconnected identities latched to avoid a reconnect notification storm.
        if snapshot.connection != .checking {
            if snapshot.connection == .offline, let previous = lastConnection, previous != .offline, settings.networkLost {
                output.append(c("網路已中斷", "Network disconnected"))
            }
            lastConnection = snapshot.connection
        }
        return output
    }
}

@MainActor
final class SmartRemindersModel: ObservableObject {
    @Published var settings: ReminderSettings { didSet { do { try storage.save(settings) } catch { self.error = error.localizedDescription }; engine = ReminderEngine() } }
    @Published private(set) var enabled = false
    @Published private(set) var history: [ReminderEvent] = []
    @Published private(set) var error: String?
    var language: AppLanguage = .system
    private var engine = ReminderEngine()
    private let storage: ToolStorage<ReminderSettings>
    private let defaults: UserDefaults?
    private let notifications: any OrbitTimerNotifications
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var pending = false
    private var suspended = false
    var needsRecovery: Bool { storage.damaged }
    init(defaults: UserDefaults?, notifications: any OrbitTimerNotifications) {
        self.defaults = defaults; self.notifications = notifications
        storage = ToolStorage(defaults, "tools.reminders.settings")
        settings = storage.load(fallback: ReminderSettings(), validate: \.valid)
        enabled = !storage.damaged && (defaults?.bool(forKey: "tools.reminders.enabled") ?? false)
    }
    func setEnabled(_ value: Bool) {
        generation = UUID(); request?.cancel(); pending = false; engine = ReminderEngine()
        enabled = false; defaults?.set(false, forKey: "tools.reminders.enabled")
        guard value, !needsRecovery else { return }
        pending = true
        let token = generation
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = try await notifications.request()
                guard !Task.isCancelled, generation == token else { return }
                pending = false; enabled = allowed; defaults?.set(allowed, forKey: "tools.reminders.enabled")
                if !allowed { error = ToolCopy(language: language)("請在系統設定允許通知。", "Allow notifications in System Settings.") }
            } catch { if generation == token { pending = false; self.error = error.localizedDescription } }
        }
    }
    var requesting: Bool { pending }
    func consume(_ snapshot: StatusSnapshot, peripherals: [Peripheral]) {
        guard enabled, !suspended, settings.valid else { return }
        let events = engine.consume(snapshot, peripherals: peripherals, settings: settings, copy: ToolCopy(language: language))
        let token = generation
        for body in events {
            history.insert(ReminderEvent(body: body), at: 0); history = Array(history.prefix(20))
            Task { [weak self] in
                guard let self, enabled, !suspended, generation == token else { return }
                do {
                    let delivered = try await notifications.deliver(body)
                    if !delivered, generation == token { error = ToolCopy(language: language)("通知未允許；事件仍會留在清單。", "Notifications are not allowed; the event remains in this list.") }
                } catch { if generation == token { self.error = error.localizedDescription } }
            }
        }
    }
    func recover() { do { try storage.backupAndReset(ReminderSettings()); settings = ReminderSettings(); error = nil } catch { self.error = error.localizedDescription } }
    func clear() { history = [] }
    func stop() { generation = UUID(); request?.cancel() }
    func setSuspended(_ value: Bool) { suspended = value; generation = UUID(); request?.cancel(); pending = false; engine = ReminderEngine() }
}
