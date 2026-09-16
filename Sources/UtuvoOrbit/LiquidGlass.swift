import AppKit
import SwiftUI

// MARK: - LiquidGlass view helpers
//
// Wraps the macOS 26+ Liquid Glass APIs behind availability checks so the
// executable keeps building on macOS 14/15 with a regular material fallback.
// Containers and buttons only: the popover's own surface is the real native
// glass and nothing here paints over it.

@available(macOS 26.0, *)
enum LiquidGlassStyle {
    static let cornerRadius: CGFloat = 18
}

struct GlassContainer<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer { content }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

struct GlassPanel<Content: View>: View {
    var cornerRadius: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            content
                .background {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

/// Apply `.glass` to a button when supported, else fall back to bordered.
struct GlassButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    func glassButton() -> some View { modifier(GlassButtonStyle()) }
}
