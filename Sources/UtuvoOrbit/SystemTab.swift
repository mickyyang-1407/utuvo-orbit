import SwiftUI
import OrbitCore

// MARK: - SystemTab (compact)
// Two horizontal progress bars + percentage labels. No rings, no big cards.
// ~60pt visible content + small battery row on laptops.

struct SystemTab: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                cpuRow
                memoryRow
                if model.systemMetrics.machine == .laptop { batteryRow }
                machineRow
                Divider()
                peripheralsSection
            }
            .padding(.vertical, 4)
        }
    }

    /// SystemMonitor is the sole producer (throttled ~30s + forced on
    /// wake) — this view only ever reads `model.peripherals`, never polls.
    /// An empty list is a truthful "none found/none readable" state, shown
    /// as text rather than silently rendering nothing.
    private var peripheralsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(l("周邊裝置電量")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if model.peripherals.isEmpty {
                Text(l("尚未取得周邊裝置電量")).font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(model.peripherals) { peripheral in
                    peripheralRow(peripheral)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func peripheralRow(_ peripheral: Peripheral) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName(for: peripheral.kind))
                .font(.system(size: 12))
                .frame(width: 20, height: 20)
            // `.lineLimit(1)` ellipsizes a long name visually; the
            // accessibility label carries the FULL name regardless.
            Text(peripheral.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(peripheral.name)
            Spacer(minLength: 8)
            // Only an EXPLICIT `.charging` shows the bolt — `.unknown` (the
            // only state the live backend ever reports today) stays
            // unknown, never implied from a battery reading alone.
            if peripheral.charging == .charging {
                // ORBIT-004 C: "make human wording 充電中 visible inline or
                // help/AX so it doesn't rely solely on ambiguous icon" — AX
                // label already covers VoiceOver; `.help` adds a real
                // mouse-hover tooltip for sighted users who'd otherwise
                // have only the bolt glyph itself to go on.
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                    .accessibilityLabel(l("充電中"))
                    .help(l("充電中"))
            }
            if let fraction = peripheral.fraction {
                Text(StatusSnapshot.percent(fraction) ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .fixedSize()
            } else {
                Text(l("電量未知")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func symbolName(for kind: PeripheralKind) -> String {
        switch kind {
        case .airpods: return "airpodspro"
        case .keyboard: return "keyboard"
        case .trackpad: return "rectangle.and.hand.point.up.left.filled"
        case .mouse: return "magicmouse"
        case .iphone: return "iphone"
        case .other: return "puzzlepiece"
        }
    }

    private var cpuRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l("CPU 使用率")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(StatusSnapshot.percent(model.systemMetrics.cpuUsage) ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            progressBar(fraction: model.systemMetrics.cpuUsage)
            // Newest 20 samples, not the oldest 20 of a possibly-30-long
            // history — `suffix` also never pads a short history with
            // fabricated zeros, it just shows however many real samples
            // exist so far. Purely decorative (the Text above already
            // states the current value): hidden from AX so VoiceOver
            // doesn't try to describe a sparkline built out of repurposed
            // `NetworkSample` values as if it were network data.
            TrendChart(samples: model.systemMetrics.cpuHistory.suffix(20).map { NetworkSample(
                downloadBytesPerSecond: $0,
                uploadBytesPerSecond: 0, localIPv4: nil, interfaceName: nil, reachable: true) })
                .frame(height: 36)
                .accessibilityHidden(true)
        }
        // `.combine` already surfaces the real CPU% Text content — a static
        // override here previously replaced it with a fixed generic label.
        .accessibilityElement(children: .combine)
    }

    private var memoryRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(l("記憶體")).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(StatusSnapshot.percent(MemoryMath.fraction(used: model.systemMetrics.usedBytes, total: model.systemMetrics.totalBytes)) ?? "—")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            progressBar(fraction: MemoryMath.fraction(used: model.systemMetrics.usedBytes, total: model.systemMetrics.totalBytes))
            Text("\(MemoryMath.label(bytes: model.systemMetrics.usedBytes)) / \(MemoryMath.label(bytes: model.systemMetrics.totalBytes))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        // Sets expectations correctly: this is active+wired+compressed
        // pages, an estimate — not macOS "memory pressure" and not the
        // exact figure Activity Monitor's "Memory Used" reports.
        .help(l("使用量估算：使用中＋固定＋壓縮頁面，非記憶體壓力指標，數字與「活動監視器」的「已用記憶體」未必一致"))
    }

    private var batteryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemMetrics.battery?.charging == true ? "battery.100.bolt" : "battery.100")
                .foregroundStyle(model.systemMetrics.battery?.charging == true ? Color.green : Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(StatusSnapshot.percent(model.systemMetrics.battery?.fraction) ?? "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(batteryStatus)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var machineRow: some View {
        HStack(spacing: 8) {
            Image(systemName: model.systemMetrics.machine == .laptop ? "laptopcomputer" : "desktopcomputer")
            Text(model.systemMetrics.model.isEmpty ? l("未知 Mac") : model.systemMetrics.model)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private func progressBar(fraction: Double?) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.22))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(fraction ?? 0))
            }
        }
        .frame(height: 6)
    }

    private var batteryStatus: String {
        guard let battery = model.systemMetrics.battery else { return "—" }
        if battery.charging { return l("充電中") }
        if battery.onAC { return l("已接電源 · 未充電") }
        return l("使用電池")
    }
}
