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
