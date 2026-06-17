import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ScreenshotImageWriter {
  static func copyToClipboard(_ image: CGImage) {
    guard let data = encode(image, as: .png) else { return }
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setData(data, forType: .png)
    ScreenshotDebugLog.log("copied \(image.width)x\(image.height) to clipboard")
  }

  @discardableResult
  static func save(_ image: CGImage, toDirectory dir: String,
                   format: ScreenshotImageFormat, alsoCopy: Bool) -> URL? {
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
    guard let data = encode(image, as: format) else { return nil }
    do {
      try data.write(to: url)
      if alsoCopy { copyToClipboard(image) }
      ScreenshotDebugLog.log("saved to \(url.path)")
      return url
    } catch {
      ScreenshotDebugLog.log("save failed: \(error.localizedDescription)")
      return nil
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
