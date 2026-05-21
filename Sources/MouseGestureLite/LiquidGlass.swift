import SwiftUI

// MARK: - Liquid Glass (macOS 26 Tahoe native API)

extension View {
    /// Native Liquid Glass surface with the system lensing effect.
    /// Pass `interactive: true` for elements that respond to pointer (buttons, list rows).
    func liquidGlass(
        in shape: some Shape = RoundedRectangle(cornerRadius: MGRadius.card, style: .continuous),
        interactive: Bool = false
    ) -> some View {
        let glass: Glass = interactive ? .regular.interactive() : .regular
        return glassEffect(glass, in: shape)
    }

    /// Convenience: rounded-rectangle Liquid Glass surface.
    func liquidGlassCard(radius: CGFloat = MGRadius.card, interactive: Bool = false) -> some View {
        liquidGlass(in: RoundedRectangle(cornerRadius: radius, style: .continuous),
                    interactive: interactive)
    }

    /// Backward-compatible alias used throughout the design system.
    /// Routes to native Liquid Glass on macOS 26+.
    func glassSurface(_ weight: GlassWeight = .thin, radius: CGFloat = MGRadius.card) -> some View {
        liquidGlassCard(radius: radius)
    }

    /// No-op now (kept for API stability) — the native effect handles the edge highlight.
    func glassEdge(radius: CGFloat = MGRadius.card, strength: Double = 1.0) -> some View {
        self
    }
}

// MARK: - Glass weight (kept for API compatibility)

enum GlassWeight {
    case heavy, regular, thin, ultraThin
}

// MARK: - Primary button style (gradient + accent glow)

struct MGPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mgCaption)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                LinearGradient(
                    colors: [Color.mgAccent.opacity(0.93), .mgAccent],
                    startPoint: .top, endPoint: .bottom
                ),
                in: RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MGRadius.control, style: .continuous)
                    .stroke(Color.white.opacity(0.35), lineWidth: 1)
                    .blendMode(.plusLighter)
                    .mask(
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                    )
            )
            .shadow(color: Color.mgAccent.opacity(0.34), radius: 8, x: 0, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: - Ghost button style (native Liquid Glass)

struct MGGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mgCaption)
            .foregroundStyle(Color.mgText1)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .liquidGlassCard(radius: MGRadius.control, interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == MGPrimaryButtonStyle {
    static var mgPrimary: MGPrimaryButtonStyle { .init() }
}

extension ButtonStyle where Self == MGGhostButtonStyle {
    static var mgGhost: MGGhostButtonStyle { .init() }
}
