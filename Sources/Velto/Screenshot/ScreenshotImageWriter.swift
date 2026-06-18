import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// 输出失败的具体原因;会话据此决定提示文案并保留标注会话(不撤窗)。
enum ScreenshotWriteError: Error {
  case encodingFailed
  case clipboardRejected
  case fileWriteFailed(String)
}

enum ScreenshotImageWriter {
  static func copyToClipboard(_ image: CGImage) -> Result<Void, ScreenshotWriteError> {
    guard let data = encode(image, as: .png) else { return .failure(.encodingFailed) }
    let pb = NSPasteboard.general
    pb.clearContents()
    guard pb.setData(data, forType: .png) else { return .failure(.clipboardRejected) }
    ScreenshotDebugLog.log("copied \(image.width)x\(image.height) to clipboard")
    return .success(())
  }

  @discardableResult
  static func save(_ image: CGImage, toDirectory dir: String,
                   format: ScreenshotImageFormat, alsoCopy: Bool) -> Result<URL, ScreenshotWriteError> {
    // 先编码,编码不出来就没必要碰文件系统。
    guard let data = encode(image, as: format) else { return .failure(.encodingFailed) }

    let fm = FileManager.default
    var targetDir = dir
    var isDir: ObjCBool = false
    let ok = fm.fileExists(atPath: targetDir, isDirectory: &isDir) && isDir.boolValue
      && fm.isWritableFile(atPath: targetDir)
    if !ok {
      targetDir = NSSearchPathForDirectoriesInDomains(.desktopDirectory, .userDomainMask, true).first
        ?? NSHomeDirectory() + "/Desktop"
      ScreenshotDebugLog.log("save dir not writable, fallback to \(targetDir)")
    }
    let name = ScreenshotGeometry.suggestedFileName(format: format)
    let url = uniqueURL(inDirectory: targetDir, fileName: name)
    do {
      try data.write(to: url)
      if alsoCopy {
        // 已成功落盘;附带复制失败不该让“保存”整体算失败,记录即可。
        if case .failure(let error) = copyToClipboard(image) {
          ScreenshotDebugLog.log("saved but clipboard copy failed: \(error)")
        }
      }
      ScreenshotDebugLog.log("saved to \(url.path)")
      return .success(url)
    } catch {
      ScreenshotDebugLog.log("save failed: \(error.localizedDescription)")
      return .failure(.fileWriteFailed(error.localizedDescription))
    }
  }

  // MARK: - 私有辅助

  /// 按格式把 CGImage 编码成图片数据。新增 ScreenshotImageFormat 枚举值时编译器会强制在此穷举。
  private static func encode(_ image: CGImage, as format: ScreenshotImageFormat) -> Data? {
    let rep = NSBitmapImageRep(cgImage: image)
    let fileType: NSBitmapImageRep.FileType = switch format {
    case .png: .png
    }
    return rep.representation(using: fileType, properties: [:])
  }

  /// 同名文件已存在时在扩展名前追加 -1、-2… 避免静默覆盖丢图。
  private static func uniqueURL(inDirectory dir: String, fileName: String) -> URL {
    let fm = FileManager.default
    let base = URL(fileURLWithPath: dir)
    var candidate = base.appendingPathComponent(fileName)
    guard fm.fileExists(atPath: candidate.path) else { return candidate }
    let ext = candidate.pathExtension
    let stem = candidate.deletingPathExtension().lastPathComponent
    var n = 1
    repeat {
      let nextName = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
      candidate = base.appendingPathComponent(nextName)
      n += 1
    } while fm.fileExists(atPath: candidate.path)
    return candidate
  }
}
