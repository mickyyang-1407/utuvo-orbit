import SwiftUI
import OrbitCore

// A single aligned control area, always visible below the status details.
struct DisplayPreferencesView: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    @ObservedObject var preferences: OrbitPreferencesModel
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
            GridRow {
                rowLabel(l("樣式"))
                Picker(l("選單列樣式"), selection: Binding(get: {
                    preferences.values.glyphStyle
                }, set: { model.setGlyphStyle($0) })) {
                    ForEach(GlyphStyle.allCases, id: \.self) { style in
                        Text(l(style.localizedTitle)).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(l("選單列樣式：合併或傳統"))
            }
            GridRow {
                rowLabel(l("內容"))
                GlassContainer {
                    HStack(spacing: 6) {
                        if monitor.snapshot.machine == .desktop {
                            DisplayMenuControl(title: l("外圈"), value: l(preferences.values.desktopRing.localizedTitle),
                                               accessibility: l("桌機外圈顯示內容")) {
                                DesktopRing.allCases.map { ring in
                                    NativeMenuEntry(title: l(ring.localizedTitle),
                                                    isChecked: preferences.values.desktopRing == ring) {
                                        model.setDesktopRing(ring)
                                    }
                                }
                            }
                        }
                        DisplayMenuControl(title: l("中央"), value: l(preferences.values.ringCenter.localizedTitle),
                                           accessibility: l("環形中央顯示網路或百分比")) {
                            RingCenter.allCases.map { center in
                                NativeMenuEntry(title: l(center.localizedTitle),
                                                isChecked: preferences.values.ringCenter == center) {
                                    model.setRingCenter(center)
                                }
                            }
                        }
                        .disabled(preferences.values.glyphStyle == .classic)
                        .help(preferences.values.glyphStyle == .classic ? l("傳統樣式沒有共用中央區域") : l("選擇合併圖示中央的內容"))
                    }
                }
            }
            GridRow {
                rowLabel(l("主題"))
                Picker(l("主題"), selection: Binding(get: {
                    preferences.values.theme
                }, set: { model.setTheme($0) })) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme == .system ? l("系統") : l(theme.localizedTitle)).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .accessibilityLabel(l("主題"))
            }
            GridRow {
                rowLabel(l("顯示"))
                HStack(spacing: 20) {
                    Toggle(l("百分比"), isOn: Binding(get: {
                        preferences.values.showPercent
                    }, set: { model.setShowPercent($0) }))
                    .accessibilityLabel(l("選單列顯示百分比"))
                    Toggle(l("狀態色彩"), isOn: Binding(get: {
                        preferences.values.colorful
                    }, set: { model.setColorful($0) }))
                    .accessibilityLabel(l("狀態色彩"))
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("顯示偏好"))
    }

    private func rowLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(width: l.identifier == "en" ? 48 : 32, alignment: .leading)
    }
}

private struct DisplayMenuControl: View {
    @Environment(\.orbitStrings) private var l
    let title: String
    let value: String
    let accessibility: String
    let entries: () -> [NativeMenuEntry]
    @StateObject private var menu = NativeMenuAnchor()

    var body: some View {
        Button { menu.present(entries()) } label: {
            HStack(spacing: 4) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
        }
        .glassButton()
        .overlay(NativeMenuAnchorView(anchor: menu).allowsHitTesting(false))
        .accessibilityLabel(l("%@，目前選擇 %@", accessibility, value))
    }
}
