import Combine
import ServiceManagement

@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
    func openSettings()
}

@MainActor
private final class SystemLoginItemService: LoginItemService {
    var status: SMAppService.Status { SMAppService.mainApp.status }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// Always opt-in. Reading/refreshing this model never registers a login item.
@MainActor
final class LoginItemModel: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastError: String?
    private let service: any LoginItemService

    init(service: any LoginItemService) {
        self.service = service
        status = service.status
    }

    convenience init() { self.init(service: SystemLoginItemService()) }

    static func preview(status: SMAppService.Status = .notRegistered) -> LoginItemModel {
        LoginItemModel(service: PreviewLoginItemService(status: status))
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    func refresh() { status = service.status }
    func openSettings() { service.openSettings() }

    func set(_ on: Bool) {
        refresh()
        guard on != isOn else { return }
        do {
            if on { try service.register() } else { try service.unregister() }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
    }
}

@MainActor
private final class PreviewLoginItemService: LoginItemService {
    var status: SMAppService.Status
    init(status: SMAppService.Status) { self.status = status }
    func register() throws { status = .enabled }
    func unregister() throws { status = .notRegistered }
    func openSettings() {}
}
