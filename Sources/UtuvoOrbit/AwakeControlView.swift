import SwiftUI
import OrbitCore

// MARK: - AwakeControlView (compact)
// Single row: native Picker for duration, toggle button, countdown label when
// active. ~70pt total. No nested glass.

struct AwakeControlView: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    @StateObject private var durationMenu = NativeMenuAnchor()
    /// Shared between the duration Menu and the start/stop Button so their
    /// LABEL text matches; actual control height/padding now comes from
    /// applying the SAME `.glassButton()` style + `.controlSize` to both,
    /// not from a manually forced frame height.
    private static let controlFont: Font = .system(size: 11, weight: .medium)
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: model.awake.isActive ? "moon.zzz.fill" : "moon")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(model.awake.isActive ? .orange : .secondary)
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                Text(l("保持喚醒"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                if model.awake.isActive {
                    Text(l(AwakeMath.countdownLabel(state: model.awake, now: Date())))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.orange)
                        .accessibilityLabel(l("剩餘 %@", l(AwakeMath.countdownLabel(state: model.awake, now: Date()))))
                }
            }
            // All three controls are the SAME kind of control — a plain
            // SwiftUI Button with the same style, font and controlSize — so
            // they cannot disagree about material, height or baseline.
            // SwiftUI's `Menu` is deliberately not used: it keeps its own
            // NSPopUpButton bezel and blue indicator whatever style is
            // applied to it. The duration button opens a real `NSMenu`
            // instead (see `NativeMenuAnchor`), so the dropdown, its
            // checkmark, keyboard handling and VoiceOver stay native, and
            // each item calls the same model method as before.
            GlassContainer {
                HStack(spacing: 6) {
                    Button {
                        durationMenu.present(AwakeDuration.allCases.map { duration in
                            NativeMenuEntry(title: l(duration.localizedTitle),
                                            isChecked: duration == model.pendingAwakeDuration) {
                                model.setPendingAwakeDuration(duration)
                            }
                        })
                    } label: {
                        HStack(spacing: 4) {
                            Text(l(model.pendingAwakeDuration.localizedTitle))
                                .font(Self.controlFont)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .glassButton()
                    .controlSize(.regular)
                    .overlay(NativeMenuAnchorView(anchor: durationMenu).allowsHitTesting(false))
                    .accessibilityLabel(l("保持喚醒持續時間，目前選擇 %@", l(model.pendingAwakeDuration.localizedTitle)))
                    if model.awake.isActive {
                        Button(role: .destructive) {
                            model.stopAwake()
                        } label: {
                            Text(l("停止")).font(Self.controlFont)
                                .frame(width: 64)
                        }
                        .glassButton()
                        .controlSize(.regular)
                        .accessibilityLabel(l("停止保持喚醒"))
                    } else {
                        Button {
                            model.startAwake(duration: model.pendingAwakeDuration)
                        } label: {
                            Text(l("啟動")).font(Self.controlFont)
                                .frame(maxWidth: .infinity)
                        }
                        .glassButton()
                        .controlSize(.regular)
                        .accessibilityLabel(l("啟動保持喚醒 %@", l(model.pendingAwakeDuration.localizedTitle)))
                    }
                }
            }
            if let error = model.awakeError {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .accessibilityLabel(l("喚醒錯誤：%@", error))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("保持喚醒控制"))
    }
}
