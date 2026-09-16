import SwiftUI
import OrbitCore

// MARK: - OverviewTab (compact)
// ~470-520pt target height. No nested GlassPanel; sections separated by a
// thin Divider and 8-12pt spacing. Audio + awake live here so the user can
// keep awake while tweaking volume.

struct OverviewTab: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var preferences: OrbitPreferencesModel

    var body: some View {
        VStack(spacing: 10) {
            // Compact, IN-PANEL surface for the same degraded reasons the
            // menubar tooltip/AX already carry — previously a degraded
            // state (offline/low battery/no audio output) was only
            // discoverable by hovering the menubar icon or reading its AX
            // label; the panel itself said nothing about WHY it looked
            // different.
            let reasons = AttentionAnalysis.reasons(snapshot: monitor.snapshot)
            if !reasons.isEmpty { AttentionRow(reasons: reasons) }
            AudioControlView(model: model)
            ThinDivider()
            AwakeControlView(model: model)
            ThinDivider()
            SystemSummaryRow(model: model)
            ThinDivider()
            NetworkSummaryRow(model: model)
        }
    }
}

private struct AttentionRow: View {
    @Environment(\.orbitStrings) private var l
    let reasons: [AttentionReason]
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Text(reasons.map { l($0.localizedTitle) }.joined(separator: " · "))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.red)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ThinDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.18))
            .frame(height: 0.5)
            .padding(.horizontal, 2)
    }
}

private struct SystemSummaryRow: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: model.systemMetrics.machine == .laptop ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.systemMetrics.cpuUsage.map { "CPU \($0 * 100, format: .number.precision(.fractionLength(0)))%" } ?? "CPU —")
                        .font(.system(size: 12, weight: .medium))
                    Text(memoryLabel)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.systemMetrics.model.isEmpty ? "Mac" : model.systemMetrics.model)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if model.systemMetrics.machine == .laptop { batteryRow }
        }
        // `.combine` already builds an accessible label from the CPU/memory/
        // model Text children's own current values — a static
        // `.accessibilityLabel` here previously replaced that with a fixed
        // generic string, hiding the actual live numbers from VoiceOver.
        .accessibilityElement(children: .combine)
    }
    private var memoryLabel: String {
        let used = MemoryMath.label(bytes: model.systemMetrics.usedBytes)
        let total = MemoryMath.label(bytes: model.systemMetrics.totalBytes)
        return l("記憶體 %@ / %@", used, total)
    }
    private var batteryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemMetrics.battery?.charging == true ? "battery.100.bolt" : "battery.100")
                .font(.system(size: 12))
                .foregroundStyle(model.systemMetrics.battery?.charging == true ? Color.green : Color.accentColor)
                .frame(width: 28)
            Text(StatusSnapshot.percent(model.systemMetrics.battery?.fraction) ?? l("電量未知"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text(batteryStatus)
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
        }
    }
    private var batteryStatus: String {
        guard let battery = model.systemMetrics.battery else { return "—" }
        if battery.charging { return l("充電中") }
        if battery.onAC { return l("已接電源 · 未充電") }
        return l("使用電池")
    }
}

private struct NetworkSummaryRow: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: NetworkGlyph.symbolName(for: model.network.interfaceType, reachable: model.network.reachable))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(l(NetworkGlyph.statusLabel(for: model.network.interfaceType, reachable: model.network.reachable)))
                    .font(.system(size: 11, weight: .medium))
                Text(model.network.interfaceName ?? l("沒有可用路徑"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Text(NetworkMath.format(bytesPerSecond: model.network.downloadBytesPerSecond))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
        // Same fix as SystemSummaryRow above — let `.combine` surface the
        // real status/interface/throughput text instead of a static label.
        .accessibilityElement(children: .combine)
    }
}
