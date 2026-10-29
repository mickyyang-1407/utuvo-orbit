import AppKit
import Carbon.HIToolbox
import Combine
import OrbitCore
import SwiftUI

@MainActor
protocol ActionShortcut: AnyObject {
    func register(_ action: @escaping () -> Void) -> Bool
    func unregister()
}
@MainActor
final class SystemActionShortcut: ActionShortcut {
    private var hotkey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    func register(_ action: @escaping () -> Void) -> Bool {
        unregister(); self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4F524241, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<SystemActionShortcut>.fromOpaque(pointer).takeUnretainedValue().action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr, RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x4F524241, id: 1), GetApplicationEventTarget(), 0, &hotkey) == noErr else { unregister(); return false }
        return true
    }
    func unregister() {
        if let hotkey { UnregisterEventHotKey(hotkey) }; hotkey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil; action = nil
    }
}
@MainActor
final class PreviewActionShortcut: ActionShortcut {
    var registrations = 0
    func register(_ action: @escaping () -> Void) -> Bool { registrations += 1; return true }
    func unregister() {}
}

struct OrbitAction: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let perform: @MainActor () -> Void
}

@MainActor
final class ActionPanelModel: ObservableObject {
    @Published var query = ""
    @Published var selection: String?
    @Published var actions: [OrbitAction] = []
    @Published var focusRequest = UUID()
    @Published private(set) var pins: [String]
    @Published private(set) var shortcutEnabled = false
    @Published private(set) var error: String?
    var language: AppLanguage = .system
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    private let storage: ToolStorage<[String]>
    private let defaults: UserDefaults?
    private let shortcut: any ActionShortcut
    private var allowed = true
    var ordered: [OrbitAction] {
        let positions = Dictionary(uniqueKeysWithValues: pins.enumerated().map { ($0.element, $0.offset) })
        return actions.enumerated().sorted { a, b in
            let left = positions[a.element.id] ?? Int.max, right = positions[b.element.id] ?? Int.max
            return left == right ? a.offset < b.offset : left < right
        }.map(\.element)
    }
    var filtered: [OrbitAction] {
        let tokens = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return ordered.filter { action in tokens.allSatisfy { (action.title + " " + action.detail).localizedCaseInsensitiveContains($0) } }
    }
    init(defaults: UserDefaults?, shortcut: any ActionShortcut) {
        self.defaults = defaults; self.shortcut = shortcut; storage = ToolStorage(defaults, "tools.actions.pins")
        pins = storage.load(fallback: [], validate: { $0.count <= 64 && Set($0).count == $0.count })
        if defaults?.bool(forKey: "tools.actions.shortcut") == true { setShortcut(true) }
    }
    func togglePin(_ action: OrbitAction) {
        var values = pins; if values.contains(action.id) { values.removeAll { $0 == action.id } } else { values.append(action.id) }
        do { try storage.save(Array(values.prefix(64))); pins = Array(values.prefix(64)); error = nil } catch { self.error = error.localizedDescription }
    }
    func setShortcut(_ enabled: Bool) {
        shortcut.unregister(); shortcutEnabled = enabled
        if enabled, allowed {
            if !shortcut.register({ [weak self] in self?.onOpen?() }) {
                shortcutEnabled = false; error = ToolCopy(language: language)("⌃⌥Space 已被占用；仍可從選單開啟。", "⌃⌥Space is unavailable. Open the panel from the menu.")
            }
        }
        defaults?.set(shortcutEnabled, forKey: "tools.actions.shortcut")
    }
    func setAllowed(_ value: Bool) { allowed = value; shortcut.unregister(); if value, shortcutEnabled { setShortcut(true) } }
    func runSelected() { if let action = filtered.first(where: { $0.id == selection }) ?? filtered.first { run(action) } }
    func run(_ action: OrbitAction) { guard allowed else { return }; onClose?(); action.perform() }
    func move(_ offset: Int) {
        let values = filtered; guard !values.isEmpty else { return }
        let index = selection.flatMap { id in values.firstIndex(where: { $0.id == id }) } ?? 0
        selection = values[min(values.count - 1, max(0, index + offset))].id
    }
    var needsRecovery: Bool { storage.damaged }
    func recover() { do { try storage.backupAndReset([]); pins = []; error = nil } catch { self.error = error.localizedDescription } }
    func stop() { shortcut.unregister() }
}

struct ActionPanelView: View {
    @ObservedObject var model: ActionPanelModel
    private var c: ToolCopy { ToolCopy(language: model.language) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(OrbitPalette.accent)
                ActionSearchField(model: model, placeholder: c("搜尋工具或情境…", "Search tools or modes…")).frame(height: 25)
                Text("esc").font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(22)
            Divider()
            List(selection: $model.selection) {
                ForEach(model.filtered) { action in
                    HStack(spacing: 12) {
                        Image(systemName: action.symbol).frame(width: 28).foregroundStyle(OrbitPalette.accent)
                        Button { model.run(action) } label: {
                            VStack(alignment: .leading, spacing: 3) { Text(action.title).fontWeight(.medium); Text(action.detail).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { model.togglePin(action) } label: { Image(systemName: model.pins.contains(action.id) ? "pin.fill" : "pin") }
                            .buttonStyle(.borderless).accessibilityLabel(c("置頂動作", "Pin action"))
                    }.padding(.vertical, 7).tag(action.id)
                }
            }.listStyle(.plain)
            if model.filtered.isEmpty { Text(c("沒有符合的動作", "No matching actions")).foregroundStyle(.secondary).padding() }
            Divider()
            HStack { Text(c("↑ ↓ 選擇 · Return 執行", "↑ ↓ select · Return run")); Spacer(); Text("UTUVO Orbit") }.font(.caption).foregroundStyle(.secondary).padding(16)
        }.frame(width: 520, height: 490).tint(OrbitPalette.accent)
            .onAppear { model.selection = model.filtered.first?.id }
            .onChange(of: model.query) { _, _ in model.selection = model.filtered.first?.id }
            .onMoveCommand { direction in if direction == .down { model.move(1) }; if direction == .up { model.move(-1) } }
            .onExitCommand { model.onClose?() }
    }
}

/// Native field-editor commands reach the action list before NSTextField consumes arrows.
private struct ActionSearchField: NSViewRepresentable {
    let model: ActionPanelModel
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(); field.isBordered = false; field.drawsBackground = false
        field.font = .systemFont(ofSize: 17); field.focusRingType = .none
        field.delegate = context.coordinator; return field
    }
    func updateNSView(_ field: NSTextField, context: Context) {
        field.placeholderString = placeholder
        if field.stringValue != model.query { field.stringValue = model.query }
        let token = model.focusRequest
        if context.coordinator.focusRequest != token {
            context.coordinator.focusRequest = token
            DispatchQueue.main.async { [weak field] in field?.window?.makeFirstResponder(field) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        let model: ActionPanelModel
        var focusRequest: UUID?
        init(_ model: ActionPanelModel) { self.model = model }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { model.query = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(selector) {
            case "moveDown:": model.move(1)
            case "moveUp:": model.move(-1)
            case "insertNewline:": model.runSelected()
            case "cancelOperation:": model.onClose?()
            default: return false
            }
            return true
        }
    }
}
