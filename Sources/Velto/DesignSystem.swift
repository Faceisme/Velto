import AppKit
import SwiftUI

// MARK: - 颜色
// 对齐原生 grouped Form:白底 + 浅灰分组卡片;卡片里的录制框、数字框再叠一层内嵌底。
// 玻璃只留在侧栏、保存栏、弹出面板,卡片和卡片里的东西一律实色。

extension Color {
  static let mgBg = Color(nsColor: .windowBackgroundColor)
  static let mgCard = Color(nsColor: .quaternarySystemFill)
  static let mgInset = Color(nsColor: .secondarySystemFill)
  /// 内嵌底上的凸起物(键帽、药丸):浅色纯白、深色 14% 白,比内嵌底亮一档
  static let mgKey = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white.withAlphaComponent(0.14) : .white
  })

  static let mgText1 = Color(nsColor: .labelColor)
  static let mgText2 = Color(nsColor: .secondaryLabelColor)
  static let mgText3 = Color(nsColor: .tertiaryLabelColor)

  static let mgAccent = Color(nsColor: .controlAccentColor)
  static let mgDanger = Color(nsColor: .systemRed)

  static let mgHair = Color(nsColor: .separatorColor).opacity(0.45)
}

// MARK: - 圆角

enum MGRadius {
  static let card: CGFloat = 16
  static let control: CGFloat = 10
  static let kbd: CGFloat = 8
}

// MARK: - 字号(只留整数)

extension Font {
  static let mgPageTitle = Font.system(size: 22, weight: .bold)
  static let mgTitleM = Font.system(size: 17, weight: .semibold)
  static let mgLabelStrong = Font.system(size: 14, weight: .semibold)
  static let mgBody = Font.system(size: 14)
  static let mgButtonSm = Font.system(size: 13, weight: .semibold)
  static let mgSubLabel = Font.system(size: 13, weight: .semibold)
  static let mgMeta = Font.system(size: 12)
  static let mgTag = Font.system(size: 11.5, weight: .bold) // 只剩手势详情的 GESTURE 标签在用,第 3 期删
}

// MARK: - 分组标题

struct MGSectionLabel: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.mgSubLabel)
      .foregroundStyle(Color.mgText2)
      .padding(.leading, 4)
      .padding(.bottom, 8)
  }
}

// MARK: - 卡片 / 内嵌底

extension View {
  func mgCard(radius: CGFloat = MGRadius.card) -> some View {
    background(Color.mgCard, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }

  func mgInset(radius: CGFloat = MGRadius.control) -> some View {
    background(Color.mgInset, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
  }
}
