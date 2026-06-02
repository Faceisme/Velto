import AppKit
import SwiftUI

// MARK: - Colors (v2 Design Tokens)

extension Color {
    // Surface
    static let mgBg       = Color(nsColor: .windowBackgroundColor)
    static let mgSidebar  = Color(nsColor: .controlBackgroundColor)
    static let mgCard     = Color(nsColor: .controlBackgroundColor)
    static let mgCardAlt  = Color(nsColor: .textBackgroundColor)

    // Text
    static let mgText1 = Color(nsColor: .labelColor)
    static let mgText2 = Color(nsColor: .secondaryLabelColor)
    static let mgText3 = Color(nsColor: .tertiaryLabelColor)

    // Accent
    static let mgAccent     = Color(nsColor: .controlAccentColor)
    static let mgAccentEnd  = Color(nsColor: .controlAccentColor)
    static let mgAccentDeep = Color(nsColor: .controlAccentColor)
    static let mgAccentSoft = Color(nsColor: .controlAccentColor).opacity(0.12)
    static let mgGreen      = Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
    static let mgDanger     = Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255)

    // Borders / hairlines
    static let mgHair       = Color(nsColor: .separatorColor).opacity(0.45)
    static let mgHairStrong = Color(nsColor: .separatorColor).opacity(0.70)

    // Kept for existing call sites; visually resolves to the current macOS accent.
    static var mgPrimaryButtonGradient: LinearGradient {
        LinearGradient(colors: [.mgAccent, .mgAccent],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Radius (concentric)

enum MGRadius {
    static let window: CGFloat   = 12
    static let cardLg: CGFloat   = 12
    static let card: CGFloat     = 10
    static let cardSm: CGFloat   = 8
    static let control: CGFloat  = 8
    static let controlSm: CGFloat = 7
    static let kbd: CGFloat      = 5    // 小键帽
    static let kbdMd: CGFloat    = 6    // 中键帽
    static let kbdLg: CGFloat    = 7    // 大键帽
    static let pill: CGFloat     = 999
}

// MARK: - Typography (system font + PingFang SC fallback)

extension Font {
    static let mgPageTitle = Font.system(size: 24, weight: .semibold)
    static let mgTitleM    = Font.system(size: 17, weight: .semibold)
    static let mgLabelStrong = Font.system(size: 13, weight: .semibold) // 13/600
    static let mgBody      = Font.system(size: 13, weight: .regular)    // 13/400
    static let mgBodyMedium = Font.system(size: 13, weight: .medium)    // 13/500
    static let mgButtonSm  = Font.system(size: 12, weight: .medium)     // 12/500
    static let mgSubLabel  = Font.system(size: 11.5, weight: .semibold) // 11.5/600
    static let mgMeta      = Font.system(size: 11.5, weight: .regular)  // 11.5/400
    static let mgTag       = Font.system(size: 11, weight: .bold)       // 11/700 大写英文 tag
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
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.mgHair, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.035), radius: 3, x: 0, y: 1)
    }
}

extension View {
    /// White card with 0.5px hairline border + soft drop shadow (matches v2 GroupCard).
    func mgCard(radius: CGFloat = MGRadius.cardLg, fill: Color = .mgCard) -> some View {
        modifier(MGCardBackground(radius: radius, fill: fill))
    }
}
