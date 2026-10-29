import Foundation
import ServiceManagement
import Sparkle
import Testing
@testable import UtuvoOrbit

@MainActor
struct LifecycleSettingsTests {
    @Test(arguments: [SMAppService.Status.notRegistered, .enabled, .requiresApproval, .notFound])
    func loginRefreshIsReadOnly(status: SMAppService.Status) {
        let service = FakeLoginService(status: status)
        let model = LoginItemModel(service: service)
        model.refresh()
        #expect(service.registrations == 0)
        #expect(service.removals == 0)
        #expect(model.isOn == (status == .enabled || status == .requiresApproval))
        service.status = .notRegistered
        model.refresh()
        #expect(!model.isOn)
    }

    @Test func loginOptInApprovalDisableAndFailure() {
        let service = FakeLoginService(status: .notRegistered)
        let model = LoginItemModel(service: service)
        model.set(true)
        model.set(true) // no redundant registration
        #expect(service.registrations == 1)
        #expect(model.status == .requiresApproval)
        model.openSettings()
        #expect(service.openedSettings == 1)
        service.status = .enabled
        model.refresh()
        #expect(model.status == .enabled)
        model.set(false)
        #expect(service.removals == 1)
        #expect(!model.isOn)
        service.fail = true
        model.set(true)
        #expect(!model.isOn)
        #expect(model.lastError != nil)
    }

    @Test func updaterStartsOnceAndPreservesExistingPreferences() {
        let driver = FakeUpdateDriver()
        let model = OrbitUpdateModel(distribution: .direct, driver: driver)
        #expect(driver.starts == 0)
        model.check()
        model.setAutomaticChecks(true)
        #expect(driver.checks == 0)
        #expect(driver.settingWrites == 0)
        model.start()
        model.start()
        #expect(driver.starts == 1)
        #expect(!model.state.automaticChecks)
        #expect(driver.settingWrites == 0)
        model.setAutomaticChecks(true)
        model.setAutomaticDownloads(true)
        #expect(driver.state.automaticDownloads)
        model.check()
        #expect(driver.checks == 1)
        #expect(!model.state.canCheck)
        model.check() // busy: no overlapping checks
        #expect(driver.checks == 1)
        driver.state.canCheck = true
        driver.state.lastCheck = Date(timeIntervalSince1970: 100)
        driver.didChange?()
        #expect(model.state.lastCheck == Date(timeIntervalSince1970: 100))
        model.setAutomaticChecks(false)
        model.setAutomaticDownloads(false) // disabled switch: preserve preference
        #expect(driver.state.automaticDownloads)
    }

    @Test(arguments: [OrbitUpdateModel.Distribution.appStore, .unconfigured])
    func otherDistributionsCannotRunDirectUpdater(distribution: OrbitUpdateModel.Distribution) {
        let driver = FakeUpdateDriver()
        let model = OrbitUpdateModel(distribution: distribution, driver: driver)
        model.start()
        model.check()
        model.setAutomaticChecks(true)
        model.setAutomaticDownloads(true)
        #expect(driver.starts == 0)
        #expect(driver.checks == 0)
        #expect(driver.settingWrites == 0)
        #expect(!model.state.canCheck)
    }

    @Test func updaterStartupFailureCanRetryWithoutClaimingReady() {
        let driver = FakeUpdateDriver()
        driver.fail = true
        let model = OrbitUpdateModel(distribution: .direct, driver: driver)
        model.start()
        #expect(model.state.error != nil)
        #expect(!model.state.canCheck)
        model.check()
        #expect(driver.checks == 0)
        driver.fail = false
        model.start()
        #expect(model.state.error == nil)
        #expect(model.state.canCheck)
    }

    @Test func updateConfigurationAndOutcomeValidation() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        #expect(OrbitUpdateModel.validConfiguration(feed: "https://example.com/appcast.xml", publicKey: key))
        for feed in [nil, "http://example.com/feed", "file:///tmp/feed", "https://user:pass@example.com/feed", "https://"] as [String?] {
            #expect(!OrbitUpdateModel.validConfiguration(feed: feed, publicKey: key))
        }
        for badKey in [nil, "", "not a key", Data(repeating: 0, count: 31).base64EncodedString()] as [String?] {
            #expect(!OrbitUpdateModel.validConfiguration(feed: "https://example.com/feed", publicKey: badKey))
        }
        #expect(OrbitUpdateErrors.message(nil) == nil)
        #expect(OrbitUpdateErrors.message(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))) == nil)
        #expect(OrbitUpdateErrors.message(NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))) == nil)
        #expect(OrbitUpdateErrors.message(NSError(domain: "other-domain", code: Int(SUError.noUpdateError.rawValue))) != nil)
        #expect(OrbitUpdateErrors.message(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) != nil)
    }
}

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status
    var registrations = 0
    var removals = 0
    var openedSettings = 0
    var fail = false
    init(status: SMAppService.Status) { self.status = status }
    func register() throws {
        registrations += 1
        if fail { throw FixtureError.failed }
        status = .requiresApproval
    }
    func unregister() throws { removals += 1; status = .notRegistered }
    func openSettings() { openedSettings += 1 }
}

@MainActor
private final class FakeUpdateDriver: OrbitUpdateDriver {
    var state = OrbitUpdateState(canCheck: true)
    var didChange: (() -> Void)?
    var starts = 0
    var checks = 0
    var settingWrites = 0
    var fail = false
    func start() throws { starts += 1; if fail { throw FixtureError.failed } }
    func check() { checks += 1; state.canCheck = false; didChange?() }
    func setAutomaticChecks(_ enabled: Bool) { settingWrites += 1; state.automaticChecks = enabled }
    func setAutomaticDownloads(_ enabled: Bool) { settingWrites += 1; state.automaticDownloads = enabled }
}

private enum FixtureError: Error { case failed }
