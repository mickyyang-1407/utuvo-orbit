import Foundation
import Testing
@testable import UtuvoOrbit

struct ProductivityCoreTests {
    @Test(arguments: [
        ("2+3*4", 14.0), ("(2+3)*4", 20.0), ("2^3^2", 512.0),
        ("-2^2", -4.0), ("2^-2", 0.25), ("120*15%", 18.0),
        ("sqrt(81)+abs(-2)", 11.0), ("1e3 + .5", 1000.5),
        ("sin(pi/2)", 1.0), ("2×3 − 4÷2", 4.0)
    ])
    func arithmetic(_ expression: String, _ expected: Double) throws {
        #expect(abs(try OrbitCalculator.evaluate(expression) - expected) < 1e-9)
    }
    @Test(arguments: ["", "1/0", "1..2", "2(3)", "1e+", "sqrt(-1)", "2^99999", "system(1)", "1,5", "()"])
    func malformedAndUnboundedResultsAreRejected(_ expression: String) {
        #expect(throws: (any Error).self) { try OrbitCalculator.evaluate(expression) }
    }
    @Test func parserBoundsApplyBeforeRecursion() {
        #expect(throws: CalculationError.tooComplex) { try OrbitCalculator.evaluate(String(repeating: "1+", count: 300)) }
        #expect(throws: CalculationError.tooComplex) { try OrbitCalculator.evaluate(String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40)) }
    }
    @Test(arguments: [
        (1.0, "mi", "km", 1.609344), (1.0, "lb", "g", 453.59237),
        (32.0, "°F", "°C", 0.0), (100.0, "°C", "°F", 212.0),
        (1.0, "MiB", "B", 1_048_576.0), (1.0, "MB", "B", 1_000_000.0),
        (1.0, "US gal", "L", 3.785411784), (90.0, "km/h", "m/s", 25.0),
        (1.0, "acre", "m²", 4046.8564224), (2.0, "h", "s", 7200.0),
        (180.0, "deg", "rad", Double.pi), (1.0, "kWh", "J", 3_600_000.0)
    ])
    func dimensionalConversion(_ value: Double, _ from: String, _ to: String, _ expected: Double) throws {
        #expect(abs(try ConversionUnit.convert(value, from: from, to: to) - expected) < 1e-7)
    }
    @Test func invalidConversionDoesNotInventResult() {
        #expect(throws: CalculationError.incompatibleUnits) { try ConversionUnit.convert(1, from: "m", to: "kg") }
        #expect(throws: CalculationError.belowAbsoluteZero) { try ConversionUnit.convert(-274, from: "°C", to: "K") }
        #expect(throws: CalculationError.nonFinite) { try ConversionUnit.convert(.infinity, from: "m", to: "km") }
    }
    @Test func clocksUseTheSelectedInstantForDSTAndDateRollover() throws {
        let parser = ISO8601DateFormatter()
        let winter = try #require(parser.date(from: "2026-01-01T01:00:00Z"))
        let summer = try #require(parser.date(from: "2026-07-01T01:00:00Z"))
        let locale = Locale(identifier: "en_US")
        let nyWinter = try #require(WorldClock.reading(zoneID: "America/New_York", at: winter, relativeTo: "Asia/Taipei", locale: locale))
        let nySummer = try #require(WorldClock.reading(zoneID: "America/New_York", at: summer, relativeTo: "Asia/Taipei", locale: locale))
        #expect(nyWinter.time == "20:00" && nyWinter.offset == "UTC−05:00" && nyWinter.dayDifference == -1)
        #expect(nySummer.time == "21:00" && nySummer.offset == "UTC−04:00")
        let kathmandu = try #require(WorldClock.reading(zoneID: "Asia/Kathmandu", at: winter, relativeTo: "UTC", locale: locale))
        #expect(kathmandu.time == "06:45" && kathmandu.offset == "UTC+05:45")
        #expect(WorldClock.reading(zoneID: "not/a/zone", at: winter, relativeTo: "UTC", locale: locale) == nil)
    }
}

@MainActor
struct ProductivityStateTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-productivity-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    @Test func historyIsBoundedAndChangingInputInvalidatesOldResult() {
        let model = CalculatorToolsModel()
        for n in 1...35 { model.input = "\(n)+1"; model.calculate() }
        #expect(model.history.count == 30 && model.result == "36")
        model.input = "bad"; #expect(model.result == nil)
        model.calculate(); #expect(model.error != nil && model.history.count == 30)
        model.selectKind(.temperature)
        #expect(model.from == "°C" && model.to == "°F")
        model.clearHistory(); #expect(model.history.isEmpty)
    }
    @Test func notesSaveBeforeSwitchAndRestoreFromTrash() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root); defer { model.stop() }
        #expect(model.create(title: "First", body: "Before"))
        let first = try #require(model.selectedID)
        model.editBody("Updated 中文 🪐")
        #expect(model.create(title: "Second"))
        let second = try #require(model.selectedID)
        let reopened = QuickNotesModel(root: root); defer { reopened.stop() }
        #expect(reopened.notes.first { $0.id == first }?.body == "Updated 中文 🪐")
        model.pin(first); model.trash(first)
        model.showTrash = true; #expect(model.visible.map(\.id) == [first])
        model.trash(first, restore: true)
        #expect(model.selectedID == first && model.notes.first { $0.id == first }?.pinned == true)
        model.query = "中文"; #expect(model.visible.map(\.id) == [first])
        model.trash(second); model.emptyTrash()
        #expect(model.notes.count == 1 && model.notes.first?.id == first)
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("notes.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func notesAutosaveAndMarkdownExportUseTheEditedText() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root); defer { model.stop() }
        #expect(model.create(title: "../not-a-path", body: "Initial"))
        model.editBody("Edited text\n- one")
        try await Task.sleep(for: .milliseconds(700))
        #expect(!model.dirty)
        let reopened = QuickNotesModel(root: root); defer { reopened.stop() }
        #expect(reopened.notes.first?.body == "Edited text\n- one")
        let exported = try #require(model.export(to: root))
        let secondExport = try #require(model.export(to: root))
        #expect(exported != secondExport)
        let files = try FileManager.default.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil)
        let output = try #require(files.first); #expect(output.pathExtension == "md")
        #expect(try String(contentsOf: output, encoding: .utf8) == "# ../not-a-path\n\nEdited text\n- one\n")
        #expect(!FileManager.default.fileExists(atPath: root.deletingLastPathComponent().appendingPathComponent("not-a-path").path))
    }
    @Test func corruptNotesRequireBackupBeforeReplacingBytes() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.json"), broken = Data("{broken".utf8)
        try broken.write(to: file)
        let model = QuickNotesModel(root: root); defer { model.stop() }
        #expect(model.needsRecovery && !model.create(title: "Do not overwrite"))
        #expect(try Data(contentsOf: file) == broken)
        model.recover(); #expect(!model.needsRecovery && model.create(title: "Recovered"))
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".backup.") }
        try #require(backups.count == 1)
        #expect(try Data(contentsOf: backups[0]) == broken)
    }
    @Test func failedSaveKeepsDraftAndBlocksSelectionChange() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root); defer { model.stop() }
        #expect(model.create(title: "One")); let first = try #require(model.selectedID)
        #expect(model.create(title: "Two")); let second = try #require(model.selectedID)
        let file = root.appendingPathComponent("notes.json")
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("saved.json"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        model.editBody("Keep this unsaved draft")
        #expect(!model.select(first))
        #expect(model.selectedID == second && model.draftBody == "Keep this unsaved draft" && model.dirty && model.error != nil)
        try FileManager.default.removeItem(at: file)
        #expect(model.flush())
        #expect(model.notes.first { $0.id == second }?.body == "Keep this unsaved draft")
    }
    @Test func zoneFavoritesRejectDuplicatesAndPreserveOrdering() {
        let model = WorldClockModel()
        let original = model.zones
        model.add("not/a/zone"); model.add(original[0]); #expect(model.zones == original)
        model.add("Asia/Tokyo"); model.move("Asia/Tokyo", by: -1)
        #expect(model.zones[model.zones.count - 2] == "Asia/Tokyo")
        model.remove("Asia/Tokyo"); #expect(model.zones == original)
        model.query = "東京"; #expect(model.matches == ["Asia/Tokyo"])
    }
    @Test func zonePreferencesSurviveReloadWithoutTouchingNormalDefaults() throws {
        let name = "orbit.clock.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = WorldClockModel(defaults: defaults)
        model.add("Asia/Kathmandu"); model.move("Asia/Kathmandu", by: -1)
        #expect(WorldClockModel(defaults: defaults).zones == model.zones)
    }
    @Test func noteLimitsIncludeTrashAndDiscardDoesNotWriteTheDraft() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root); defer { model.stop() }
        #expect(model.create(title: "Keep", body: "Saved"))
        let keep = try #require(model.selectedID)
        model.editBody("Do not save this"); model.discardDraft()
        #expect(!model.dirty && model.draftBody == "Saved")
        for n in 1..<100 { #expect(model.create(title: "Note \(n)")) }
        #expect(!model.create(title: "Over limit"))
        model.trash(keep)
        #expect(!model.create(title: "Trash still counts"))
        model.emptyTrash(); #expect(model.create(title: "Room again"))
        model.editBody(String(repeating: "中", count: 30_000))
        #expect(model.draftBody.isEmpty && model.error != nil)
    }
}
