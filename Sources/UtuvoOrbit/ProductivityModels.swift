import Foundation
import OrbitCore

struct CalculationEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let expression: String
    let result: String
}

@MainActor
final class CalculatorToolsModel: ObservableObject {
    @Published var input = "" { didSet { if input != oldValue { result = nil; error = nil } } }
    @Published private(set) var result: String?
    @Published private(set) var error: String?
    @Published private(set) var history: [CalculationEntry] = []
    @Published var kind: ConversionKind = .length
    @Published var conversionInput = "1"
    @Published var from = "m"
    @Published var to = "ft"
    private let store: ToolStorage<[CalculationEntry]>
    init(defaults: UserDefaults? = nil) {
        store = ToolStorage(defaults, "orbit.calculator.history")
        history = store.load(fallback: [], validate: { entries in
            entries.count <= 30 && Set(entries.map(\.id)).count == entries.count &&
            entries.allSatisfy { $0.expression.count <= 512 && $0.result.count <= 80 }
        })
    }
    var needsRecovery: Bool { store.damaged }
    var converted: Result<String, any Error> {
        Result {
            let value = try OrbitCalculator.evaluate(conversionInput)
            return OrbitCalculator.format(try ConversionUnit.convert(value, from: from, to: to))
        }
    }
    func calculate() {
        do {
            let value = try OrbitCalculator.evaluate(input)
            let formatted = OrbitCalculator.format(value)
            var updated = history.filter { $0.expression != input }
            updated.insert(CalculationEntry(expression: input, result: formatted), at: 0)
            updated = Array(updated.prefix(30))
            if !store.damaged { try store.save(updated); history = updated }
            result = formatted; error = store.damaged ? "History needs recovery / 歷史資料需先還原" : nil
        } catch { result = nil; self.error = error.localizedDescription }
    }
    func selectKind(_ value: ConversionKind) {
        kind = value; from = value.units[0].id; to = value.units[min(1, value.units.count - 1)].id
    }
    func clearHistory() {
        do { try store.save([]); history = []; error = nil }
        catch { self.error = error.localizedDescription }
    }
    func recover() {
        do { try store.backupAndReset([]); history = []; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class WorldClockModel: ObservableObject {
    @Published private(set) var zones: [String]
    @Published var query = ""
    @Published var baseZone = TimeZone.current.identifier
    @Published var useCurrentTime = true
    @Published var previewDate = Date()
    @Published private(set) var error: String?
    private let store: ToolStorage<[String]>
    static let available = Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC"])).sorted()
    static let cityAliases = [
        "Asia/Taipei": "台北 臺北", "Asia/Tokyo": "東京", "Asia/Hong_Kong": "香港",
        "Asia/Singapore": "新加坡", "Asia/Shanghai": "上海", "Asia/Seoul": "首爾",
        "America/Los_Angeles": "洛杉磯", "America/New_York": "紐約",
        "Europe/London": "倫敦", "Europe/Paris": "巴黎", "Europe/Berlin": "柏林",
        "Australia/Sydney": "雪梨", "Asia/Dubai": "杜拜", "Asia/Kolkata": "印度 加爾各答"
    ]
    private static let suggestions = ["Asia/Tokyo", "America/New_York", "Asia/Hong_Kong", "Asia/Singapore", "Australia/Sydney", "Europe/Paris", "UTC"]
    init(defaults: UserDefaults? = nil) {
        store = ToolStorage(defaults, "orbit.worldclock.zones")
        zones = store.load(fallback: ["Asia/Taipei", "America/Los_Angeles", "Europe/London"], validate: { values in
            values.count <= 16 && Set(values).count == values.count && values.allSatisfy { TimeZone(identifier: $0) != nil }
        })
    }
    var needsRecovery: Bool { store.damaged }
    var matches: [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = term.isEmpty ? Self.suggestions : Self.available
        return Array(source.filter { zone in
            !zones.contains(zone) && (term.isEmpty || (zone.replacingOccurrences(of: "_", with: " ") + " " + (Self.cityAliases[zone] ?? "")).localizedCaseInsensitiveContains(term))
        }.prefix(12))
    }
    func add(_ zone: String) {
        guard TimeZone(identifier: zone) != nil, !zones.contains(zone) else { return }
        guard zones.count < 16 else { error = "Up to 16 cities / 最多 16 個城市"; return }
        save(zones + [zone])
    }
    func remove(_ zone: String) { save(zones.filter { $0 != zone }) }
    func move(_ zone: String, by offset: Int) {
        guard let i = zones.firstIndex(of: zone), zones.indices.contains(i + offset) else { return }
        var updated = zones; updated.swapAt(i, i + offset); save(updated)
    }
    func recover() {
        do { try store.backupAndReset([]); zones = []; error = nil }
        catch { self.error = error.localizedDescription }
    }
    private func save(_ values: [String]) {
        do { try store.save(values); zones = values; error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct QuickNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var body: String
    var pinned = false
    var modified: Date
    var deleted: Date?
}

@MainActor
final class QuickNotesModel: ObservableObject {
    @Published private(set) var notes: [QuickNote]
    @Published private(set) var selectedID: UUID?
    @Published private(set) var draftTitle = ""
    @Published private(set) var draftBody = ""
    @Published private(set) var dirty = false
    @Published private(set) var error: String?
    @Published private(set) var exported: URL?
    @Published var query = ""
    @Published var showTrash = false
    private let store: ToolStorage<[QuickNote]>
    private let now: () -> Date
    private var autosave: Task<Void, Never>?
    var needsRecovery: Bool { store.damaged }
    var selected: QuickNote? { notes.first { $0.id == selectedID } }
    var visible: [QuickNote] {
        notes.filter { ($0.deleted != nil) == showTrash && (query.isEmpty || ($0.title + "\n" + $0.body).localizedCaseInsensitiveContains(query)) }
            .sorted {
                if $0.pinned != $1.pinned { return $0.pinned }
                if $0.modified != $1.modified { return $0.modified > $1.modified }
                return $0.id.uuidString < $1.id.uuidString
            }
    }
    init(root: URL? = nil, preview: Bool = false, now: @escaping () -> Date = Date.init) {
        self.now = now
        let url = preview ? nil : (root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UTUVO Orbit/Notes", isDirectory: true)).appendingPathComponent("notes.json")
        store = ToolStorage(nil, "notes", fileURL: url)
        notes = store.load(fallback: [], validate: { values in
            values.count <= 100 && Set(values.map(\.id)).count == values.count &&
            values.reduce(0, { $0 + $1.body.utf8.count }) <= 2_000_000 &&
            values.allSatisfy { $0.title.count <= 120 && $0.body.utf8.count <= 65_536 &&
                $0.modified.timeIntervalSince1970.isFinite && ($0.deleted?.timeIntervalSince1970.isFinite ?? true) }
        })
        if let first = notes.first(where: { $0.deleted == nil }) {
            selectedID = first.id; draftTitle = first.title; draftBody = first.body
        }
    }
    @discardableResult func create(title: String = "", body: String = "") -> Bool {
        guard flush() else { return false }
        guard notes.count < 100, title.count <= 120, body.utf8.count <= 65_536 else {
            error = "Up to 100 notes, 120 title characters, 64 KiB per note / 最多 100 筆、標題 120 字、每筆 64 KiB"; return false
        }
        let note = QuickNote(title: title, body: body, modified: now())
        guard save(notes + [note]) else { return false }
        showTrash = false; selectDraft(note); return true
    }
    @discardableResult func select(_ id: UUID) -> Bool {
        guard let note = notes.first(where: { $0.id == id }), flush() else { return false }
        // flush may have replaced the selected record, so use its saved value.
        selectDraft(notes.first(where: { $0.id == note.id })!); return true
    }
    func editTitle(_ value: String) {
        guard selected?.deleted == nil, selectedID != nil, value.count <= 120 else { return }
        draftTitle = value; schedule()
    }
    func editBody(_ value: String) {
        guard selected?.deleted == nil, selectedID != nil else { return }
        guard value.utf8.count <= 65_536 else { error = "Note is limited to 64 KiB / 每筆上限 64 KiB"; return }
        draftBody = value; schedule()
    }
    @discardableResult func flush() -> Bool {
        autosave?.cancel(); autosave = nil
        guard dirty, let i = notes.firstIndex(where: { $0.id == selectedID }) else { return true }
        var updated = notes
        updated[i].title = draftTitle; updated[i].body = draftBody; updated[i].modified = now()
        guard save(updated) else { return false }
        dirty = false; return true
    }
    func pin(_ id: UUID) {
        guard flush(), let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = notes; updated[i].pinned.toggle(); _ = save(updated)
    }
    func trash(_ id: UUID, restore: Bool = false) {
        guard flush(), let i = notes.firstIndex(where: { $0.id == id }) else { return }
        var updated = notes; updated[i].deleted = restore ? nil : now()
        guard save(updated) else { return }
        if restore { showTrash = false; selectDraft(updated[i]) }
        else if selectedID == id {
            if let next = notes.first(where: { $0.deleted == nil }) { selectDraft(next) }
            else { selectedID = nil; draftTitle = ""; draftBody = ""; dirty = false }
        }
    }
    func emptyTrash() {
        guard flush(), save(notes.filter { $0.deleted == nil }) else { return }
        if !notes.contains(where: { $0.id == selectedID }) {
            if let first = notes.first { selectDraft(first) }
            else { selectedID = nil; draftTitle = ""; draftBody = ""; dirty = false }
        }
    }
    @discardableResult func export(to parent: URL) -> URL? {
        guard flush(), let note = selected else { return nil }
        do {
            let title = note.title.isEmpty ? "Orbit Note" : note.title
            let url = try ToolFiles.write([ToolExport(name: "Note-\(note.id.uuidString).md", data: Data(("# " + title + "\n\n" + note.body + "\n").utf8))], to: parent)
            exported = url; error = nil; return url
        } catch { self.error = error.localizedDescription; return nil }
    }
    func recover() {
        autosave?.cancel(); autosave = nil
        do {
            try store.backupAndReset([]); notes = []; selectedID = nil
            draftTitle = ""; draftBody = ""; dirty = false; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func stop() { _ = flush() }
    func discardDraft() {
        autosave?.cancel(); autosave = nil
        if let selected { selectDraft(selected) }
        else { draftTitle = ""; draftBody = ""; dirty = false }
        error = nil
    }
    private func selectDraft(_ note: QuickNote) {
        selectedID = note.id; draftTitle = note.title; draftBody = note.body; dirty = false
    }
    private func schedule() {
        dirty = true; autosave?.cancel()
        autosave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard !Task.isCancelled else { return }; _ = self?.flush()
        }
    }
    private func save(_ updated: [QuickNote]) -> Bool {
        guard updated.reduce(0, { $0 + $1.body.utf8.count }) <= 2_000_000 else {
            error = "Notes storage is full (2 MB) / 筆記已達 2 MB 上限"; return false
        }
        do { try store.save(updated); notes = updated; error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
}
