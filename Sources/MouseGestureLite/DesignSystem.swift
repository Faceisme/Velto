import SwiftUI

// MARK: - Colors

extension Color {
    static let mgAccent = Color(red: 0/255, green: 122/255, blue: 255/255)
    static let mgAccentEnd = Color(red: 94/255, green: 92/255, blue: 230/255)

    static var mgAccentGradient: LinearGradient {
        LinearGradient(colors: [.mgAccent, .mgAccentEnd],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let mgText1 = Color(NSColor.labelColor)
    static let mgText2 = Color(NSColor.secondaryLabelColor)
    static let mgText3 = Color(NSColor.tertiaryLabelColor)

    static let mgBorder = Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.06)
    static let mgBorderStrong = Color(red: 15/255, green: 30/255, blue: 60/255).opacity(0.10)
}

// MARK: - Spacing

enum MGSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 18
    static let xxl: CGFloat = 24
}

// MARK: - Radius (concentric)

enum MGRadius {
    static let window: CGFloat = 18
    static let card: CGFloat = 14
    static let control: CGFloat = 9
    static let pill: CGFloat = 999
}

// MARK: - Typography

extension Font {
    static let mgTitleL = Font.system(size: 22, weight: .bold)
    static let mgTitleM = Font.system(size: 17, weight: .bold)
    static let mgBody = Font.system(size: 13)
    static let mgBodyStrong = Font.system(size: 13, weight: .semibold)
    static let mgCaption = Font.system(size: 12, weight: .medium)
    static let mgLabelTiny = Font.system(size: 11, weight: .semibold)
    static let mgMeta = Font.system(size: 11)
}

// MARK: - Section label

struct MGSectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.mgLabelTiny)
            .tracking(0.6)
            .foregroundStyle(.tertiary)
    }
}
