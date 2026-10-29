import SwiftUI

enum OrbitPalette {
    static let accent = Color(red: 0.10, green: 0.48, blue: 0.50)
}

enum OrbitVersion {
    static var label: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.11.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "16"
        return "\(version) (\(build))"
    }
}

struct OrbitBrandMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(OrbitPalette.accent.opacity(0.12))
            Circle().stroke(OrbitPalette.accent.opacity(0.5), lineWidth: size * 0.045).padding(size * 0.2)
            Ellipse().stroke(OrbitPalette.accent, lineWidth: size * 0.045)
                .frame(width: size * 0.8, height: size * 0.34).rotationEffect(.degrees(-40))
            Circle().fill(OrbitPalette.accent).frame(width: size * 0.16, height: size * 0.16)
        }
        .frame(width: size, height: size).accessibilityHidden(true)
    }
}
