import AppKit
import VeltoAnnotationCore

/// 原位文字编辑器:无背景的 NSTextView,字体/颜色/对齐取自当前样式。编辑时显示一圈高亮边框
/// 与极淡填充,让用户看清输入框的位置与范围;框随输入内容自适应宽高(不自动换行,横向生长,
/// 仅 Shift-Enter 显式换行),因此"所见尺寸 == 导出尺寸"。
/// 失焦或按 Enter 提交,按 Esc 或右键取消。frame 用所在父视图(画布)坐标回传,空文本由
/// 编辑器侧 commit 后交 `AnnotationEditor` 丢弃。
@MainActor
final class AnnotationTextEditor: NSView, NSTextViewDelegate {
  var onCommit: ((String, CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private let scrollView = NSScrollView()
  private let textView = NSTextView()
  private var finished = false
  private var cancelling = false
  /// 自适应时保持不动的"框左上角"(父视图 y-up 坐标):高度增长时框向下长,宽度增长时向右长。
  private var anchorTopLeft: CGPoint = .zero
  /// 右侧留白:确保导出端 CTFramesetter 以同样宽度排版时不会把行尾字符挤到换行。
  private static let caretPadding: CGFloat = 6
  /// 专属撤销栈:绝不让 NSTextView 把撤销注册到窗口的 NSUndoManager。否则编辑器销毁后
  /// 这些注册的目标对象失效、成为悬垂指针,之后任意 ⌘Z 调用窗口撤销栈即崩溃。
  private let textUndoManager = UndoManager()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    setup()
  }

  required init?(coder: NSCoder) {
    fatalError("not implemented")
  }

  private func setup() {
    wantsLayer = true
    // 编辑态可见的框:极淡强调色填充 + 1pt 强调色边框,圆角 3。提交后编辑器移除,标注本身无背景。
    layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor
    layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
    layer?.borderWidth = 1
    layer?.cornerRadius = 3

    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.autoresizingMask = [.width, .height]

    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    // 不自动换行:容器给到无限宽,文字横向生长,只有显式换行(Shift-Enter)才折行。
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = true
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textContainerInset = NSSize(width: 2, height: 2)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.delegate = self

    scrollView.documentView = textView
    addSubview(scrollView)
  }

  func begin(text: String, frame: CGRect, style: AnnotationStyle, in parent: NSView) {
    finished = false
    cancelling = false
    self.frame = frame
    // 父视图 y-up:框左上角 = (minX, maxY)。增长时锁定它,框向下/向右生长。
    anchorTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
    parent.addSubview(self)
    scrollView.frame = bounds

    apply(style: style)
    textView.string = text
    resizeToFitText()
    textView.selectAll(nil)
    parent.window?.makeFirstResponder(textView)
  }

  func commit() {
    guard !finished else { return }
    finished = true
    onCommit?(textView.string, frame)
    teardown()
  }

  func cancel() {
    guard !finished else { return }
    finished = true
    cancelling = true
    onCancel?()
    teardown()
  }

  /// 移除视图前先清空专属撤销栈,确保不留任何指向即将释放对象的注册。
  private func teardown() {
    textUndoManager.removeAllActions()
    removeFromSuperview()
  }

  /// 把框尺寸贴合当前文字:宽=最长行宽、高=总行高(各加内边距);左上角锁定不动。
  private func resizeToFitText() {
    guard let layoutManager = textView.layoutManager,
          let container = textView.textContainer else { return }
    layoutManager.ensureLayout(for: container)
    let used = layoutManager.usedRect(for: container)
    let inset = textView.textContainerInset
    let lineHeight = textView.font.map { ceil($0.boundingRectForFont.height) } ?? 16

    let width = max(ceil(used.width), lineHeight * 0.6) + inset.width * 2 + Self.caretPadding
    let height = max(ceil(used.height), lineHeight) + inset.height * 2
    let newFrame = CGRect(
      x: anchorTopLeft.x,
      y: anchorTopLeft.y - height,
      width: width,
      height: height
    )
    guard newFrame != frame else { return }
    frame = newFrame
    scrollView.frame = bounds
  }

  private func apply(style: AnnotationStyle) {
    textView.font = NSFont.systemFont(
      ofSize: style.fontSize,
      weight: style.isBold ? .bold : .regular
    )
    textView.textColor = style.strokeColor.nsColor
    textView.insertionPointColor = style.strokeColor.nsColor
    switch style.textAlignment {
    case .left: textView.alignment = .left
    case .center: textView.alignment = .center
    case .right: textView.alignment = .right
    }
  }

  // MARK: - NSTextViewDelegate

  /// 把字内撤销引到专属管理器,而非窗口的共享 NSUndoManager。
  func undoManager(for view: NSTextView) -> UndoManager? {
    textUndoManager
  }

  func textDidChange(_ notification: Notification) {
    resizeToFitText()
  }

  func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    switch selector {
    case #selector(NSResponder.cancelOperation(_:)):
      cancel()
      return true
    case #selector(NSResponder.insertNewline(_:)):
      // Enter 提交;Shift-Enter 换行。
      if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
        return false
      }
      commit()
      return true
    default:
      return false
    }
  }

  func textDidEndEditing(_ notification: Notification) {
    guard !cancelling else { return }
    commit()
  }
}
