import AppKit
import OrbitCore
import SwiftUI

struct WorkbenchHeading: View {
    let title: String
    let detail: String
    var body: some View { VStack(alignment: .leading, spacing: 7) { Text(title).font(.system(size: 24, weight: .semibold, design: .rounded)); Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 5) }
}
struct WorkbenchCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(alignment: .leading, spacing: 14) { content }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.045))) }
}
struct WorkbenchEmpty: View {
    let symbol: String
    let text: String
    var body: some View { VStack(spacing: 10) { Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(OrbitPalette.accent); Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, 28) }
}

struct CommandsToolsView: View {
    @ObservedObject var model: ActionPanelModel
    var language: AppLanguage
    var onOpen: () -> Void
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("想做什麼，打幾個字。", "Find an action. Keep moving."), detail: c("搜尋工具、啟動情境，把常用動作置頂。工具窗內可按 ⌘K 開啟。", "Search tools and modes, and pin your favorites. Press ⌘K in the workbench."))
            WorkbenchCard {
                HStack { Label(c("快捷動作面板", "Action panel"), systemImage: "command").font(.headline); Spacer(); Button(c("開啟面板", "Open panel"), action: onOpen).buttonStyle(.borderedProminent) }
                Toggle(c("全域快捷鍵 ⌃⌥Space", "Global shortcut ⌃⌥Space"), isOn: Binding(get: { model.shortcutEnabled }, set: { model.setShortcut($0) })).toggleStyle(.switch)
                Text(c("預設關閉；開啟後，在其他 App 也能呼叫 Orbit。", "Off by default. Enable it to call Orbit from other Apps.")).font(.caption).foregroundStyle(.secondary)
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                if model.needsRecovery { Button(c("備份並重設置頂", "Back up and reset pins")) { model.recover() } }
            }
            Text(c("工具與情境", "Tools and modes")).font(.headline)
            ForEach(model.ordered) { action in
                HStack(spacing: 12) {
                    Image(systemName: action.symbol).frame(width: 22).foregroundStyle(OrbitPalette.accent)
                    VStack(alignment: .leading, spacing: 3) { Text(action.title); Text(action.detail).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button { model.togglePin(action) } label: { Image(systemName: model.pins.contains(action.id) ? "pin.fill" : "pin") }.accessibilityLabel(c("置頂動作", "Pin action"))
                    Button(c("執行", "Run")) { model.run(action) }
                }.buttonStyle(.borderless).padding(.vertical, 8)
            }
        }.font(.system(size: 12))
    }
}

struct ContextModesView: View {
    @ObservedObject var model: ContextModesModel
    @ObservedObject var scenes: AudioScenesModel
    var language: AppLanguage
    var preview: Bool
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("一個情境，準備好一切。", "One mode. Ready for anything."), detail: c("把音訊、喚醒、計時和常用 App 串成一個動作。", "Bring audio, keep-awake, a timer and your Apps together."))
            ForEach(model.modes) { mode in
                WorkbenchCard {
                    HStack(spacing: 14) {
                        Image(systemName: mode.symbol).font(.system(size: 24)).foregroundStyle(OrbitPalette.accent).frame(width: 34)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(mode.name).font(.system(size: 15, weight: .semibold))
                            Text(summary(mode)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(c("啟動", "Start")) { model.apply(mode) }.buttonStyle(.borderedProminent).disabled(model.busy)
                        Menu {
                            Button(c("編輯", "Edit")) { model.edit(mode) }
                            Button(c("刪除", "Delete"), role: .destructive) { model.remove(mode) }
                        } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel(c("情境選項", "Mode options"))
                    }
                }
            }
            WorkbenchCard {
                HStack { Text(c(model.modes.contains(where: { $0.id == model.draft.id }) ? "編輯情境" : "建立情境", model.modes.contains(where: { $0.id == model.draft.id }) ? "Edit mode" : "Create a mode")).font(.headline); Spacer(); if !model.draft.name.isEmpty { Button(c("清空表單", "New draft")) { model.draft = ContextMode(name: "") } } }
                TextField(c("例如：專心工作", "e.g. Deep work"), text: $model.draft.name).textFieldStyle(.roundedBorder)
                Picker(c("音訊情境", "Audio scene"), selection: $model.draft.audioSceneID) {
                    Text(c("維持目前設定", "Keep current settings")).tag(Optional<UUID>.none)
                    ForEach(scenes.scenes) { Text($0.name).tag(Optional($0.id)) }
                    if let id = model.draft.audioSceneID, !scenes.scenes.contains(where: { $0.id == id }) { Text(c("情境已移除", "Missing scene")).tag(Optional(id)) }
                }
                HStack {
                    Picker(c("保持喚醒", "Keep awake"), selection: $model.draft.awakeMinutes) {
                        ForEach([0,30,60,120], id: \.self) { Text($0 == 0 ? c("不變更", "Unchanged") : "\($0) min").tag($0) }
                    }
                    Stepper(c("倒數", "Timer") + " · " + (model.draft.timerMinutes == 0 ? c("不啟動", "Off") : "\(model.draft.timerMinutes) min"), value: $model.draft.timerMinutes, in: 0...120).frame(width: 240)
                }
                ForEach(model.draft.applications) { app in HStack { Label(app.name, systemImage: "app"); Spacer(); Button(c("移除", "Remove")) { model.draft.applications.removeAll { $0.id == app.id } } } }
                HStack {
                    Button(c("加入 App…", "Add Apps…")) { model.addApplications() }.disabled(preview)
                    Spacer()
                    Button(c("儲存情境", "Save mode")) { model.save() }.buttonStyle(.borderedProminent).disabled(!model.draft.valid || model.needsRecovery || model.busy)
                }
            }.disabled(model.busy)
            if let text = model.message { Label(text, systemImage: model.failed ? "exclamationmark.triangle" : "checkmark.circle").foregroundStyle(model.failed ? .orange : OrbitPalette.accent) }
            if model.needsRecovery { Button(c("備份並重設情境", "Back up and reset modes")) { model.recover() } }
            Button(c("解除情境的喚醒", "End mode keep-awake")) { model.endAwake() }
            Text(c("只在按下啟動後執行。解除喚醒只影響情境自己的設定。", "Runs when you press Start. Ending keep-awake releases only the mode’s assertion.")).font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private func summary(_ mode: ContextMode) -> String {
        var parts: [String] = []
        if mode.audioSceneID != nil { parts.append(c("音訊", "Audio")) }
        if mode.awakeMinutes > 0 { parts.append(c("喚醒", "Awake") + " \(mode.awakeMinutes)m") }
        if mode.timerMinutes > 0 { parts.append(c("倒數", "Timer") + " \(mode.timerMinutes)m") }
        if !mode.applications.isEmpty { parts.append("\(mode.applications.count) Apps") }
        return parts.isEmpty ? c("尚未加入動作", "No actions yet") : parts.joined(separator: " · ")
    }
}

struct ClipboardToolsView: View {
    @ObservedObject var model: ClipboardToolsModel
    var language: AppLanguage
    var onSendToText: (String) -> Void
    @State private var clearing = false
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("剛剛複製的，都找得到。", "Keep the things you copy."), detail: c("最多 50 筆、16 MB，儲存在這台 Mac。標為機密或暫存的剪貼簿內容會略過。", "Up to 50 items and 16 MB, stored on this Mac. Clipboard items marked concealed or transient are skipped."))
            WorkbenchCard {
                Toggle(c("記錄新的剪貼簿內容", "Remember new clipboard items"), isOn: Binding(get: { model.enabled }, set: { model.setEnabled($0) })).toggleStyle(.switch).disabled(model.needsRecovery)
                Text(c("關閉後停止記錄；已保存的項目仍可使用。", "Pausing stops new entries; saved items remain available.")).font(.caption).foregroundStyle(.secondary)
                HStack { TextField(c("搜尋內容…", "Search contents…"), text: $model.query).textFieldStyle(.roundedBorder); Button(c("全部清除", "Clear all"), role: .destructive) { clearing = true }.disabled(model.entries.isEmpty) }
            }
            if model.filtered.isEmpty { WorkbenchEmpty(symbol: "doc.on.clipboard", text: c("複製一些文字或圖片，讓常用內容留在手邊。", "Copy text or an image to keep it close at hand.")) }
            ForEach(model.filtered) { entry in
                WorkbenchCard {
                    HStack(alignment: .top, spacing: 12) {
                        if let data = entry.png, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 90, height: 70).background(.white, in: RoundedRectangle(cornerRadius: 6)) }
                        VStack(alignment: .leading, spacing: 7) {
                            Text(entry.text ?? c("圖片", "Image")).font(.system(size: 12)).lineLimit(4).textSelection(.enabled)
                            Text(entry.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Button(c("複製", "Copy")) { model.copy(entry) }
                        if let text = entry.text { Button { onSendToText(text) } label: { Image(systemName: "text.alignleft") }.accessibilityLabel(c("送到文字工具", "Send to Text")) }
                        Button { model.togglePin(entry) } label: { Image(systemName: entry.pinned ? "pin.fill" : "pin") }.accessibilityLabel(c("置頂", "Pin"))
                        Button(role: .destructive) { model.remove(entry) } label: { Image(systemName: "trash") }.accessibilityLabel(c("刪除項目", "Delete item"))
                    }.buttonStyle(.borderless)
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            if model.needsRecovery { Button(c("備份並重設抽屜", "Back up and reset drawer")) { model.recover() } }
        }.confirmationDialog(c("清除所有已保存的內容？", "Clear all saved items?"), isPresented: $clearing) {
            Button(c("全部清除", "Clear all"), role: .destructive) { model.clear() }
        }
    }
}

struct TextToolsView: View {
    @ObservedObject var model: TextToolsModel
    var language: AppLanguage
    var copyText: (String) -> Void
    var pasteText: () -> String?
    var onSendToQR: (String) -> Void
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("把文字，整理成想要的樣子。", "A little cleanup for your text."), detail: c("清理空白、JSON 排版、網址編碼。所有處理都在本機。", "Clean up lines, format JSON and encode URLs. All on your Mac."))
            WorkbenchCard {
                HStack { Text(c("輸入", "Input")).font(.headline); Spacer(); Text("\(model.input.count) " + c("字元", "characters")).foregroundStyle(.secondary); Button(c("貼上純文字", "Paste plain text")) { if let value = pasteText() { model.input = value } } }
                TextEditor(text: $model.input).font(.system(size: 12, design: .monospaced)).frame(height: 145).scrollContentBackground(.hidden).padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(c("待處理文字", "Text input"))
                HStack { Picker(c("處理方式", "Transform"), selection: $model.action) { ForEach(TextAction.allCases) { Text($0.title(c)).tag($0) } }; Button(c("轉換", "Transform")) { model.transform() }.buttonStyle(.borderedProminent) }
            }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            WorkbenchCard {
                HStack { Text(c("結果", "Result")).font(.headline); Spacer(); Button("QR Code") { onSendToQR(model.output) }.disabled(model.output.isEmpty); Button(c("用作輸入", "Use as input")) { model.input = model.output }.disabled(model.output.isEmpty); Button(c("複製結果", "Copy result")) { copyText(model.output) }.disabled(model.output.isEmpty) }
                TextEditor(text: .constant(model.output)).font(.system(size: 12, design: .monospaced)).frame(height: 150).scrollContentBackground(.hidden).padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(c("處理結果", "Transform result"))
            }
        }.font(.system(size: 12))
    }
}

struct PDFToolsView: View {
    @ObservedObject var model: PDFToolsModel
    var language: AppLanguage
    var preview: Bool
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("PDF 的小事，幾下就好。", "Small PDF tasks, done quickly."), detail: c("合併、拆分、取頁、旋轉，或把圖片集成一份文件。原始檔案會保留。", "Merge, split, extract, rotate or collect images into a document. Original files stay intact."))
            WorkbenchCard {
                Picker(c("操作", "Action"), selection: $model.action) { ForEach(PDFAction.allCases) { Text($0.title(c)).tag($0) } }
                if model.action != .merge && model.action != .images { TextField(c("頁碼，例如 1-3,5；留白表示全部", "Pages: 1-3,5; leave empty for all"), text: $model.pages).textFieldStyle(.roundedBorder) }
                HStack { Button(c("選擇檔案…", "Choose files…")) { model.choose() }.disabled(preview); Spacer(); Text(c("依下列順序處理", "Processed in this order")).font(.caption).foregroundStyle(.secondary) }
                ForEach(model.files.indices, id: \.self) { index in
                    HStack { Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 18); Text(model.files[index].lastPathComponent).lineLimit(1); Spacer(); Button { model.move(index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0).accessibilityLabel(c("向上移", "Move up")); Button { model.move(index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == model.files.count - 1).accessibilityLabel(c("向下移", "Move down")); Button(role: .destructive) { model.remove(index) } label: { Image(systemName: "xmark") }.accessibilityLabel(c("移除檔案", "Remove file")) }.buttonStyle(.borderless)
                }
                if model.files.isEmpty { WorkbenchEmpty(symbol: "doc.richtext", text: c("加入檔案，選一個操作。", "Add files and choose an action.")) }
                HStack { if model.busy { ProgressView().controlSize(.small) }; Spacer(); Button(c("選擇位置並輸出…", "Export to folder…")) { model.export() }.buttonStyle(.borderedProminent).disabled(model.files.isEmpty || preview) }
            }.disabled(model.busy)
            if let output = model.output { Label(c("已輸出到：", "Exported to: ") + output.lastPathComponent, systemImage: "checkmark.circle").foregroundStyle(OrbitPalette.accent); Button(c("在 Finder 顯示", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([output]) }.disabled(preview) }
            if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Text(c("最多 50 個檔案、500 頁、200 MB。加密 PDF 請先解鎖。", "Up to 50 files, 500 pages, 200 MB. Unlock encrypted PDFs first.")).font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
}

struct QRToolsView: View {
    @ObservedObject var model: QRToolsModel
    var language: AppLanguage
    var preview: Bool
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("文字變成碼，圖片讀出來。", "From text to QR. From QR to text."), detail: c("產生高解析 PNG，或從圖片與編修後的截圖辨識。連結不會自動開啟。", "Generate a crisp PNG or read codes from images and edited screenshots. Links stay as text."))
            WorkbenchCard {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $model.text).font(.system(size: 12, design: .monospaced)).frame(height: 120).scrollContentBackground(.hidden).padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel(c("QR Code 內容", "QR code content"))
                        HStack { Button(c("產生 QR Code", "Generate QR")) { model.generate() }.buttonStyle(.borderedProminent); Button(c("匯出 PNG…", "Export PNG…")) { model.export() }.disabled(model.image == nil || preview) }
                    }
                    if let image = model.image { Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit().frame(width: 170, height: 170).background(.white, in: RoundedRectangle(cornerRadius: 8)).accessibilityLabel("QR Code") }
                }
            }
            WorkbenchCard {
                HStack { Label(c("辨識圖片", "Read an image"), systemImage: "qrcode.viewfinder").font(.headline); Spacer(); if model.busy { ProgressView().controlSize(.small) }; Button(c("選擇圖片…", "Choose image…")) { model.chooseImage() }.disabled(preview || model.busy) }
                if model.results.isEmpty { Text(c("也可以從「截圖」頁把編修後的圖片送來。", "You can also send an edited image from Screenshots.")).foregroundStyle(.secondary) }
                ForEach(Array(model.results.enumerated()), id: \.offset) { _, value in HStack { Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading); Button(c("複製", "Copy")) { model.copy(value) } } }
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }
        }.font(.system(size: 12))
    }
}

struct ColorToolsView: View {
    @ObservedObject var model: ColorToolsModel
    var language: AppLanguage
    var preview: Bool
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("看到喜歡的顏色，就留下。", "A color worth keeping."), detail: c("用系統取色器選色，複製 HEX、RGB，收藏常用配色。", "Sample a color, copy HEX or RGB, and save your palette."))
            WorkbenchCard {
                RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: model.current?.color ?? .clear)).frame(height: 135).overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.1)))
                HStack { TextField("#RRGGBB", text: $model.input).textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)); Button(c("螢幕取色…", "Sample screen…")) { model.sample() }.disabled(preview); Button(c("收藏", "Save")) { model.save() }.buttonStyle(.borderedProminent).disabled(model.current == nil || model.needsRecovery) }
                if let color = model.current { HStack { Button(color.hex) { model.copy(color.hex) }; Button(color.rgb) { model.copy(color.rgb) } }.font(.system(.body, design: .monospaced)) }
            }
            Text(c("我的配色", "Your palette")).font(.headline)
            if model.swatches.isEmpty { WorkbenchEmpty(symbol: "paintpalette", text: c("收藏一個顏色，從這裡開始。", "Save your first color to start a palette.")) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                ForEach(model.swatches) { swatch in
                    VStack(spacing: 8) {
                        Button { model.input = swatch.hex } label: { RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: swatch.color)).frame(height: 65) }.buttonStyle(.plain).accessibilityLabel(swatch.hex)
                        HStack { Button(swatch.hex) { model.copy(swatch.hex) }.font(.caption.monospaced()); Spacer(); Button(role: .destructive) { model.remove(swatch) } label: { Image(systemName: "xmark") }.accessibilityLabel(c("移除顏色", "Remove color")) }.buttonStyle(.borderless)
                    }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            if model.needsRecovery { Button(c("備份並重設配色", "Back up and reset palette")) { model.recover() } }
        }.font(.system(size: 12))
    }
}

struct SmartRemindersView: View {
    @ObservedObject var model: SmartRemindersModel
    var language: AppLanguage
    var preview: Bool
    private var c: ToolCopy { ToolCopy(language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("需要你的時候，再提醒。", "A heads-up when it matters."), detail: c("沿用 Orbit 的系統讀值，同一狀態只提醒一次，恢復後再重新偵測。", "Uses Orbit’s existing readings. Alerts once per condition, then rearms after recovery."))
            WorkbenchCard {
                Toggle(c("開啟聰明提醒", "Enable smart reminders"), isOn: Binding(get: { model.enabled || model.requesting }, set: { model.setEnabled($0) })).toggleStyle(.switch).disabled(preview || model.needsRecovery)
                Divider()
                Toggle(c("Mac 低電量", "Mac low battery"), isOn: $model.settings.macLow)
                Toggle(c("Mac 充電達標", "Mac charge target"), isOn: $model.settings.charged)
                Toggle(c("周邊低電量", "Accessory low battery"), isOn: $model.settings.peripheralLow)
                Toggle(c("網路從連線變成離線", "Network connection lost"), isOn: $model.settings.networkLost)
                Divider()
                Stepper(c("低電量門檻", "Low battery threshold") + " · \(model.settings.threshold)%", value: $model.settings.threshold, in: 5...50, step: 5)
                Stepper(c("充電目標", "Charge target") + " · \(model.settings.chargedThreshold)%", value: $model.settings.chargedThreshold, in: 80...100, step: 5)
            }.disabled(model.needsRecovery)
            HStack { Text(c("這次開啟後的提醒", "This session")).font(.headline); Spacer(); Button(c("清除", "Clear")) { model.clear() }.disabled(model.history.isEmpty) }
            if model.history.isEmpty { WorkbenchEmpty(symbol: "bell.badge", text: c("目前沒有提醒，安心做你的事。", "All quiet. Carry on with your day.")) }
            ForEach(model.history) { event in WorkbenchCard { HStack { Label(event.body, systemImage: "bell"); Spacer(); Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary) } } }
            if let error = model.error { Text(error).foregroundStyle(.orange) }
            if model.needsRecovery { Button(c("備份並重設提醒", "Back up and reset reminders")) { model.recover() } }
            Text(c("未知電量不會推測；桌機不會收到筆電充電提醒。通知由 macOS 的通知設定與專注模式控制。", "Unknown battery levels stay unknown. Desktop Macs receive no laptop charge alerts. macOS notification settings and Focus control delivery.")).font(.caption).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
}
