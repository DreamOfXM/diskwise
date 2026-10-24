import Foundation

// ── 仪表几何：一段 = 盘上一块真实的字节，以及「光标这一点归哪一段」 ──
//
// 这段数学原来长在 `SweepRing`（界面层）里，而它决定的是「你点的那一下要动哪个目录」——
// 算错的代价是删错东西，不该只能靠真鼠标一遍遍试出来。搬到这里之后 SelfTest 能逐段断言，
// 界面上那一层只剩「把事件坐标递进来」。
//
// 文件名仍叫 `RingGeometry`：`ringArcs`/`ringArcIndex` 这两个函数名被 SelfTest 的十几条断言
// 和一圈注释引用着，改名会让以后每次 bisect 都多一批无关 diff。
// 但**内容已经不只环形**了：下面那对函数讲的是「整块画面按字节分给各段」，
// 形状那一层由 `GaugeLayout` 承接，环只是它的 `radial` 实现。

/// 环上一段弧占的角范围。单位是**整圈的占比**（0…1），不是度：
/// 弧是 `Circle().trim(from:to:)` 画的，两边同一个口径才对得上。
///
/// 2026-10-21 起它的正式名字是 `GaugeRegion`——「一整块画面里的哪一截」这件事跟形状无关。
/// `RingArc` 作为别名留着：`SelfTest` 那十几条断言和一堆注释都写的是它，
/// 一次性改名会让这个本该「零像素变化」的 diff 里混进几十行无关改动。
public struct GaugeRegion: Equatable {
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

/// 旧名字，见上面 `GaugeRegion` 那条说明。新写的代码用 `GaugeRegion`。
public typealias RingArc = GaugeRegion

/// 按字节量把整圈切成弧。返回的下标就是「第几段」，调用方自己配名字。
public func ringArcs(values: [Int64], gap: Double = ringHairlineGap) -> [GaugeRegion] {
    let live = values.map { max(0, $0) }.filter { $0 > 0 }
    let total = max(1, live.reduce(0, +))
    var out: [GaugeRegion] = []
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
        out.append(GaugeRegion(from: start + g / 2, to: start + span - g / 2,
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
                         arcs: [GaugeRegion], reveal: Double = 1) -> Int? {
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

// ── 把「形状」本身立成一个可替换的东西（2026-10-21）──────────────────────────
//
// 上面那对函数一直是形状无关的：`ringArcs` 说的是「各段占整块 0…1 里的哪一截」，
// `ringArcIndex` 说的是「这一点归第几段」。真正**假设了它是圆**的只有两处——
// 画的时候用 `Circle().trim`，以及命中时把落点换算成极角。
//
// 所以这里不加新数学，只把已有的两个函数**收进一个协议**，让那两处假设变成协议的一个实现。
// 换形状 = 再写一个 conformer，`ringArcs`/`ringArcIndex` 与 SelfTest 那十几条断言一个字不动。
//
// 边界（写在这里，不是写在文档里）：**几何不进配置。** 一份 JSON 可以按 `layoutID`
// **选**一种已注册形状、可以调材质参数，**不可以定义区域**——因为「这一点归哪一段」
// 决定的是第二下点击把哪个目录搬进废纸篓。能重划区域的配置，就是能让 App 删错文件夹的输入。

/// 命中层自己那一格里的一个点。刻意不用 `CGPoint`：Core 只 `import Foundation`，
/// 不碰图形框架，`SelfTest` 才能在没有界面的命令行里跑全套断言。
public struct GaugePoint: Equatable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// 一块画面。给宽高而不是给「直径」：直径那个词本身就是环的假设。
public struct GaugeCanvas: Equatable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) { self.width = width; self.height = height }
}

// ── 模式决策记录：Strategy（本文件唯一一处「为将来的变化买开放性」的结构）──────────────
// 问题：换形状时，「切区间」和「落点归谁」这两件事原先只能改 `SweepRing` 的 `Circle().trim`
//       与极角换算——而那两处同时是「画」和「点」的唯一真源。
// 变化句：**段→区域/命中** 会变；**谁占多少字节** 不变。决定者是用户投放的 JSON（`shape` 字段），
//       时机是运行期。外部配置决定 = Strategy，不是 State。
// 阶梯：落在 L3（一个协议 + 默认值构造）。比它省的 L1 是「`[id: 闭包]` 一张表」——
//       留手理由写在下面的撤销条件里。
// 数出来的三条（不许口算）：
//   #8 消费者 = 2 个文件（`RingLayers` 读 `thickness`、`Components` 读 `regions`/`regionIndex`）
//      再加 SelfTest 一个漂移守卫 → 大于 1，它买到了隔离，不是仪式。
//   #3 净增 = 本文件 +4 类型（协议、GaugeCanvas、GaugePoint、RadialGaugeLayout），消掉分支 0 处。
//      这条单独看是「代码搬家」；判据是它答得出「哪几个文件因此变成只读」：新增形状时
//      `RingLayers` 那 371 行绘制与 `SweepRing` 的事件层一行不改。
//   #1 第二个实现 = **没有**（构造点只有 RadialGaugeLayout，且两处是同默认值 + 一处测试）。
//      这是本条唯一欠着的账，也是下面撤销条件的触发项。
// 接受的代价：读栈时要多跳一层才知道真实执行者；`any GaugeLayout` 让 `RingFrame` 不能进 Equatable。
// 撤销条件（第 13 章授权收回）：若 `shape` 字段上线时**可填的 id 只有 "radial"**，这个协议就是
//       给不存在的东西留门——收回成 L1：`[String: (GaugeCanvas, [Int64]) -> [GaugeRegion]]` 一张表
//       加 `bandRatio` 数据。SelfTest 那 10 条断言不用动（它按点断言，不看实现形态）。
//       反案成立的条件是「第二种形状与 `shape` 字段**同版本**落地」——判据是同版本，不是「以后可能有」。
// 复查：`shape` 配置项定稿那一天。

/// 段 → 画面上可命中区域。**这就是换形状时唯一要 implements 的东西。**
public protocol GaugeLayout {
    /// 选它用的名字。配置里按这个 id 选形状。
    static var layoutID: String { get }

    /// 按字节量把整块画面切给各段。
    ///
    /// 注意下标口径：值为 0 的段不占地方（`ringArcs` 就是这么定的），所以返回的下标
    /// **不等于** `values` 的下标——调用方要自己把段配回它那一格的账，`SweepRing.slices`
    /// 就是拿 `zip(live, …)` 配的。这条不是疏漏，是「0 GB 的东西不该在图上有一格」的语义。
    func regions(for values: [Int64]) -> [GaugeRegion]

    /// 这一形状里「带子」有多厚。**画和点必须读同一个数**：分成两处算，
    /// 迟早出现「看着点在带子上、命中层说带子以外」，而那一次的代价是删错目录。
    func thickness(of canvas: GaugeCanvas) -> Double

    /// 落点归第几个区域；区域以外一律 nil（不许"就近吸附"到隔壁段——那等于替用户选了一个他没指的目录）。
    func regionIndex(at p: GaugePoint, canvas: GaugeCanvas,
                     regions: [GaugeRegion], reveal: Double) -> Int?
}

/// 环形：今天线上跑的唯一一种，就是上面那两个函数换了个壳。
public struct RadialGaugeLayout: GaugeLayout {
    public static let layoutID = "radial"

    /// 带宽 / 画面短边。这个数原来长在 `SweepRing.band`（`diameter * 0.145`），
    /// 搬到这儿来是为了让「多厚」和「点哪儿归谁」由**同一个来源**决定。
    public var bandRatio: Double

    public init(bandRatio: Double = 0.145) { self.bandRatio = bandRatio }

    public func regions(for values: [Int64]) -> [GaugeRegion] { ringArcs(values: values) }

    public func thickness(of c: GaugeCanvas) -> Double { min(c.width, c.height) * bandRatio }

    public func regionIndex(at p: GaugePoint, canvas c: GaugeCanvas,
                            regions: [GaugeRegion], reveal: Double) -> Int? {
        let d = min(c.width, c.height)
        return ringArcIndex(x: p.x, y: p.y, diameter: d,
                            rIn: d / 2 - thickness(of: c), rOut: d / 2,
                            arcs: regions, reveal: reveal)
    }
}
