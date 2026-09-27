import Foundation

// ── 环形几何：一段弧 = 盘上一块真实的字节，以及「光标这一点归哪一段」 ──
//
// 这段数学原来长在 `SweepRing`（界面层）里，而它决定的是「你点的那一下要动哪个目录」——
// 算错的代价是删错东西，不该只能靠真鼠标一遍遍试出来。搬到这里之后 SelfTest 能逐段断言，
// 界面上那一层只剩「把事件坐标递进来」。

/// 环上一段弧占的角范围。单位是**整圈的占比**（0…1），不是度：
/// 弧是 `Circle().trim(from:to:)` 画的，两边同一个口径才对得上。
public struct RingArc: Equatable {
    /// 画出来的那一截的起点（已经让出半个发丝缝）
    public var from: Double
    /// 画出来的那一截的终点
    public var to: Double
    /// 这一段的**归属**区间：累计起点到累计终点，中间不留缝。
    /// 命中层认这个而不是 `from`/`to`——见 `ringArcIndex`。
    public var claimFrom: Double
    public var claimTo: Double
    /// 这一段占整圈多少（含它两侧让给发丝缝的那半份）
    public var span: Double

    public init(from: Double, to: Double, claimFrom: Double, claimTo: Double, span: Double) {
        self.from = from
        self.to = to
        self.claimFrom = claimFrom
        self.claimTo = claimTo
        self.span = span
    }
}

/// 段间那道发丝缝：原型 SVG 里根本没有缝，是遮罩边缘。缝再宽一分，
/// 「一整圈 = 一整块盘」这句承诺就在图上露馅——缝是盘上没有被抹掉的字节。
public let ringHairlineGap: Double = 0.6 / 360

/// 按字节量把整圈切成弧。返回的下标就是「第几段」，调用方自己配名字。
public func ringArcs(values: [Int64], gap: Double = ringHairlineGap) -> [RingArc] {
    let live = values.map { max(0, $0) }.filter { $0 > 0 }
    let total = max(1, live.reduce(0, +))
    var out: [RingArc] = []
    var start: Double = 0
    for (i, v) in live.enumerated() {
        let span = Double(v) / Double(total)
        // 最后一段的归属区间钉死在 1：占比是浮点累加的，尾巴上那 1e-17 的误差
        // 要是留成缝，贴着 12 点钟顺时针那一侧的最后一格就谁都不归。
        let end = i == live.count - 1 ? 1 : start + span
        // 缝不许吃掉整段：照原样写死 0.6°，比它小的段会算出 from > to——
        // 那段既画不出来也点不着。4 TB 盘上 0.6° 就是 6.7 GB，一条 3 GB 的弧
        // 会整个从图上消失，而旁边账目行还列着它。
        let g = min(gap, span * 0.4)
        out.append(RingArc(from: start + g / 2, to: start + span - g / 2,
                           claimFrom: start, claimTo: end, span: span))
        start += span
    }
    return out
}

/// 环心坐标系里的一个落点归哪一段；带子以外（孔里、环外）一律 nil。
///
/// - Parameters:
///   - x, y: 相对**命中层左上角**的点，单位与 `diameter` 一致（SwiftUI 视图坐标，y 朝下）
///   - rIn, rOut: 环带的内外半径
///   - reveal: 这一圈已经画出来多少（0…1）。入场动画把整圈按 `reveal` 压缩着画，
///     命中区得跟着压缩，否则光标还没走到弧上就已经能点它了。
public func ringArcIndex(x: Double, y: Double, diameter: Double,
                         rIn: Double, rOut: Double,
                         arcs: [RingArc], reveal: Double = 1) -> Int? {
    let dx = x - diameter / 2, dy = y - diameter / 2
    let r = (dx * dx + dy * dy).squareRoot()
    guard r >= rIn - 2, r <= rOut + 2 else { return nil }
    guard reveal > 0 else { return nil }
    // 0 = 12 点钟、顺时针，和 `ringArcs` 的占比同一个口径。
    var deg = atan2(dx, -dy) * 180 / .pi
    if deg < 0 { deg += 360 }
    let frac = deg / 360 / reveal
    guard frac >= 0, frac <= 1 else { return nil }
    // 比的是**归属区间**而不是画出来那截：正落在发丝缝里（环外径 340 时是一道 1.8 px 的缝）
    // 也要有人接，否则光标贴着边界走会「亮一下灭一下」，读起来像画坏了。
    // 这里原先的写法是给 `from`/`to` 各让 0.4° 的松弛量，两个方向都错：
    // 让得比半道缝还小，缝照旧是死的；让得够大，就偷隔壁——一段比松弛量还窄的弧，
    // 它的中点被前一段整个盖掉，永远点不着。归属区间是无缝铺满的，两头都不用凑。
    return arcs.firstIndex { frac >= $0.claimFrom && frac <= $0.claimTo }
}
