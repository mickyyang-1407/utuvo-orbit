import Foundation
import Testing
@testable import UtuvoOrbit

/// Phase 1 of the expansion ticket: web quick links only.
/// No window, no browser, no pasteboard, no real network — the opener is injected.
@MainActor
struct QuickLinksTests {
    // MARK: - Templates

    @Test func fixedTemplateOpensWithoutAQuery() throws {
        let url = try QuickLinkTemplate.build(template: "https://utuvo.app", query: nil)
        #expect(url.absoluteString == "https://utuvo.app")
        #expect(url.host == "utuvo.app")
    }

    @Test func aFixedHostMayContainTheProbeText() throws {
        let url = try QuickLinkTemplate.build(template: "https://orbitqueryplaceholder.example/path", query: nil)
        #expect(url.host == "orbitqueryplaceholder.example")
        let templated = try QuickLinkTemplate.build(template: "https://orbitqueryplaceholder.example/search?q={query}", query: "swift")
        #expect(templated.host == "orbitqueryplaceholder.example")
        #expect(templated.absoluteString == "https://orbitqueryplaceholder.example/search?q=swift")
    }

    @Test func queryPlaceholderFillsInPathAndQuery() throws {
        let inPath = try QuickLinkTemplate.build(template: "https://example.com/find/{query}", query: "swift")
        #expect(inPath.absoluteString == "https://example.com/find/swift")
        let inQuery = try QuickLinkTemplate.build(template: "https://example.com/search?q={query}", query: "swift")
        #expect(inQuery.absoluteString == "https://example.com/search?q=swift")
    }

    @Test func onlyTheQueryPlaceholderIsSupported() {
        #expect(throws: QuickLinkError.unsupportedPlaceholder) { try QuickLinkTemplate.validate("https://example.com/{term}") }
        #expect(throws: QuickLinkError.unsupportedPlaceholder) { try QuickLinkTemplate.validate("https://example.com/{{query}}") }
        #expect(throws: QuickLinkError.unclosedPlaceholder) { try QuickLinkTemplate.validate("https://example.com/{query") }
        #expect(throws: QuickLinkError.unclosedPlaceholder) { try QuickLinkTemplate.validate("https://example.com/{que") }
    }

    @Test func queryPlaceholderIsRefusedInSchemeAuthorityAndFragment() {
        #expect(throws: QuickLinkError.placeholderNotAllowed) { try QuickLinkTemplate.validate("{query}://example.com/") }
        #expect(throws: QuickLinkError.placeholderNotAllowed) { try QuickLinkTemplate.validate("https://{query}.example.com/") }
        #expect(throws: QuickLinkError.placeholderNotAllowed) { try QuickLinkTemplate.validate("https://user{query}@example.com/") }
        #expect(throws: QuickLinkError.placeholderNotAllowed) { try QuickLinkTemplate.validate("https://example.com/#{query}") }
    }

    @Test(arguments: [
        ("ftp://example.com/", QuickLinkError.unsupportedScheme),
        ("example.com/path", QuickLinkError.unsupportedScheme),
        ("/relative/path", QuickLinkError.unsupportedScheme),
        ("https://", QuickLinkError.missingHost),
        ("https://user@example.com/", QuickLinkError.userInfoNotAllowed),
        ("https://user:secret@example.com/", QuickLinkError.userInfoNotAllowed),
        ("https://example.com/\u{0}", QuickLinkError.controlCharacters),
        ("https://example.com/\n", QuickLinkError.controlCharacters)
    ])
    func unsafeTemplatesAreRejected(_ template: String, _ expected: QuickLinkError) {
        #expect(throws: expected) { try QuickLinkTemplate.validate(template) }
    }

    @Test func queryIsPercentEncodedExactlyOnceWithUnreservedCharacters() throws {
        let raw = "a&b=c#d/e+f%g 中文"
        let url = try QuickLinkTemplate.build(template: "https://example.com/s?q={query}", query: raw)
        #expect(url.absoluteString == "https://example.com/s?q=a%26b%3Dc%23d%2Fe%2Bf%25g%20%E4%B8%AD%E6%96%87")
        // The separators survive only as data, never as URL structure.
        #expect(url.host == "example.com")
        #expect(url.path == "/s")
        let query = try #require(url.query)
        #expect(!query.contains("&"))
        #expect(!query.contains("#"))
        #expect(!query.contains("/"))
        #expect(!query.contains("+"))
        #expect(query == "q=a%26b%3Dc%23d%2Fe%2Bf%25g%20%E4%B8%AD%E6%96%87")
        #expect(QuickLinkTemplate.percentEncode("%") == "%25")
        #expect(QuickLinkTemplate.percentEncode("a-b_c.d~e") == "a-b_c.d~e")
    }

    @Test func emptyQueryIsAnErrorAndNeverNavigates() throws {
        #expect(throws: QuickLinkError.emptyQuery) { try QuickLinkTemplate.build(template: "https://example.com/?q={query}", query: "") }
        #expect(throws: QuickLinkError.emptyQuery) { try QuickLinkTemplate.build(template: "https://example.com/?q={query}", query: nil) }
        #expect(throws: QuickLinkError.unexpectedQuery) { try QuickLinkTemplate.build(template: "https://utuvo.app", query: "swift") }
    }

    @Test func queryAndFinalURLHaveHardLimits() {
        #expect(throws: QuickLinkError.queryTooLong) {
            try QuickLinkTemplate.build(template: "https://example.com/?q={query}", query: String(repeating: "a", count: 2049))
        }
        #expect(throws: QuickLinkError.urlTooLong) {
            try QuickLinkTemplate.build(template: "https://example.com/?q={query}", query: String(repeating: "中", count: 1000))
        }
        #expect(throws: QuickLinkError.templateTooLong) {
            try QuickLinkTemplate.validate("https://example.com/" + String(repeating: "a", count: 2049))
        }
    }

    // MARK: - Model

    @Test func linksAreStoredInAPrivateFileAndReloaded() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickLinksModel(root: root)
        #expect(model.add(title: "UTUVO", template: "https://utuvo.app"))
        #expect(model.links.count == 1)

        let file = root.appendingPathComponent("quicklinks.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let reloaded = QuickLinksModel(root: root)
        #expect(reloaded.links.count == 1)
        #expect(reloaded.links.first?.title == "UTUVO")
        #expect(reloaded.links.first?.template == "https://utuvo.app")
        #expect(reloaded.needsRecovery == false)
    }

    @Test func previewKeepsEverythingInMemory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickLinksModel(root: root, preview: true)
        #expect(model.add(title: "UTUVO", template: "https://utuvo.app"))
        #expect(model.links.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("quicklinks.json").path))
    }

    @Test func damagedStorageIsBackedUpAndResetOnlyWhenAsked() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("quicklinks.json")
        try Data("not json at all".utf8).write(to: file)

        let model = QuickLinksModel(root: root)
        #expect(model.needsRecovery)
        #expect(model.links.isEmpty)
        // A damaged store refuses to be written until it is reset on purpose.
        #expect(model.add(title: "UTUVO", template: "https://utuvo.app") == false)

        model.recover()
        #expect(model.needsRecovery == false)
        #expect(model.links.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("quicklinks.json.backup.") }
        #expect(backups.count == 1)
        #expect(model.add(title: "UTUVO", template: "https://utuvo.app"))
    }

    @Test func limitsAndValidationGuardTheSavedList() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickLinksModel(root: root)
        #expect(model.add(title: "   ", template: "https://utuvo.app") == false)
        #expect(model.add(title: String(repeating: "t", count: 121), template: "https://utuvo.app") == false)
        #expect(model.add(title: "Bad", template: "not a url") == false)
        #expect(model.add(title: "Bad", template: "https://example.com/{term}") == false)
        for index in 0..<50 { #expect(model.add(title: "Link \(index)", template: "https://example.com/\(index)")) }
        #expect(model.links.count == 50)
        #expect(model.add(title: "One too many", template: "https://example.com/51") == false)
        #expect(model.links.count == 50)
    }

    @Test func searchingPinningEditingAndRemovingWork() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QuickLinksModel(root: root)
        #expect(model.add(title: "UTUVO", template: "https://utuvo.app"))
        #expect(model.add(title: "Search", template: "https://example.com/search?q={query}"))
        model.query = "search"
        #expect(model.visible.count == 1)
        #expect(model.visible.first?.title == "Search")
        model.query = ""

        let search = try #require(model.links.first { $0.title == "Search" })
        #expect(model.togglePin(search.id))
        #expect(model.link(search.id)?.pinned == true)
        #expect(model.visible.first?.title == "Search")

        #expect(model.update(search.id, title: "Lookup", template: "https://example.com/find?q={query}"))
        #expect(model.link(search.id)?.title == "Lookup")
        #expect(model.link(search.id)?.template == "https://example.com/find?q={query}")
        #expect(model.update(search.id, title: "Lookup", template: "nonsense") == false)
        #expect(model.link(search.id)?.template == "https://example.com/find?q={query}")

        #expect(model.remove(search.id))
        #expect(model.links.count == 1)
    }

    // MARK: - Opening

    @Test func fixedLinkOpensThroughTheInjectedOpener() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = PreviewQuickLinkOpener()
        let model = QuickLinksModel(root: root, opener: opener)
        #expect(model.add(title: "UTUVO", template: "https://utuvo.app"))
        let link = try #require(model.links.first)
        #expect(model.requestOpen(link.id))
        #expect(opener.opened.count == 1)
        #expect(opener.opened.first?.absoluteString == "https://utuvo.app")
        #expect(model.pendingLinkID == nil)
    }

    @Test func templateLinkWaitsForItsSearchTermAndNeverOpensEarly() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = PreviewQuickLinkOpener()
        let model = QuickLinksModel(root: root, opener: opener)
        #expect(model.add(title: "Search", template: "https://example.com/search?q={query}"))
        let link = try #require(model.links.first)

        #expect(model.requestOpen(link.id))
        #expect(opener.opened.isEmpty)
        #expect(model.pendingLinkID == link.id)

        model.pendingQuery = "swift & co"
        #expect(model.confirmPendingOpen())
        #expect(opener.opened.count == 1)
        #expect(opener.opened.first?.absoluteString == "https://example.com/search?q=swift%20%26%20co")
        #expect(model.pendingLinkID == nil)
    }

    @Test func anEmptySearchTermIsReportedAndNothingOpens() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = PreviewQuickLinkOpener()
        let model = QuickLinksModel(root: root, opener: opener)
        #expect(model.add(title: "Search", template: "https://example.com/search?q={query}"))
        let link = try #require(model.links.first)
        #expect(model.requestOpen(link.id))
        model.pendingQuery = ""
        #expect(model.confirmPendingOpen() == false)
        #expect(opener.opened.isEmpty)
        #expect(model.error != nil)
        #expect(model.pendingLinkID == link.id)
    }

    @Test func cancellingTheSearchTermOpensNothing() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let opener = PreviewQuickLinkOpener()
        let model = QuickLinksModel(root: root, opener: opener)
        #expect(model.add(title: "Search", template: "https://example.com/search?q={query}"))
        let link = try #require(model.links.first)
        #expect(model.requestOpen(link.id))
        model.cancelPendingOpen()
        #expect(model.pendingLinkID == nil)
        #expect(opener.opened.isEmpty)
    }

    // MARK: - Helpers

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OrbitQuickLinksTests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Phase 2 of the expansion ticket: plain-text snippets.
/// No window, no pasteboard, no global typing — the clipboard closure is injected.
@MainActor
struct SnippetTests {
    // MARK: - Template grammar

    @Test func dateAndTimeComeFromOneSharedSnapshot() throws {
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 29
        components.hour = 9; components.minute = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = taipei
        let snapshot = try #require(calendar.date(from: components))

        var calls = 0
        let now: () -> Date = { calls += 1; return snapshot }
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root, now: now, timeZone: taipei)
        #expect(model.create(title: "Standup", body: "{{date}} {{time}}"))

        calls = 0
        #expect(model.makePreview())
        #expect(calls == 1)
        #expect(model.preview == "2026-10-29 09:05")
    }

    @Test func aValueIsSubstitutedOnlyOnce() throws {
        let taipei = try #require(TimeZone(identifier: "Asia/Taipei"))
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root, timeZone: taipei)
        #expect(model.create(title: "Greeting", body: "Hi {{name}}"))
        model.setFieldValue("{{date}}", for: "name")
        #expect(model.makePreview())
        #expect(model.preview == "Hi {{date}}")
    }

    @Test func customFieldsAreResolvedAndMissingValuesAreRefused() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "Mail", body: "To {{name}} at {{city}}"))
        #expect(model.customFields.map(\.name) == ["name", "city"])
        #expect(model.makePreview() == false)
        #expect(model.previewError != nil)
        model.setFieldValue("Ada", for: "name")
        #expect(model.makePreview() == false)
        model.setFieldValue("Taipei", for: "city")
        #expect(model.makePreview())
        #expect(model.preview == "To Ada at Taipei")
    }

    @Test(arguments: [
        ("{{name", SnippetError.malformedBraces),
        ("{{name}", SnippetError.malformedBraces),
        ("{{clipboard}}", SnippetError.unsupportedPlaceholder),
        ("{{network}}", SnippetError.unsupportedPlaceholder),
        ("{{1name}}", SnippetError.invalidFieldName),
        ("{{na-me}}", SnippetError.invalidFieldName),
        ("{{name!}}", SnippetError.invalidFieldName),
        ("{{" + String(repeating: "n", count: 33) + "}}", SnippetError.invalidFieldName)
    ])
    func brokenTemplatesAreRejected(_ body: String, _ expected: SnippetError) {
        #expect(throws: expected) { try SnippetTemplate.parse(body) }
    }

    @Test func aSingleBraceIsOrdinaryText() throws {
        #expect(try SnippetTemplate.parse("a { b") == [.literal("a { b")])
        #expect(try SnippetTemplate.parse("{}") == [.literal("{}")])
        #expect(try SnippetTemplate.parse("{{date}}") == [.field("date")])
    }

    @Test func nestedJSONBracesStayOrdinaryText() throws {
        let json = #"{"user": {"name": "Ada", "id": 1}, "tags": ["a", "b"]}"#
        #expect(try SnippetTemplate.parse(json) == [.literal(json)])
        #expect(try SnippetTemplate.expand(json, values: [:], snapshot: Date(), timeZone: .current) == json)
        #expect(try SnippetTemplate.fields(in: json).isEmpty)
    }

    @Test(arguments: ["email", "url", "user", "path", "input", "name", "who", "company"])
    func ordinaryFieldNamesAreAvailableToTheUser(_ name: String) throws {
        let fields = try SnippetTemplate.fields(in: "{{\(name)}}")
        #expect(fields.count == 1)
        #expect(fields[0].name == name)
        #expect(fields[0].isBuiltIn == false)
    }

    @Test(arguments: ["clipboard", "network", "shell", "env", "system"])
    func namesThatWouldImplyAnAutomaticReadAreRefused(_ name: String) {
        #expect(throws: SnippetError.unsupportedPlaceholder) { try SnippetTemplate.parse("{{\(name)}}") }
    }

    @Test func aDateLookingValueStaysLiteral() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "Greeting", body: "Hi {{name}}"))
        model.setFieldValue("{{date}}", for: "name")
        #expect(model.makePreview())
        #expect(model.preview == "Hi {{date}}")
        // The built-in is not expanded a second time.
        #expect(model.preview?.contains("-") == false)
    }

    @Test func atMostSixteenCustomFieldsAreAllowed() throws {
        let body = (0..<17).map { "{{\(name(for: $0))}}" }.joined(separator: " ")
        #expect(throws: SnippetError.tooManyFields) { try SnippetTemplate.fields(in: body) }
        let ok = (0..<16).map { "{{\(name(for: $0))}}" }.joined(separator: " ")
        let fields = try SnippetTemplate.fields(in: ok)
        #expect(fields.count == 16)
    }

    @Test func builtInFieldsAreMarkedAndNotAskedFor() throws {
        let fields = try SnippetTemplate.fields(in: "{{date}} {{time}} {{who}}")
        #expect(fields.map(\.name) == ["date", "time", "who"])
        #expect(fields.filter(\.isBuiltIn).map(\.name) == ["date", "time"])
    }

    // MARK: - Model

    @Test func snippetsAreStoredInAPrivateFileAndReloaded() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "Standup", body: "{{date}}", keyword: "standup"))
        #expect(model.snippets.count == 1)

        let file = root.appendingPathComponent("snippets.json")
        #expect(FileManager.default.fileExists(atPath: file.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        let reloaded = SnippetsModel(root: root)
        #expect(reloaded.snippets.count == 1)
        #expect(reloaded.snippets.first?.title == "Standup")
        #expect(reloaded.snippets.first?.keyword == "standup")
        #expect(reloaded.snippets.first?.body == "{{date}}")
        #expect(reloaded.needsRecovery == false)
    }

    @Test func previewKeepsEverythingInMemory() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root, preview: true)
        #expect(model.create(title: "Standup", body: "{{date}}"))
        #expect(model.snippets.count == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("snippets.json").path))
    }

    @Test func damagedStorageIsBackedUpAndResetOnlyWhenAsked() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: root.appendingPathComponent("snippets.json"))

        let model = SnippetsModel(root: root)
        #expect(model.needsRecovery)
        #expect(model.snippets.isEmpty)
        #expect(model.create(title: "Blocked", body: "x") == false)

        model.recover()
        #expect(model.needsRecovery == false)
        #expect(model.snippets.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("snippets.json.backup.") }
        #expect(backups.count == 1)
        #expect(model.create(title: "Now it works", body: "x"))
    }

    @Test func theDefaultCreationPathWorks() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        // The New snippet button creates one with a localized default title.
        #expect(model.create(title: "新片段"))
        #expect(model.snippets.count == 1)
        #expect(model.selected?.title == "新片段")
        #expect(model.dirty == false)
        #expect(model.create(title: "New snippet"))
        #expect(model.snippets.count == 2)
        #expect(model.error == nil)
    }

    @Test func anInvalidEditedTitleIsKeptAndBlocksTheSave() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "Valid", body: "one"))
        #expect(model.create(title: "Second", body: "two"))
        #expect(model.selected?.title == "Second")

        // The user empties the title: the draft stays, the save is refused.
        model.editTitle("")
        #expect(model.dirty)
        #expect(model.flush() == false)
        #expect(model.error != nil)
        #expect(model.draftTitle == "")
        #expect(model.snippets.first { $0.title == "Valid" } != nil)

        // Switching to another snippet is blocked while the draft is invalid.
        let valid = try #require(model.snippets.first { $0.title == "Valid" })
        #expect(model.select(valid.id) == false)
        #expect(model.selected?.title == "Second")

        // The library on disk is untouched and still loads cleanly.
        let reloaded = SnippetsModel(root: root)
        #expect(reloaded.needsRecovery == false)
        #expect(reloaded.snippets.count == 2)
        #expect(reloaded.snippets.allSatisfy { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    @Test func keywordsStayUniqueIgnoringCase() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "First", body: "a", keyword: "Meet"))
        #expect(model.create(title: "Second", body: "b", keyword: "meet") == false)
        #expect(model.error != nil)
        #expect(model.snippets.count == 1)
        #expect(model.create(title: "Second", body: "b", keyword: "Standup"))
        #expect(model.snippets.count == 2)
    }

    @Test func limitsGuardTheSavedList() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "   ", body: "a") == false)
        #expect(model.create(title: String(repeating: "t", count: 121), body: "a") == false)
        #expect(model.create(title: "Fine", body: "a", keyword: String(repeating: "k", count: 33)) == false)
        #expect(model.create(title: "Fine", body: String(repeating: "b", count: 65_537)) == false)
        #expect(model.snippets.isEmpty)

        let chunk = String(repeating: "b", count: 61_440)
        for index in 0..<32 { #expect(model.create(title: "Snippet \(index)", body: chunk)) }
        #expect(model.snippets.count == 32)
        // 32 × 60 KiB is still under the 2 MB total; the next one is not.
        #expect(model.create(title: "One too many", body: chunk) == false)
        #expect(model.error != nil)
    }

    @Test func atMostOneHundredSnippetsAreKept() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        for index in 0..<100 { #expect(model.create(title: "Snippet \(index)", body: "x")) }
        #expect(model.snippets.count == 100)
        #expect(model.create(title: "One too many", body: "x") == false)
        #expect(model.error != nil)
        #expect(model.snippets.count == 100)
    }

    @Test func searchingPinningAndDeletingWork() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "Standup", body: "{{date}}", keyword: "daily"))
        #expect(model.create(title: "Invoice", body: "invoice", keyword: "billing"))

        model.query = "daily"
        #expect(model.visible.count == 1)
        #expect(model.visible.first?.title == "Standup")
        model.query = ""

        let invoice = try #require(model.snippets.first { $0.title == "Invoice" })
        #expect(model.pin(invoice.id))
        #expect(model.snippets.first { $0.id == invoice.id }?.pinned == true)
        #expect(model.visible.first?.title == "Invoice")

        // Deleting needs a confirmation.
        #expect(model.delete(invoice.id, confirmed: false) == false)
        #expect(model.snippets.count == 2)
        #expect(model.delete(invoice.id, confirmed: true))
        #expect(model.snippets.count == 1)
    }

    // MARK: - Drafts and failure

    @Test func aFailedSaveKeepsTheDraftAndStopsASelectionChange() throws {
        let root = temporaryRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "First", body: "one"))
        #expect(model.create(title: "Second", body: "two"))

        // Make the storage directory unwritable so the save really fails.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        model.editBody("two, edited")
        #expect(model.flush() == false)
        #expect(model.dirty)
        #expect(model.draftBody == "two, edited")
        #expect(model.error != nil)

        // The selection change is refused while the draft cannot be saved.
        let first = try #require(model.snippets.first { $0.title == "First" })
        #expect(model.select(first.id) == false)
        #expect(model.selected?.title == "Second")

        // The user can still discard the draft on purpose.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        model.discardDraft()
        #expect(model.dirty == false)
        #expect(model.draftBody == "two")
    }

    @Test func copyingIsExplicitAndUsesTheInjectedClosure() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var copied: [String] = []
        let model = SnippetsModel(root: root, copyText: { copied.append($0) })
        #expect(model.create(title: "Standup", body: "{{date}} {{who}}"))
        #expect(copied.isEmpty)

        model.setFieldValue("Ada", for: "who")
        #expect(copied.isEmpty)
        model.copyPreview()
        #expect(copied.count == 1)
        #expect(copied.first?.contains("Ada") == true)
        #expect(copied.first?.contains("{{date}}") == false)
    }

    @Test func sendingUsesTheExpansionAndNeverCopies() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var copied: [String] = []
        let model = SnippetsModel(root: root, copyText: { copied.append($0) })
        #expect(model.create(title: "Standup", body: "Hi {{name}}"))
        model.setFieldValue("Ada", for: "name")
        #expect(model.expansionForSending() == "Hi Ada")
        #expect(copied.isEmpty)
        model.setFieldValue("", for: "name")
        #expect(model.expansionForSending() == nil)
        #expect(model.previewError != nil)
    }

    @Test func aDraftSurvivesPageChangesBecauseTheModelIsKept() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SnippetsModel(root: root)
        #expect(model.create(title: "Draft", body: "hello"))
        model.editBody("hello again")
        #expect(model.dirty)
        // Another page of the workbench does not touch this model.
        #expect(model.draftBody == "hello again")
        #expect(model.flush())
        #expect(model.dirty == false)
    }

    // MARK: - Helpers

    private func name(for index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        return String(letters[index % 26]) + String(letters[(index / 26) % 26])
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("OrbitSnippetTests-\(UUID().uuidString)", isDirectory: true)
    }
}

/// Phase 3 of the expansion ticket: streaming file checksums.
/// Fixtures only — no window, no pasteboard, no file outside the temporary folder.
@MainActor
struct FileIntegrityTests {
    // Reference vectors produced with Python's hashlib, so they do not come
    // from this implementation.
    static let abcSHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let abcSHA512 = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"
    static let abcMD5 = "900150983cd24fb0d6963f7d28e17f72"
    static let emptySHA256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let emptySHA512 = "cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e"
    static let emptyMD5 = "d41d8cd98f00b204e9800998ecf8427e"
    /// 3,000,000 bytes of "Orbit" — more than two 1 MiB chunks.
    static let bigSHA256 = "5931b431996404807d370d8ff123693177b258581d365de57aafbbd2c048f25b"
    static let bigSHA512 = "2aff5fd7fc73c58c19beb06fdcfd3e87dc7c25faa73b0a75ded69c00c96dad22b20f48d60d15837bc2f3375f4845841f6db57bec6843752f524822f251ed9f38"
    static let bigMD5 = "51ebbca7147dd2770ea0a792d36ca5ff"

    // MARK: - Known answers

    @Test func theKnownAnswersMatchTheReferenceVectors() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let abc = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: abc)
        let empty = directory.appendingPathComponent("empty.txt")
        try Data().write(to: empty)

        #expect(try digest(of: abc, .sha256) == Self.abcSHA256)
        #expect(try digest(of: abc, .sha512) == Self.abcSHA512)
        #expect(try digest(of: abc, .md5) == Self.abcMD5)
        #expect(try digest(of: empty, .sha256) == Self.emptySHA256)
        #expect(try digest(of: empty, .sha512) == Self.emptySHA512)
        #expect(try digest(of: empty, .md5) == Self.emptyMD5)
    }

    @Test func aMultiChunkFixtureMatchesTheReferenceVectors() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let big = directory.appendingPathComponent("big.bin")
        try Data(repeating: 0, count: 0).write(to: big)
        let handle = try FileHandle(forWritingTo: big)
        try handle.write(contentsOf: Data(Array(repeating: Array("Orbit".utf8), count: 600_000).flatMap { $0 }))
        try handle.close()

        #expect(try FileManager.default.attributesOfItem(atPath: big.path)[.size] as? NSNumber == 3_000_000)
        #expect(try digest(of: big, .sha256) == Self.bigSHA256)
        #expect(try digest(of: big, .sha512) == Self.bigSHA512)
        #expect(try digest(of: big, .md5) == Self.bigMD5)
        #expect(FileIntegrityHasher.chunkSize == 1 << 20)
    }

    // MARK: - Refusals

    @Test func symlinksAreRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("real.txt")
        try Data("abc".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: FileIntegrityError.symlinkRejected) { try digest(of: link, .sha256) }
    }

    @Test func directoriesAreRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = directory.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(throws: FileIntegrityError.notRegularFile) { try digest(of: folder, .sha256) }
    }

    @Test func aFifoIsRefusedWithoutHanging() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("pipe")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)
        // A FIFO must never block the open; the type check rejects it at once.
        #expect(throws: FileIntegrityError.notRegularFile) { try digest(of: fifo, .sha256) }
    }

    @Test func aMissingFileIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("nothing.txt")
        #expect(throws: FileIntegrityError.cannotOpen) { try digest(of: missing, .sha256) }
    }

    // MARK: - Change detection

    @Test func aFileThatChangesWhileItIsReadIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("growing.txt")
        try Data(repeating: 0x41, count: 4096).write(to: file)

        #expect(throws: FileIntegrityError.changedDuringRead) {
            try FileIntegrityHasher.digest(of: file, algorithm: .sha256, isCancelled: { false }, afterOpen: {
                if let handle = try? FileHandle(forWritingTo: file) {
                    try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data(repeating: 0x42, count: 16))
                    try? handle.close()
                }
            })
        }
    }

    @Test func aPathThatIsReplacedWhileItIsReadIsRefused() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("target.txt")
        let other = directory.appendingPathComponent("other.txt")
        try Data(repeating: 0x41, count: 4096).write(to: file)
        try Data(repeating: 0x42, count: 4096).write(to: other)

        #expect(throws: FileIntegrityError.changedDuringRead) {
            try FileIntegrityHasher.digest(of: file, algorithm: .sha256, isCancelled: { false }, afterOpen: {
                rename(other.path, file.path)
            })
        }
    }

    @Test func hashingStopsWhenItIsCancelled() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("big.bin")
        try Data().write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data(Array(repeating: Array("Orbit".utf8), count: 600_000).flatMap { $0 }))
        try handle.close()

        let counter = TestCounter()
        #expect(throws: FileIntegrityError.cancelled) {
            try FileIntegrityHasher.digest(of: file, algorithm: .sha256, isCancelled: {
                counter.increment() > 2
            })
        }
        #expect(counter.value > 2)
    }

    // MARK: - Model

    @Test func computingProducesTheExpectedHashes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        var copied: [String] = []
        let model = FileIntegrityModel(copyText: { copied.append($0) })
        #expect(model.results.isEmpty)   // nothing is hashed before the user asks
        #expect(model.addFiles([file]))
        #expect(model.files.count == 1)
        await model.compute()
        #expect(model.results.count == 1)
        #expect(model.results.first?.digest == Self.abcSHA256)
        #expect(model.results.first?.byteCount == 3)
        #expect(model.results.first?.fileName == "abc.txt")
        #expect(model.busy == false)
        #expect(model.error == nil)

        model.copyHash(try #require(model.results.first).id)
        #expect(copied == [Self.abcSHA256])
        #expect(model.reportText()?.contains(Self.abcSHA256) == true)
    }

    @Test func twoFilesAreComparedOnlyWhenBothSucceeded() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let same = directory.appendingPathComponent("same.txt")
        let copy = directory.appendingPathComponent("copy.txt")
        let other = directory.appendingPathComponent("other.txt")
        try Data("abc".utf8).write(to: same)
        try Data("abc".utf8).write(to: copy)
        try Data("abd".utf8).write(to: other)

        let model = FileIntegrityModel()
        model.addFiles([same, copy])
        await model.compute()
        #expect(model.results.count == 2)
        #expect(model.comparison?.matches == true)

        let different = FileIntegrityModel()
        different.addFiles([same, other])
        await different.compute()
        #expect(different.comparison?.matches == false)

        // Three files are not compared.
        let three = FileIntegrityModel()
        three.addFiles([same, copy, other])
        await three.compute()
        #expect(three.results.count == 3)
        #expect(three.comparison == nil)
    }

    @Test func theExpectedChecksumIsNormalisedAndChecked() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let model = FileIntegrityModel()
        model.addFiles([file])
        await model.compute()

        model.expected = "  BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD  "
        model.checkExpected()
        #expect(model.expectedChecks.count == 1)
        #expect(model.expectedChecks.first?.matched == true)

        // Case and whitespace are ignored, the length is not.
        model.expected = "ba7816bf 8f01cfea 414140de 5dae2223 b00361a3 96177a9c b410ff61 f20015ad"
        model.checkExpected()
        #expect(model.expectedChecks.first?.matched == true)

        model.expected = String(repeating: "0", count: 64)
        model.checkExpected()
        #expect(model.expectedChecks.first?.matched == false)

        model.expected = String(repeating: "z", count: 64)
        model.checkExpected()
        #expect(model.expectedError != nil)

        model.expected = String(repeating: "0", count: 10)
        model.checkExpected()
        #expect(model.expectedError != nil)
    }

    @Test func aCancelledRunCommitsNothing() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)

        // The hash is held open, so the cancel really lands on a pending run.
        let gate = TestGate()
        let model = gatedModel(gate)
        model.addFiles([file])
        let task = Task { await model.compute() }
        try await waitForRounds(gate, 1)
        #expect(model.busy == true)

        model.cancel()
        gate.release(1)
        await task.value
        #expect(model.results.isEmpty)
        #expect(model.busy == false)
    }

    @Test func aStaleResultIsNeverCommitted() throws {
        let model = FileIntegrityModel()
        let stale = FileIntegrityResult(fileName: "stale.txt", digest: "00", byteCount: 0, algorithm: .sha256)
        model.commit(.success([stale]), requestID: model.currentRequestID + 1)
        #expect(model.results.isEmpty)
        model.commit(.success([stale]), requestID: model.currentRequestID)
        #expect(model.results.count == 1)
        #expect(model.results.first?.fileName == "stale.txt")
    }

    @Test func previewModeNeverReadsFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let model = FileIntegrityModel(preview: true)
        #expect(model.addFiles([file]) == false)
        #expect(model.files.isEmpty)
        await model.compute()
        #expect(model.results.isEmpty)
        #expect(model.busy == false)
    }

    @Test func atMostEightFilesAreKept() throws {
        let model = FileIntegrityModel()
        let urls = (0..<9).map { URL(fileURLWithPath: "/tmp/orbit-integrity-\($0).txt") }
        #expect(model.addFiles(Array(urls.prefix(8))))
        #expect(model.files.count == 8)
        #expect(model.addFiles([urls[8]]) == false)
        #expect(model.files.count == 8)
    }

    // MARK: - Input changes while the work is pending

    @Test func changingTheAlgorithmWhileHashingDropsThePendingRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)

        let gate = TestGate()
        let model = gatedModel(gate)
        model.addFiles([file])
        let task = Task { await model.compute() }
        try await waitForRounds(gate, 1)
        #expect(model.busy == true)

        model.algorithm = .sha512
        #expect(model.busy == false)
        #expect(model.results.isEmpty)

        gate.release(1)
        await task.value
        #expect(model.results.isEmpty)
        #expect(model.busy == false)
    }

    @Test func removingAFileWhileHashingDropsThePendingRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        let other = directory.appendingPathComponent("b.txt")
        try Data("abc".utf8).write(to: file)
        try Data("abc".utf8).write(to: other)

        let gate = TestGate()
        let model = gatedModel(gate)
        model.addFiles([file, other])
        let task = Task { await model.compute() }
        try await waitForRounds(gate, 1)

        model.removeFile(file)
        #expect(model.busy == false)
        #expect(model.results.isEmpty)
        #expect(model.files.count == 1)

        gate.release(1)
        await task.value
        #expect(model.results.isEmpty)
        #expect(model.busy == false)
    }

    @Test func aFinishedButNotDeliveredSuccessIsNotCommittedAfterCancel() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)

        let gate = TestGate()
        let model = gatedModel(gate)
        model.addFiles([file])
        let task = Task { await model.compute() }
        try await waitForRounds(gate, 1)
        let runID = model.currentRequestID

        // The hash is ready, but the result is not delivered yet.
        gate.release(1)
        // The user cancels before the result reaches the screen.
        model.cancel()
        await task.value
        #expect(model.results.isEmpty)
        #expect(model.busy == false)
        #expect(model.currentRequestID != runID)

        // A late result from the cancelled run is ignored.
        let late = FileIntegrityResult(fileName: "a.txt", digest: "0011", byteCount: 3, algorithm: .sha256)
        model.commit(.success([late]), requestID: runID)
        #expect(model.results.isEmpty)
    }

    @Test func anOlderRunCannotClearTheNewerRun() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)

        let gate = TestGate()
        let model = gatedModel(gate)
        model.addFiles([file])
        let first = Task { await model.compute() }
        try await waitForRounds(gate, 1)

        // A change of the algorithm invalidates the first run.
        model.algorithm = .sha512
        let second = Task { await model.compute() }
        try await waitForRounds(gate, 2)

        // The first run finishes late. It must not take the second run's task
        // and token with it.
        gate.release(1)
        await first.value
        model.cancel()
        gate.release(2)
        await second.value

        #expect(model.results.isEmpty)
        #expect(model.busy == false)
    }

    @Test func changingTheAlgorithmDropsTheOldResults() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let model = FileIntegrityModel()
        model.addFiles([file])
        await model.compute()
        #expect(model.results.count == 1)
        #expect(model.results.first?.algorithm == .sha256)

        model.algorithm = .sha512
        #expect(model.results.isEmpty)
        #expect(model.comparison == nil)
        #expect(model.expectedChecks.isEmpty)
        #expect(model.busy == false)
    }

    // MARK: - Expected checksum state

    @Test func editingTheExpectedTextInvalidatesThePreviousMatch() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("abc.txt")
        try Data("abc".utf8).write(to: file)

        let model = FileIntegrityModel()
        model.addFiles([file])
        await model.compute()

        model.expected = Self.abcSHA256
        model.checkExpected()
        #expect(model.expectedChecks.count == 1)
        #expect(model.expectedChecks.first?.matched == true)

        // A different expectation drops the old match right away.
        model.expected = String(repeating: "0", count: 64)
        #expect(model.expectedChecks.isEmpty)

        // A wrong length is a checksum error of its own.
        model.expected = "abc"
        model.checkExpected()
        #expect(model.expectedError != nil)
        #expect(model.expectedChecks.isEmpty)

        // A successful recheck clears that error.
        model.expected = Self.abcSHA256
        model.checkExpected()
        #expect(model.expectedError == nil)
        #expect(model.expectedChecks.first?.matched == true)

        // Clearing the field clears the error as well.
        model.expected = "abc"
        model.checkExpected()
        #expect(model.expectedError != nil)
        model.expected = ""
        model.checkExpected()
        #expect(model.expectedError == nil)
        #expect(model.expectedChecks.isEmpty)
    }

    @Test func aSuccessfulRecheckDoesNotHideAnUnrelatedFileFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try Data("abc".utf8).write(to: file)
        let link = directory.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let model = FileIntegrityModel()
        model.addFiles([link])
        await model.compute()
        #expect(model.error != nil)
        #expect(model.results.isEmpty)

        model.expected = "not hex"
        model.checkExpected()
        #expect(model.expectedError != nil)

        model.expected = Self.abcSHA256
        model.checkExpected()
        #expect(model.expectedError == nil)
        // The file failure is still reported.
        #expect(model.error != nil)
    }

    @Test func onlyResultsOfTheCurrentAlgorithmAreCompared() throws {
        let model = FileIntegrityModel()
        model.algorithm = .sha512
        let result = FileIntegrityResult(fileName: "a.txt", digest: Self.abcSHA256, byteCount: 3, algorithm: .sha256)
        model.commit(.success([result]), requestID: model.currentRequestID)
        model.expected = Self.abcSHA512
        model.checkExpected()
        #expect(model.expectedChecks.isEmpty)
        #expect(model.expectedError == nil)
    }

    // MARK: - Helpers

    private func digest(of url: URL, _ algorithm: FileIntegrityAlgorithm) throws -> String {
        try FileIntegrityHasher.digest(of: url, algorithm: algorithm, isCancelled: { false }).hex
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("OrbitIntegrityTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A counter that can be read from the hashing task.
    private final class TestCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Lets a test hold a hash open, so an input change can be made while the
    /// work is still pending.
    private final class TestGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var rounds = 0
        private var released = 0

        var enteredRounds: Int {
            condition.lock()
            defer { condition.unlock() }
            return rounds
        }
        func enter() -> Int {
            condition.lock()
            rounds += 1
            let mine = rounds
            condition.broadcast()
            condition.unlock()
            return mine
        }
        func waitForRelease(_ round: Int) {
            condition.lock()
            while released < round { condition.wait() }
            condition.unlock()
        }
        func release(_ round: Int) {
            condition.lock()
            released = max(released, round)
            condition.broadcast()
            condition.unlock()
        }
    }

    /// A model whose hashing step waits on the gate instead of reading a file.
    private func gatedModel(_ gate: TestGate) -> FileIntegrityModel {
        FileIntegrityModel(hashFile: { _, _, isCancelled in
            let round = gate.enter()
            gate.waitForRelease(round)
            if isCancelled() { throw FileIntegrityError.cancelled }
            return FileIntegrityDigest(hex: "aabbccdd", byteCount: 0)
        })
    }

    private func waitForRounds(_ gate: TestGate, _ count: Int) async throws {
        while gate.enteredRounds < count {
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
