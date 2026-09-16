import SwiftUI
import OrbitCore

// MARK: - TrendChart
//
// Shared sparkline that renders an array of `NetworkSample` values. CPU usage
// is fed in via the downloadBytesPerSecond field so we don't need a parallel
// view type. All values are clamped to 0...max for stable visuals.

struct TrendChart: View {
    let samples: [NetworkSample]
    var body: some View {
        GeometryReader { geo in
            let values = samples.map { max($0.downloadBytesPerSecond ?? 0, $0.uploadBytesPerSecond ?? 0) }
            let maxValue = max(values.max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Capsule()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 4, height: CGFloat(value / maxValue) * geo.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
    }
}
