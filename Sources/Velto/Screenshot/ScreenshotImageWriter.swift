import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum ScreenshotImageWriter {
  static func copyToClipboard(_ image: CGImage) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
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
    let url = URL(fileURLWithPath: targetDir).appendingPathComponent(name)
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
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
}
