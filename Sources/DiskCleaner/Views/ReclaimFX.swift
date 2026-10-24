import AppKit
import CoreImage
import SwiftUI
import DiskCleanerCore

/// 点第二下之后那一趟「字节离开环」的动效。
///
/// 时间轴照抄样稿 `diskwise-v2.6-crystal.html` 的 `CLEAN_TIMELINE`：
/// 响指冲击波 + 光圈收进盘心 + 弧上甩出一把水珠，水珠越过右栏落进废纸篓。
/// 样稿 v2.5 那一层把水珠的落点从盘心改到了废纸篓：一颗水珠只能有一个去处，
/// 两处同时报「收到了」等于说这堆字节搬去了两个地方。
/// 这一版留了那条退路：篓子那一格被滚出视野时（他这扇 612 高的窗就是），
/// 落点退回盘心——样稿 `?mo=0` 那一档写的就是这一条。判据见 `trayInView`。
///
/// **全部交给 Core Animation。** 这趟动效一次二十来层、活三秒出头，
/// 但它们是这一页最容易被点到的动作；只要有一帧走 SwiftUI 的布局，
/// 一次点击就会按 `PerfProbe` 顶部记的那笔「整扇窗重排」记账。
/// 所以这里只建图层、装一次发条，之后主线程一帧都不碰。
enum ReclaimTimeline {
    /// 水珠从半透明长出来那一拍（样稿 `emerge`）。
    static let emerge: Double = 0.26
    /// 长满之后、起飞之前按在带上的那一拍。
    ///
    /// 这一拍是「看得清」的全部来源：上一版水珠一边淡入一边已经被贝塞尔拉走，
    /// 在环上停的只有 `emerge/duration ≈ 0.25` 秒里那一小段渐显，眼睛读到的是
    /// 「弧上闪了一下」而不是一把水珠。现在先长满、再在带面上钉住这一拍，
    /// 每一颗都以原尺寸停得住一次眨眼，才谈得上「水珠离开环」。
    /// 样稿没有这一拍（它靠 1.44 秒的长飞行买「看得清」），这一拍是他 2026-10-24
    /// 那句「要有延迟能看到清的感觉」要的；0.34 → 0.42 是同一句在 2026-10-24 晚上
    /// 又重说了一遍——「不要那么快」。
    static let bead: Double = 0.42
    /// 环光收进盘心。
    static let collapse: Double = 0.56
    /// 按下之后隔多久甩水珠（样稿 `gatherAt`）。
    static let gatherAt: Double = 0.36
    /// 第一颗水珠真正**离开带面**的那一格：长满 + 钉住之后才起飞。
    static let releaseAt: Double = gatherAt + emerge + bead
    /// 一颗水珠飞完要走多久（不含上面那两拍）。
    ///
    /// 0.62 → 1.05：这一程是从环带飞到废纸篓那一格，两百多 pt，0.62 秒跑完读作
    /// 「闪了一下就到了」。样稿买「看得清」用的是 1.44 秒的长飞行（`suction`），
    /// 它的落点在盘心、路短；我们路长，所以把时间还给路，而不是把路缩短。
    static let flight: Double = 1.05
    /// 逐颗错开的最长那一段：越靠弧尾的水珠越晚走，但整串要在 `flightSpread` 内起步。
    static let flightSpread: Double = 0.26
    /// 水珠飞完的那一档（样稿 `suction`）。
    static let suction: Double = 1.44
    /// 落定之后留给眼睛确认的空（样稿 `hold`）。
    static let hold: Double = 0.90
    /// 冲击波一圈。
    static let shock: Double = 0.66
    /// 涟漪在落点上摊开。
    static let splash: Double = 0.42
    /// 废纸篓那一格亮一下。
    static let trayFlash: Double = 0.46
    /// 「天亮」那一声该落在什么时候：第一颗水珠砸进篓子的那一格，不是拍脑袋的偏移。
    static let dawnAt: Double = gatherAt + emerge + bead + flight
    /// 水珠数按字节量给（样稿：按弧的张角给 5…9 颗）。
    ///
    /// 下限从 3 抬到 5、上限从 7 抬到 10：三颗水珠在两百多 pt 的路上读不出「一串水被收走」，
    /// 只读得出「有个亮点飞过去了」——他 2026-10-24 那句「动画效果要足够」说的是这个。
    static func dropletCount(bytes: Int64) -> Int {
        let gb = Double(max(0, bytes)) / 1_000_000_000
        return min(10, max(5, Int((gb / 1.1).rounded())))
    }
}

/// 环上每一条弧的角区间，往页面报一份。
///
/// 页面不自己按 `regions(for:)` 再算一遍：那个 `zip` 把零值段剔掉之后下标就跟 `segments`
/// 对不上了（见 `SweepRing.slices` 那条注释）。弧的几何只有一个真源，页面只读。
struct RingArcMap: Equatable {
    var diameter: CGFloat = 0
    /// 环带厚度，取自 `RingFrame.band`。回收动效的水珠、光圈、冲击波都按这两条线
    /// （`diameter/2` 与 `band`）在带面上定位，不许自己按「框宽的百分之几」再估一遍：
    /// 换一环径或换 `layout` 之后那个百分数就是另一个数，动效会套在真环外面。
    var band: CGFloat = 0
    var spans: [String: GaugeRegion] = [:]
}

struct RingArcMapKey: PreferenceKey {
    static var defaultValue = RingArcMap()
    static func reduce(value: inout RingArcMap, nextValue: () -> RingArcMap) {
        let next = nextValue()
        if next.diameter > 0 { value.diameter = next.diameter }
        if next.band > 0 { value.band = next.band }
        value.spans.merge(next.spans) { _, new in new }
    }
}

/// 环与废纸篓那一格在英雄卡里的矩形（水珠的起点、终点和槽位都要宽度，光有中心不够）。
struct HeroRectKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func heroFrame(_ name: String, in space: String) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: HeroRectKey.self,
                                       value: [name: g.frame(in: .named(space))])
            }
        )
    }
}

/// 一次回收的完整参数。`id` 是唯一身份：同一份参数重画不该再来一趟。
struct ReclaimBurst: Equatable {
    let id = UUID()
    var arc: GaugeRegion
    /// 环那一格（水珠从它的外沿起飞、冲击波和光圈以它为心）。
    var ring: CGRect
    /// 环带厚度，画这条弧的那个 `RingFrame.band`。动效的每一档半径都从它推。
    var band: CGFloat
    /// 废纸篓那一格（落点只在它的左半段）。
    var tray: CGRect
    var bytes: Int64
    var tint: Color

    static func == (a: ReclaimBurst, b: ReclaimBurst) -> Bool { a.id == b.id }
}

/// 铺在英雄卡最上面的一层。不要接鼠标（`allowsHitTesting(false)`）——
/// 它盖着环和整本账，接一下就再也点不到它们了。
struct ReclaimFXLayer: NSViewRepresentable {
    var burst: ReclaimBurst?

    func makeNSView(context: Context) -> ReclaimFXHost { ReclaimFXHost(frame: .zero) }

    func updateNSView(_ host: ReclaimFXHost, context: Context) { host.play(burst) }
}

final class ReclaimFXHost: NSView {
    /// 图层跟着 SwiftUI 一起 y 朝下。
    ///
    /// 这一条拆掉的是「动效挂在卡片**下沿**」这件事（他 2026-10-24 那张实拍：动效的圆
    /// 和真环不同心）。原先宿主是默认的 y 朝上，`geometry(for:)` 每算一个点都要
    /// `h - y` 翻一次，那个 `h` 是 `bounds.height`：卡片往下长一截，挂在底沿上的这一整趟
    /// 就跟着往下滑一截，而环在顶部不动——半径没变、整枚挪了家，看着就是两枚不同心的圆。
    /// 真机那一趟只在按下时排一次队（`flush` 之后 `pending` 就空了，`layout()` 不再重排它），
    /// 所以卡片中途长高没人补；取证那条路反过来，每次 `layout()` 都 `redrawPinned()`
    /// 拆了重排，同一个 `h` 现读现翻，两边一错一补——**这条路结构上拍不到这一偏**，
    /// 前几轮「图上明明同心」和「你看到的还是偏」就是这么对不上的。
    /// 翻掉之后这一层里再无 `h`：动效只认环那一格的矩形，卡片长高、变矮都跟它无关。
    /// 代价是方向性的数要跟着镜像——两处 `CAGradientLayer` 的起止点、珠子高光的
    /// `frame.y`、溅起水沫的上下——见 `dropMaterial` 与 `addSplash`。
    ///
    /// 同源的第二处（翻不翻都躲不过，见 `rebake`）：让环挪家的不是这一层的坐标，是**视口矮了**。
    /// 环居中的那一片按滚动视口高算（`ringBox(viewportH, ring)`，`OverviewView.swift:3192` +
    /// `:1863`），视口一矮，环就在**自己卡片的局部坐标里**挪了位；这一账不是 anchored 的账
    /// （那一账翻掉已经平了），是「按下时量到的矩形过期了」，只能靠重排。
    /// 2026-10-24 实拍命中它，靠的是那条「已把 …移入废纸篓…」的提示——当时它是版面的一行，
    /// 插在整页**上面**，一进来就削掉视口几十 pt，而取证帧从来没有它，两边就是这么对不上。
    /// 现在提示条按设计稿浮在内容区底沿（`.dbar`/`.pgtip` 都是 `position:absolute`，不占版面），
    /// 这一条根已经拔掉；留着 `rebake` 是为剩下的那些——主要是飞行途中拖窗口下沿。
    override var isFlipped: Bool { true }

    private var pending: ReclaimBurst?
    private var lastID: UUID?
    /// 真机那一趟**正在用**的那份参数（含它按下时量到的矩形）。矩形换了要照着新矩形重排。
    private var baked: ReclaimBurst?
    /// 上一趟排出去的那一刻（`CACurrentMediaTime` 的钟）。重排只认它之前的一小段，见 `rebake`。
    private var bakedAt: CFTimeInterval = 0
    /// 每一趟一个号。重排时把号换掉，上一趟那些「到点自己摘图层」的延后闭包就作废，
    /// 否则它们会在新水珠飞到半路时把整层摘干净。
    private var gen = 0
    /// 同时在飞的趟数。超过三趟就丢掉新的：这一下本来就不该连点，
    /// 叠到第四趟既不读得出谁是谁，也白占图层。
    private var active = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("ReclaimFXHost is code-only") }   // l10n-scan: skip

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 量具钩子：`DISKWISE_PERF_FX=<秒>` 时按这个间隔自演一趟回收（不碰真账）。
    /// 没有它，无人值守的机器上一次「点第二下」都不会发生，帧账只能靠猜；
    /// 演的是 `animate` 那条真机路径，连声音一起，跟按下时排的队一模一样。
    private var probeTimer: Timer?

    private func startProbeIfAsked() {
        guard probeTimer == nil,
              let raw = ProcessInfo.processInfo.environment["DISKWISE_PERF_FX"],
              let every = Double(raw), every > 0 else { return }
        let t = Timer(timeInterval: every, repeats: true) { [weak self] _ in
            guard let self, bounds.width > 1, bounds.height > 1 else { return }
            let ringSide = min(420, bounds.height * 0.78)
            let burst = ReclaimBurst(
                arc: GaugeRegion(from: 0, to: 0.24, claimFrom: 0, claimTo: 0.24, span: 0.24),
                ring: CGRect(x: 0, y: (bounds.height - ringSide) / 2,
                             width: ringSide, height: ringSide),
                band: ringSide * 0.145,
                tray: CGRect(x: bounds.width * 0.44, y: bounds.height - 88,
                             width: bounds.width * 0.54, height: 30),
                bytes: 6_300_000_000,
                tint: .blue)
            animate(burst)
            Sound.shared.play(.snap)
            Sound.shared.play(.gather, after: ReclaimTimeline.releaseAt)
            Sound.shared.play(.dawn, after: ReclaimTimeline.dawnAt)
        }
        RunLoop.main.add(t, forMode: .common)
        probeTimer = t
    }

    func play(_ burst: ReclaimBurst?) {
        guard let burst else { return }
        guard burst.id == lastID else {
            lastID = burst.id
            pending = burst
            flush()
            redrawPinned()
            return
        }
        // 同一趟、矩形换了：环在飞行途中被顶走了，跟着重排一次（`rebake`）。
        // 只在头一颗水珠离开带面之前认——过了那一格，水珠已在半路，重排会把它们
        // 拽回环上重新长一遍，那比偏一点更难看。
        guard SnapshotMode.flightPhase == nil, let old = baked,
              CACurrentMediaTime() - bakedAt < ReclaimTimeline.releaseAt,
              old.ring != burst.ring || old.tray != burst.tray || old.band != burst.band else { return }
        rebake(burst)
    }

    /// 环在飞行途中被顶走，就按新矩形把这一趟整个重排一遍。
    ///
    /// 为什么要重排而不是平移：这一趟的每一个点都是从环那一格推出来的（带面半径、
    /// 水珠起飞角、冲击波心），平移能把圆心对上却对不上尺寸——环被挤小的时候整圈会糊出带外。
    /// 什么时候走得到这里：回收提示条是版面的一行、插在整页**上面**，它一进来滚动视口就矮
    /// 一截，而环居中的那一片按视口高算（`ringBox(viewportH, ring)`）——环在自己卡片的局部
    /// 坐标里就挪了位，这一趟吃的却还是按下时量到的那份矩形。他 2026-10-24 那张实拍顶上
    /// 挂着这条提示，而取证帧从来没有它：两边对不上就是从这里分的岔。
    /// 代价是这一趟从头再演一次，所以只在头一颗水珠起飞之前认（`play` 里那一窗）。
    /// 提示条是落定那一瞬间插进来的，本来就在这窗里；真到了水珠已经在飞的时候才变
    /// （比如中途拖窗口），就让它按旧矩形飞完——重新对齐那一下会把半空的水珠拽回环上，
    /// 比偏着飞完更扎眼。
    private func rebake(_ b: ReclaimBurst) {
        gen += 1
        active = 0
        baked = nil
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        animate(b)
    }

    /// 定帧用的那一份参数。截图这一档不吞掉它：每次 `layout()` 都重排一遍节点。
    /// 矩形本身由页面在 `HeroRectKey` 变化时重发（`fireSnapshotBurstIfAsked`），
    /// 所以窗口从 820 长到 852 之后，这一格画的是新布局那一圈水珠——
    /// 2026-10-22 实拍过旧的：落点比 SwiftUI 自己画的同一个矩形低 27 pt，
    /// 取证图上看着就是「水珠砸在提示行上」。
    private var pinned: ReclaimBurst?

    override func layout() {
        super.layout()
        startProbeIfAsked()
        flush()
        redrawPinned()
    }

    /// 按当前布局重画那一格定帧。每次都先拆干净再建：这一档只留一张图，
    /// 叠着画会在同一张证据里混进上一版布局的水珠。
    private func redrawPinned() {
        guard let pinned, let phase = SnapshotMode.flightPhase,
              bounds.width > 1, bounds.height > 1, let root = layer else { return }
        root.sublayers?.forEach { $0.removeFromSuperlayer() }
        render(pinned, phase: CGFloat(phase))
    }

    private func flush() {
        guard let burst = pending, bounds.width > 1, bounds.height > 1 else { return }
        pending = nil
        // 截图那几条路：给了相位就画一格定帧；没给就一个节点都不建。
        if SnapshotMode.flightPhase != nil {
            pinned = burst
            return
        }
        guard !SnapshotMode.active else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        animate(burst)
    }

    // MARK: 几何

    /// 一颗水珠的行程。坐标就是卡片坐标（y 朝下，与宿主图层同向，见 `isFlipped`）。
    private struct Drop {
        var start: CGPoint
        var end: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var size: CGFloat
        var delay: Double
        var duration: Double
        var blurred: Bool
    }

    private struct Geometry {
        var drops: [Drop]
        var ringCenter: CGPoint
        var ringRadius: CGFloat
        var band: CGFloat
        var trayRect: CGRect
        /// 这一趟是不是落进废纸篓。false = 篓子那一格在视野外，整趟退回盘心（`trayInView`）。
        var toTray: Bool
        /// 盘心那一档的落点：水珠的终点与 `settleSpark` 那颗必须是一个点。样稿里两处都写
        /// 同一个 `cx + 2*sc, cy + 10*sc`；上一版真机把亮斑画在 `ringCenter`、水珠画在
        /// `cy + 10*sc`，于是「收到了这里」那颗亮在数字正中（`16.0` 的冒号上）。
        var settle: CGPoint
    }

    /// 固定种子的 LCG：同一段弧连点两次，水珠逐帧一致——否则同参数的连拍每张都不一样，
    /// 取证时说不清变化是改动带来的还是随机数带来的。种子与样稿同一个。
    private struct Seeded {
        var state: UInt64 = 20261021
        mutating func next() -> Double {
            state = state &* 1103515245 &+ 12345
            state &= 0x7fff_ffff
            return Double(state) / Double(0x7fff_ffff)
        }
    }

    private func geometry(for b: ReclaimBurst) -> Geometry {
        // 宿主已经 flipped（见 `isFlipped`），这里的点全部留在卡片坐标里，不再翻。
        let cx = b.ring.midX, cy = b.ring.midY
        let scale = max(0.62, b.ring.width / 420)
        var rnd = Seeded()
        var drops: [Drop] = []
        let n = ReclaimTimeline.dropletCount(bytes: b.bytes)
        let span = max(0.002, b.arc.span)
        let trayW = max(1, b.tray.width)
        let trayH = max(1, b.tray.height)
        // 下降走廊：环带外沿再往内收 4 pt。环右沿（420）与账本左沿（444）之间只有
        // 24 pt，而账本那一列从 447 起就是主按钮——贴着环带走这一条，水珠全程压在
        // 数字与按钮之间的空档上，不遮任何一处读数。
        let corridor = b.ring.maxX - 4
        // 篓子这一格此刻在不在视野里。这一问决定水珠的落点，见 `trayInView`。
        let toTray = trayInView(b.tray)
        // 盘心那一档的落点：样稿写的是 `cy + 10*sc`（「盘心下面一点，别压住数字」），那句
        // 在他们那版排版里刚好落在大数下沿之外。我们这一版大数是**压在盘心**上的
        // （实拍 `f612_plain` 量得数字占中心 −28…+22 pt，往下一行读数从 +43 pt 起），
        // 照抄 +8 pt 就是把亮斑按在冒号上。取 +0.20 rOut = 33 pt，正落在两者那条 21 pt 空档里。
        let settleUp = CGPoint(x: cx + 2 * scale, y: cy + (b.ring.width / 2) * 0.20)

        for k in 0..<n {
            var t = (Double(k) + 0.5) / Double(n) + (rnd.next() - 0.5) * 0.10
            t = min(0.95, max(0.05, t))
            let deg = (b.arc.claimFrom + span * t) * 2 * Double.pi
            let rad = Double(b.ring.width / 2)
            let x: CGFloat, y: CGFloat
            if toTray {
                // 起飞点压在**带面里**，不许骑在外沿上：`rOut − band×(0.18…0.82)`。
                // 上一版给的是 `rOut × (0.90…1.04)`，那 4% 直接落在环的轮廓之外，
                // 水珠看着是从环外头冒出来的（他 2026-10-24 那句「圆环跟我们的圆环不是
                // 一个圆心」读到的就是这一截，加上 `addIris` 那圈糊到带外的光）。
                let rr = rad - Double(b.band) * (0.18 + rnd.next() * 0.64)
                x = cx + CGFloat(rr * sin(deg)); y = cy - CGFloat(rr * cos(deg))
            } else {
                // 退回盘心这一档按样稿基座 `gatherBurst` 的散落：`rad×(0.44…1.06)`，
                // 「从孔心到环带，散落得到处都是」。1.06 那一头收在 1.00——带外不许有
                // 水珠，那正是上面「不是同一个圆心」的来处。
                let rr = rad * (0.44 + rnd.next() * 0.56)
                x = cx + CGFloat(rr * sin(deg)); y = cy - CGFloat(rr * cos(deg))
            }
            let tx: CGFloat, ty: CGFloat
            let p1: CGPoint, p2: CGPoint
            if toTray {
                // 落点锁在废纸篓条子的左半段：右半段是数与本钮，溅上去读作「按钮坏了」。
                tx = b.tray.minX + 26 + CGFloat(rnd.next()) * min(110, trayW * 0.22)
                // 落点略高于那一行的中线：篓子这一格只有 30 pt 高，涟漪（24 pt 直径）
                // 居中画会有一圈压到行沿；抬 3 pt 之后整圈都落在条子上，离下面那句
                // 提示还有十几 pt。
                ty = b.tray.minY + trayH * 0.42
                // 前半程就往走廊靠、同时往下掉：先离开环带，再贴边走，
                // 最后一段在篓子上沿横着进去。控制点全压在按钮下沿以下或左边。
                p1 = CGPoint(x: x + (corridor - x) * 0.25, y: y + (ty - y) * 0.62)
                p2 = CGPoint(x: corridor, y: ty - 2)
            } else {
                // 样稿 `?mo=0` 那一档的落点：盘心再往下一点，别压住那个大数（`settleUp`）。
                tx = settleUp.x
                ty = settleUp.y
                // 切向先甩出去一点再被吸进盘心（样稿那句「像水被抽进漏斗」）。
                // 两个控制点取同一个位置：三次贝塞尔在这一档退化成样稿那条二次曲线。
                let push = rad * (0.26 + rnd.next() * 0.20)
                let m = CGPoint(x: x + CGFloat(cos(deg) * push), y: y + CGFloat(sin(deg) * push))
                p1 = m; p2 = m
            }
            let big = rnd.next() < 0.36
            let size = (big ? 20 + rnd.next() * 10 : 11 + rnd.next() * 6) * scale
            drops.append(Drop(start: CGPoint(x: x, y: y),
                              end: CGPoint(x: tx, y: ty),
                              control1: p1,
                              control2: p2,
                              size: CGFloat(size),
                              delay: t * ReclaimTimeline.flightSpread * 0.4
                                  + rnd.next() * ReclaimTimeline.flightSpread * 0.6,
                              duration: ReclaimTimeline.emerge + ReclaimTimeline.bead
                                  + ReclaimTimeline.flight + rnd.next() * 0.22,
                              blurred: rnd.next() < 0.26))
        }

        return Geometry(drops: drops,
                        ringCenter: CGPoint(x: cx, y: cy),
                        ringRadius: b.ring.width / 2,
                        band: b.band,
                        trayRect: b.tray,
                        toTray: toTray,
                        settle: settleUp)
    }

    /// 落点那一格此刻是不是真的在视野里。
    ///
    /// 覆盖层画在 ScrollView 的内容里，视口外那一段会被整个裁掉：他这扇 612 高的窗
    /// 里废纸篓那一格沉在折线以下（2026-10-24 实拍 `f612_plain`，同一趟在 700 高的
    /// `fh700` 里刚好露头），水珠飞出去半秒就被裁掉，读出来的就是他那句
    /// 「还有没有水滴回收的效果了」。所以起飞前先问一次，落在视野外就整趟改落盘心
    /// （样稿 `?mo=0` 自带的那条退路，不是这里新发明的落点）。
    ///
    /// 量的是 AppKit 那层：SwiftUI 没有「滚到哪儿了」这个读数，而裁剪这件事本来就是
    /// `NSClipView` 干的。找不到夹视图就当看得见——宁可沿用样稿的主落点，
    /// 也不要在这条路上多一个会自己改主意的分支。
    private func trayInView(_ tray: CGRect) -> Bool {
        var v: NSView? = superview
        var clip: NSClipView?
        while let c = v {
            if let k = c as? NSClipView { clip = k; break }
            v = c.superview
        }
        guard let clip, let doc = clip.documentView else { return true }
        let mid = convert(CGPoint(x: tray.midX, y: tray.midY), to: doc)
        return clip.documentVisibleRect.contains(mid)
    }

    /// 样稿的三次贝塞尔：控制点压进竖槽，前段慢、后段快。
    private func bezier(_ d: Drop, _ t: Double) -> CGPoint {
        let u = pow(t, 1.28), w = 1 - u
        let x = w * w * w * Double(d.start.x) + 3 * w * w * u * Double(d.control1.x)
            + 3 * w * u * u * Double(d.control2.x) + u * u * u * Double(d.end.x)
        let y = w * w * w * Double(d.start.y) + 3 * w * w * u * Double(d.control1.y)
            + 3 * w * u * u * Double(d.control2.y) + u * u * u * Double(d.end.y)
        return CGPoint(x: x, y: y)
    }

    /// CSS `cubic-bezier(x1,y1,x2,y2)` 的求值：给整趟进度 x，回这条曲线在同一时刻的 y。
    /// 定帧（`render`）这条路没有 CA 播放器来消费 `timingFunction`，只能自己算一次——
    /// 否则取证图上光圈收到哪一档半径、残影吃掉几度，跟真机那一下不是同一格。
    private func ease(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let u = 1 - t
            let bx = 3 * u * u * t * x1 + 3 * u * t * t * x2 + t * t * t
            let dbx = 3 * u * u * x1 + 6 * u * t * (x2 - x1) + 3 * t * t * (1 - x2)
            if abs(dbx) < 1e-9 { break }
            t = min(1, max(0, t - (bx - x) / dbx))
        }
        let u = 1 - t
        return 3 * u * u * t * y1 + 3 * u * t * t * y2 + t * t * t
    }

    /// 真环**看得见的墨**的径向跨度。截面那 11 档的径向端点是 0.073–0.927
    /// （`dump612` 实录：`rIn 117.505 rOut 165.5 带宽 47.995`），带子两端各空着 3.5 pt。
    /// 光圈与残影都按这个宽度描、中心线取带面正中 `rOut − band/2`，于是它们盖住的
    /// 就是那条看得见的带子。按整条 `band` 描的版本里外各大出一圈，屏幕上多出一条
    /// 同心环——他 2026-10-24 那句「动画的圆环跟我们的圆环圆心不是一个」读到的就是这一截
    /// （圆心没偏，偏的是描宽）。
    private func inkWidth(_ g: Geometry) -> CGFloat { g.band * 0.854 }

    /// 带面上那一段弧，用**跟水珠同一套**角度采样：θ 从 12 点起、顺时针，
    /// `x = cx + r·sinθ`、`y = cy − r·cosθ`，`from`/`to` 是整圈的比例。
    ///
    /// 不写 `addArc(clockwise:)`：那个 flag 说的是「在这套坐标系里怎么走」，宿主图层一
    /// 改成 flipped 它画出来就是镜像的那一段——同一段账，弧会跑到环的对面去。采样成折线
    /// 就没有这个岔子：每 1° 一个点，85 pt 的描宽下弦高不到 0.1 px，屏幕上看不出是折线。
    private func bandArc(_ c: CGPoint, _ r: CGFloat, from: Double, to: Double) -> CGPath {
        let path = CGMutablePath()
        let steps = max(2, Int((to - from) * 360))
        for i in 0...steps {
            let th = (from + (to - from) * Double(i) / Double(steps)) * 2 * Double.pi
            let p = CGPoint(x: c.x + r * CGFloat(sin(th)), y: c.y - r * CGFloat(cos(th)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        return path
    }

    // MARK: 真机：装一次发条

    private func animate(_ b: ReclaimBurst) {
        guard layer != nil else { return }
        active += 1
        guard active <= 3 else { active -= 1; return }
        baked = b
        bakedAt = CACurrentMediaTime()
        let mine = gen

        let g = geometry(for: b)
        let now = CACurrentMediaTime()
        let lamp = NSColor(b.tint)

        addGhostArc(g, arc: b.arc, tint: lamp, at: now)
        addIris(g, tint: lamp, at: now + 0.02)
        addShock(g, at: now)
        addShock(g, at: now + 0.096, faint: true)

        var firstLanding = Double.infinity
        var lastLanding = ReclaimTimeline.gatherAt
        for d in g.drops {
            firstLanding = min(firstLanding, ReclaimTimeline.gatherAt + d.delay + d.duration)
            lastLanding = max(lastLanding, ReclaimTimeline.gatherAt + d.delay + d.duration)
            addDrop(d, now: now + ReclaimTimeline.gatherAt, splash: g.toTray)
        }
        if firstLanding.isFinite {
            if g.toTray {
                addTrayFlash(g, tint: lamp, at: now + firstLanding)
            } else {
                addSettleSpark(g.settle, at: now + firstLanding)
            }
        }

        // 这一趟最晚的节点之后把整棵子树摘掉：一次 `removeFromSuperlayer`，
        // 之后不再有任何图层留在屏上。最晚那一格从**真发出去的那几颗**里取，
        // 不再写死 `1.14`——上一版那个常数是水珠的老行程时长，节拍一改
        // （`emerge`+`bead` 长了 0.36 秒）它就把还在飞的最后一颗连图层一起摘了。
        // 盘心那一档还要多留 `hold`：落定那颗亮斑自己就跑 0.9 秒。
        let settle = g.toTray ? lastLanding + ReclaimTimeline.splash
                             : firstLanding + ReclaimTimeline.hold
        let end = max(settle + 0.20, ReclaimTimeline.collapse + 0.12)
        DispatchQueue.main.asyncAfter(deadline: .now() + end) { [weak self] in
            guard let self, mine == self.gen else { return }   // 中途重排过：这一趟的账已经翻篇
            self.active -= 1
            if self.active == 0 {
                self.baked = nil
                if let root = self.layer {
                    root.sublayers?.forEach { $0.removeFromSuperlayer() }
                }
            }
        }
    }

    /// 一颗水珠的材质：左上近白高光、冷蓝身、深底、亮边。真机与定格共用一份，
    /// 免得「截图里好看、点下去变了个人」。
    private func dropMaterial(size: CGFloat) -> CALayer {
        let c = CALayer()
        c.frame = CGRect(x: 0, y: 0, width: size, height: size)
        c.cornerRadius = size / 2
        c.shadowColor = NSColor(red: 0.72, green: 0.84, blue: 1, alpha: 1).cgColor
        c.shadowOpacity = size > 20 ? 0.55 : 0.34
        c.shadowRadius = size * 0.30
        c.shadowOffset = .zero
        // 边是一圈折射出来的亮线，不是深色描边：玻璃在水里的边永远是更亮的那一侧。
        c.borderColor = NSColor(red: 0.86, green: 0.94, blue: 1.0, alpha: 0.62).cgColor
        c.borderWidth = max(0.7, size * 0.045)

        let fill = CAGradientLayer()
        fill.type = .radial
        fill.frame = c.bounds
        fill.cornerRadius = size / 2
        fill.masksToBounds = true
        fill.colors = [
            NSColor(red: 1.00, green: 0.99, blue: 0.95, alpha: 0.99).cgColor,
            NSColor(red: 0.93, green: 0.97, blue: 1.00, alpha: 0.72).cgColor,
            NSColor(red: 0.55, green: 0.73, blue: 1.00, alpha: 0.34).cgColor,
            NSColor(red: 0.06, green: 0.13, blue: 0.26, alpha: 0.58).cgColor,
            NSColor(red: 0.78, green: 0.89, blue: 1.00, alpha: 0.62).cgColor,
            NSColor(red: 1.00, green: 0.99, blue: 0.96, alpha: 0.94).cgColor,
        ]
        fill.locations = [0, 0.12, 0.28, 0.56, 0.82, 1.0]
        // 宿主 flipped（`isFlipped`）之后，图层自己的单位空间也跟着 y 朝下，
        // 这两处方向性的数要跟着镜像，珠子的受光面才还在老位置。
        fill.startPoint = CGPoint(x: 0.30, y: 0.24)
        fill.endPoint = CGPoint(x: 1.0, y: 1.0)
        c.addSublayer(fill)

        // 一颗实心的高光点：玻璃球再透，也得有一个不透明的小核，
        // 否则在蓝色环面上只剩一圈淡淡的冷光，动起来像脏点（2026-10-22 实拍）。
        let spec = CALayer()
        let core = size * 0.26
        // `0.16` 是从**底边**量的：flipped 之后要写成「高 − 底距 − 芯径」。
        spec.frame = CGRect(x: size * 0.20, y: size - size * 0.16 - core,
                            width: core, height: core)
        spec.cornerRadius = core / 2
        spec.backgroundColor = NSColor(white: 1, alpha: 0.92).cgColor
        c.addSublayer(spec)
        return c
    }

    private func addDrop(_ d: Drop, now: CFTimeInterval, splash: Bool) {
        let container = dropMaterial(size: d.size)
        container.position = d.start
        container.opacity = 0
        if d.blurred { container.filters = [CIFilter(name: "CIGaussianBlur",
                                                     parameters: ["inputRadius": 1.8]) as Any] }
        layer?.addSublayer(container)

        // 28 个采样点：最大的一颗现在要飞一秒出头、路程还是那 ~500 pt，眼睛跟着走的时间
        // 翻了快一倍——上一版 16 点在 0.78 秒里跑完，折线糊在速度里看不见，飞慢了才露。
        // 每段从三十几 pt 收到二十 pt 出头，代价是每颗多 12 个关键帧，仍然全是 CA 的事。
        let samples = 28
        let pop = ReclaimTimeline.emerge / d.duration
        let hold = (ReclaimTimeline.emerge + ReclaimTimeline.bead) / d.duration
        var offsets: [NSNumber] = [0, NSNumber(value: pop), NSNumber(value: hold)]
        var points: [CGPoint] = [d.start, d.start, d.start]
        var alphas: [NSNumber] = [0, 1, 1]
        var scales: [NSNumber] = [0.42, 1, 1]
        for q in 1...samples {
            let t = Double(q) / Double(samples)
            let u = pow(t, 1.28)
            offsets.append(NSNumber(value: hold + (1 - hold) * t))
            points.append(bezier(d, u))
            // 先满亮飞完全程的三分之二，最后才收：早淡出的水珠读不出「落进篓子」。
            alphas.append(NSNumber(value: max(0, 1 - pow(u, 3.4) * 1.02)))
            scales.append(NSNumber(value: 1 - 0.50 * pow(u, 1.5)))
        }

        let pos = CAKeyframeAnimation(keyPath: "position")
        pos.values = points.map { NSValue(point: $0) }
        pos.keyTimes = offsets
        pos.calculationMode = .linear
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = alphas
        fade.keyTimes = offsets
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = scales
        scale.keyTimes = offsets

        let group = CAAnimationGroup()
        group.animations = [pos, fade, scale]
        group.duration = d.duration
        group.beginTime = now + d.delay
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        // 模型值停在终点、透明：动画被系统撤掉时不会闪回起点。
        container.opacity = 0
        container.position = d.end
        container.setValue(d.end, forKey: "dw.end")
        container.add(group, forKey: "dw.drop")

        // 起飞也压在 `gatherAt` 之后：这一句是从**现在**起算的，别漏掉那 0.36 秒，
        // 否则涟漪会比水珠先到（上一版就是这么错的）。
        DispatchQueue.main.asyncAfter(deadline: .now() + ReclaimTimeline.gatherAt
                                      + d.delay + d.duration + 0.08) {
            container.removeFromSuperlayer()
            // 琥珀涟漪是「砸进篓子」那一档的落点回执；水珠退回盘心时不许跟过来，
            // 盘心那颗是冷白的 `addSettleSpark`，落点在环上亮一圈暖色读作脏点。
            if splash { self.addSplash(at: d.end) }
        }
    }

    /// 盘心那一档的「落定」：一颗 9 pt 的冷白亮斑，从 1.7 倍收到 0.5 倍再熄掉，
    /// 跑满样稿 `hold` 那 0.9 秒。抄的是样稿 `settleSpark` + `.settle` 那一格——
    /// `?mo=0` 那一档水珠回盘心，落定回执也就跟着回盘心。
    private func addSettleSpark(_ p: CGPoint, at now: CFTimeInterval) {
        let side: CGFloat = 9
        let dot = CALayer()
        dot.frame = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        dot.cornerRadius = side / 2
        dot.shadowColor = NSColor(red: 0.729, green: 0.839, blue: 1.0, alpha: 1).cgColor
        dot.shadowOpacity = 0.55
        dot.shadowRadius = 12
        dot.shadowOffset = .zero

        let fill = CAGradientLayer()
        fill.type = .radial
        fill.frame = dot.bounds
        fill.cornerRadius = side / 2
        fill.masksToBounds = true
        fill.colors = [
            NSColor(red: 1.00, green: 0.99, blue: 0.96, alpha: 0.96).cgColor,
            NSColor(red: 0.81, green: 0.90, blue: 1.00, alpha: 0.52).cgColor,
            NSColor(red: 0.47, green: 0.66, blue: 1.00, alpha: 0.14).cgColor,
            NSColor(red: 0.47, green: 0.66, blue: 1.00, alpha: 0).cgColor,
        ]
        fill.locations = [0, 0.46, 0.72, 1.0]
        fill.startPoint = CGPoint(x: 0.42, y: 0.62)
        fill.endPoint = CGPoint(x: 1.0, y: 0.0)
        dot.addSublayer(fill)
        layer?.addSublayer(dot)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1.7
        grow.toValue = 0.5
        grow.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.4, 1)
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.55, 0]
        fade.keyTimes = [0, 0.26, 1]
        fade.duration = ReclaimTimeline.hold
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = ReclaimTimeline.hold
        group.beginTime = now
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        dot.opacity = 0
        dot.add(group, forKey: "dw.settle")
        // `now` 是第一颗水珠砸进盘心的时刻，排在将来，删除要从「还有多久才开演」起算。
        let wait = max(0, now - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + ReclaimTimeline.hold + 0.10) {
            dot.removeFromSuperlayer()
        }
    }

    private func addSplash(at p: CGPoint) {
        let ring = CAShapeLayer()
        let side: CGFloat = 12
        ring.frame = CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side)
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side),
                           transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor(red: 0.910, green: 0.698, blue: 0.408, alpha: 0.55).cgColor
        ring.lineWidth = 1
        ring.shadowColor = NSColor(red: 0.886, green: 0.647, blue: 0.361, alpha: 1).cgColor
        ring.shadowOpacity = 0.34
        ring.shadowRadius = 5
        ring.shadowOffset = .zero
        layer?.addSublayer(ring)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.25
        grow.toValue = 2.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = ReclaimTimeline.splash
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        ring.opacity = 0
        ring.add(group, forKey: "dw.splash")

        // 两颗回溅的小水珠：证明是「落」而不是「淡出」。
        var rnd = Seeded()
        for i in 0..<2 {
            let bit = CALayer()
            bit.frame = CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)
            bit.cornerRadius = 1.5
            bit.backgroundColor = NSColor(red: 1, green: 0.86, blue: 0.69, alpha: 1).cgColor
            layer?.addSublayer(bit)
            let dx = (i == 0 ? -1 : 1) * CGFloat(10 + 10 * rnd.next())
            // flipped：往上跳是 y 变小，落回篓子沿是 y 变大。
            let up = CGPoint(x: p.x + dx, y: p.y - 12)
            let down = CGPoint(x: p.x + dx * 1.4, y: p.y + 2)
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = [NSValue(point: p), NSValue(point: up), NSValue(point: down)]
            path.keyTimes = [0, 0.55, 1]
            path.duration = 0.46
            path.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.6, 0.4, 1)
            let bitFade = CAKeyframeAnimation(keyPath: "opacity")
            bitFade.values = [0.9, 0.35, 0]
            bitFade.keyTimes = [0, 0.55, 1]
            bitFade.duration = 0.46
            let group2 = CAAnimationGroup()
            group2.animations = [path, bitFade]
            group2.duration = 0.46
            group2.fillMode = .forwards
            group2.isRemovedOnCompletion = false
            bit.opacity = 0
            bit.add(group2, forKey: "dw.bit")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) {
                bit.removeFromSuperlayer()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + ReclaimTimeline.splash + 0.10) {
            ring.removeFromSuperlayer()
        }
    }

    /// 被点的那一段原地被「吃掉」。账已经当场挪到虚线那条弧上了，但眼睛还停在原处：
    /// 这一层残影让那一下读作「这一段被收走」，而不是「弧凭空消失」。
    ///
    /// 抄样稿那一笔 `stroke-dasharray = '0 ' + C`（`.edge` 0.56 s、`cubic-bezier(.45,0,.62,.38)`）：
    /// 可见的那一段从**尾端**往**起端**收缩，收干净为止。上一版画的是整段扇面填 0.34 的墨再整体
    /// 淡出——那是一塊比带子还硬边的平板，压在上面既不像我们这条玻璃带，又多出一个同心形状。
    private func addGhostArc(_ g: Geometry, arc: GaugeRegion, tint: NSColor, at now: CFTimeInterval) {
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.fillColor = nil
        shape.strokeColor = tint.withAlphaComponent(0.34).cgColor
        shape.lineWidth = inkWidth(g)
        shape.path = bandArc(g.ringCenter, g.ringRadius - g.band / 2,
                             from: arc.claimFrom, to: arc.claimTo)
        shape.strokeEnd = 1
        layer?.addSublayer(shape)

        let shrink = CABasicAnimation(keyPath: "strokeEnd")
        shrink.fromValue = 1
        shrink.toValue = 0
        shrink.duration = ReclaimTimeline.collapse
        shrink.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.62, 0.38)
        shrink.beginTime = now
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        shape.strokeEnd = 0
        shape.add(shrink, forKey: "dw.ghost")
        let wait = max(0, now - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait + ReclaimTimeline.collapse + 0.10) {
            shape.removeFromSuperlayer()
        }
    }

    /// 光圈收进盘心：把这一段的环光整体收回一个点，短片里的「收拢」翻成界面语言就是这一下。
    /// 光圈的四档半径与描宽。真机拿它填 `keyTimes`，定帧拿它取同一格——两处必须读同一份，
    /// 且都过一遍 `cubic-bezier(.4,0,.6,1)`，否则取证图拍到的光圈不是点下去那一下的光圈。
    ///
    /// 光圈收拢的四档半径/描宽，抄样稿 `irisCollapse` 的骨架：描宽 `W → W → W*0.50 → 1`、
    /// 关键帧时刻 `0 / 0.16 / 0.62 / 1`、亮度 `0 → 1 → .62 → 0`。
    ///
    /// 半径的基准取真环**带面中心线** `rOut − band/2`（样稿里的 `R` 就是那条弧的描边中心线，
    /// 不是外轮廓）；描宽基准取看得见的墨 `inkWidth`，样稿再乘 0.92。
    /// 前 16% 半径几乎不动、只有亮度从 0 升到 1：光圈先在原地**亮起**再开始收——少了这一拍，
    /// 它从第一帧就在往里走，读起来就是「另一圈东西在动」而不是「我们这条带子在收」。
    ///
    /// 唯一一处不照抄：样稿的末端收到 `R*0.58 → 4 px`，也就是**穿过盘心**。我们这扇盘的大数
    /// 正压在盘心（实拍量得数字占中心 −28…+22 pt），收到 83 pt 那一档时屏幕上是一条亮环套着
    /// 数字——他 2026-10-24 那句「动画的圆环跟我们的圆环圆心不是一个」量的就是这个：圆心实测
    /// 只差 0.3 pt（对位是准的），错的是**半径**，一条比真环小一半的同心亮环。样稿自己在
    /// `irisCollapse` 的注释里也盯过这件事（「不在盘心留一枚亮斑：那个位置正压在 16.0 的『6』上」），
    /// 只是它那一版排版本身躲开了。这里把内收停在井口（带子内沿）之外，让它熄成一根细丝。
    private func irisKeys(_ g: Geometry) -> (radii: [CGFloat], widths: [CGFloat], at: [Double]) {
        let mid = g.ringRadius - g.band / 2
        let rIn = g.ringRadius - g.band
        let ink = inkWidth(g)
        return ([mid, mid * 0.98, rIn * 1.04, rIn * 0.97],
                [ink * 0.92, ink * 0.92, ink * 0.50, 1],
                [0, 0.16, 0.62, 1])
    }

    /// 冲击波的两档直径。起头压在环的**外轮廓**上、只往外走。
    private func shockKeys(_ g: Geometry) -> (small: CGFloat, big: CGFloat) {
        (g.ringRadius * 2, g.ringRadius * 2 * 1.42)
    }

    private func addIris(_ g: Geometry, tint: NSColor, at now: CFTimeInterval) {
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.fillColor = nil
        shape.strokeColor = NSColor(red: 0.635, green: 0.796, blue: 1.0, alpha: 0.92).cgColor
        let keys = irisKeys(g)
        shape.lineWidth = keys.widths[0]
        shape.compositingFilter = "screenBlendMode"
        shape.shadowColor = NSColor(red: 0.549, green: 0.729, blue: 1.0, alpha: 0.55).cgColor
        shape.shadowOpacity = 0.7
        shape.shadowRadius = 8
        shape.shadowOffset = .zero
        layer?.addSublayer(shape)

        let path = CAKeyframeAnimation(keyPath: "path")
        path.values = keys.radii.map { r in
            CGPath(ellipseIn: CGRect(x: g.ringCenter.x - r, y: g.ringCenter.y - r,
                                     width: r * 2, height: r * 2), transform: nil)
        }
        path.keyTimes = keys.at.map { NSNumber(value: $0) }
        let width = CAKeyframeAnimation(keyPath: "lineWidth")
        width.values = keys.widths.map { NSNumber(value: Double($0)) }
        width.keyTimes = keys.at.map { NSNumber(value: $0) }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0.62, 0]
        fade.keyTimes = [0, 0.16, 0.62, 1]
        let group = CAAnimationGroup()
        group.animations = [path, width, fade]
        group.duration = ReclaimTimeline.collapse
        group.beginTime = now
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.6, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        shape.opacity = 0
        shape.add(group, forKey: "dw.iris")
        DispatchQueue.main.asyncAfter(deadline: .now() + ReclaimTimeline.collapse + 0.12) {
            shape.removeFromSuperlayer()
        }
    }

    /// 响指那一圈冲击波。两圈，第二圈晚 96 ms、淡一档——一圈读起来像描边，两圈才像扩散。
    private func addShock(_ g: Geometry, at now: CFTimeInterval, faint: Bool = false) {
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.fillColor = nil
        shape.strokeColor = NSColor(red: 0.839, green: 0.918, blue: 1.0,
                                    alpha: faint ? 0.22 : 0.62).cgColor
        shape.lineWidth = 1
        shape.shadowColor = NSColor(red: 0.549, green: 0.706, blue: 1.0, alpha: 0.34).cgColor
        shape.shadowOpacity = 0.8
        shape.shadowRadius = 12
        shape.shadowOffset = .zero
        layer?.addSublayer(shape)

        // 起头压在环的外轮廓上、只往外走。上一版从 `0.94 rOut` 起，也就是从带面**里面**
        // 起——头几帧那圈冲击波藏在那条带子底下，眼睛先看到环亮了一下、才看到有圈东西
        // 出去，那一拍就散了。
        let keys = shockKeys(g)
        let path = CAKeyframeAnimation(keyPath: "path")
        path.values = [keys.small, keys.big].map { side in
            CGPath(ellipseIn: CGRect(x: g.ringCenter.x - side / 2, y: g.ringCenter.y - side / 2,
                                     width: side, height: side), transform: nil)
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, faint ? 0.55 : 0.92, 0]
        fade.keyTimes = [0, 0.10, 1]
        let group = CAAnimationGroup()
        group.animations = [path, fade]
        group.duration = ReclaimTimeline.shock
        group.beginTime = now
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.82, 0.24, 1)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        shape.opacity = 0
        shape.add(group, forKey: "dw.shock")
        // `now` 可能在未来（第二圈晚 96 ms），排删除要从「还有多久才开演」起算。
        let wait = max(0, now - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait
                                      + ReclaimTimeline.shock + 0.12) {
            shape.removeFromSuperlayer()
        }
    }

    /// 废纸篓那一格亮一下：字节落进来的那一下，格子自己得承认收到了。
    private func addTrayFlash(_ g: Geometry, tint: NSColor, at now: CFTimeInterval) {
        let shape = CAShapeLayer()
        shape.frame = bounds
        shape.path = CGPath(roundedRect: g.trayRect.insetBy(dx: -6, dy: -5),
                            cornerWidth: 9, cornerHeight: 9, transform: nil)
        shape.fillColor = NSColor(red: 0.886, green: 0.647, blue: 0.361, alpha: 0.10).cgColor
        shape.strokeColor = NSColor(red: 0.886, green: 0.647, blue: 0.361, alpha: 0.46).cgColor
        shape.lineWidth = 1
        layer?.addSublayer(shape)

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.18, 1]
        let group = CAAnimationGroup()
        group.animations = [fade]
        group.duration = ReclaimTimeline.trayFlash
        group.beginTime = now
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        shape.opacity = 0
        shape.add(group, forKey: "dw.tray")
        let wait = max(0, now - CACurrentMediaTime())
        DispatchQueue.main.asyncAfter(deadline: .now() + wait
                                      + ReclaimTimeline.trayFlash + 0.12) {
            shape.removeFromSuperlayer()
        }
    }

    // MARK: 截图：钉一格

    /// `DISKWISE_FLIGHT=<0~1>`：0 = 水珠刚在带面上冒头，0.5 = 长满并钉住之后飞到半路，
    /// 1 = 已落进废纸篓。建节点、不装发条；这张图拍完就拆，连拍与静帧判定都不受影响。
    private func render(_ b: ReclaimBurst, phase: CGFloat) {
        guard let root = layer else { return }
        let g = geometry(for: b)
        let lamp = NSColor(b.tint)
        let p = Double(min(1, max(0, phase)))

        /// 一颗水珠「起飞前」在它自己那条时间轴里占的比例。真机把这一拍写进
        /// `keyTimes`（`addDrop` 里 `[0, pop, hold]` 三个点全钉在 `d.start`），
        /// 定帧这边必须吃同一个式子——否则取证图拍的是「已经在飞」，点下去看到的是
        /// 「还在长」，那两张图就再也不是一回事了。
        func sit(_ d: Drop) -> Double {
            (ReclaimTimeline.emerge + ReclaimTimeline.bead) / d.duration
        }
        /// `phase` 是整趟的归一进度。先换成**秒**，再让每个节点按它在真机 `animate`
        /// 里自己的起止时间摆：残影弧 0→`collapse`，光圈 0.02→0.02+`collapse`，
        /// 两圈冲击波 0 与 0.096 起、各跑 `shock`，水珠 `gatherAt`+delay→+duration。
        /// 上一版直接拿 `p` 当每颗水珠自己的进度、又整个跳过光圈，于是取证图上没有
        /// 「环收拢」那一拍，水珠却已经在半路——拿这张图回答「点下去看到什么」是答错的。
        /// 时间轴是真的；残影与光圈那两条 easing 曲线由 `ease` 自己算过一遍，
        /// 与真机挂在 CA 上的 `CAMediaTimingFunction` 是同一条曲线。水珠那两档仍按线性取。
        let landAt = g.drops.map { ReclaimTimeline.gatherAt + $0.delay + $0.duration }
        let firstLanding = landAt.min() ?? ReclaimTimeline.gatherAt
        let settleEnd = g.toTray
            ? (landAt.max() ?? ReclaimTimeline.gatherAt) + ReclaimTimeline.splash
            : firstLanding + ReclaimTimeline.hold
        let total = max(ReclaimTimeline.collapse + 0.12, settleEnd + 0.20)
        let sec = p * total

        func key(_ values: [Double], _ times: [Double], _ t: Double) -> Double {
            let t = min(1, max(0, t))
            for i in 1..<values.count where t <= times[i] {
                let w = (t - times[i - 1]) / max(1e-6, times[i] - times[i - 1])
                return values[i - 1] + (values[i] - values[i - 1]) * w
            }
            return values.last ?? 0
        }
        func circle(_ r: CGFloat) -> CGPath {
            CGPath(ellipseIn: CGRect(x: g.ringCenter.x - r, y: g.ringCenter.y - r,
                                     width: r * 2, height: r * 2), transform: nil)
        }

        // 残影弧：与真机同一个墨宽、同一条 cubic-bezier(.45,0,.62,.38)——
        // 可见段从尾端往起端收缩到 0，不是整块平板淡出。
        let gt = sec / ReclaimTimeline.collapse
        if gt < 1 {
            let ghost = CAShapeLayer()
            ghost.frame = bounds
            ghost.fillColor = nil
            ghost.strokeColor = lamp.withAlphaComponent(0.34).cgColor
            ghost.lineWidth = inkWidth(g)
            let span = (b.arc.claimTo - b.arc.claimFrom)
                * (1 - ease(0.45, 0, 0.62, 0.38, gt))
            if span > 0.0001 {
                ghost.path = bandArc(g.ringCenter, g.ringRadius - g.band / 2,
                                     from: b.arc.claimFrom, to: b.arc.claimFrom + span)
                root.addSublayer(ghost)
            }
        }

        // 光圈收进盘心：与真机共用 `irisKeys`，所以定帧里这一圈盖住的就是那条带子。
        let ik = irisKeys(g)
        let it = (sec - 0.02) / ReclaimTimeline.collapse
        if it > 0, it < 1 {
            let ie = ease(0.4, 0, 0.6, 1, it)
            let iris = CAShapeLayer()
            iris.frame = bounds
            iris.fillColor = nil
            iris.strokeColor = NSColor(red: 0.635, green: 0.796, blue: 1.0, alpha: 0.92).cgColor
            iris.compositingFilter = "screenBlendMode"
            iris.shadowColor = NSColor(red: 0.549, green: 0.729, blue: 1.0, alpha: 0.55).cgColor
            iris.shadowOpacity = 0.7
            iris.shadowRadius = 8
            iris.shadowOffset = .zero
            iris.path = circle(CGFloat(key(ik.radii.map { Double($0) }, ik.at, ie)))
            iris.lineWidth = CGFloat(key(ik.widths.map { Double($0) }, ik.at, ie))
            iris.opacity = Float(key([0, 1, 0.62, 0], [0, 0.16, 0.62, 1], ie))
            root.addSublayer(iris)
        }

        // 两圈冲击波，第二圈晚 96 ms、淡一档。
        let sk = shockKeys(g)
        let skSide = [Double(sk.small), Double(sk.big)]
        for (start, faint) in [(0.0, false), (0.096, true)] {
            let st = (sec - start) / ReclaimTimeline.shock
            guard st > 0, st < 1 else { continue }
            let shock = CAShapeLayer()
            shock.frame = bounds
            shock.fillColor = nil
            shock.lineWidth = 1
            shock.path = circle(CGFloat(key(skSide, [0, 1], st)) / 2)
            let a = (faint ? 0.22 : 0.62) * key([0, faint ? 0.55 : 0.92, 0], [0, 0.10, 1], st)
            shock.strokeColor = NSColor(red: 0.839, green: 0.918, blue: 1.0, alpha: a).cgColor
            root.addSublayer(shock)
        }

        // 水珠：与真机同一条曲线、同一个时间→行程映射（`pow(t, 1.28)`），
        // 起飞前那一拍也吃同一个 `sit`。定格图拍的必须是点下去真会发生的那一格。
        for d in g.drops {
            let dt = (sec - ReclaimTimeline.gatherAt - d.delay) / d.duration
            guard dt < 1 else { continue }
            let pop = ReclaimTimeline.emerge / d.duration
            let s = sit(d)
            let q = max(0, min(1, (dt - s) / max(1e-6, 1 - s)))
            let u = pow(q, 1.28)
            let alpha: Double
            let scale: Double
            if dt <= 0 {
                alpha = 0
                scale = 0.42
            } else if dt < pop {
                alpha = dt / pop
                scale = 0.42 + 0.58 * alpha
            } else {
                alpha = max(0, 1 - pow(u, 3.4) * 1.02)
                scale = 1 - 0.50 * pow(u, 1.5)
            }
            guard alpha > 0.004 else { continue }
            let container = dropMaterial(size: d.size * CGFloat(max(0.32, scale)))
            container.position = bezier(d, u)
            container.opacity = Float(alpha)
            root.addSublayer(container)
        }

        // 落点：先到的那颗砸出涟漪，废纸篓那一格在第一批落定之后亮一下。
        // 盘心那一档两样都不画——涟漪的暖色是篓子沿上的回执，那颗冷白亮斑才是盘心的。
        if g.toTray {
            for d in g.drops {
                let landed = ReclaimTimeline.gatherAt + d.delay + d.duration
                let sp = (sec - landed) / ReclaimTimeline.splash
                guard sp > 0, sp < 1 else { continue }
                let side: CGFloat = 12 * CGFloat(0.25 + 2.25 * sp)
                let splash = CAShapeLayer()
                splash.frame = CGRect(x: d.end.x - side / 2, y: d.end.y - side / 2,
                                      width: side, height: side)
                splash.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side),
                                     transform: nil)
                splash.fillColor = nil
                splash.strokeColor = NSColor(red: 0.910, green: 0.698, blue: 0.408,
                                             alpha: 0.55 * (1 - sp)).cgColor
                splash.lineWidth = 1
                root.addSublayer(splash)
            }
        }
        let fp = (sec - firstLanding) / (g.toTray ? ReclaimTimeline.trayFlash
                                                 : ReclaimTimeline.hold)
        if fp > 0, fp < 1 {
            let flash = CAShapeLayer()
            if g.toTray {
                flash.frame = bounds
                flash.path = CGPath(roundedRect: g.trayRect.insetBy(dx: -6, dy: -5),
                                    cornerWidth: 9, cornerHeight: 9, transform: nil)
                let k = key([0, 1, 0], [0, 0.18, 1], fp)
                flash.fillColor = NSColor(red: 0.886, green: 0.647, blue: 0.361,
                                          alpha: 0.16 * k).cgColor
                flash.strokeColor = NSColor(red: 0.886, green: 0.647, blue: 0.361,
                                            alpha: 0.46 * k).cgColor
                flash.lineWidth = 1
            } else {
                // 与真机 `addSettleSpark` 同一个落点、同一格：1.7 倍收到 0.5 倍、亮到 .55 再熄。
                let k = key([0, 0.55, 0], [0, 0.26, 1], fp)
                let side = 9 * CGFloat(1.7 + (0.5 - 1.7) * fp)
                flash.frame = CGRect(x: g.settle.x - side / 2,
                                     y: g.settle.y - side / 2,
                                     width: side, height: side)
                flash.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: side, height: side),
                                    transform: nil)
                flash.fillColor = NSColor(red: 0.98, green: 0.99, blue: 1.0, alpha: k).cgColor
                flash.shadowColor = NSColor(red: 0.729, green: 0.839, blue: 1.0, alpha: 1).cgColor
                flash.shadowOpacity = Float(k)
                flash.shadowRadius = 12
                flash.shadowOffset = .zero
            }
            root.addSublayer(flash)
        }
    }
}
