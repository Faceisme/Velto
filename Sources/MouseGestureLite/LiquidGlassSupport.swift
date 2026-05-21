import SwiftUI

extension View {
    func liquidGlassPanel(cornerRadius: CGFloat = 22, interactive: Bool = false) -> some View {
        let glass = interactive ? Glass.regular.interactive() : Glass.regular
        return glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
