import SwiftUI

/// 浏览器规则新增/编辑弹窗。应用规则走系统选 App 面板,不需要本编辑器。
struct BrowserRuleEditor: View {
  @Environment(\.dismiss) private var dismiss
  let sources: [InputSourceInfo]
  let initial: InputSourceBrowserRule
  let onSave: (InputSourceBrowserRule) -> Void

  @State private var draft: InputSourceBrowserRule

  init(
    sources: [InputSourceInfo],
    initial: InputSourceBrowserRule,
    onSave: @escaping (InputSourceBrowserRule) -> Void
  ) {
    self.sources = sources
    self.initial = initial
    self.onSave = onSave
    _draft = State(initialValue: initial)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("浏览器规则").font(.mgPageTitle).foregroundStyle(Color.mgText1)

      MGMenuPicker(
        selection: $draft.type,
        options: InputSourceBrowserRuleType.allCases.map { MGMenuOption($0, $0.displayName) },
        minWidth: 180
      )
      TextField("匹配值(如 github.com)", text: $draft.value)
      TextField("示例 URL(如 https://github.com/x)", text: $draft.sample)

      MGMenuPicker(
        selection: Binding(
          get: { draft.inputSourceID ?? "" },
          set: { draft.inputSourceID = $0.isEmpty ? nil : $0 }
        ),
        options: [MGMenuOption("", "不指定")] + sources.map { MGMenuOption($0.id, $0.localizedName) },
        minWidth: 180
      )

      // 正则类型先校验 pattern 合法性,无效时单独提示(区别于"不命中")。
      if draft.type == .urlRegex, !draft.value.isEmpty,
         (try? NSRegularExpression(pattern: draft.value)) == nil {
        Text("⚠︎ 正则表达式无效")
          .font(.mgMeta)
          .foregroundStyle(Color.red)
      } else if let url = URL(string: draft.sample), !draft.sample.isEmpty {
        // 示例 URL 即时显示是否命中。
        let hit = InputSourceSwitchController.matches(rule: draft, url: url)
        Text(hit ? "✓ 示例 URL 命中" : "✗ 示例 URL 不命中")
          .font(.mgMeta)
          .foregroundStyle(hit ? Color.mgAccent : Color.mgText3)
      }

      HStack {
        Spacer()
        Button("取消") { dismiss() }
        Button("保存") { onSave(draft); dismiss() }
          .keyboardShortcut(.defaultAction)
          .disabled(draft.value.isEmpty)
      }
    }
    .padding(24)
    .frame(width: 420)
  }
}
