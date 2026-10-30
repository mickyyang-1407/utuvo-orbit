import Darwin
import Foundation
import Testing
@testable import UtuvoOrbit

// MARK: - Helpers

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("orbit-library-backup-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The three fixed public oracle files. They are the independent fixtures,
/// copied into the test so the shipped source can check them without the
/// evidence folder. The originals in the evidence stay untouched.
private let oracleNotesJSON = #"{"format": "utuvo.orbit.library", "kind": "notes", "records": [{"body": "第一行\nUnicode 🪐\u0000second", "deleted": 12346.25, "id": "11111111-1111-4111-8111-111111111111", "modified": 12345.125, "pinned": true, "title": "測試筆記"}], "version": 1}"#
private let oracleSnippetsJSON = #"{"format": "utuvo.orbit.library", "kind": "snippets", "records": [{"body": "{{date}} {{name}} 🪐", "id": "11111111-1111-4111-8111-111111111111", "keyword": "meet", "modified": 12345.125, "pinned": true, "title": "Meeting"}], "version": 1}"#
private let oracleQuickLinksJSON = #"{"format": "utuvo.orbit.library", "kind": "quicklinks", "records": [{"id": "11111111-1111-4111-8111-111111111111", "pinned": true, "template": "https://example.com/search?q={query}", "title": "Search"}], "version": 1}"#

/// Counts how often a file was read, so a test can prove that nothing was
/// read without touching the file system.
private final class ReadCounter {
    var count = 0
}

/// Where the original oracle files live. They are only used to show that the
/// shipped copy is the same bytes.
private func oracleFolder() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("evidence/orbit-portable-libraries-20261029/oracle", isDirectory: true)
}

private func note(title: String = "t", body: String = "b",
                  id: UUID = UUID(), pinned: Bool = false,
                  modified: Double = 1000,
                  deleted: Double? = nil) -> QuickNote {
    QuickNote(id: id, title: title, body: body, pinned: pinned,
              modified: Date(timeIntervalSinceReferenceDate: modified),
              deleted: deleted.map { Date(timeIntervalSinceReferenceDate: $0) })
}

private func snippet(title: String = "t", keyword: String = "k", body: String = "b",
                      id: UUID = UUID(), pinned: Bool = false,
                      modified: Double = 1000) -> Snippet {
    Snippet(id: id, title: title, keyword: keyword, body: body, pinned: pinned,
            modified: Date(timeIntervalSinceReferenceDate: modified))
}

private func link(title: String = "t", template: String = "https://example.com",
                   id: UUID = UUID(), pinned: Bool = false) -> QuickLink {
    QuickLink(id: id, title: title, template: template, pinned: pinned)
}

// MARK: - Pure core

/// The format itself: envelope, round trip, limits and the refusals.
struct LibraryBackupCoreTests {
    @Test func notesKeepEveryPartOfTheRecord() throws {
        let original = note(title: "測試筆記", body: "第一行\nUnicode 🪐\u{0}second",
                            pinned: true, modified: 12345.125, deleted: 12346.25)
        let data = try LibraryBackupCodec.encodeNotes([original])
        let decoded = try LibraryBackupCodec.decodeNotes(data)
        #expect(decoded == [original])
        // The dates keep their fraction instead of being cut to a date.
        #expect(decoded[0].modified.timeIntervalSinceReferenceDate == 12345.125)
        #expect(decoded[0].deleted?.timeIntervalSinceReferenceDate == 12346.25)
        #expect(decoded[0].id == original.id)
        #expect(decoded[0].pinned)
        // The trash stays trash.
        #expect(decoded[0].deleted != nil)
    }

    @Test func snippetsAndQuickLinksKeepEveryPartOfTheRecord() throws {
        let original = snippet(title: "Meeting", keyword: "meet", body: "{{date}} {{name}} 🪐",
                               pinned: true, modified: 12345.125)
        let decoded = try LibraryBackupCodec.decodeSnippets(try LibraryBackupCodec.encodeSnippets([original]))
        #expect(decoded == [original])
        #expect(decoded[0].modified.timeIntervalSinceReferenceDate == 12345.125)

        let address = link(title: "Search", template: "https://example.com/search?q={query}", pinned: true)
        let links = try LibraryBackupCodec.decodeQuickLinks(try LibraryBackupCodec.encodeQuickLinks([address]))
        #expect(links == [address])
    }

    @Test func theEnvelopeIsThePublishedShape() throws {
        let data = try LibraryBackupCodec.encodeNotes([note()])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["format"] as? String == "utuvo.orbit.library")
        #expect(object["version"] as? Int == 1)
        #expect(object["kind"] as? String == "notes")
        #expect((object["records"] as? [Any])?.count == 1)

        let snippets = try JSONSerialization.jsonObject(with: try LibraryBackupCodec.encodeSnippets([])) as? [String: Any]
        #expect(snippets?["kind"] as? String == "snippets")
        let links = try JSONSerialization.jsonObject(with: try LibraryBackupCodec.encodeQuickLinks([])) as? [String: Any]
        #expect(links?["kind"] as? String == "quicklinks")
    }

    @Test func theFixedOracleFilesDecode() throws {
        let notes = try LibraryBackupCodec.decodeNotes(Data(oracleNotesJSON.utf8))
        #expect(notes.count == 1)
        #expect(notes[0].id.uuidString == "11111111-1111-4111-8111-111111111111")
        #expect(notes[0].title == "測試筆記")
        #expect(notes[0].body == "第一行\nUnicode 🪐\u{0}second")
        #expect(notes[0].pinned)
        #expect(notes[0].modified.timeIntervalSinceReferenceDate == 12345.125)
        #expect(notes[0].deleted?.timeIntervalSinceReferenceDate == 12346.25)

        let snippets = try LibraryBackupCodec.decodeSnippets(Data(oracleSnippetsJSON.utf8))
        #expect(snippets.count == 1)
        #expect(snippets[0].title == "Meeting")
        #expect(snippets[0].keyword == "meet")
        #expect(snippets[0].body == "{{date}} {{name}} 🪐")
        #expect(snippets[0].modified.timeIntervalSinceReferenceDate == 12345.125)

        let links = try LibraryBackupCodec.decodeQuickLinks(Data(oracleQuickLinksJSON.utf8))
        #expect(links.count == 1)
        #expect(links[0].title == "Search")
        #expect(links[0].template == "https://example.com/search?q={query}")
        #expect(links[0].pinned)

        // The shipped copy is the same bytes as the original files.
        let folder = oracleFolder()
        if let original = try? Data(contentsOf: folder.appendingPathComponent("notes.json")) {
            #expect(original == Data((oracleNotesJSON + "\n").utf8))
        }
        if let original = try? Data(contentsOf: folder.appendingPathComponent("snippets.json")) {
            #expect(original == Data((oracleSnippetsJSON + "\n").utf8))
        }
        if let original = try? Data(contentsOf: folder.appendingPathComponent("quicklinks.json")) {
            #expect(original == Data((oracleQuickLinksJSON + "\n").utf8))
        }
    }

    @Test func anotherFormatVersionOrKindIsRefused() throws {
        let otherFormat = Data(#"{"format":"other.library","version":1,"kind":"notes","records":[]}"#.utf8)
        #expect(throws: LibraryBackupError.notABackupFile) { try LibraryBackupCodec.decodeNotes(otherFormat) }
        let otherVersion = Data(#"{"format":"utuvo.orbit.library","version":2,"kind":"notes","records":[]}"#.utf8)
        #expect(throws: LibraryBackupError.unsupportedVersion(2)) { try LibraryBackupCodec.decodeNotes(otherVersion) }
        let otherKind = Data(#"{"format":"utuvo.orbit.library","version":1,"kind":"snippets","records":[]}"#.utf8)
        #expect(throws: LibraryBackupError.wrongKind(expected: .notes)) { try LibraryBackupCodec.decodeNotes(otherKind) }
        let broken = Data(#"{"format":"utuvo.orbit.library","version":1,"kind":"notes","records":[{"id":"nope"}]}"#.utf8)
        #expect(throws: LibraryBackupError.malformed) { try LibraryBackupCodec.decodeNotes(broken) }
    }

    @Test func everyRecordLimitIsEnforced() throws {
        // Notes: at most 100, title 120, body 64 KiB, finite dates, unique IDs.
        let tooMany = (0...100).map { _ in note() }
        #expect(throws: LibraryBackupError.recordInvalid(.tooManyRecords)) { try LibraryBackupValidation.notes(tooMany) }
        let repeated = UUID()
        let sameID = [note(title: "t", id: repeated), note(title: "t", id: repeated)]
        #expect(throws: LibraryBackupError.recordInvalid(.duplicateIdentifier)) { try LibraryBackupValidation.notes(sameID) }
        #expect(throws: LibraryBackupError.recordInvalid(.titleTooLong)) {
            try LibraryBackupValidation.notes([note(title: String(repeating: "字", count: 121))])
        }
        #expect(throws: LibraryBackupError.recordInvalid(.bodyTooLarge)) {
            try LibraryBackupValidation.notes([note(title: "t", body: String(repeating: "a", count: 65_537))])
        }
        #expect(throws: LibraryBackupError.recordInvalid(.invalidDate)) {
            try LibraryBackupValidation.notes([QuickNote(title: "t", body: "", modified: Date(timeIntervalSince1970: .infinity))])
        }
        // An empty note title is valid.
        #expect(throws: Never.self) { try LibraryBackupValidation.notes([note(title: "")]) }

        // Snippets: a title is needed, a keyword is unique, the body may be an
        // unfinished template.
        #expect(throws: LibraryBackupError.recordInvalid(.emptyTitle)) {
            try LibraryBackupValidation.snippets([snippet(title: "   ")])
        }
        #expect(throws: LibraryBackupError.recordInvalid(.duplicateKeyword)) {
            try LibraryBackupValidation.snippets([snippet(title: "t", keyword: "Meet"), snippet(title: "t", keyword: " meet ")])
        }
        #expect(throws: Never.self) {
            try LibraryBackupValidation.snippets([snippet(title: "t", body: "{{date}} {{unclosed")])
        }

        // Quick links: a fixed http(s) template with a title.
        #expect(throws: LibraryBackupError.recordInvalid(.emptyTitle)) {
            try LibraryBackupValidation.quickLinks([link(title: " ")])
        }
        #expect(throws: LibraryBackupError.recordInvalid(.invalidTemplate)) {
            try LibraryBackupValidation.quickLinks([link(title: "t", template: "example.com")])
        }
        #expect(throws: LibraryBackupError.recordInvalid(.templateTooLong)) {
            try LibraryBackupValidation.quickLinks([link(title: "t", template: "https://example.com/" + String(repeating: "a", count: 2048))])
        }
    }

    @Test func aPathologicalDocumentIsRefusedBeforeItIsDecoded() throws {
        let deep = String(repeating: "[", count: 40) + String(repeating: "]", count: 40)
        #expect(throws: LibraryBackupError.tooDeep) { try LibraryBackupCodec.decodeNotes(Data(deep.utf8)) }
        // Braces inside a quoted string are text, not nesting.
        let quoted = "\"" + String(repeating: "{", count: 200) + "\""
        #expect(throws: Never.self) { try LibraryBackupJSON.checkDepth(Data(quoted.utf8)) }
        // A record may hold braces in its text.
        let original = note(title: "{{date}} { } [ ] {{{")
        #expect(try LibraryBackupCodec.decodeNotes(try LibraryBackupCodec.encodeNotes([original])) == [original])
    }

    @Test func anOversizedDocumentIsRefused() throws {
        let huge = Data(repeating: 0x20, count: LibraryBackupFormat.maxEncodedBytes + 1)
        #expect(throws: LibraryBackupError.tooLarge) { try LibraryBackupCodec.decodeNotes(huge) }
    }

    @Test func aMergeSkipsWhatIsAlreadyThereAndRefusesWhatConflicts() throws {
        let shared = UUID()
        let current: [LibraryBackupRecord] = [.note(note(title: "here", id: shared))]
        let same: [LibraryBackupRecord] = [.note(note(title: "here", id: shared))]
        let plan = try LibraryBackupPlanner.plan(kind: .notes, current: current, incoming: same)
        #expect(plan.additions.isEmpty)
        #expect(plan.identicalCount == 1)

        let other: [LibraryBackupRecord] = [.note(note(title: "different", id: shared))]
        #expect(throws: LibraryBackupError.conflictingRecord) {
            try LibraryBackupPlanner.plan(kind: .notes, current: current, incoming: other)
        }
    }

    @Test func aRepeatedIdentifierInThePayloadIsRefused() throws {
        let repeated = UUID()
        let incoming: [LibraryBackupRecord] = [.note(note(id: repeated)), .note(note(title: "two", id: repeated))]
        #expect(throws: LibraryBackupError.recordInvalid(.duplicateIdentifier)) {
            try LibraryBackupPlanner.plan(kind: .notes, current: [], incoming: incoming)
        }
    }

    @Test func aKeywordThatAnotherRecordUsesIsRefused() throws {
        let owner = UUID()
        let current: [LibraryBackupRecord] = [.snippet(snippet(title: "t", keyword: "Meet", id: owner))]
        let incoming: [LibraryBackupRecord] = [.snippet(snippet(title: "t", keyword: " meet "))]
        #expect(throws: LibraryBackupError.duplicateKeyword) {
            try LibraryBackupPlanner.plan(kind: .snippets, current: current, incoming: incoming)
        }
        // The very same record may keep its own keyword.
        let same: [LibraryBackupRecord] = [.snippet(snippet(title: "t", keyword: "Meet", id: owner))]
        let plan = try LibraryBackupPlanner.plan(kind: .snippets, current: current, incoming: same)
        #expect(plan.additions.isEmpty)
        #expect(plan.identicalCount == 1)
        // The same ID with another content is a conflict, whatever the case.
        let changed: [LibraryBackupRecord] = [.snippet(snippet(title: "t", keyword: "MEET", id: owner))]
        #expect(throws: LibraryBackupError.conflictingRecord) {
            try LibraryBackupPlanner.plan(kind: .snippets, current: current, incoming: changed)
        }
    }

    @Test func twoRecordsThatOnlyLookTheSameAreNotTheSameRecord() throws {
        let identifier = UUID()
        let composed = "Caf\u{E9}"
        let decomposed = "Cafe\u{301}"
        // Swift says the two texts are the same string, but the bytes are not.
        #expect(composed == decomposed)
        #expect(Data(composed.utf8) != Data(decomposed.utf8))
        #expect(composed.utf8.count == 5)
        #expect(decomposed.utf8.count == 6)

        let current: [LibraryBackupRecord] = [.note(note(title: composed, id: identifier))]
        let incoming: [LibraryBackupRecord] = [.note(note(title: decomposed, id: identifier))]
        // The same ID with other bytes is a conflict, not a skip.
        #expect(throws: LibraryBackupError.conflictingRecord) {
            try LibraryBackupPlanner.plan(kind: .notes, current: current, incoming: incoming)
        }
        #expect(throws: LibraryBackupError.conflictingRecord) {
            try LibraryBackupPlanner.plan(kind: .notes, current: incoming, incoming: current)
        }
    }

    @Test func aMergedLibraryThatIsTooBigIsRefusedWhole() throws {
        let current = (0..<100).map { _ in LibraryBackupRecord.note(note()) }
        let incoming: [LibraryBackupRecord] = [.note(note())]
        #expect(throws: LibraryBackupError.limitExceeded) {
            try LibraryBackupPlanner.plan(kind: .notes, current: current, incoming: incoming)
        }
    }

    @Test func onlyRegularFilesAreReadAndTheReadIsBounded() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appendingPathComponent("notes.json")
        try Data("{}".utf8).write(to: file)
        #expect(throws: Never.self) { try LibraryBackupFileIO.readBackup(at: file) }

        // A folder is not a backup file.
        #expect(throws: LibraryBackupError.notRegularFile) { try LibraryBackupFileIO.readBackup(at: root) }

        // A link is not followed.
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: LibraryBackupError.notRegularFile) { try LibraryBackupFileIO.readBackup(at: link) }

        // A pipe is refused instead of waiting for a writer.
        let pipe = root.appendingPathComponent("pipe.json")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: LibraryBackupError.notRegularFile) { try LibraryBackupFileIO.readBackup(at: pipe) }

        // A file that is too big is refused before it is read.
        let big = root.appendingPathComponent("big.json")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(LibraryBackupFormat.maxEncodedBytes) + 1)
        try handle.close()
        #expect(throws: LibraryBackupError.tooLarge) { try LibraryBackupFileIO.readBackup(at: big) }
    }

    @Test func anExportedBackupIsPrivateAndReadsBack() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = note(title: "private", body: "text")
        let data = try LibraryBackupCodec.encodeNotes([original])

        let folder = try LibraryBackupFileIO.writeBackup(data, kind: .notes, to: root)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.count == 1)
        let file = folder.appendingPathComponent(names[0])
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let read = try LibraryBackupFileIO.readBackup(at: file)
        #expect(try LibraryBackupCodec.decodeNotes(read) == [original])

        // A second export never touches the first one.
        let second = try LibraryBackupFileIO.writeBackup(data, kind: .notes, to: root)
        #expect(second != folder)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 2)
    }
}

// MARK: - The models and the transfer

/// The transfer itself: a preview never writes, an apply writes once, and a
/// refusal changes nothing.
@MainActor
struct LibraryTransferTests {
    @Test func aPreviewNeverWritesAndAnApplyAddsEveryRecord() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        let notesFile = root.appendingPathComponent("notes.json")
        #expect(model.notes.isEmpty)

        let incoming = [note(title: "一", body: "b", modified: 10), note(title: "", body: "", modified: 20)]
        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes(incoming).write(to: file)

        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan?.additions.count == 2)
        #expect(controller.failure == nil)
        // The preview wrote nothing at all.
        #expect(!FileManager.default.fileExists(atPath: notesFile.path))

        controller.apply()
        #expect(controller.failure == nil)
        #expect(model.notes == incoming)
        #expect(FileManager.default.fileExists(atPath: notesFile.path))
        // The first imported note is selected, because the library was empty.
        #expect(model.selectedID == incoming[0].id)

        // A reload sees exactly the same library.
        let reloaded = QuickNotesModel(root: root, preview: false)
        #expect(reloaded.notes == incoming)
    }

    @Test func anImportWithNothingNewChangesNothing() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        let notesFile = root.appendingPathComponent("notes.json")
        let incoming = [note(title: "一", body: "b")]
        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes(incoming).write(to: file)

        let first = LibraryBackupController(model: model, preview: false)
        first.load(file)
        first.apply()
        let bytesAfterFirst = try Data(contentsOf: notesFile)

        let second = LibraryBackupController(model: model, preview: false)
        second.load(file)
        #expect(second.plan?.additions.isEmpty == true)
        #expect(second.plan?.identicalCount == 1)
        second.apply()
        // Nothing new means no write at all.
        #expect(try Data(contentsOf: notesFile) == bytesAfterFirst)
        #expect(model.notes == incoming)
    }

    @Test func aDirtyDraftBlocksEveryTransfer() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        #expect(model.create(title: "a", body: "b"))
        model.editBody("changed")
        #expect(model.dirty)

        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "new")]).write(to: file)

        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        // The preview did not flush the draft either.
        #expect(model.dirty)
        #expect(model.notes.count == 1)
    }

    @Test func aDamagedLibraryBlocksEveryTransfer() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("this is not json".utf8).write(to: root.appendingPathComponent("notes.json"))
        let model = QuickNotesModel(root: root, preview: false)
        #expect(model.needsRecovery)

        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "new")]).write(to: file)
        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        // The damaged bytes are still there.
        #expect(try Data(contentsOf: root.appendingPathComponent("notes.json")) == Data("this is not json".utf8))
    }

    @Test func aPreviewThatWentOutOfDateIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "one"), note(title: "two")]).write(to: file)

        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan?.additions.count == 2)
        #expect(model.create(title: "new", body: "b"))

        controller.apply()
        #expect(controller.failure != nil)
        #expect(controller.plan == nil)
        // The refused import changed nothing.
        #expect(model.notes.count == 1)
        #expect(model.notes[0].title == "new")
    }

    @Test func anEditingSessionDropsThePreview() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "one")]).write(to: file)

        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan != nil)
        #expect(model.create(title: "new", body: "b"))

        for _ in 0..<50 where controller.plan != nil { await Task.yield() }
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
    }

    @Test func aFailedImportKeepsEverythingAndCanBeRetried() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        #expect(model.create(title: "keep", body: "b"))
        let notesFile = root.appendingPathComponent("notes.json")
        let before = try Data(contentsOf: notesFile)
        let selected = model.selectedID

        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "new")]).write(to: file)
        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)

        // The save cannot land while the folder cannot be written.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        controller.apply()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        #expect(controller.failure != nil)
        #expect(model.notes.count == 1)
        #expect(model.selectedID == selected)
        #expect(model.notes[0].title == "keep")
        // The file on disk still holds the library as it was.
        #expect(try Data(contentsOf: notesFile) == before)

        // The retry works and the file holds the merged library.
        controller.apply()
        #expect(controller.failure == nil)
        #expect(model.notes.count == 2)
        let reloaded = QuickNotesModel(root: root, preview: false)
        #expect(reloaded.notes == model.notes)
    }

    @Test func theSameIdentifierWithAnotherContentIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        #expect(model.create(title: "here", body: "b"))
        let identifier = try #require(model.notes.first?.id)

        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "different", id: identifier)]).write(to: file)
        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        #expect(model.notes.count == 1)
        #expect(model.notes[0].title == "here")
    }

    @Test func aKeywordThatAnotherRecordUsesIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root, preview: false)
        #expect(model.create(title: "A", body: "b", keyword: "Meet"))

        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeSnippets([snippet(title: "B", keyword: " meet ")]).write(to: file)
        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        #expect(model.snippets.count == 1)
        #expect(model.snippets[0].title == "A")
    }

    @Test func snippetsAndQuickLinksAreImportedTheSameWay() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let snippets = SnippetsModel(root: root, preview: false)
        let snippetFile = root.appendingPathComponent("snippets.json")
        try LibraryBackupCodec.encodeSnippets([snippet(title: "Meeting", keyword: "meet", body: "{{date}}")]).write(to: snippetFile)
        let snippetController = LibraryBackupController(model: snippets, preview: false)
        snippetController.load(snippetFile)
        #expect(snippetController.plan?.additions.count == 1)
        snippetController.apply()
        #expect(snippets.snippets.count == 1)
        #expect(snippets.snippets[0].keyword == "meet")
        let reloadedSnippets = SnippetsModel(root: root, preview: false)
        #expect(reloadedSnippets.snippets == snippets.snippets)

        let links = QuickLinksModel(root: root, preview: false, opener: PreviewQuickLinkOpener())
        let linkFile = root.appendingPathComponent("quicklinks.json")
        try LibraryBackupCodec.encodeQuickLinks([link(title: "Search", template: "https://example.com/search?q={query}")]).write(to: linkFile)
        let linkController = LibraryBackupController(model: links, preview: false)
        linkController.load(linkFile)
        #expect(linkController.plan?.additions.count == 1)
        linkController.apply()
        #expect(links.links.count == 1)
        #expect(links.links[0].template == "https://example.com/search?q={query}")
        let reloadedLinks = QuickLinksModel(root: root, preview: false, opener: PreviewQuickLinkOpener())
        #expect(reloadedLinks.links == links.links)
    }

    @Test func anImportedTrashRecordStaysTrashAndPinsSurvive() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        #expect(model.create(title: "pinned", body: "b"))
        model.pin(model.notes[0].id)

        let file = root.appendingPathComponent("incoming.json")
        try LibraryBackupCodec.encodeNotes([note(title: "trashed", body: "", deleted: 500)]).write(to: file)
        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        controller.apply()
        #expect(model.notes.count == 2)
        #expect(model.notes[0].pinned)
        #expect(model.notes[1].deleted != nil)
        // The trash is not restored by an import.
        #expect(model.notes[1].deleted?.timeIntervalSinceReferenceDate == 500)
    }

    @Test func anOlderPreviewIsNeverActionableAfterANewerFile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        let good = root.appendingPathComponent("good.json")
        try LibraryBackupCodec.encodeNotes([note(title: "good")]).write(to: good)
        let bad = root.appendingPathComponent("bad.json")
        try Data(#"{"format":"utuvo.orbit.library","version":1,"kind":"snippets","records":[]}"#.utf8).write(to: bad)

        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(good)
        #expect(controller.plan != nil)
        controller.load(bad)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        controller.apply()
        #expect(model.notes.isEmpty)
    }

    @Test func aStaleTitleThatOnlyLooksTheSameIsStillStale() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickLinksModel(root: root, preview: false, opener: PreviewQuickLinkOpener())
        #expect(model.add(title: "Caf\u{E9}", template: "https://example.com"))
        let identifier = try #require(model.links.first?.id)
        let original = try #require(model.links.first?.title)

        let file = root.appendingPathComponent("incoming.json")
        let incoming = [link(title: "Caf\u{E9}", template: "https://example.com", id: identifier),
                        link(title: "Second", template: "https://example.org", id: UUID())]
        try LibraryBackupCodec.encodeQuickLinks(incoming).write(to: file)

        let controller = LibraryBackupController(model: model, preview: false)
        controller.load(file)
        #expect(controller.plan?.identicalCount == 1)
        #expect(controller.plan?.additions.count == 1)

        // The title changes to the same text in another form. Swift calls the
        // two the same, the bytes are not.
        #expect(model.update(identifier, title: "Cafe\u{301}", template: "https://example.com"))
        #expect(model.links[0].title == original)
        #expect(Data(model.links[0].title.utf8) != Data(original.utf8))

        controller.apply()
        #expect(controller.failure != nil)
        #expect(controller.plan == nil)
        // The refused import added nothing.
        #expect(model.links.count == 1)
    }

    @Test func thePreviewModeRefusesTheTransferWithoutReadingAnything() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        let counter = ReadCounter()
        let controller = LibraryBackupController(model: model, preview: true, readFile: { _ in
            counter.count += 1
            return Data()
        })
        controller.load(root.appendingPathComponent("anything.json"))
        #expect(counter.count == 0)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)

        // The apply refuses too, and nothing is written.
        controller.apply()
        #expect(counter.count == 0)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        #expect(model.notes.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("notes.json").path))
    }

    @Test func aDirtyDraftOrADamagedLibraryIsRefusedBeforeAnythingIsRead() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickNotesModel(root: root, preview: false)
        #expect(model.create(title: "a", body: "b"))
        model.editBody("changed")
        #expect(model.dirty)

        let counter = ReadCounter()
        let controller = LibraryBackupController(model: model, preview: false, readFile: { _ in
            counter.count += 1
            return Data()
        })
        controller.load(root.appendingPathComponent("anything.json"))
        #expect(counter.count == 0)
        #expect(controller.plan == nil)
        #expect(controller.failure != nil)
        #expect(model.dirty)

        // A damaged library is refused the same way.
        try Data("not json".utf8).write(to: root.appendingPathComponent("notes.json"))
        let damaged = QuickNotesModel(root: root, preview: false)
        #expect(damaged.needsRecovery)
        let secondCounter = ReadCounter()
        let second = LibraryBackupController(model: damaged, preview: false, readFile: { _ in
            secondCounter.count += 1
            return Data()
        })
        second.load(root.appendingPathComponent("anything.json"))
        #expect(secondCounter.count == 0)
        #expect(second.plan == nil)
        #expect(second.failure != nil)
    }

    @Test func aFailedResetKeepsTheLibraryDamagedAndTheOldBytes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("notes.json")
        let broken = Data("this is not json".utf8)
        try broken.write(to: file)

        let storage = ToolStorage<[QuickNote]>(nil, "notes", fileURL: file)
        #expect(storage.load(fallback: [], validate: { _ in true }).isEmpty)
        #expect(storage.damaged)

        // The reset cannot land while the commit fails.
        storage.beforeFileCommit = { throw WorkbenchError.invalid("injected failure / 注入失敗") }
        #expect(throws: WorkbenchError.self) { try storage.backupAndReset([]) }
        // The library is still damaged and the old bytes are still there.
        #expect(storage.damaged)
        #expect(try Data(contentsOf: file) == broken)
        // The raw backup of the damaged file was kept.
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("notes.json.backup.") }
        #expect(backups.count == 1)
        #expect(try Data(contentsOf: root.appendingPathComponent(backups[0])) == broken)

        // Without the failure the reset works and the library is healthy.
        storage.beforeFileCommit = nil
        try storage.backupAndReset([])
        #expect(storage.damaged == false)
        #expect(try Data(contentsOf: file) == Data("[]".utf8))
        let reopened = ToolStorage<[QuickNote]>(nil, "notes", fileURL: file)
        #expect(reopened.load(fallback: [], validate: { _ in true }).isEmpty)
        #expect(reopened.damaged == false)
    }

    @Test func aFailedWriteKeepsTheOldFileAndLeavesNoTemp() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The folder does not exist yet, so the storage makes it private.
        let folder = root.appendingPathComponent("library", isDirectory: true)
        let file = folder.appendingPathComponent("notes.json")
        let storage = ToolStorage<[QuickNote]>(nil, "notes", fileURL: file)
        try storage.save([note(title: "first")])
        let before = try Data(contentsOf: file)

        storage.beforeFileCommit = { throw WorkbenchError.invalid("injected failure / 注入失敗") }
        #expect(throws: WorkbenchError.self) { try storage.save([note(title: "second")]) }

        // The file still holds the first version and no temp file is left.
        #expect(try Data(contentsOf: file) == before)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0 != "notes.json" }
        #expect(leftovers.isEmpty)

        // Without the failure the file is replaced and stays private.
        storage.beforeFileCommit = nil
        try storage.save([note(title: "second")])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try Data(contentsOf: file) != before)
    }
}
