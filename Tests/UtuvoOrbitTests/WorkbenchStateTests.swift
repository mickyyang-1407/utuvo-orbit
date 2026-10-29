import AppKit
import Testing
import OrbitCore
@testable import UtuvoOrbit

@MainActor
struct WorkbenchStateTests {
    @Test func previewFileCopyUsesTheInjectedClipboard() {
        let routing = PreviewSceneRouting()
        let scenes = AudioScenesModel(defaults: nil, routing: routing, audio: AudioBackendImpl(driver: routing.driver), awake: FakeAwakeBackend())
        let timer = OrbitTimerModel(awake: FakeAwakeBackend(), enableTicker: false)
        let preferences = OrbitPreferencesModel(backend: FakePreferencesBackend(initial: OrbitPreferencesValues(), legacy: nil))
        let controller = OrbitToolsWindowController(preferences: preferences, scenes: scenes, timer: timer, preview: true)
        controller.files.setFiles([URL(fileURLWithPath: "/fixture/readme.txt")]); controller.files.copyPaths()
        #expect(controller.workbench.pasteText() == "/fixture/readme.txt")
        controller.stop()
    }
    @Test func clipboardDiskHistoryIsPrivateAndCorruptionRequiresExplicitBackup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit.clipboard.disk.\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let access = PreviewClipboardAccess()
        let first = ClipboardToolsModel(defaults: nil, access: access, enableTicker: false, root: root)
        first.admit(ClipboardEntry(text: "persist this", pinned: true))
        let file = root.appendingPathComponent("history.json")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let restored = ClipboardToolsModel(defaults: nil, access: access, enableTicker: false, root: root)
        #expect(restored.entries.first?.text == "persist this" && restored.entries.first?.pinned == true)
        let damaged = Data("damaged".utf8); try damaged.write(to: file)
        let broken = ClipboardToolsModel(defaults: nil, access: access, enableTicker: false, root: root)
        broken.admit(ClipboardEntry(text: "do not overwrite"))
        let preserved = try Data(contentsOf: file)
        #expect(broken.needsRecovery && preserved == damaged)
        broken.recover()
        let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("history.json.backup.") })
        #expect(try Data(contentsOf: backup) == damaged)
        #expect(!broken.needsRecovery && broken.entries.isEmpty)
    }
    @Test func clipboardRejectsInvalidImagesBeforeRendering() throws {
        #expect(!ClipboardEntry(png: Data("not a PNG".utf8)).valid)
        let valid = try QRToolkit.png(QRToolkit.generate("fixture"))
        #expect(ClipboardEntry(png: valid).valid)
        let context = try #require(CGContext(data: nil, width: 9000, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let huge = try QRToolkit.png(#require(context.makeImage()))
        #expect(!ClipboardEntry(png: huge).valid)
    }
    @Test func textInputAndResultStayInTheSessionAndInvalidateAfterEdits() {
        let model = TextToolsModel(); model.input = "  keep me  "; model.transform()
        #expect(model.output == "keep me")
        let sameSession = model; #expect(sameSession.input == "  keep me  " && sameSession.output == "keep me")
        model.input = "new input"; #expect(model.output.isEmpty)
        model.transform(); model.action = .upper; #expect(model.output.isEmpty)
    }
    @Test func clipboardStartsOffSkipsBaselineDeduplicatesAndPersistsPins() throws {
        let name = "orbit.clipboard.tests.\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let access = PreviewClipboardAccess(); access.value = ClipboardEntry(text: "old clipboard")
        let model = ClipboardToolsModel(defaults: defaults, access: access, enableTicker: false)
        #expect(!model.enabled && model.entries.isEmpty)
        model.setEnabled(true); model.poll(); #expect(model.entries.isEmpty)
        access.value = ClipboardEntry(text: "One"); access.changeCount += 1; model.poll()
        let first = try #require(model.entries.first); model.togglePin(first)
        access.value = ClipboardEntry(text: "One"); access.changeCount += 1; model.poll()
        #expect(model.entries.count == 1 && model.entries[0].pinned)
        model.copy(first); model.poll(); #expect(model.entries.count == 1)
        model.setEnabled(false); access.value = ClipboardEntry(text: "paused"); access.changeCount += 1; model.poll()
        #expect(model.entries.count == 1)
        let restored = ClipboardToolsModel(defaults: defaults, access: access, enableTicker: false)
        #expect(restored.entries.count == 1 && restored.entries[0].pinned && !restored.enabled)
        model.query = "one"; #expect(model.filtered.count == 1)
        model.clear(); #expect(model.entries.isEmpty)
        #expect(access.value?.text == "paused") // Clearing history does not write the system pasteboard.
    }
    @Test func clipboardCapacityRetainsPinnedAndSuspensionSkipsInterveningItems() throws {
        let access = PreviewClipboardAccess(); let model = ClipboardToolsModel(defaults: nil, access: access, enableTicker: false)
        model.admit(ClipboardEntry(text: "pinned", pinned: true))
        for index in 0..<70 { model.admit(ClipboardEntry(text: "entry \(index)")) }
        #expect(model.entries.count == 50 && model.entries.contains { $0.text == "pinned" })
        model.setEnabled(true); model.setSuspended(true)
        access.value = ClipboardEntry(text: "locked"); access.changeCount += 1; model.poll()
        model.setSuspended(false); model.poll()
        #expect(!model.entries.contains { $0.text == "locked" })
        model.admit(ClipboardEntry(text: String(repeating: "x", count: 4_000_001)))
        #expect(model.entries.count == 50)
    }
    @Test func corruptDataIsPreservedUntilBackupReset() throws {
        let name = "orbit.storage.tests.\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let raw = Data("broken".utf8); defaults.set(raw, forKey: "tools.clipboard.v1")
        let model = ClipboardToolsModel(defaults: defaults, access: PreviewClipboardAccess(), enableTicker: false)
        model.admit(ClipboardEntry(text: "must not overwrite")); model.setEnabled(true)
        #expect(model.needsRecovery && !model.enabled && defaults.data(forKey: "tools.clipboard.v1") == raw)
        model.recover()
        #expect(!model.needsRecovery && model.entries.isEmpty)
        #expect(defaults.dictionaryRepresentation().contains { $0.key.hasPrefix("tools.clipboard.v1.backup.") && $0.value as? Data == raw })
    }
    @Test func colorValidationNormalizationAndPalettePersistence() throws {
        let name = "orbit.colors.tests.\(UUID())"; let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var copied = ""; let model = ColorToolsModel(defaults: defaults, copyText: { copied = $0 })
        model.input = "  27a89a "; model.save(); model.save()
        #expect(model.swatches.count == 1 && model.swatches[0].hex == "#27A89A")
        #expect(model.current?.rgb == "rgb(39, 168, 154)")
        model.copy(model.current!.rgb); #expect(copied == "rgb(39, 168, 154)")
        model.input = "#GGGGGG"; #expect(model.current == nil)
        let restored = ColorToolsModel(defaults: defaults, copyText: { _ in })
        #expect(restored.swatches == model.swatches)
    }
    @Test func actionSearchPinsKeyboardMovementAndLockGate() throws {
        let shortcut = PreviewActionShortcut(); let model = ActionPanelModel(defaults: nil, shortcut: shortcut)
        var executed: [String] = []
        model.actions = [OrbitAction(id: "text", title: "Text 文字", detail: "Open tool", symbol: "text.alignleft", perform: { executed.append("text") }), OrbitAction(id: "qr", title: "QR Code", detail: "Open tool", symbol: "qrcode", perform: { executed.append("qr") })]
        #expect(shortcut.registrations == 0)
        model.togglePin(model.actions[1]); #expect(model.filtered.first?.id == "qr")
        model.query = "文字 tool"; #expect(model.filtered.map(\.id) == ["text"])
        #expect(model.ordered.count == 2) // The settings list remains complete after a palette search.
        model.runSelected(); #expect(executed == ["text"])
        model.query = ""; model.selection = "qr"; model.move(1); #expect(model.selection == "text")
        model.setAllowed(false); model.runSelected(); #expect(executed.count == 1)
        model.setAllowed(true); model.setShortcut(true); #expect(shortcut.registrations == 1)
        model.stop()
    }
}
