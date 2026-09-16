import SwiftUI
import OrbitCore

// MARK: - NetworkTab (compact)
// Compact rows, no big cards. ~50pt main + a trend bar.

struct NetworkTab: View {
    @Environment(\.orbitStrings) private var l
    @ObservedObject var model: OrbitPanelModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                routeRow
                ipRow
                trafficRow
            }
            .padding(.vertical, 4)
        }
    }

    private var routeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: NetworkGlyph.symbolName(for: model.network.interfaceType, reachable: model.network.reachable))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.network.interfaceName ?? l("沒有可用路徑"))
                    .font(.system(size: 12, weight: .medium))
                Text(l(NetworkGlyph.statusLabel(for: model.network.interfaceType, reachable: model.network.reachable)))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        // `.combine` surfaces the real interface name + status text; no
        // interactive children here so collapsing to one element is fine.
        .accessibilityElement(children: .combine)
    }

    private var ipRow: some View {
        HStack(spacing: 8) {
            Text(l("本機 IPv4"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(model.localIPv4 ?? "—")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .textSelection(.enabled)
            Spacer()
            Button {
                if let ip = model.localIPv4 {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ip, forType: .string)
                }
            } label: {
                Label(l("複製"), systemImage: "doc.on.doc").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .disabled(model.localIPv4 == nil)
            .accessibilityLabel(l("複製本機 IPv4"))
        }
        // No `.accessibilityElement(children: .combine)` here on purpose:
        // `.combine` would swallow the copy Button into one merged label,
        // making it unreachable as its own VoiceOver stop. Default (contain)
        // behavior keeps the IP value text and the button separately
        // focusable, each with its own real, current content.
    }

    private var trafficRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                trafficStat(title: l("下載"), value: model.network.downloadBytesPerSecond, color: .accentColor)
                trafficStat(title: l("上傳"), value: model.network.uploadBytesPerSecond, color: .orange)
            }
            TrendChart(samples: model.networkHistory)
                .frame(height: 36)
                .accessibilityLabel(l("即時流量趨勢"))
        }
    }

    private func trafficStat(title: String, value: Double?, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(NetworkMath.format(bytesPerSecond: value))
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - NetworkGlyph
//
// Shared icon/label logic so Ethernet, Wi-Fi, other and offline/checking
// each get a distinct glyph and description — previously every state that
// wasn't "unreachable" rendered as the Wi-Fi icon, even on Ethernet.

enum NetworkGlyph {
    static func symbolName(for type: Connection, reachable: Bool) -> String {
        guard reachable else { return "wifi.slash" }
        switch type {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector"
        case .other: return "network"
        case .offline: return "wifi.slash"
        case .checking: return "ellipsis.circle"
        }
    }

    static func statusLabel(for type: Connection, reachable: Bool) -> String {
        guard reachable else {
            return type == .checking ? "正在確認網路狀態" : "目前沒有可用路徑"
        }
        switch type {
        case .wifi: return "Wi-Fi 連線中"
        case .ethernet: return "有線網路連線中"
        case .other: return "已連線（其他介面）"
        case .offline: return "目前沒有可用路徑"
        case .checking: return "正在確認網路狀態"
        }
    }
}