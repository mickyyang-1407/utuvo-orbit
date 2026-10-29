import AppKit
import ClotheslineKit
import OrbitCore
import SwiftUI

struct ScreenshotToolsView: View {
    @ObservedObject var model: ScreenshotToolsModel
    let language: AppLanguage
    var preview = false
    private var l: OrbitStrings { OrbitStrings(language: language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(l("抓住畫面，留下重點。" )).font(.system(size: 21, weight: .semibold))
                    Text(l("選取內容，再裁切、標記或遮蓋。" )).foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy {
                    ProgressView().controlSize(.small)
                    Button(l("取消")) { model.cancel() }
                }
            }
            HStack {
                Button { model.take(.window) } label: { Label(l("擷取視窗"), systemImage: "macwindow") }
                Button { model.take(.display) } label: { Label(l("擷取螢幕"), systemImage: "display") }
                Spacer()
                Button(l("匯入圖片…")) { model.chooseImage() }.disabled(preview)
            }.buttonStyle(.bordered).disabled(model.busy)
            if model.waitingForSelection {
                Text(l("若系統選擇器未出現，請取消並匯入 ⌘⇧4 的截圖。"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let image = model.image {
                Picker(l("編修工具"), selection: $model.tool) {
                    ForEach(ScreenshotTool.allCases) { tool in Label(l(title(tool)), systemImage: symbol(tool)).tag(tool) }
                }.pickerStyle(.segmented).disabled(model.busy)
                ScreenshotCanvas(image: image, tool: model.tool, enabled: !model.busy,
                                 hint: l("在圖片上拖曳套用所選工具。"), commit: { model.apply(from: $0, to: $1) })
                    .frame(height: 224)
                HStack {
                    Text("\(image.width) × \(image.height) px").monospacedDigit().foregroundStyle(.secondary)
                    Text(l("%d 次編修", model.edits.count)).foregroundStyle(.secondary)
                    Spacer()
                    Button(l("復原")) { model.undo() }.disabled(model.edits.isEmpty)
                    Button(l(model.draftNeedsRecovery ? "備份並還原原圖" : "還原原圖")) { model.resetEdits() }
                        .disabled(model.edits.isEmpty && !model.draftNeedsRecovery)
                }.disabled(model.busy)
                HStack {
                    Button(l("複製圖片")) { model.copy() }.disabled(preview)
                    Button(l("辨識文字")) { model.recognize() }.disabled(preview)
                    Button(l("輸出 PNG…")) { model.chooseExport() }.disabled(preview)
                    Spacer()
                    Button(l("檔案工具")) { model.sendToFiles() }
                    Button("QR Code") { if let image = model.image { model.onSendToQR?(image) } }
                    Button(l("掛上晾衣繩")) { model.sendToClothesline() }
                        .disabled(preview || !model.canSendToClothesline())
                        .help(l("先在模組設定中開啟截圖晾衣繩。"))
                }.disabled(model.busy)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "viewfinder").font(.system(size: 42, weight: .light)).foregroundStyle(OrbitPalette.accent)
                    Text(l("從一次截圖開始。" )).font(.system(size: 17, weight: .medium))
                    Text(l("只有你在系統選擇器中選取的內容會被擷取。"))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).frame(height: 260)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            }
            if !model.recent.isEmpty {
                HStack {
                Picker(l("最近截圖"), selection: Binding(get: { model.selectedID }, set: { id in if let id { model.select(id) } })) {
                    ForEach(model.recent.prefix(24)) { item in
                        Text(item.capturedAt.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Locale(identifier: l.identifier)))).tag(Optional(item.id))
                    }
                }.disabled(model.busy)
                    Button { model.openLibrary() } label: { Image(systemName: "folder") }
                        .accessibilityLabel(l("打開截圖素材庫")).disabled(preview)
                }
            }
            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(model.failed ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text(l("編修與輸出使用副本；遮蓋會寫入圖片像素。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12)).tint(.primary)
    }
    private func title(_ tool: ScreenshotTool) -> String {
        switch tool { case .crop: "裁切"; case .arrow: "箭頭"; case .rectangle: "框線"; case .redact: "遮蓋" }
    }
    private func symbol(_ tool: ScreenshotTool) -> String {
        switch tool { case .crop: "crop"; case .arrow: "arrow.up.right"; case .rectangle: "rectangle"; case .redact: "rectangle.fill" }
    }
}

private struct ScreenshotCanvas: View {
    let image: CGImage
    let tool: ScreenshotTool
    let enabled: Bool
    let hint: String
    let commit: (CGPoint, CGPoint) -> Void
    @State private var start: CGPoint?
    @State private var end: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let factor = min(geometry.size.width / Double(image.width), geometry.size.height / Double(image.height))
            let size = CGSize(width: Double(image.width) * factor, height: Double(image.height) * factor)
            ZStack {
                Color(nsColor: .controlBackgroundColor)
                Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size.width, height: size.height)
                    .overlay {
                        Canvas { context, _ in
                            if let start, let end {
                                let a = CGPoint(x: start.x * size.width, y: start.y * size.height)
                                let b = CGPoint(x: end.x * size.width, y: end.y * size.height)
                                if tool == .arrow {
                                    var path = Path(); path.move(to: a); path.addLine(to: b)
                                    context.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                } else {
                                    let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                                    context.fill(Path(rect), with: .color(tool == .redact ? .black : .cyan.opacity(0.15)))
                                    context.stroke(Path(rect), with: .color(.cyan), style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 3)
                        .onChanged { value in
                            guard enabled else { return }
                            start = normalized(value.startLocation, in: size); end = normalized(value.location, in: size)
                        }
                        .onEnded { value in
                            defer { start = nil; end = nil }
                            guard enabled else { return }
                            commit(normalized(value.startLocation, in: size), normalized(value.location, in: size))
                        })
                    .accessibilityLabel(hint)
                    .accessibilityAddTraits(.isImage)
            }.clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / max(1, size.width))), y: min(1, max(0, point.y / max(1, size.height))))
    }
}
