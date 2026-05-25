import SwiftUI

// MARK: - Colors (v2 Design Tokens)

extension Color {
    // Surface
    static let mgBg       = Color(red: 0xF5/255, green: 0xF5/255, blue: 0xF7/255) // 主背景
    static let mgSidebar  = Color(red: 0xEC/255, green: 0xEC/255, blue: 0xEE/255) // 侧栏
    static let mgCard     = Color.white                                            // 卡片
    static let mgCardAlt  = Color(red: 0xF8/255, green: 0xF9/255, blue: 0xFB/255) // 卡片内嵌区

    // Text
    static let mgText1 = Color(red: 0x1D/255, green: 0x1D/255, blue: 0x1F/255)
    static let mgText2 = Color(red: 0x6B/255, green: 0x72/255, blue: 0x80/255)
    static let mgText3 = Color(red: 0xA1/255, green: 0xA1/255, blue: 0xA6/255)

    // Accent
    static let mgAccent     = Color(red: 0x0A/255, green: 0x84/255, blue: 0xFF/255)
    static let mgAccentEnd  = Color(red: 0x5E/255, green: 0x5C/255, blue: 0xE6/255)
    static let mgAccentDeep = Color(red: 0x00/255, green: 0x6F/255, blue: 0xE0/255) // 蓝色按钮渐变末端
    static let mgAccentSoft = Color(red: 0xE6/255, green: 0xF0/255, blue: 0xFF/255)
    static let mgGreen      = Color(red: 0x34/255, green: 0xC7/255, blue: 0x59/255)
    static let mgDanger     = Color(red: 0xFF/255, green: 0x3B/255, blue: 0x30/255)

    // Borders / hairlines (rgba(15,30,60,*))
    static let mgHair       = Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.06)
    static let mgHairStrong = Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.10)

    // Aliases kept for backward compatibility with files we didn't rewrite
    static let mgBorder       = mgHair
    static let mgBorderStrong = mgHairStrong

    // Gradient helpers
    static var mgAccentGradient: LinearGradient {
        LinearGradient(colors: [.mgAccent, .mgAccentEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var mgPrimaryButtonGradient: LinearGradient {
        LinearGradient(colors: [.mgAccent, .mgAccentDeep],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Spacing (4 / 6 / 8 / 10 / 12 / 14 / 16 / 20 / 22 / 28)

enum MGSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 16
    static let xxxl: CGFloat = 22
}

// MARK: - Radius (concentric)

enum MGRadius {
    static let window: CGFloat   = 12
    static let cardLg: CGFloat   = 14   // 大卡片
    static let card: CGFloat     = 12   // 中卡片
    static let cardSm: CGFloat   = 10   // 小卡片 / 嵌入画布
    static let control: CGFloat  = 9    // 控件
    static let controlSm: CGFloat = 7   // 段控件 / 小按钮
    static let kbd: CGFloat      = 5    // 小键帽
    static let kbdMd: CGFloat    = 6    // 中键帽
    static let kbdLg: CGFloat    = 7    // 大键帽
    static let pill: CGFloat     = 999
}

// MARK: - Typography (system font + PingFang SC fallback)

extension Font {
    static let mgPageTitle = Font.system(size: 26, weight: .bold)      // 26/700/-0.4
    static let mgTitleM    = Font.system(size: 17, weight: .bold)      // 17/700/-0.2
    static let mgLabelStrong = Font.system(size: 13, weight: .semibold) // 13/600
    static let mgBody      = Font.system(size: 13, weight: .regular)    // 13/400
    static let mgBodyMedium = Font.system(size: 13, weight: .medium)    // 13/500
    static let mgButtonSm  = Font.system(size: 12, weight: .medium)     // 12/500
    static let mgSubLabel  = Font.system(size: 11.5, weight: .semibold) // 11.5/600
    static let mgMeta      = Font.system(size: 11.5, weight: .regular)  // 11.5/400
    static let mgTag       = Font.system(size: 11, weight: .bold)       // 11/700 大写英文 tag

    // Legacy aliases (used by AppDelegate menu / status etc.)
    static let mgTitleL      = mgPageTitle
    static let mgBodyStrong  = mgLabelStrong
    static let mgCaption     = mgButtonSm
    static let mgLabelTiny   = mgSubLabel
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
                // 0.5px hairline
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.mgHair, lineWidth: 0.5)
            )
            // 0 1px 2px rgba(15,30,60,0.03)
            .shadow(color: Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.03),
                    radius: 1, x: 0, y: 1)
    }
}

extension View {
    /// White card with 0.5px hairline border + soft drop shadow (matches v2 GroupCard).
    func mgCard(radius: CGFloat = MGRadius.cardLg, fill: Color = .mgCard) -> some View {
        modifier(MGCardBackground(radius: radius, fill: fill))
    }
}
