import SwiftUI
import OrbitCore

// MARK: - AudioControlView (compact)
// One row: icon + Output menu (the current output name), right-side mute
// toggle, slider + percent below. ~90pt total. No nested glass card; sections
// are separated by Divider + spacing in the parent.

struct AudioControlView: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: model.audio.muted ? "speaker.slash" : "speaker.wave.2")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                deviceMenu
                Spacer(minLength: 4)
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.audio.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 24, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(!canMute)
                .accessibilityLabel(model.audio.muted ? l("取消靜音") : l("靜音"))
                .help(model.audio.muted ? l("取消靜音") : l("靜音"))
            }
            volumeRow
            if let error = model.audioWriteError {
                Text(error)
                    .font(.system(size: 11)).foregroundStyle(.red)
                    .accessibilityLabel(l("音訊錯誤：%@", error))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l("音訊控制"))
    }
    private var canMute: Bool { model.audio.device?.hasWritableMute ?? false }
    private var canSetVolume: Bool { model.audio.device?.hasWritableVolume ?? false }

    @ViewBuilder private var deviceMenu: some View {
        if model.audio.device != nil, model.audio.available, !model.audio.outputs.isEmpty {
            Picker(l("輸出裝置"), selection: Binding(get: {
                model.audio.device?.id ?? model.audio.outputs.first?.id ?? 0
            }, set: { model.selectOutput($0) })) {
                ForEach(model.audio.outputs, id: \.id) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel(l("選擇輸出裝置"))
        } else if model.audio.available {
            Text(model.audio.device?.name ?? l("音訊輸出"))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
        } else {
            Text(l("無輸出裝置"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var volumeRow: some View {
        if let volume = model.audio.masterVolume, canSetVolume {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { volume }, set: { model.setVolume($0) }), in: 0...1)
                    .controlSize(.small)
                    .accessibilityLabel(l("輸出音量"))
                    .accessibilityValue("\(Int((volume * 100).rounded()))%")
                Text(StatusSnapshot.percent(volume) ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        } else if model.audio.available {
            HStack(spacing: 6) {
                Image(systemName: "lock").font(.system(size: 11)).foregroundStyle(.secondary)
                Text(l("由裝置控制")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .accessibilityLabel(l("音量由裝置控制，無法從這裡調整"))
        }
    }
}
