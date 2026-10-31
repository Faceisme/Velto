import CoreGraphics

/// 乱划检测 (scribble-to-cancel):画错了就来回甩几下或转个圈,取消本次手势。
///
/// 把手势按"腿"(leg) 切分:从 `legStart` 起累积直线位移,达到 `legMinLength` 就定一条
/// 腿的方向。腿方向相对**锚点方向**偏离到 `turnHysteresis` 才算真转弯:把这段偏离累加到
/// `accumulatedTurn`,锚点挪到当前腿。来回甩每次反向 ≈180°、转圈圈每圈 =360°,两种
/// "乱划"都靠总转角统一识别。累积转角到 `turnThreshold` 即判为取消。
///
/// 不能全量累加相邻腿的夹角:10px 的腿很短,鼠标抖动每条腿都贡献几度,路越长攒得越多。
/// 折返手势(置顶/置底)真实转角 ≈180°,全量累加却到了 216~371°,画长一点就撞线被当成
/// 乱划取消 —— 2026-10-31 调试日志 7 次折返被吞 3 次,全是行程 >700px 的那几次,
/// 看上去就是「置顶/置底时灵时不灵」。
///
/// 也不能按角度门槛直接丢掉小转角:平滑大圈每条腿只转几度,丢掉就永远攒不起来(这正是
/// 早期版本对画圈完全失效的根因)。锚点不动时偏离量逐腿累积,大圈转够滞回角就入账一次,
/// 总量不丢;抖动只是围绕真实方向来回摆,越不过滞回带。
struct GestureScribbleDetector {
    /// 一条"腿"成立所需的最小直线位移。太小会被手抖/微漂噪声带偏方向判断,
    /// 太大则小圈切不出腿。10px 在实测里既滤抖又能逐段累积小圈的转角。
    static let legMinLength: CGFloat = 10
    /// 腿方向偏离锚点到这个角度才算转弯。真实轨迹上 20°~50° 结果一致,取中间偏小,
    /// 半径 20px 的小圈(每条腿约转 29°)也能逐段入账。
    static let turnHysteresis: CGFloat = .pi / 6    // 30°
    /// 累积转角达到此值即判为乱划/转圈取消:一次折返实测 ≤174°,来回甩两下 ≈340°。
    /// 不能再用 360°:滤掉抖动后两次反向凑不够,原来是抖动在帮忙补足。
    static let turnThreshold: CGFloat = 5 * .pi / 3 // 300°

    private var legStart: CGPoint
    private var anchorDirection: CGVector?
    private(set) var accumulatedTurn: CGFloat = 0

    init(at location: CGPoint = .zero) {
        legStart = location
    }

    /// 喂入一个拖动点。返回 `true` 表示本次手势已判定为乱划/转圈,调用方应取消。
    mutating func update(at location: CGPoint) -> Bool {
        let dx = location.x - legStart.x
        let dy = location.y - legStart.y
        let legLength = hypot(dx, dy)
        // 位移还不够一条腿,继续累积,方向待定。
        guard legLength >= Self.legMinLength else { return false }

        legStart = location
        let direction = CGVector(dx: dx / legLength, dy: dy / legLength)

        // 第一条腿没有参照方向,只记录不判定。
        guard let anchor = anchorDirection else {
            anchorDirection = direction
            return false
        }

        // 与锚点的夹角(无向, 0...π)。没越过滞回带就不动锚点,偏离量留给后面的腿继续攒。
        let dot = max(-1, min(1, anchor.dx * direction.dx + anchor.dy * direction.dy))
        let turn = acos(dot)
        guard turn >= Self.turnHysteresis else { return false }

        accumulatedTurn += turn
        anchorDirection = direction
        return accumulatedTurn >= Self.turnThreshold
    }
}
