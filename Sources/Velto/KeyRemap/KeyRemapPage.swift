import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyRemapPage: View {
  private let store = KeyRemapStore.shared

  @State private var showFileImporter = false
  @State private var importMessage: String = ""
  @State private var showImportResult = false

  var body: some View {
    let manual = store.rules.first(where: { $0.isManual })?.manipulators ?? []
    let imported = store.rules.filter { !$0.isManual }
    SettingsPage {
      PageHeader(
        page: .keyRemap,
        subtitle: "手动添加简单映射,或导入 Karabiner 社区规则文件。",
        isOn: Binding(get: { store.masterEnabled }, set: { store.setMasterEnabled($0) })
      )
      .help("关闭后所有映射规则（手动 + 导入）暂停生效。")

      SettingsSection("简单映射") {
        ForEach(manual) { m in
          ManualRemapRow(manipulator: m) { store.deleteManualManipulator(id: m.id) }
        }
        AddRemapRow { from, to in
          store.addManualManipulator(KeyRemapManipulator(from: from, to: [to]))
        }
      }

      SettingsSection("导入的规则") {
        if imported.isEmpty {
          EmptyRow("还没有导入的规则。从 ke-complex-modifications.pqrs.org 下载 JSON 文件后点「导入…」。")
        } else {
          ForEach(imported) { ImportedRuleRow(rule: $0) }
        }
      } accessory: {
        Button("导入…") { showFileImporter = true }
          .buttonStyle(.bordered)
      }

      DebugSection(
        isOn: Binding(get: { store.debugLoggingEnabled }, set: { store.setDebugLoggingEnabled($0) }),
        logURL: KeyRemapDebugLog.fileURL,
        help: "排查映射不生效时打开,详尽记录规则编译 / 按键事件 / 合成动作,只写 key-remap.log。"
      )
    }
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: [.json]
    ) { result in
      handleImport(result: result)
    }
    .alert("导入结果", isPresented: $showImportResult) {
      Button("好") {}
    } message: {
      Text(importMessage)
    }
  }

  // MARK: - 导入逻辑

  private func handleImport(result: Result<URL, Error>) {
    guard case .success(let url) = result else { return }
    guard url.startAccessingSecurityScopedResource() else { return }
    defer { url.stopAccessingSecurityScopedResource() }

    guard let data = try? Data(contentsOf: url) else {
      importMessage = "无法读取文件。"
      showImportResult = true
      return
    }
    let parsed = KarabinerJSONParser.parse(data: data)
    for rule in parsed.rules { store.addRule(rule) }

    if parsed.rules.isEmpty {
      importMessage = "未找到支持的规则。跳过了 \(parsed.skippedCount) 条（包含不支持的功能）。"
    } else {
      let m = parsed.rules.reduce(0) { $0 + $1.manipulators.count }
      importMessage = "导入 \(m) 条映射" +
        (parsed.skippedCount > 0 ? "，跳过了 \(parsed.skippedCount) 条不支持的规则。" : "。")
    }
    showImportResult = true
  }
}

// MARK: - 添加行(选择器 + 添加,卡内底部)

private struct AddRemapRow: View {
  let onAdd: (KeyRemapFrom, KeyRemapTo) -> Void

  @State private var fromKeyCode: UInt16 = KeyCodeMap.modifierKeys.first?.keyCode ?? 57
  @State private var toKeyCode: UInt16 = KeyCodeMap.functionKeys.first?.keyCode ?? 80

  private var fromEntry: KeyCodeEntry? { KeyCodeMap.byKeyCode[fromKeyCode] }
  private var toEntry: KeyCodeEntry? {
    toKeyCode == 0xFFFF ? KeyCodeMap.vkNone : KeyCodeMap.byKeyCode[toKeyCode]
  }

  var body: some View {
    HStack(spacing: 8) {
      Picker("", selection: $fromKeyCode) {
        ForEach(KeyCodeMap.pickerSections, id: \.title) { section in
          Section(section.title) {
            ForEach(section.entries, id: \.keyCode) { e in
              Text(e.displayLabel).tag(e.keyCode)
            }
          }
        }
      }
      .labelsHidden()
      .frame(minWidth: 150)

      Image(systemName: "arrow.right")
        .foregroundStyle(Color.mgText3)

      Picker("", selection: $toKeyCode) {
        ForEach(KeyCodeMap.pickerSectionsForTo, id: \.title) { section in
          Section(section.title) {
            ForEach(section.entries, id: \.keyCode) { e in
              Text(e.displayLabel).tag(e.keyCode)
            }
          }
        }
      }
      .labelsHidden()
      .frame(minWidth: 150)

      Spacer()

      Button {
        guard let fe = fromEntry, let te = toEntry else { return }
        let from = KeyRemapFrom(keyCode: fe.keyCode, isModifier: fe.isModifier, mandatory: [])
        let to = KeyRemapTo(keyCode: te.keyCode, isModifier: te.isModifier, additionalModifierCodes: [])
        onAdd(from, to)
      } label: {
        Label("添加", systemImage: "plus")
      }
      .buttonStyle(.bordered)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 44)
  }
}

// MARK: - 手动映射行(每行自带删除)

private struct ManualRemapRow: View {
  let manipulator: KeyRemapManipulator
  let onDelete: () -> Void

  var body: some View {
    let fromLabel = KeyCodeMap.byKeyCode[manipulator.from.keyCode]?.displayLabel ?? "#\(manipulator.from.keyCode)"
    let toLabel = manipulator.to.first.map {
      $0.keyCode == 0xFFFF ? "禁用" : (KeyCodeMap.byKeyCode[$0.keyCode]?.displayLabel ?? "#\($0.keyCode)")
    } ?? "—"

    // 左列宽度对齐添加行的选择器(minWidth 150),箭头上下成一列
    HStack(spacing: 8) {
      Kbd(keys: [fromLabel])
        .frame(minWidth: 150, alignment: .leading)
      Image(systemName: "arrow.right")
        .foregroundStyle(Color.mgText3)
      Kbd(keys: [toLabel])
      Spacer()
      DeleteIconButton(action: onDelete)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(minHeight: 44)
  }
}

// MARK: - 导入规则行(标题 + 开关,下列各条映射摘要)

private struct ImportedRuleRow: View {
  let rule: KeyRemapRule
  private let store = KeyRemapStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        Text(rule.title)
          .font(.mgBody)
          .foregroundStyle(Color.mgText1)
        Spacer(minLength: 8)
        DeleteIconButton { store.deleteRule(id: rule.id) }
        SettingsSwitch(isOn: Binding(get: { rule.enabled }, set: { store.setEnabled($0, ruleID: rule.id) }))
      }
      ForEach(rule.manipulators) { ManipulatorSummaryRow(manipulator: $0) }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

private struct ManipulatorSummaryRow: View {
  let manipulator: KeyRemapManipulator

  var body: some View {
    let fromLabel = KeyCodeMap.byKeyCode[manipulator.from.keyCode]?.displayLabel
      ?? "#\(manipulator.from.keyCode)"
    let mandatoryLabels = manipulator.from.mandatory.compactMap {
      KeyCodeMap.byKeyCode[$0]?.displayLabel
    }
    let toLabel = manipulator.to.first.map {
      $0.keyCode == 0xFFFF ? "禁用"
        : (KeyCodeMap.byKeyCode[$0.keyCode]?.displayLabel ?? "#\($0.keyCode)")
    } ?? "—"

    let fromDesc = mandatoryLabels.isEmpty
      ? fromLabel
      : mandatoryLabels.joined(separator: "+") + " + " + fromLabel

    HStack(spacing: 6) {
      Text(fromDesc)
        .font(.mgMeta.monospaced())
        .foregroundStyle(Color.mgText2)
      Image(systemName: "arrow.right")
        .font(.system(size: 10))
        .foregroundStyle(Color.mgText3)
      Text(toLabel)
        .font(.mgMeta.monospaced())
        .foregroundStyle(Color.mgText2)
    }
  }
}
