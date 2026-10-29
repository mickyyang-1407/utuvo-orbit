#if ORBIT_UPDATE_VERIFICATION && !MAS
import AppKit
import Combine
import Foundation

/// Compiled only into the separately identified update-verification edition.
/// Real Orbit startup, preferences, hardware and optional modules are never constructed.
@MainActor
final class OrbitUpdateVerification: NSObject {
    private let model = OrbitUpdateModel.live()
    private var window: NSWindow?
    private var observation: AnyCancellable?
    private let status = NSTextField(labelWithString: "")
    func start() {
        guard Bundle.main.bundleIdentifier == "com.utuvo.orbit.updateverification20261029" else { NSApp.terminate(nil); return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let marker = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("verification-installed.json")
        let receipt: [String: Any] = ["version": version,"build": build,"pid":ProcessInfo.processInfo.processIdentifier,"bundle":Bundle.main.bundleIdentifier!,"feed":Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""]
        try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted,.sortedKeys]).write(to: marker, options: .atomic)
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 600,height: 300), styleMask: [.titled,.closable],backing: .buffered,defer: false)
        window.title = "Orbit Update Verification — \(version) (\(build))"
        let title = NSTextField(labelWithString: "UTUVO Orbit \(version) · build \(build)\nIsolated real-updater verification")
        title.font = .systemFont(ofSize: 21,weight: .semibold); title.frame = NSRect(x: 28,y: 185,width: 540,height: 70); window.contentView?.addSubview(title)
        status.frame = NSRect(x: 28,y: 125,width: 540,height: 50); window.contentView?.addSubview(status)
        let check = NSButton(title: "Check for Updates…", target: self, action: #selector(check))
        check.frame = NSRect(x: 28,y: 60,width: 230,height: 36); window.contentView?.addSubview(check)
        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.frame = NSRect(x: 420,y: 60,width: 150,height: 36); window.contentView?.addSubview(quit)
        self.window = window
        observation = model.$state.sink { [weak self] value in
            self?.status.stringValue = value.error ?? "Checks: \(value.automaticChecks) · Downloads: \(value.automaticDownloads) · Ready: \(value.canCheck)"
        }
        model.start()
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func check() { model.check() }
}
#endif
