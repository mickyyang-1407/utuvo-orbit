import AppKit
import Combine
import Foundation
#if !MAS
import Sparkle
#endif

struct OrbitUpdateState: Equatable {
    var canCheck = false
    var automaticChecks = false
    var automaticDownloads = false
    var lastCheck: Date?
    var error: String?
}

/// The production driver owns Sparkle's settings; tests and previews never
/// instantiate Sparkle or read/write the app's real defaults.
@MainActor
protocol OrbitUpdateDriver: AnyObject {
    var state: OrbitUpdateState { get }
    var didChange: (() -> Void)? { get set }
    func start() throws
    func check()
    func setAutomaticChecks(_ enabled: Bool)
    func setAutomaticDownloads(_ enabled: Bool)
}

@MainActor
final class OrbitUpdateModel: ObservableObject {
    enum Distribution: Equatable { case direct, appStore, unconfigured }
    let distribution: Distribution
    @Published private(set) var state = OrbitUpdateState()
    private let driver: (any OrbitUpdateDriver)?
    private var started = false

    init(distribution: Distribution, driver: (any OrbitUpdateDriver)? = nil) {
        self.distribution = distribution
        self.driver = distribution == .direct ? driver : nil
        self.driver?.didChange = { [weak self] in self?.refresh() }
        refresh()
    }

    static func live(bundle: Bundle = .main) -> OrbitUpdateModel {
        #if MAS
        return OrbitUpdateModel(distribution: .appStore)
        #else
        guard bundle.bundleURL.pathExtension == "app",
              validConfiguration(feed: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
                                 publicKey: bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String) else {
            return OrbitUpdateModel(distribution: .unconfigured)
        }
        return OrbitUpdateModel(distribution: .direct, driver: SparkleUpdateDriver())
        #endif
    }

    nonisolated static func validConfiguration(feed: String?, publicKey: String?) -> Bool {
        guard let feed, let url = URL(string: feed), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              let publicKey, let bytes = Data(base64Encoded: publicKey), bytes.count == 32 else { return false }
        return true
    }

    func start() {
        guard !started, let driver else { return }
        do {
            try driver.start()
            started = true
            refresh()
        } catch {
            state.canCheck = false
            state.error = error.localizedDescription
        }
    }

    func check() {
        guard started, state.canCheck else { return }
        driver?.check()
        refresh()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        guard started else { return }
        driver?.setAutomaticChecks(enabled)
        refresh()
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        guard started, state.automaticChecks else { return }
        driver?.setAutomaticDownloads(enabled)
        refresh()
    }

    func openAppStore() {
        guard distribution == .appStore else { return }
        NSWorkspace.shared.open(URL(string: "macappstore://itunes.apple.com/app/id6818213167")!)
    }

    private func refresh() { if let driver { state = driver.state } }

    static func preview() -> OrbitUpdateModel {
        let model = OrbitUpdateModel(distribution: .direct, driver: PreviewUpdateDriver())
        model.start()
        return model
    }
}

@MainActor
private final class PreviewUpdateDriver: OrbitUpdateDriver {
    var state = OrbitUpdateState(canCheck: true, automaticChecks: true)
    var didChange: (() -> Void)?
    func start() throws {}
    func check() { state.lastCheck = Date(); didChange?() }
    func setAutomaticChecks(_ enabled: Bool) { state.automaticChecks = enabled; didChange?() }
    func setAutomaticDownloads(_ enabled: Bool) { state.automaticDownloads = enabled; didChange?() }
}

#if !MAS
enum OrbitUpdateErrors {
    static func message(_ error: (any Error)?) -> String? {
        guard let error else { return nil }
        let nsError = error as NSError
        // Sparkle uses these outcomes for successful no-update checks and
        // user cancellation too; neither should become a persistent error.
        if nsError.domain == SUSparkleErrorDomain,
           nsError.code == Int(SUError.noUpdateError.rawValue) || nsError.code == Int(SUError.installationCanceledError.rawValue) {
            return nil
        }
        return error.localizedDescription
    }
}

@MainActor
private final class SparkleUpdateDriver: NSObject, OrbitUpdateDriver, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var cancellables = Set<AnyCancellable>()
    private var lastError: String?
    var didChange: (() -> Void)?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in self?.didChange?() }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] _ in self?.didChange?() }.store(in: &cancellables)
        updater.publisher(for: \.automaticallyDownloadsUpdates).sink { [weak self] _ in self?.didChange?() }.store(in: &cancellables)
        updater.publisher(for: \.lastUpdateCheckDate).sink { [weak self] _ in self?.didChange?() }.store(in: &cancellables)
    }

    var state: OrbitUpdateState {
        let updater = controller.updater
        return OrbitUpdateState(canCheck: updater.canCheckForUpdates,
                                automaticChecks: updater.automaticallyChecksForUpdates,
                                automaticDownloads: updater.automaticallyDownloadsUpdates,
                                lastCheck: updater.lastUpdateCheckDate, error: lastError)
    }

    func start() throws { try controller.updater.start() }
    func check() { lastError = nil; controller.checkForUpdates(nil); didChange?() }
    func setAutomaticChecks(_ enabled: Bool) { controller.updater.automaticallyChecksForUpdates = enabled; didChange?() }
    func setAutomaticDownloads(_ enabled: Bool) { controller.updater.automaticallyDownloadsUpdates = enabled; didChange?() }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        lastError = OrbitUpdateErrors.message(error)
        didChange?()
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastError = OrbitUpdateErrors.message(error)
        didChange?()
    }
}
#endif
