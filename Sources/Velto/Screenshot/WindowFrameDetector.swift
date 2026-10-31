import CoreGraphics

/// Pointer-based hit testing over a window snapshot, adapted from CapCap.
enum WindowFrameDetector {
  static func hitWindowBounds(in snapshot: WindowSnapshot, atGlobalPoint p: CGPoint) -> CGRect? {
    // CapCap-style window snap: the visible topmost window under the cursor wins.
    // In particular, never jump to another app's window away from the pointer.
    snapshot.windows.first { w in
      [0, 3, 8, 24, 25, 101].contains(w.layer) && w.alpha > 0
        && w.bounds.width > 1 && w.bounds.height > 1 && w.bounds.contains(p)
    }?.bounds
  }
}
