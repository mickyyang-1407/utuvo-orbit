import Foundation
import Testing
import OrbitCore
@testable import UtuvoOrbit

/// The guide and the main menu are checked here without any GUI: no
/// NSApplication, no NSWindow, no window server. Everything below is pure
/// model and file reading.
@MainActor
struct OrbitHelpTests {
    // MARK: - The 18 tool pages

    @Test func everyToolPageHasHelpInBothLanguages() throws {
        let pages = OrbitToolsNavigation.Page.allCases
        // The workbench has 18 pages today; the guide must describe each of
        // them. If a page is added, this fails until it is described.
        #expect(pages.count == 18)

        let english = OrbitHelpContent.toolEntries(language: .english)
        let chinese = OrbitHelpContent.toolEntries(language: .traditionalChinese)
        #expect(english.count == pages.count)
        #expect(chinese.count == pages.count)

        for page in pages {
            let id = "tool." + page.rawValue
            let en = try #require(english.first { $0.id == id },
                                  "no English help for the \(page.rawValue) page")
            let zh = try #require(chinese.first { $0.id == id },
                                  "no Chinese help for the \(page.rawValue) page")
            let key = "orbit.help.tool.\(page.rawValue).body"
            #expect(!en.body.isEmpty, "the \(page.rawValue) help is empty in English")
            #expect(!zh.body.isEmpty, "the \(page.rawValue) help is empty in Chinese")
            // A key that was never translated comes back as the key itself.
            #expect(en.body != key, "the \(page.rawValue) help is missing in English")
            #expect(zh.body != key, "the \(page.rawValue) help is missing in Chinese")
            #expect(en.body != zh.body, "the \(page.rawValue) help says the same thing in both languages")
        }
    }

    // MARK: - Both languages

    @Test func everyHelpSectionHasContentInBothLanguages() {
        let english = OrbitHelpContent.sections(language: .english)
        let chinese = OrbitHelpContent.sections(language: .traditionalChinese)
        #expect(!english.isEmpty)
        #expect(english.map(\.id) == chinese.map(\.id))

        for section in english {
            #expect(!section.title.isEmpty)
            #expect(!section.summary.isEmpty)
            #expect(!section.entries.isEmpty)
            for entry in section.entries {
                #expect(!entry.title.isEmpty)
                #expect(!entry.body.isEmpty)
            }
        }
        for (en, zh) in zip(english, chinese) {
            #expect(en.title != zh.title, "the \(en.id) section title is the same in both languages")
            #expect(en.summary != zh.summary, "the \(en.id) summary is the same in both languages")
            #expect(en.entries.count == zh.entries.count)
            for (enEntry, zhEntry) in zip(en.entries, zh.entries) {
                #expect(enEntry.id == zhEntry.id)
                #expect(enEntry.body != zhEntry.body, "the \(enEntry.id) paragraph is the same in both languages")
                // The tool pages are named by the workbench itself, and two of
                // those names ("PDF", "QR Code") are the same in both
                // languages by design — so the title is only compared for the
                // sections whose titles are prose.
                if en.id != "tools" {
                    #expect(enEntry.title != zhEntry.title, "the \(enEntry.id) title is the same in both languages")
                }
            }
        }
    }

    @Test func theGuideNeedsNoNetworkToBeRead() {
        // The guide has to be usable with no network at all, so the prose
        // itself must not send the reader off to look something up.
        for language in [AppLanguage.english, .traditionalChinese] {
            for section in OrbitHelpContent.sections(language: language) {
                for entry in section.entries {
                    #expect(!entry.body.contains("http"), "the \(entry.id) paragraph points at a web address")
                    #expect(!entry.title.contains("http"))
                }
            }
        }
        // The optional links are the only outbound pointers, and they are
        // kept separate from the prose so a reader can ignore them.
        let links = OrbitHelpContent.links(language: .english)
        #expect(!links.isEmpty)
        #expect(links.allSatisfy { $0.url.scheme == "https" })
        #expect(links.count <= 3)
    }

    // MARK: - Locale completeness

    @Test func everyHelpAndMenuKeyIsTranslatedInBothLocales() throws {
        let root = try Self.packageRoot()
        let englishFile = try StringsFile.parse(root.appendingPathComponent("Sources/OrbitCore/Resources/en.lproj/Localizable.strings"))
        let chineseFile = try StringsFile.parse(root.appendingPathComponent("Sources/OrbitCore/Resources/zh-Hant.lproj/Localizable.strings"))
        #expect(!englishFile.isEmpty)

        // Neither table may have a key the other one lacks.
        for key in englishFile.keys {
            #expect(chineseFile[key] != nil, "zh-Hant has no value for \(key)")
        }
        for key in chineseFile.keys {
            #expect(englishFile[key] != nil, "en has no value for \(key)")
        }

        // And every help and menu key must actually resolve through the
        // bundle — in both languages — and say something different in each.
        let english = OrbitStrings(language: .english)
        let chinese = OrbitStrings(language: .traditionalChinese)
        for key in englishFile.keys where key.hasPrefix("orbit.help.") || key.hasPrefix("orbit.menu.") {
            let englishValue = english(key)
            let chineseValue = chinese(key)
            #expect(!englishValue.isEmpty, "the English value for \(key) is empty")
            #expect(!chineseValue.isEmpty, "the Chinese value for \(key) is empty")
            #expect(englishValue != key, "no English value for \(key)")
            #expect(chineseValue != key, "no Chinese value for \(key)")
            #expect(englishValue != chineseValue, "\(key) reads the same in both languages")
        }
    }

    @Test func theSettingsHelpPageHasATitleInBothLanguages() {
        let page = OrbitSettingsView.Page.help
        #expect(OrbitSettingsView.Page.allCases.contains(page))
        let english = OrbitStrings(language: .english)
        let chinese = OrbitStrings(language: .traditionalChinese)
        #expect(english(page.title) == "Help")
        #expect(chinese(page.title) == "說明")
    }

    // MARK: - The main menu

    @Test func theMainMenuKeepsTheStandardEditItems() {
        let menus = OrbitMainMenuSpec.menus()
        let edit = menus.first { $0.id == OrbitMainMenuSpec.edit }
        #expect(edit != nil)
        let entries = edit?.entries ?? []
        // The responder-chain items, in the standard order, with their
        // standard key equivalents. Only Redo carries shift.
        #expect(entries.map(\.action) == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        #expect(entries.map(\.keyEquivalent) == ["z", "z", "x", "c", "v", "a"])
        #expect(entries.map(\.shift) == [false, true, false, false, false, false])
    }

    @Test func theMainMenuKeepsQuitAndCarriesAppLocalHelp() {
        let menus = OrbitMainMenuSpec.menus()
        let application = menus.first { $0.id == OrbitMainMenuSpec.application }
        let quit = application?.entries.first { $0.action == "terminate:" }
        #expect(quit != nil)
        #expect(quit?.keyEquivalent == "q")
        #expect(quit?.shift == false)

        let help = menus.first { $0.id == OrbitMainMenuSpec.help }
        #expect(help != nil)
        let item = help?.entries.first
        #expect(item?.action == "showOrbitHelp:")
        #expect(item?.keyEquivalent == "?")

        // No global hotkey is registered: every key equivalent in the app's
        // own menu is one of the standard editing keys plus ⌘? and ⌘Q.
        let keys = menus.flatMap { $0.entries.map(\.keyEquivalent) }
        #expect(Set(keys) == ["q", "z", "x", "c", "v", "a", "?"])
    }

    @Test func everyMainMenuTitleIsTranslatedInBothLanguages() {
        let english = OrbitStrings(language: .english)
        let chinese = OrbitStrings(language: .traditionalChinese)
        for menu in OrbitMainMenuSpec.menus() {
            if !menu.titleKey.isEmpty {
                #expect(english(menu.titleKey) != menu.titleKey)
                #expect(chinese(menu.titleKey) != menu.titleKey)
                #expect(english(menu.titleKey) != chinese(menu.titleKey))
            }
            for entry in menu.entries {
                #expect(english(entry.titleKey) != entry.titleKey)
                #expect(chinese(entry.titleKey) != entry.titleKey)
                #expect(english(entry.titleKey) != chinese(entry.titleKey))
            }
        }
    }

    // MARK: - Helpers

    /// The package root, found by walking up from this file. `#filePath` may
    /// be relative to the compilation directory, so it is resolved against
    /// the working directory when it is not absolute.
    static func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        if !url.path.hasPrefix("/") {
            url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(#filePath)
        }
        var directory = url.deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw HelpTestError.packageRootNotFound
    }

    enum HelpTestError: Error {
        case packageRootNotFound
    }
}

/// Reads a `.strings` table. The files in this project use one
/// `"key" = "value";` per line, so a line-based parse is enough and needs no
/// property-list machinery.
enum StringsFile {
    static func parse(_ url: URL) throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("\"") else { continue }
            guard let separator = line.range(of: "\" = \"") else { continue }
            let key = String(line[line.index(line.startIndex, offsetBy: 1)..<separator.lowerBound])
            let valueStart = separator.upperBound
            guard line.hasSuffix("\";"),
                  valueStart < line.index(line.endIndex, offsetBy: -2) else { continue }
            let value = String(line[valueStart..<line.index(line.endIndex, offsetBy: -2)])
            result[unescape(key)] = unescape(value)
        }
        return result
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}
