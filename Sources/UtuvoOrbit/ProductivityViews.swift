import AppKit
import OrbitCore
import SwiftUI

struct CalculatorToolsView: View {
    @ObservedObject var model: CalculatorToolsModel
    var language: AppLanguage
    var copyText: (String) -> Void
    @State private var clearingHistory = false
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("算一下，接著往前。", "A quick answer. Back to work."),
                             detail: c("四則運算、括號、次方與百分比。單位換算也在這裡。", "Arithmetic, parentheses, powers and percentages. Unit conversions, too."))
            WorkbenchCard {
                TextField(c("例如：(240 + 36) / 3", "Try (240 + 36) / 3"), text: $model.input)
                    .font(.system(size: 20, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(c("算式", "Expression")).onSubmit { model.calculate() }
                HStack {
                    Text(model.result ?? "—").font(.system(size: 34, weight: .medium, design: .rounded))
                        .lineLimit(2).minimumScaleFactor(0.6).textSelection(.enabled).accessibilityLabel(c("計算結果", "Result"))
                    Spacer()
                    Button(c("計算", "Calculate")) { model.calculate() }.buttonStyle(.borderedProminent)
                    Button(c("複製", "Copy")) { if let result = model.result { copyText(result) } }.disabled(model.result == nil)
                }
                Text(c("小數點使用 .；% 代表除以 100。支援 pi、e、sqrt、abs、sin、cos（弧度）。結果最多顯示 12 位有效數字。",
                       "Use . for decimals. % divides by 100. Supports pi, e, sqrt, abs, sin and cos (radians). Results show up to 12 significant digits."))
                    .font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
                if model.needsRecovery { Button(c("備份並重設歷史", "Back up and reset history")) { model.recover() } }
            }
            WorkbenchCard {
                Text(c("單位換算", "Unit conversion")).font(.headline)
                Picker(c("類型", "Kind"), selection: Binding(get: { model.kind }, set: { model.selectKind($0) })) {
                    ForEach(ConversionKind.allCases) { Text($0.title(c)).tag($0) }
                }
                HStack {
                    TextField(c("數值或算式", "Value or expression"), text: $model.conversionInput).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(c("換算輸入", "Conversion input"))
                    Picker(c("從", "From"), selection: $model.from) { ForEach(model.kind.units) { Text($0.id).tag($0.id) } }.frame(width: 145)
                    Button { let old = model.from; model.from = model.to; model.to = old } label: { Image(systemName: "arrow.left.arrow.right") }
                        .accessibilityLabel(c("交換單位", "Swap units"))
                    Picker(c("到", "To"), selection: $model.to) { ForEach(model.kind.units) { Text($0.id).tag($0.id) } }.frame(width: 145)
                }
                switch model.converted {
                case .success(let result):
                    HStack { Text(result + " " + model.to).font(.system(size: 22, weight: .medium, design: .monospaced)).textSelection(.enabled); Spacer(); Button(c("複製", "Copy")) { copyText(result + " " + model.to) } }
                case .failure(let error): Text(error.localizedDescription).font(.caption).foregroundStyle(.orange)
                }
                Text(c("MB 為十進位，MiB 為二進位；gal 與 fl oz 使用美制。", "MB uses decimal prefixes; MiB uses binary prefixes. gal and fl oz are US units.")).font(.caption).foregroundStyle(.secondary)
            }
            if !model.history.isEmpty {
                HStack { Text(c("最近的計算", "Recent calculations")).font(.headline); Spacer(); Button(c("清除歷史", "Clear history")) { clearingHistory = true } }
                ForEach(model.history) { item in
                    HStack {
                        Button { model.input = item.expression; model.calculate() } label: { Text(item.expression).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        Text(item.result).monospacedDigit().textSelection(.enabled)
                        Button { copyText(item.result) } label: { Image(systemName: "doc.on.doc") }.accessibilityLabel(c("複製結果", "Copy result"))
                    }.font(.system(size: 12)).padding(.vertical, 4)
                }
            }
        }
        .confirmationDialog(c("清除計算歷史？", "Clear calculation history?"), isPresented: $clearingHistory) {
            Button(c("清除歷史", "Clear history"), role: .destructive) { model.clearHistory() }
        }
    }
}

struct WorldClockToolsView: View {
    @ObservedObject var model: WorldClockModel
    var language: AppLanguage
    var copyText: (String) -> Void
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("這裡幾點，那裡呢？", "Your time. Their time."),
                             detail: c("收藏常用時區，預覽開會時間。夏令時間由 macOS 時區資料處理。", "Save cities and preview meeting times. macOS time-zone data handles daylight saving."))
            WorkbenchCard {
                Toggle(c("顯示現在時間", "Show current time"), isOn: $model.useCurrentTime).toggleStyle(.switch)
                Picker(c("參考時區", "Reference zone"), selection: $model.baseZone) {
                    ForEach(Array(Set(model.zones + [model.baseZone])).sorted(), id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ")).tag($0) }
                }
                DatePicker(c("預覽日期與時間", "Preview date and time"), selection: $model.previewDate, displayedComponents: [.date, .hourAndMinute])
                    .environment(\.timeZone, TimeZone(identifier: model.baseZone) ?? .gmt).disabled(model.useCurrentTime)
                Text(c("預覽輸入使用上方參考時區；各城市顯示同一個時間點。", "The date input uses the reference zone. Every city shows the same instant.")).font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let instant = model.useCurrentTime ? context.date : model.previewDate
                VStack(spacing: 12) {
                    ForEach(model.zones, id: \.self) { zone in
                        if let reading = WorldClock.reading(zoneID: zone, at: instant, relativeTo: model.baseZone, locale: Locale(identifier: c.chinese ? "zh_TW" : "en_US")) {
                            WorkbenchCard {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(zone.components(separatedBy: "/").last!.replacingOccurrences(of: "_", with: " ")).font(.headline)
                                        Text(reading.date + " · " + reading.offset).font(.caption).foregroundStyle(.secondary)
                                        if reading.dayDifference != 0 { Text(String(format: "%+d", reading.dayDifference) + c(" 天", " day")).font(.caption).foregroundStyle(OrbitPalette.accent) }
                                    }
                                    Spacer()
                                    Text(reading.time).font(.system(size: 30, weight: .medium, design: .rounded)).monospacedDigit()
                                    Menu {
                                        Button(c("複製時間", "Copy time")) { copyText(zone + " · " + reading.date + " " + reading.time + " " + reading.offset) }
                                        Button(c("向上", "Move up")) { model.move(zone, by: -1) }.disabled(model.zones.first == zone)
                                        Button(c("向下", "Move down")) { model.move(zone, by: 1) }.disabled(model.zones.last == zone)
                                        Button(c("移除城市", "Remove city")) { model.remove(zone) }
                                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel(zone + c(" 選項", " options"))
                                }
                            }
                        }
                    }
                }
            }
            WorkbenchCard {
                Text(c("加入城市或時區", "Add a city or zone")).font(.headline)
                TextField(c("搜尋，例如 東京、紐約、UTC", "Search Tokyo, New York, UTC…"), text: $model.query).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(c("搜尋時區", "Search time zones"))
                ForEach(model.matches, id: \.self) { zone in
                    HStack { Text(zone.replacingOccurrences(of: "_", with: " ")).font(.system(size: 12)); Spacer(); Button(c("加入", "Add")) { model.add(zone) }.disabled(model.needsRecovery || model.zones.count >= 16) }
                }
                if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
                if model.needsRecovery { Button(c("備份並重設城市", "Back up and reset cities")) { model.recover() } }
            }
        }
    }
}

struct QuickNotesToolsView: View {
    @ObservedObject var model: QuickNotesModel
    var language: AppLanguage
    var preview: Bool
    var copyText: (String) -> Void
    var onSendToText: (String) -> Void
    @State private var emptyingTrash = false
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("先記下來，繼續你的事。", "Catch a thought. Keep your flow."),
                             detail: c("筆記只存這台 Mac，自動儲存。刪除後可從最近刪除復原。", "Notes stay on this Mac and save automatically. Restore them from Recently Deleted."))
            WorkbenchCard {
                HStack {
                    TextField(c("搜尋筆記…", "Search notes…"), text: $model.query).textFieldStyle(.roundedBorder)
                    Button(c("新增筆記", "New note")) { model.create() }.buttonStyle(.borderedProminent).disabled(model.needsRecovery)
                }
                Toggle(c("最近刪除", "Recently Deleted"), isOn: $model.showTrash)
                if model.showTrash {
                    HStack { Text(c("包含最近刪除，最多 100 筆、合計 2 MB。", "Up to 100 notes and 2 MB, including Recently Deleted.")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(c("清空最近刪除", "Empty Recently Deleted"), role: .destructive) { emptyingTrash = true }.disabled(!model.notes.contains { $0.deleted != nil }) }
                }
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.visible) { note in
                            HStack {
                                Button { model.select(note.id) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(note.title.isEmpty ? c("未命名筆記", "Untitled note") : note.title).fontWeight(.medium).lineLimit(1)
                                        Text(note.body.isEmpty ? c("還沒有內容", "No text yet") : note.body).lineLimit(1).foregroundStyle(.secondary).font(.caption)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                                if note.deleted == nil {
                                    Button { model.pin(note.id) } label: { Image(systemName: note.pinned ? "pin.fill" : "pin") }.accessibilityLabel(c("置頂筆記", "Pin note"))
                                    Button { model.trash(note.id) } label: { Image(systemName: "trash") }.accessibilityLabel(c("移到最近刪除", "Move to Recently Deleted"))
                                } else { Button(c("復原", "Restore")) { model.trash(note.id, restore: true) } }
                            }.buttonStyle(.borderless).padding(9)
                                .background(model.selectedID == note.id ? OrbitPalette.accent.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }.frame(height: model.visible.isEmpty ? 20 : min(190, CGFloat(model.visible.count) * 59))
            }
            if let note = model.selected, (note.deleted != nil) == model.showTrash {
                WorkbenchCard {
                    TextField(c("標題", "Title"), text: Binding(get: { model.draftTitle }, set: { model.editTitle($0) }))
                        .textFieldStyle(.roundedBorder).font(.headline).disabled(note.deleted != nil || model.needsRecovery)
                    TextEditor(text: Binding(get: { model.draftBody }, set: { model.editBody($0) }))
                        .font(.system(size: 13)).frame(height: 225).scrollContentBackground(.hidden).padding(8)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(c("筆記內容", "Note text")).disabled(note.deleted != nil || model.needsRecovery)
                    HStack {
                        Text(model.dirty ? (model.error == nil ? c("儲存中…", "Saving…") : c("尚未儲存", "Not saved")) : c("已儲存", "Saved")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(c("儲存", "Save")) { model.flush() }.keyboardShortcut("s", modifiers: .command)
                        Button(c("複製", "Copy")) { copyText(model.draftBody) }
                        Button(c("送到文字工具", "Send to Text")) { onSendToText(model.draftBody) }
                        Button(c("匯出 Markdown", "Export Markdown")) {
                            if let url = ToolFiles.directory() {
                                let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                                model.export(to: url)
                            }
                        }.disabled(preview)
                    }
                }
            } else { WorkbenchEmpty(symbol: "note.text", text: c("選一筆筆記，或記下新的想法。", "Choose a note, or start a new thought.")) }
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
            if model.needsRecovery { Button(c("備份損壞資料並重設", "Back up damaged data and reset")) { model.recover() } }
            if let url = model.exported { Text(c("已匯出到：", "Exported to: ") + url.lastPathComponent).font(.caption).textSelection(.enabled) }
        }
        .onDisappear { model.stop() }
        .confirmationDialog(c("永久清除最近刪除的筆記？", "Permanently delete the notes in Recently Deleted?"), isPresented: $emptyingTrash) {
            Button(c("永久清除", "Delete permanently"), role: .destructive) { model.emptyTrash() }
        }
    }
}
