import AppKit
import OrbitCore
import SwiftUI

/// Web quick links: saved http/https templates that open only after an explicit
/// user action. Template links ask for their search term first.
struct QuickLinksToolsView: View {
    @ObservedObject var model: QuickLinksModel
    var language: AppLanguage
    var preview: Bool
    private var c: ToolCopy { ToolCopy(language: language) }

    @State private var newTitle = ""
    @State private var newTemplate = ""
    @State private var editingID: UUID?
    @State private var editingTitle = ""
    @State private var editingTemplate = ""
    @State private var removing: QuickLink?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("常用網址，一點就開。", "Your web shortcuts, one click away."),
                             detail: c("只放網址模板。連結只會在你按下開啟時才會被開啟。", "Web templates only. A link opens only after you ask for it."))
            WorkbenchCard {
                HStack {
                    TextField(c("搜尋連結…", "Search links…"), text: $model.query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(c("搜尋連結", "Search links"))
                    Button(c("清除", "Clear")) { model.query = "" }.disabled(model.query.isEmpty)
                }
                Divider()
                TextField(c("名稱", "Title"), text: $newTitle).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(c("連結名稱", "Link title"))
                TextField(c("網址範本，例如 https://example.com/search?q={query}", "URL template, e.g. https://example.com/search?q={query}"),
                          text: $newTemplate).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(c("網址範本", "URL template"))
                HStack {
                    Text(c("支援 http 與 https。{query} 只能放在路徑或查詢字串，開啟時才會填入搜尋字詞。",
                           "http and https only. {query} works in the path or the query part and is filled in when you open the link."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(c("新增連結", "Add link")) { addLink() }.buttonStyle(.borderedProminent)
                        .disabled(model.needsRecovery || newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newTemplate.isEmpty)
                }
            }

            if model.visible.isEmpty {
                WorkbenchEmpty(symbol: "link", text: c("還沒有連結。加一個常用網址，或從上方搜尋。", "No links yet. Add a favourite, or search above."))
            } else {
                ForEach(model.visible) { link in
                    WorkbenchCard {
                        HStack(spacing: 12) {
                            Button { model.requestOpen(link.id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(link.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                        if QuickLinkTemplate.requiresQuery(link.template) {
                                            Text(c("需搜尋字詞", "Needs a search term")).font(.caption)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(OrbitPalette.accent.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text(link.template).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { model.togglePin(link.id) } label: { Image(systemName: link.pinned ? "pin.fill" : "pin") }
                                .accessibilityLabel(c("置頂連結", "Pin link"))
                            Button { model.requestOpen(link.id) } label: { Image(systemName: "arrow.up.right.square") }
                                .accessibilityLabel(c("開啟連結", "Open link"))
                            Button { beginEditing(link) } label: { Image(systemName: "pencil") }
                                .accessibilityLabel(c("編輯連結", "Edit link"))
                            Button { removing = link } label: { Image(systemName: "trash") }
                                .accessibilityLabel(c("移除連結", "Remove link"))
                        }
                        if editingID == link.id {
                            Divider()
                            TextField(c("名稱", "Title"), text: $editingTitle).textFieldStyle(.roundedBorder)
                                .accessibilityLabel(c("連結名稱", "Link title"))
                            TextField(c("網址範本", "URL template"), text: $editingTemplate).textFieldStyle(.roundedBorder)
                                .accessibilityLabel(c("網址範本", "URL template"))
                            HStack {
                                Spacer()
                                Button(c("取消", "Cancel")) { editingID = nil }.keyboardShortcut(.cancelAction)
                                Button(c("儲存", "Save")) { saveEditing(link.id) }.buttonStyle(.borderedProminent)
                                    .keyboardShortcut(.defaultAction)
                            }
                        }
                    }
                }
            }

            if let pending = model.pendingLink {
                WorkbenchCard {
                    Text(c("開啟「%@」", "Open “%@”").replacingOccurrences(of: "%@", with: pending.title)).font(.headline)
                    TextField(c("搜尋字詞", "Search term"), text: $model.pendingQuery).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(c("搜尋字詞", "Search term"))
                        .onSubmit { model.confirmPendingOpen() }
                    HStack {
                        Spacer()
                        Button(c("取消", "Cancel")) { model.cancelPendingOpen() }.keyboardShortcut(.cancelAction)
                        Button(c("開啟", "Open")) { model.confirmPendingOpen() }.buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }

            LibraryBackupControls(model: model, language: language, preview: preview)
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
            if model.needsRecovery {
                Button(c("備份損壞資料並重設", "Back up damaged data and reset")) { model.recover() }
            }
        }
        .confirmationDialog(c("移除這個連結？", "Remove this link?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(c("移除", "Remove"), role: .destructive) {
                if let removing { model.remove(removing.id) }
                removing = nil
            }
            Button(c("取消", "Cancel"), role: .cancel) { removing = nil }
        }
    }

    private func addLink() {
        guard model.add(title: newTitle, template: newTemplate) else { return }
        newTitle = ""
        newTemplate = ""
    }

    private func beginEditing(_ link: QuickLink) {
        editingID = link.id
        editingTitle = link.title
        editingTemplate = link.template
    }

    private func saveEditing(_ id: UUID) {
        guard model.update(id, title: editingTitle, template: editingTemplate) else { return }
        editingID = nil
    }
}

/// Plain-text snippets with a small template grammar: `{{date}}`, `{{time}}`
/// and named custom fields. Nothing is copied until the user asks for it.
struct SnippetsToolsView: View {
    @ObservedObject var model: SnippetsModel
    var language: AppLanguage
    var preview: Bool
    var onSendToText: (String) -> Void
    var onSendToNotes: (_ title: String, _ body: String) -> Void
    @State private var deleting: Snippet?
    private var c: ToolCopy { ToolCopy(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("常用片段，一鍵就貼。", "Snippets you reuse every day."),
                             detail: c("純文字片段，只存這台 Mac。可以放日期、時間與自訂欄位。", "Plain text only, stored on this Mac. Date, time and your own fields are supported."))
            WorkbenchCard {
                HStack {
                    TextField(c("搜尋片段…", "Search snippets…"), text: $model.query).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(c("搜尋片段", "Search snippets"))
                    Button(c("新增片段", "New snippet")) { model.create(title: c("新片段", "New snippet")) }.buttonStyle(.borderedProminent)
                        .disabled(model.needsRecovery)
                }
                if !model.snippets.isEmpty {
                    Text(c("最多 100 則、每則 64 KiB、合計 2 MB。關鍵字不可重複。",
                           "Up to 100 snippets, 64 KiB each and 2 MB in total. Keywords must be unique."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if model.visible.isEmpty {
                WorkbenchEmpty(symbol: "text.quote", text: c("還沒有片段。加一則常用文字，之後直接貼上。", "No snippets yet. Add the text you keep typing."))
            } else {
                ForEach(model.visible) { snippet in
                    WorkbenchCard {
                        HStack(spacing: 12) {
                            Button { model.select(snippet.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(snippet.title).fontWeight(.medium).lineLimit(1)
                                        if !snippet.keyword.isEmpty {
                                            Text(snippet.keyword).font(.caption)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(OrbitPalette.accent.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    Text(snippet.body.isEmpty ? c("還沒有內容", "No text yet") : snippet.body)
                                        .lineLimit(1).foregroundStyle(.secondary).font(.caption)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                            Button { model.pin(snippet.id) } label: { Image(systemName: snippet.pinned ? "pin.fill" : "pin") }
                                .accessibilityLabel(c("置頂片段", "Pin snippet"))
                            Button { deleting = snippet } label: { Image(systemName: "trash") }
                                .accessibilityLabel(c("刪除片段", "Delete snippet"))
                        }
                    }
                }
            }

            if model.selected != nil {
                WorkbenchCard {
                    TextField(c("標題", "Title"), text: Binding(get: { model.draftTitle }, set: { model.editTitle($0) }))
                        .textFieldStyle(.roundedBorder).font(.headline)
                        .accessibilityLabel(c("片段標題", "Snippet title"))
                    TextField(c("關鍵字（可留空）", "Keyword (optional)"), text: Binding(get: { model.draftKeyword }, set: { model.editKeyword($0) }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(c("關鍵字", "Keyword"))
                    TextEditor(text: Binding(get: { model.draftBody }, set: { model.editBody($0) }))
                        .font(.system(size: 13)).frame(height: 160).scrollContentBackground(.hidden).padding(8)
                        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(c("片段內容", "Snippet text"))
                    Text(c("可用 {{date}}、{{time}}，以及自訂欄位（例如 {{name}}，最多 16 個）。欄位值只會取代原模板一次。",
                           "Use {{date}}, {{time}} and your own fields (for example {{name}}, up to 16). A value replaces the template once."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                    if !model.customFields.isEmpty {
                        Divider()
                        Text(c("自訂欄位", "Custom fields")).font(.headline)
                        ForEach(model.customFields) { field in
                            TextField(field.name, text: Binding(get: { model.fieldValue(field.name) }, set: { model.setFieldValue($0, for: field.name) }))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel(c("欄位 %@", "Field %@").replacingOccurrences(of: "%@", with: field.name))
                        }
                    }

                    HStack {
                        Text(model.dirty ? (model.error == nil ? c("儲存中…", "Saving…") : c("尚未儲存", "Not saved")) : c("已儲存", "Saved"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(c("儲存", "Save")) { model.flush() }.keyboardShortcut("s", modifiers: .command)
                        Button(c("預覽", "Preview")) { model.makePreview() }
                        Button(c("複製", "Copy")) { model.copyPreview() }
                        Button(c("送到文字工具", "Send to Text")) {
                            if let text = model.expansionForSending() { onSendToText(text) }
                        }
                        Button(c("送到筆記", "Send to Notes")) {
                            if let text = model.expansionForSending() { onSendToNotes(model.selected?.title ?? "Snippet", text) }
                        }
                    }
                }
                if let preview = model.preview {
                    WorkbenchCard {
                        Text(c("預覽", "Preview")).font(.headline)
                        Text(preview).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let failure = model.previewError {
                    Text(failure).foregroundStyle(.orange).font(.caption)
                }
            } else {
                WorkbenchEmpty(symbol: "text.quote", text: c("選一則片段，或新增一則。", "Choose a snippet, or add a new one."))
            }

            LibraryBackupControls(model: model, language: language, preview: preview)
            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
            if model.needsRecovery {
                Button(c("備份損壞資料並重設", "Back up damaged data and reset")) { model.recover() }
            }
        }
        .confirmationDialog(c("刪除這則片段？", "Delete this snippet?"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(c("刪除", "Delete"), role: .destructive) {
                if let deleting { model.delete(deleting.id, confirmed: true) }
                deleting = nil
            }
            Button(c("取消", "Cancel"), role: .cancel) { deleting = nil }
        }
    }
}

/// File integrity: streaming checksums for files the user picks by hand.
/// Nothing is hashed until the user presses Compute, and no file is ever
/// written, moved or deleted.
struct FileIntegrityToolsView: View {
    @ObservedObject var model: FileIntegrityModel
    var language: AppLanguage
    var preview: Bool
    var onSendToText: (String) -> Void
    private var c: ToolCopy { ToolCopy(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WorkbenchHeading(title: c("檔案有沒有變？算一下。", "Did the file change? Check it."),
                             detail: c("挑選檔案後才會計算雜湊。連結、資料夾與符號連結都不會被處理，檔案內容不會離開這台 Mac。",
                                       "Hashes run only after you pick the files and press Compute. Links, folders and symlinks are refused, and nothing leaves this Mac."))
            WorkbenchCard {
                Picker(c("演算法", "Algorithm"), selection: $model.algorithm) {
                    ForEach(FileIntegrityAlgorithm.allCases) { algorithm in
                        Text(algorithm.compatibilityOnly ? c("\(algorithm.title)（相容用）", "\(algorithm.title) (compatibility)") : algorithm.title).tag(algorithm)
                    }
                }
                .pickerStyle(.segmented)
                if model.algorithm.compatibilityOnly {
                    Text(c("MD5 只用來比對舊工具產生的雜湊值，不能證明兩個檔案相同。",
                           "MD5 only compares with checksums made by older tools. It cannot prove two files are identical."))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button(c("加入檔案", "Add files")) {
                        let urls = ToolFiles.choose([.data], multiple: true)
                        if !urls.isEmpty { model.addFiles(urls) }
                    }.buttonStyle(.bordered).disabled(preview)
                    Button(c("清除清單", "Clear list")) { model.clearFiles() }.disabled(model.files.isEmpty)
                    Spacer()
                    if model.busy {
                        Button(c("取消", "Cancel")) { model.cancel() }.buttonStyle(.bordered)
                    }
                    Button(c("計算", "Compute")) {
                        Task { await model.compute() }
                    }.buttonStyle(.borderedProminent).disabled(model.files.isEmpty || model.busy)
                }
                if model.busy {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(c("計算中…", "Hashing…")).font(.caption).foregroundStyle(.secondary) }
                }
                if model.files.isEmpty {
                    WorkbenchEmpty(symbol: "doc.text.magnifyingglass", text: c("加入最多 8 個檔案，再按計算。", "Add up to 8 files, then press Compute."))
                } else {
                    ForEach(model.files, id: \.self) { file in
                        HStack {
                            Image(systemName: "doc").foregroundStyle(OrbitPalette.accent)
                            Text(file.lastPathComponent).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeFile(file) } label: { Image(systemName: "trash") }
                                .accessibilityLabel(c("移除檔案", "Remove file"))
                        }.font(.system(size: 12)).padding(.vertical, 3)
                    }
                }
            }

            if !model.results.isEmpty {
                WorkbenchCard {
                    Text(c("雜湊值", "Hashes")).font(.headline)
                    ForEach(model.results) { result in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.fileName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text(result.digest).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(c("%lld 個位元組", "%lld bytes").replacingOccurrences(of: "%lld", with: String(result.byteCount)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.copyHash(result.id) } label: { Image(systemName: "doc.on.doc") }
                                .accessibilityLabel(c("複製雜湊值", "Copy hash"))
                        }
                    }
                    Button(c("送出報告到文字工具", "Send report to Text")) {
                        if let report = model.reportText() { onSendToText(report) }
                    }.buttonStyle(.bordered)
                }
            }

            if let comparison = model.comparison {
                WorkbenchCard {
                    Text(c("兩個檔案", "Two files")).font(.headline)
                    Label(comparison.matches
                          ? c("雜湊值相同。這不代表兩個檔案一定相同。", "The hash values match. That does not prove the files are identical.")
                          : c("雜湊值不同。", "The hash values differ."),
                          systemImage: comparison.matches ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(comparison.matches ? OrbitPalette.accent : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            WorkbenchCard {
                Text(c("預期雜湊值", "Expected checksum")).font(.headline)
                TextField(c("貼上要比對的雜湊值", "Paste the checksum to compare"), text: $model.expected)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel(c("預期雜湊值", "Expected checksum"))
                HStack {
                    Button(c("比對", "Compare")) { model.checkExpected() }.disabled(model.results.isEmpty)
                    Spacer()
                }
                if !model.expectedChecks.isEmpty {
                    ForEach(model.expectedChecks) { check in
                        Label(check.matched ? c("\(check.fileName)：相符", "\(check.fileName): matches")
                                             : c("\(check.fileName)：不相符", "\(check.fileName): does not match"),
                              systemImage: check.matched ? "checkmark.circle" : "xmark.circle")
                            .foregroundStyle(check.matched ? OrbitPalette.accent : Color.orange)
                            .font(.system(size: 12))
                    }
                }
                if let failure = model.expectedError { Text(failure).foregroundStyle(.orange).font(.caption) }
                Text(c("大小寫與空白會自動忽略，長度必須符合目前演算法。",
                       "Case and whitespace are ignored. The length must match the chosen algorithm."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let error = model.error { Text(error).foregroundStyle(.orange).font(.caption) }
        }
    }
}
