import AppKit
import VeltoAnnotationCore

/// 原位文字编辑器:无边框、透明背景的 NSTextView,字体/颜色/对齐取自当前样式。
/// 失焦或按 Enter 提交,按 Esc 取消。frame 用所在父视图(画布)坐标回传,空文本由
/// 编辑器侧 commit 后交 `AnnotationEditor` 丢弃。
@MainActor
final class AnnotationTextEditor: NSView, NSTextViewDelegate {
  var onCommit: ((String, CGRect) -> Void)?
  var onCancel: (() -> Void)?

  private let scrollView = NSScrollView()
  private let textView = NSTextView()
  private var finished = false
  private var cancelling = false
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
    layer?.backgroundColor = NSColor.clear.cgColor

    scrollView.hasVerticalScroller = false
    scrollView.hasHorizontalScroller = false
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.autoresizingMask = [.width, .height]

    textView.isRichText = false
    textView.importsGraphics = false
    textView.allowsUndo = true
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.textContainerInset = NSSize(width: 2, height: 2)
    textView.delegate = self

    scrollView.documentView = textView
    addSubview(scrollView)
  }

  func begin(text: String, frame: CGRect, style: AnnotationStyle, in parent: NSView) {
    finished = false
    cancelling = false
    self.frame = frame
    parent.addSubview(self)
    scrollView.frame = bounds

    textView.textContainer?.containerSize = NSSize(
      width: bounds.width,
      height: .greatestFiniteMagnitude
    )
    textView.textContainer?.widthTracksTextView = true
    textView.minSize = NSSize(width: 0, height: bounds.height)
    textView.maxSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)

    apply(style: style)
    textView.string = text
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
