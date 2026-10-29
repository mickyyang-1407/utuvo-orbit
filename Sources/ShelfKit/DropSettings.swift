import AppKit

enum DropLanguage: String, CaseIterable {
    case system, traditionalChinese = "zh-Hant", english = "en"
    func resolved(preferred: [String] = Locale.preferredLanguages) -> DropLanguage {
        self == .system ? (preferred.first?.hasPrefix("zh") == true ? .traditionalChinese : .english) : self
    }
}

/// Only appearance preferences persist; file references remain in memory.
final class DropSettings {
    private let defaults: UserDefaults?
    var language: DropLanguage {
        didSet { defaults?.set(language.rawValue, forKey: "drop.language") }
    }
    var savedOrigin: NSPoint? {
        didSet {
            if let p = savedOrigin { defaults?.set([Double(p.x), Double(p.y)], forKey: "drop.position") }
            else { defaults?.removeObject(forKey: "drop.position") }
        }
    }
    var petOnLeft: Bool { didSet { defaults?.set(petOnLeft, forKey: "drop.petOnLeft") } }
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        language = defaults?.string(forKey: "drop.language").flatMap(DropLanguage.init(rawValue:)) ?? .system
        if let values = defaults?.array(forKey: "drop.position") as? [Double], values.count == 2,
           values.allSatisfy(\.isFinite) { savedOrigin = NSPoint(x: values[0], y: values[1]) }
        petOnLeft = defaults?.bool(forKey: "drop.petOnLeft") ?? false
    }
    var strings: DropStrings { DropStrings(language: language) }
}

struct DropStrings {
    var language: DropLanguage = .system
    private var zh: Bool { language.resolved() == .traditionalChinese }
    func text(_ chinese: String, _ english: String) -> String { zh ? chinese : english }
    var clear: String { text("清空", "Clear") }
    var clearHelp: String { text("清空暫放清單，原始檔案不動。", "Clear the list; keep original files.") }
    var close: String { text("收起想法", "Close thought bubble") }
    var empty: String { text("把檔案拖過來，\n我幫你保管。", "Drop files here.\nI'll keep them handy.") }
    var footer: String { text("拖曳取出，原始檔案留在原處。", "Drag files out. Originals stay in place.") }
    var dragAll: String { text("全部帶走", "Take all files") }
    var dragAllHelp: String { text("拖曳這裡，把所有檔案帶到另一個 App。", "Drag here to take all files to another app.") }
    var move: String { text("拖曳移動小貓", "Drag to move the cat") }
    var movementHelp: String { text("拖尾巴或移動把手可換位置；Option＋拖貓咪也可以。", "Drag the tail or move handle to reposition; Option-drag the cat also works.") }
    var catLabel: String { text("檔案小貓，點一下查看清單", "File cat; click to see files") }
    var tailLabel: String { text("貓咪尾巴，拖曳移動，點一下查看清單", "Cat tail; drag to move, click to see files") }
    var missing: String { text("檔案不在原處，請移除或重新拖入", "Missing — remove or re-drop") }
    var unreadable: String { text("無法讀取，不能拖出", "Unreadable — cannot drag") }
    var invalidDrop: String { text("有檔案遺失或無法讀取，請重新拖入", "Missing or unreadable reference — re-drop it") }
    var invalidDrag: String { text("檔案遺失或無法讀取，不能拖出", "Missing or unreadable file — cannot drag") }
    var removeHelp: String { text("從清單移除，原始檔案不動。", "Remove from shelf; keep the original file.") }
    var folder: String { text("資料夾", "Folder") }
    func title(_ count: Int) -> String { count == 0 ? text("今天有什麼好吃的？", "What's on the menu?") : text("我幫你收著 · \(count) 份", "Keeping \(count) file\(count == 1 ? "" : "s")") }
    func count(_ count: Int) -> String { text("保管 \(count) 份檔案", "Holding \(count) file\(count == 1 ? "" : "s")") }
}
