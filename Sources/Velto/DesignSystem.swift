import AppKit
import SwiftUI

// MARK: - Colors (system surfaces + native Liquid Glass)

extension Color {
    // Surface
    static let mgBg       = Color(nsColor: .windowBackgroundColor)
    static let mgSidebar  = Color(nsColor: .controlBackgroundColor)
    static let mgCard     = Color(nsColor: .controlBackgroundColor)
    static let mgCardAlt  = Color(nsColor: .textBackgroundColor)
    static let mgGlassWeak = Color(nsColor: .controlBackgroundColor)
    static let mgGlassControl = Color(nsColor: .controlBackgroundColor)

    // Text
    static let mgText1 = Color(nsColor: .labelColor)
    static let mgText2 = Color(nsColor: .secondaryLabelColor)
    static let mgText3 = Color(nsColor: .tertiaryLabelColor)

    // Accent
    static let mgAccent     = Color(nsColor: .controlAccentColor)
    static let mgAccentEnd  = Color(nsColor: .controlAccentColor)
    static let mgAccentDeep = Color(nsColor: .controlAccentColor)
    static let mgAccentSoft = Color(nsColor: .controlBackgroundColor)
    static let mgGreen      = Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
    static let mgDanger     = Color(nsColor: .systemRed)

    // Borders / hairlines
    static let mgHair       = Color(nsColor: .separatorColor).opacity(0.45)
    static let mgHairStrong = Color(nsColor: .separatorColor).opacity(0.70)
    static let mgShadow     = Color.black

}

// MARK: - Radius (concentric)

enum MGRadius {
    static let window: CGFloat   = 20
    static let cardLg: CGFloat   = 16
    static let card: CGFloat     = 16
    static let cardSm: CGFloat   = 14
    static let control: CGFloat  = 11
    static let controlSm: CGFloat = 10
    static let kbd: CGFloat      = 7
    static let kbdMd: CGFloat    = 8
    static let kbdLg: CGFloat    = 9
    static let pill: CGFloat     = 999
}

// MARK: - Typography (system font + PingFang SC fallback)

extension Font {
    static let mgPageTitle = Font.system(size: 30, weight: .bold)
    static let mgTitleM    = Font.system(size: 21, weight: .bold)
    static let mgLabelStrong = Font.system(size: 14.5, weight: .semibold)
    static let mgBody      = Font.system(size: 14, weight: .regular)
    static let mgBodyMedium = Font.system(size: 13.5, weight: .semibold)
    static let mgButtonSm  = Font.system(size: 13, weight: .semibold)
    static let mgSubLabel  = Font.system(size: 12, weight: .semibold)
    static let mgMeta      = Font.system(size: 12, weight: .regular)
    static let mgTag       = Font.system(size: 11.5, weight: .bold)
}

// MARK: - Wallpaper / glass surfaces

struct VeltoWallpaper: View {
    var body: some View {
        Color.mgBg.ignoresSafeArea()
    }
}

struct VeltoGlassSurface: ViewModifier {
    var radius: CGFloat = MGRadius.cardLg
    var fill: Color = .mgCard
    var shadow: Bool = true

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .glassEffect(.regular.tint(fill.opacity(0.08)), in: shape)
                .shadow(color: shadow ? Color.mgShadow.opacity(0.08) : .clear, radius: 10, x: 0, y: 4)
        } else {
            content
                .background(fill, in: shape)
                .shadow(color: shadow ? Color.mgShadow.opacity(0.04) : .clear, radius: 3, x: 0, y: 1)
        }
    }
}

struct VeltoGlassWindow: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: MGRadius.window, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(Color.mgBg, in: shape)
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
        } else {
            content
                .background(Color.mgBg, in: shape)
                .clipShape(shape)
        }
    }
}

// MARK: - Section / group label

struct MGSectionLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.mgSubLabel)
            .tracking(0.3)
            .foregroundStyle(Color.mgText3)
            .padding(.leading, 4)
            .padding(.bottom, 8)
    }
}

// MARK: - Card shadow modifier (the 0.5px hairline + soft drop)

struct MGCardBackground: ViewModifier {
    var radius: CGFloat = MGRadius.cardLg
    var fill: Color = .mgCard

    func body(content: Content) -> some View {
        content
            .veltoGlassSurface(radius: radius, fill: fill)
    }
}

extension View {
    @ViewBuilder
    func veltoNativeGlass<S: Shape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
        }
    }

    func veltoGlassSurface(radius: CGFloat = MGRadius.cardLg, fill: Color = .mgCard, shadow: Bool = true) -> some View {
        modifier(VeltoGlassSurface(radius: radius, fill: fill, shadow: shadow))
    }

    func veltoGlassPanel(radius: CGFloat = MGRadius.cardSm, shadow: Bool = false) -> some View {
        modifier(VeltoGlassSurface(radius: radius, fill: .mgGlassWeak, shadow: shadow))
    }

    func veltoGlassWindow() -> some View {
        modifier(VeltoGlassWindow())
    }

    /// Existing card API, now backed by the liquid-glass surface.
    func mgCard(radius: CGFloat = MGRadius.cardLg, fill: Color = .mgCard) -> some View {
        modifier(MGCardBackground(radius: radius, fill: fill))
    }
}
