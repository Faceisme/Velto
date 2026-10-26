extension Sequence {
  /// 依次对元素求值,返回第一个非 nil 的结果;每个元素最多求一次值,命中就停。
  ///
  /// 看着和 `lazy.compactMap(transform).first` 一样,但那个对 Collection(Array、Set)会对
  /// 命中的元素**求两次值**:标准库的 lazy compactMap 是 `map(transform).filter { $0 != nil }
  /// .map { $0! }`,`first` 先求 startIndex(跑 filter,调一次 transform),再取下标(又调一次)。
  /// transform 不纯(问 AX、读窗口)时两次结果可能不同,第二次是 nil 就崩在那个 `$0!` 上。
  ///
  /// 2026-10-26 22:36 Velto 闪退就是这个:专注自动化问 Movist Pro 窗口载入的文件,第一次
  /// 标题还是文件名,第二次视频窗口正在关、标题变回 App 名 → nil → EXC_BREAKPOINT。
  func firstNonNil<T>(_ transform: (Element) throws -> T?) rethrows -> T? {
    for element in self {
      if let value = try transform(element) { return value }
    }
    return nil
  }
}
