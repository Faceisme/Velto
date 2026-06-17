import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct KeyRemapPage: View {
  private let store = KeyRemapStore.shared

  @State private var showFileImporter = false
  @State private var importMessage: String = ""
  @State private var showImportResult = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        PageHeader(
          tag: "Key Remap",
          title: "按键映射",
          subtitle: "手动添加简单映射，或导入 Karabiner 社区规则文件。"
        )

        manualSection
        importedSection
      }
      .padding(.horizontal, 32)
      .padding(.top, 28)
      .padding(.bottom, 28)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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

  // MARK: - 简单映射区

  private var manualSection: some View {
    let manualManipulators = store.rules.first(where: { $0.isManual })?.manipulators ?? []
    return VStack(alignment: .leading, spacing: 10) {
      MGSectionLabel(text: "简单映射")
      GroupCard(radius: MGRadius.cardLg) {
        VStack(spacing: 0) {
          ForEach(manualManipulators) { m in
            ManualRemapRow(manipulator: m) {
              store.deleteManualManipulator(id: m.id)
            }
          }
          // Add item 行
          AddRemapRow { from, to in
            store.addManualManipulator(KeyRemapManipulator(from: from, to: [to]))
          }
        }
      }
    }
  }

  // MARK: - 导入规则区

  private var importedSection: some View {
    let imported = store.rules.filter { !$0.isManual }
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        MGSectionLabel(text: "导入的规则")
        Spacer()
        Button {
          showFileImporter = true
        } label: {
          Label("导入 JSON 规则文件", systemImage: "square.and.arrow.down")
        }
        .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
      }

      if imported.isEmpty {
        GroupCard(radius: MGRadius.cardLg) {
          Text("还没有导入的规则。从 ke-complex-modifications.pqrs.org 下载 JSON 文件后点右上角导入。")
            .font(.mgBody)
            .foregroundStyle(Color.mgText3)
            .padding(16)
        }
      } else {
        ForEach(imported) { rule in
          ImportedRuleCard(rule: rule)
        }
      }
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

// MARK: - 手动映射行

private struct ManualRemapRow: View {
  let manipulator: KeyRemapManipulator
  let onDelete: () -> Void

  var body: some View {
    let fromLabel = KeyCodeMap.byKeyCode[manipulator.from.keyCode]?.displayLabel ?? "#\(manipulator.from.keyCode)"
    let toLabel = manipulator.to.first.map {
      $0.keyCode == 0xFFFF ? "禁用" : (KeyCodeMap.byKeyCode[$0.keyCode]?.displayLabel ?? "#\($0.keyCode)")
    } ?? "—"

    HStack {
      Text(fromLabel)
        .font(.mgBody)
        .frame(minWidth: 120, alignment: .leading)
      Image(systemName: "arrow.right")
        .foregroundStyle(Color.mgText3)
      Text(toLabel)
        .font(.mgBody)
        .frame(minWidth: 120, alignment: .leading)
      Spacer()
      Button(role: .destructive) { onDelete() } label: {
        Image(systemName: "trash")
          .foregroundStyle(Color.mgText3)
      }
      .buttonStyle(.plain)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}

// MARK: - Add item 行

private struct AddRemapRow: View {
  let onAdd: (KeyRemapFrom, KeyRemapTo) -> Void

  @State private var fromKeyCode: UInt16 = KeyCodeMap.modifierKeys.first?.keyCode ?? 57
  @State private var toKeyCode: UInt16 = KeyCodeMap.functionKeys.first?.keyCode ?? 80

  private var fromEntry: KeyCodeEntry? { KeyCodeMap.byKeyCode[fromKeyCode] }
  private var toEntry: KeyCodeEntry? {
    toKeyCode == 0xFFFF ? KeyCodeMap.vkNone : KeyCodeMap.byKeyCode[toKeyCode]
  }

  var body: some View {
    HStack {
      // From picker
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
      .frame(minWidth: 140)

      Image(systemName: "arrow.right")
        .foregroundStyle(Color.mgText3)

      // To picker
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
      .frame(minWidth: 140)

      Spacer()

      Button {
        guard let fe = fromEntry, let te = toEntry else { return }
        let from = KeyRemapFrom(keyCode: fe.keyCode, isModifier: fe.isModifier, mandatory: [])
        let to = KeyRemapTo(keyCode: te.keyCode, isModifier: te.isModifier, additionalModifierCodes: [])
        onAdd(from, to)
      } label: {
        Label("添加映射", systemImage: "plus")
      }
      .buttonStyle(MGSecondaryButtonStyle(foreground: .mgAccent))
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
  }
}

// MARK: - 导入规则卡片

private struct ImportedRuleCard: View {
  let rule: KeyRemapRule
  private let store = KeyRemapStore.shared

  var body: some View {
    GroupCard(radius: MGRadius.cardLg) {
      VStack(alignment: .leading, spacing: 0) {
        // 标题行
        HStack {
          Text(rule.title)
            .font(.mgBody.bold())
            .foregroundStyle(Color.mgText1)
          Spacer()
          Toggle("", isOn: Binding(
            get: { rule.enabled },
            set: { store.setEnabled($0, ruleID: rule.id) }
          ))
          .labelsHidden()
          .toggleStyle(.switch)
          .controlSize(.small)
          .tint(.mgAccent)

          Button(role: .destructive) {
            store.deleteRule(id: rule.id)
          } label: {
            Image(systemName: "trash")
              .foregroundStyle(Color.red.opacity(0.8))
          }
          .buttonStyle(.plain)
        }
        .padding(16)

        // manipulator 摘要列表
        if !rule.manipulators.isEmpty {
          Divider().padding(.horizontal, 16)
          VStack(alignment: .leading, spacing: 4) {
            ForEach(rule.manipulators) { m in
              ManipulatorSummaryRow(manipulator: m)
            }
          }
          .padding(16)
        }
      }
    }
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
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.mgText2)
      Image(systemName: "arrow.right")
        .font(.system(size: 10))
        .foregroundStyle(Color.mgText3)
      Text(toLabel)
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(Color.mgText2)
    }
  }
}
