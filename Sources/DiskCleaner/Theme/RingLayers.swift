import SwiftUI
import AppKit
import DiskCleanerCore

// ── 环的绘制层：把 `RingStyle` 那一份数画到 `GaugeLayout` 那一份几何上 ──
//
// 从 `SweepRing` 搬出来的那 300 行，搬的过程要求**逐字节不变**（六皮快照 md5 一致）。
// 搬完之后的分工是这样的：
//
//   Core `GaugeLayout`  → 段↔画面、落点↔段（谁能被点，只有它说了算）
//   `RingStyle`         → 材质：几档亮度、洇多远、哪个色相当灯
//   `RingLayers`（这里）→ 把上面两者合起来的一帧画面，纯绘制，一律不接事件
//   `SweepRing`         → 状态机（扫描进度、呼吸相位、上膛）、事件层、无障碍
//
// 这里**没有任何一处** `.onHover`／`.onContinuousHover`／手势：环上唯一的悬停追踪层是
// `SweepRing.ringHitLayer`（那条 NSTrackingArea 的教训记在它身上）。往这里加事件，
// 「无论点哪儿都是左上角有反应」那个 bug 就原地复活。
//
// 同理，这里也不读 `SnapshotMode`、不读 `reduceMotion`：会呼吸到哪一档、反光转到哪一度、
// 弹不弹，都是外面算好了从 `RingFrame` 递进来的。截图取证钉相位的开关留在视图层。

/// 环上的一**段** = 一块真实的字节。切法在 Core（`ringArcs` / `layout.regions(for:)`），
/// 这里只把弧配回它那一格的账。
///
/// `arc` 原样留着：画的是 `from`/`to`，命中层比的是 `claimFrom`/`claimTo`，少一处都错。
struct RingSlice {
    var arc: GaugeRegion
    var seg: GaugeSegment
    var from: CGFloat { CGFloat(arc.from) }
    var to: CGFloat { CGFloat(arc.to) }
    var span: CGFloat { CGFloat(arc.span) }
}

/// 画一帧环要的全部输入：几何 + 材质 + 此刻的状态。只读，不改。
///
/// 半径**不**从外面传：`band`/`rIn`/`rOut` 一律由这里的 `layout` 现算。这不是省参数，
/// 是「画在 A 半径上、点算在 B 半径上」唯一的防呆——形状一换，两边必须一起动，
/// 而它们动的代价是第二下点击搬错目录。
struct RingFrame {
    var style: RingStyle = .shipped
    var layout: any GaugeLayout = RadialGaugeLayout()
    var theme: Theme
    var isDark: Bool
    var diameter: CGFloat
    /// 0…1，入场那 0.9 秒里画出来的比例。弧是压缩着画的，落点和绘制都吃它。
    var reveal: CGFloat = 1
    /// 上了膛的那条弧（`GaugeSegment.path`，或 `SweepRing.armAll`）。
    var armed: String? = nil
    /// 上膛脉冲此刻在哪一档（真机由 `repeatForever` 来回，截图钉死）。
    var pulse: Bool = false
    /// 预演那几秒（按住空格）：整圈「全部清空之后」那一档。
    /// 会搬走的那几段退到后面，主角让给带心线上那截绿光弧（`gainArc`）。
    var previewing: Bool = false
    /// 内孔那团光此刻怎么动。**动与不动、动到哪一档，由视图层算好递进来**：
    /// 这里只管照着装发条（`CALoopView`），不读 `reduceMotion`、也不读截图开关。
    var halo: HaloMotion = .still(level: 1, scale: 1)
    /// 环上反光要不要绕圈。真机交给 Core Animation；截图/连拍钉住相位，走静态那条。
    var glintSpins: Bool = false
    /// 反光绕一圈的秒数（原型 9 秒）。
    var glintPeriod: Double = 9
    /// 扫描期那道光束要不要绕圈。和 `glintSpins` 同一分界：真机交给图层，截图钉相位。
    var scanBeamSpins: Bool = false

    /// 内孔那团光的两种命：钉在一档，还是交给 Core Animation 在 lo↔hi 之间来回。
    enum HaloMotion: Equatable {
        case still(level: Double, scale: CGFloat)
        /// `period` 是**单程**秒数（lo→hi），返回由 CA 的 `autoreverses` 走完。
        case breathe(lo: Double, hi: Double, scaleAmp: CGFloat, period: Double)
    }

    private var canvas: GaugeCanvas {
        GaugeCanvas(width: Double(diameter), height: Double(diameter))
    }
    /// 环带厚度：绘制和命中**同源**的那个数。
    var band: CGFloat { CGFloat(layout.thickness(of: canvas)) }
    /// 环外沿。光层的每一档都按这三条线定位，不按「框的百分比」。
    var rOut: CGFloat { diameter / 2 }
    var rIn: CGFloat { diameter / 2 - band }
    /// 这一屏的光源。
    var lamp: Color { RingMaterial.lamp(theme.palette.tint, style) }

    /// 这一格算不算「已经上膛」。`armAll` 时动得了的弧一起描边：
    /// 主按钮那一下要动的是整圈里所有能搬的，只亮一条弧是在报假账。
    func isArmed(_ seg: GaugeSegment) -> Bool {
        guard let armed, seg.reclaim > 0 else { return false }
        return armed == SweepRing.armAll || armed == seg.armKey
    }
}

// MARK: - 永续循环的宿主

/// 一条**永续**循环（余晖呼吸、环上反光）的宿主：画面由 SwiftUI 画一次，
/// 之后每一帧交给 Core Animation 的渲染服务器去算。
///
/// 为什么不能再用 `withAnimation(...repeatForever)`：那是 SwiftUI 自己的动画，
/// 每一帧都要在主线程重算视图树、把整扇窗过一遍布局。2026-10-22 的 `sample` 里，
/// 总览静置时每秒 60 次出现的
/// `UC::DriverCore::continueProcessing → CA::Transaction::commit → NSDisplayCycleFlush
/// → NSWindow layoutIfNeeded → _layoutSubtreeWithOldSize` 就是它发起的。
/// 把内孔呼吸和环上反光两条都摘掉，主线程常驻从 17–20% 掉到 1.7%（p99 不动）；
/// 只摘一条，另一条照样把这条 60 Hz 的更新循环续上——所以两条都搬到了这里。
///
/// 旋转、透明度、缩放都是 Core Animation 自己会算的图层属性：发条装一次，
/// 之后主线程一帧都不碰。装的条件是**配方变了**（`CALoopMotion` 就是配方的签名）：
/// 悬停、扫描进度、试穿皮肤引起的 SwiftUI 更新不许把反光打回 0°。
/// 一条永续循环的配方。等值即「同一支舞」：它不变就不重装发条。
struct CALoopMotion: Equatable {
    /// 秒/圈；nil = 不转。
    var spinPeriod: Double? = nil
    /// 单程（lo→hi）秒数；nil = 不呼吸。
    var breathPeriod: Double? = nil
    var breathLo: Double = 1
    var breathHi: Double = 1
    /// 缩放呼吸的振幅；0 = 只呼吸透明度（静皮）。
    var breathScaleAmp: CGFloat = 0
}

struct CALoopView<Content: View>: NSViewRepresentable {
    var motion: CALoopMotion
    /// 环的直径：宿主按「直径 + 两侧 bleed」报尺寸。
    var side: CGFloat
    /// `blur` 会洇出 frame；宿主留出这一段，否则光的边会被裁成一条直边。
    var bleed: CGFloat = 0
    /// 这一帧长什么样。只有它（或尺寸）变了才重画：悬停、扫描进度引起的 SwiftUI 更新
    /// 到这里只比一次字符串，不会把那张图重算一遍。
    var artKey: String = ""
    /// 仅取证（`DISKWISE_RING_SPIN=on`）：把自转钉在某一相位，度。
    /// nil = 照常转。真机永远走 nil，这一格只为把图层那条路拍成静图。
    var frozenAngle: Double? = nil
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> CALoopHost {
        let host = CALoopHost()
        host.apply(motion: motion, frozenAngle: frozenAngle)
        host.setArt(content(), side: side + 2 * bleed, key: artKey)
        return host
    }

    func updateNSView(_ host: CALoopHost, context: Context) {
        host.apply(motion: motion, frozenAngle: frozenAngle)
        host.setArt(content(), side: side + 2 * bleed, key: artKey)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CALoopHost,
                      context: Context) -> CGSize? {
        CGSize(width: side + 2 * bleed, height: side + 2 * bleed)
    }
}

/// `CALoopView` 的宿主。画面用 `ImageRenderer` 光栅化一次，之后旋转/呼吸只在
/// **我们自己造的**那一层 `art` 上做。
///
/// 为什么不把 SwiftUI 内容放进 `NSHostingView`：视图的 backing layer 归 AppKit 管，
/// 写上去的 `transform` 会在下一次布局被抹平。2026-10-23 实测：相位钉 110° 与 230°
/// 各拍一张，两张在环带内逐像素相同、亮度停在渐变自己的 0°——光画出来了，但一寸没转。
/// 换成自己造的 `CALayer` 才能在渲染服务器上转，AppKit 不碰它。
final class CALoopHost: NSView {
    private let art = CALayer()
    private var artKey = ""
    private var artSide: CGFloat = 0
    private var installed: CALoopMotion?
    private var installedFrozen: Double?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        art.masksToBounds = false
        art.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer?.addSublayer(art)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CALoopHost is code-only") }   // l10n-scan: skip

    /// 转起来之后不能再用 `frame` 摆位：`frame` 是由 bounds/position/transform 反推的，
    /// 带旋转时写它会算歪。只写 bounds 与 position（正中）。
    private func syncArtFrame() {
        let b = bounds
        art.bounds = CGRect(origin: .zero, size: b.size)
        art.position = CGPoint(x: b.midX, y: b.midY)
    }

    override func layout() {
        super.layout()
        syncArtFrame()
    }

    /// 宿主尺寸是 SwiftUI 直接给的，`layout()` 不保证先跑；尺寸一到就同步。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncArtFrame()
    }

    /// 环上的事件全归 `SweepRing.ringHitLayer`：这里只是垫在背景里的一层光，
    /// 不许挡在鼠标前面（NSView 不认 SwiftUI 的 `allowsHitTesting`）。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 把这一帧画成一张图。`side` = 直径 + 两侧 bleed，与 `sizeThatFits` 报的尺寸同一个数。
    func setArt<Content: View>(_ content: Content, side: CGFloat, key: String) {
        guard key != artKey || side != artSide, side > 1 else { return }
        let scale = max(2, window?.backingScaleFactor ?? 2)
        let renderer = ImageRenderer(content: content.frame(width: side, height: side))
        renderer.scale = scale
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return }
        artKey = key
        artSide = side
        art.contentsScale = scale
        art.contents = image
        syncArtFrame()
    }

    func apply(motion: CALoopMotion, frozenAngle: Double? = nil) {
        guard motion != installed || frozenAngle != installedFrozen else { return }
        installed = motion
        installedFrozen = frozenAngle
        install(motion: motion, frozenAngle: frozenAngle)
    }

    private func install(motion: CALoopMotion, frozenAngle: Double?) {
        let layer = art
        for key in ["dw.spin", "dw.breath-opacity", "dw.breath-scale"] {
            layer.removeAnimation(forKey: key)
        }

        // 模型值 = 静下来该停的那一档：动画被撤掉（减弱动态效果、截图）时不会闪一下满亮。
        layer.opacity = motion.breathPeriod == nil ? 1 : Float(motion.breathLo)
        let amp = motion.breathPeriod == nil ? 0 : motion.breathScaleAmp
        var transform = amp > 0 ? CATransform3DMakeScale(1 - amp, 1 - amp, 1)
                                : CATransform3DIdentity

        if let period = motion.spinPeriod {
            // 起始相位：取证钉在 `frozenAngle` 那一格，真机从**正上方**起转（同一套读数：
            // 0 = 正上方、顺时针增大）。喂进来的画面一律把峰值画在渐变自己的 0°（三点钟），
            // 所以这里统一减 90 换算。
            //
            // 2026-10-23 实拍订正：扫描光束那一路曾经把 `-90` 提前烤进画面里，于是这里
            // 又减了一次 90 —— `DISKWISE_SCAN_BEAM=0` 拍出来那道光落在正左方，四张连拍
            // 全部差 180°。换算只许有一处做。
            let deg = frozenAngle ?? 0
            let clockwise = ((deg - 90).truncatingRemainder(dividingBy: 360) + 360)
                .truncatingRemainder(dividingBy: 360)
            // 静态那条路（`orbitGlint` 的 `rotationEffect(angle - 90)`）是 SwiftUI 的
            // 顺时针角；AppKit 图层 y 向上，负角才是顺时针，所以这里取负。
            // 取证那一档写的是**模型值**而不是 `speed=0`+`timeOffset`：早先那么停动画，
            // 实测钉 110° 与 230° 拍出来逐像素相同——相位根本没吃进去。
            let rad = -clockwise * .pi / 180
            if frozenAngle == nil {
                let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                spin.fromValue = rad
                spin.toValue = rad - 2 * Double.pi
                spin.duration = period
                spin.repeatCount = .infinity
                spin.timingFunction = CAMediaTimingFunction(name: .linear)
                layer.add(spin, forKey: "dw.spin")
            }
            transform = CATransform3DConcat(
                CATransform3DMakeRotation(CGFloat(rad), 0, 0, 1),
                transform)
        }
        layer.transform = transform

        guard let period = motion.breathPeriod else { return }
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = motion.breathLo
        breathe.toValue = motion.breathHi
        breathe.duration = period
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(breathe, forKey: "dw.breath-opacity")
        if amp > 0 {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 1 - amp
            scale.toValue = 1 + amp
            scale.duration = period
            scale.autoreverses = true
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(scale, forKey: "dw.breath-scale")
        }
    }
}

/// 井口**往外**那一圈墨/蓝的落点：一个从 `inner` 到 `outer` 的环带，洞内不在形状里。
/// 配 `RadialGradient(startRadius: inner, endRadius: outer)` 用，衰减曲线见
/// `RingLayers.boreMouthInk`。反向绕两圈 + `eoFill`，中间那块是真的不填。
private struct BoreTail: Shape {
    var inner: CGFloat
    var outer: CGFloat

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addArc(center: c, radius: outer, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        p.addArc(center: c, radius: inner, startAngle: .zero, endAngle: .degrees(360), clockwise: true)
        return p
    }
}

/// 环的每一层绘制。全部是 `some View` 的方法，接一个 `RingSlice` 或什么都不接。
struct RingLayers {
    let frame: RingFrame

    /// 临时量具：`DISKWISE_RINGDIM=off` 只把预演那档的「退到后面」乘子钉回 1
    /// （带子和光都不退），亮弧、流速、盘心与条子都照旧。
    /// 分账用的：一发预演为什么有 >100 ms 的空档，得先分清是这一档退后、还是那截带模糊
    /// 和两道投影的绿弧。2026-10-22 就是用它量出「贵的是换树形，不是画什么」的
    /// （读数记在 `previewDim(_:)`）。规矩同 `RingEdgeLightsBands.offByEnv`。
    static let dimOffByEnv: Bool = {
        (ProcessInfo.processInfo.environment["DISKWISE_RINGDIM"] ?? "").lowercased() == "off"
    }()

    /// 分账量具：`DISKWISE_LIGHTS=halo,bloom,reclaim` 逐个摘掉环上的三层光。
    ///
    /// 规矩同 `RingEdgeLightsBands.offByEnv`（环上任何一层都要有能摘掉它的开关，
    /// 否则它的价永远是糊涂账），但这里要的不是性能价而是**像素价**：2026-10-22 他圈出
    /// 环外那团「会移动的光晕」，只有把三层分别摘掉、各拍一张同尺度图逐半径读数，
    /// 才说得清那圈灰阶是谁抬的——不摘就只能在三笔里猜。
    /// 认不出的名字忽略，空值=全亮，所以正常跑与出厂一致。
    ///
    /// 2026-10-23 又补了几把，全是**画在弧上面**的那几层（`edge/label/hit/gain`，加一把
    /// `warm` 管内侧那道暖沿）。逼出来的是 `差距盘点.md` §3.6 第 2 条那条单弧残差：
    /// 三条 hot 弧喂进截面的颜色、档数、首末档、opacity 在运行时打印里**逐字节相同**
    /// （`DISKWISE_SLICE_DUMP=1`），弧上却读成两条平台（0–100° 是 98、134–256° 是 153）。
    /// 老七个键摘完之后那条差一格不动，而弧上面还剩「线框与亮丝、弧上数、事件层、
    /// 预演那截、顶光竖向坡道」没被任何开关管过——不摘就没法把这条差从它们里挑出来。
    ///
    /// **这批已经结案**：`shade`（层内旧名 `topShade`）一把就把它抬回来了——r203
    /// 98.7 → 149.0，样稿同一片是 148.0。那一层不是坡道而是按弧整条一致的墨，
    /// 已经连着配置一起删掉，所以 `shade` 现在不再摘任何东西（写了也不报错）。
    /// 弧自己身上只剩 `warm`（内侧那道暖沿）还值得一摘：账见 §3.6 第 1 条，
    /// 按亮带对齐之后是带内半支偏暗、起头晚 1 pt、彩度剖面是平的。
    /// （同批的 `edge/label/hit` 三把都试过：读数与 g21 逐格相同，不是它们。）
    ///
    /// 2026-10-24 再补三把：`bands`（段身那一摞，含底纹与上膛描边）、`glint`（常驻反光）、
    /// `beam`（扫描期那道光束 / 入场光）。逼出来的是「扫描中最外层一圈灰不喇唧」那条：
    /// 把当时能摘的十一层全摘掉，r=329 px（164.5 pt，带外沿内侧 1 pt）那一圈仍然是平的
    /// (98,87,75) R−B +23、L 78，12 个方位里只有光束那 46° 被盖住——这条暖沿出自一段
    /// **没有任何开关管过**的绘制。规矩从头就是：加一层就得能摘一层。
    /// **当天结案**：那段绘制是扫描期那一整圈 alpha 0 的占位弧，`visualBand` 现在按段色
    /// alpha 把它拦在门外（算式与实测读数都记在那条注释上）。三把开关留着，`bands` 摘的
    /// 还是同一摞像素。
    static let lightsOff: Set<String> = {
        Set((ProcessInfo.processInfo.environment["DISKWISE_LIGHTS"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }()

    /// 量具：`DISKWISE_SLICE_DUMP=1` 把每条弧**真正喂进截面的那几样**打一行（每种配方一次）。
    ///
    /// 为什么要有它：`~/Library` 那条弧和它两个**同色同 tone** 的兄弟在 r203 上差 0.642 倍，
    /// 四批包都一样、七层光全摘也一样，而且色相两边对得上（R/G、G/B 三个通道等比）——
    /// 数与整条排除清单记在 `gap-audit-2026-10-23/差距盘点.md` §3.6 第 2 条。
    /// 光读代码找不出任何「按弧分叉」的输入，所以只能把运行时真正进 `tube()` 的那份
    /// 颜色、alpha、首末档打出来对：如果两边这几样逐字节相同，那这条差就不在 DiskWise 里。
    static let dumpByEnv: Bool = {
        ProcessInfo.processInfo.environment["DISKWISE_SLICE_DUMP"] == "1"
    }()
    private static var dumped: Set<String> = []

    /// 同一帧，只把「预演那一档」换成 `on`。给**自己订阅 `PreviewSignal`** 的那几颗叶子用。
    ///
    /// 为什么要现兑而不是让 `SweepRing.frame` 直接带上：`frame` 是整棵 `dial` 的输入，
    /// 它一变就等于让轨道、六枚弧上数、命中层、四层光全跟着重算，而按住空格这一下
    /// 该改的只有环带那退后的几段。兑出来的这一份只交给叶子，代价是那几组重画。
    func previewed(_ on: Bool) -> RingLayers {
        guard on != frame.previewing, !Self.dimOffByEnv else { return self }
        var f = frame
        f.previewing = on
        return RingLayers(frame: f)
    }

    private var style: RingStyle { frame.style }
    private var theme: Theme { frame.theme }
    private var isDark: Bool { frame.isDark }
    private var diameter: CGFloat { frame.diameter }
    private var band: CGFloat { frame.band }
    private var rIn: CGFloat { frame.rIn }
    private var rOut: CGFloat { frame.rOut }
    private var lamp: Color { frame.lamp }

    /// `.halo` —— 内孔里那团会呼吸的暖光。
    ///
    /// 原型的算法：`inset:14%` 的方框里一枚 `radial-gradient(circle, rgba(242,180,92,.26),
    /// transparent 62%)`，再 `blur(22px)`。
    ///
    /// 浅皮不能照抄：白纸上 screen 等于没有，往洞里铺一层主色又会让「还能腾出 6.3」那三行
    /// 坐在一片蓝雾上。改成浅皮自己的洗淡底色（`tintSoft`），它本来就是给这种用途准备的。
    ///
    /// 会呼吸的那一档不走 SwiftUI 的 `withAnimation`：画面画一次，亮度与缩放交给
    /// `CALoopView` 的图层动画——见文件顶上那段「永续循环的宿主」。
    @ViewBuilder
    var haloGlow: some View {
        let r = rIn + band * style.haloBiteRatio
        let fill = isDark ? lamp.opacity(style.haloInkOpacity) : theme.palette.tintSoft
        let paint = Circle()
            .fill(RadialGradient(stops: [.init(color: fill, location: 0),
                                         .init(color: fill.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: r))
            .frame(width: r * 2, height: r * 2)
            // 第二层 frame 把**布局尺寸**收回 diameter：这团光画得比方框大，
            // 但不许把整块环撑胖——它挪的是像素，不是卡片里的位置。
            .frame(width: diameter, height: diameter)
            .blur(radius: band * style.haloBlurRatio)
            // 样稿这一层是**普通叠加**，不是 screen：`.beam`/`.orbit`/`.bloom` 三处写了
            // mix-blend-mode:screen，`.halo` 偏偏没写。深皮上给屏混合，孔外沿那圈会被抬到
            // 42.8（样稿 25.8），洞里那三行数就坐进雾里了。
            .blendMode(.normal)

        switch frame.halo {
        case .still(let level, let scale):
            paint
                .opacity(level)
                .scaleEffect(scale)
                .allowsHitTesting(false)
        case .breathe(let lo, let hi, let amp, let period):
            CALoopView(motion: .init(breathPeriod: period, breathLo: lo, breathHi: hi,
                                     breathScaleAmp: amp),
                       side: diameter,
                       // ⚠️ **这里不许留 `bleed`**——它会把环外画成一整圈平色皮带。
                       //
                       // 2026-10-23 他真机（500 G 盘、量完那一态）上环外 3…43 px 是一整圈
                       // **一动不动的平色**：15-105° 是 (93,85,77)、120-165° 是 (102,111,139)、
                       // 178-205° 是 (91,86,84)、211-359° 是 (74,66,59)，断口硬切在 +44 px。
                       // 那四个数逐段等于每条弧自己截面的**最后一档**（`DISKWISE_SLICE_DUMP=1`
                       // 打出来的 `末[u1.00 …]`，七段全对上）。同构建同皮肤同窗口，
                       // `DISKWISE_LIGHTS=halo` 一把就把这一圈摘干净（环外均值 93→14）。
                       // 机制与 `beamArt` 那一条完全相同（见它的注释）：宿主为模糊外溢留出的
                       // 那格 `bleed`，被 `ImageRenderer` 烤成位图时把**近透明像素连 RGB 一起
                       // 钉死**，交给图层再合成上去就是一条不随模糊衰减的平色带，宽度正好等于
                       // `bleed`、外沿正好断在 `rOut + bleed`。这一档 `bleed` = band×0.42 =
                       // 20.2 pt = 40 px，实测断口 370 px = rOut(330)+40 ✓。
                       //
                       // 而**这团光根本不需要那一格**：洞光的半径是 `rIn + band*haloBiteRatio`
                       // = 117.5 + 12.0 = 129.5 pt，模糊尾巴（`band*0.42` = 20.2 pt）只够到
                       // 约 150 pt，而 `rOut` 是 165.5 pt——静态那一路（截图）这些年一直是对的，
                       // 因为它由渲染服务器现算模糊、看得见真实背景，越界的部分本来就是透明的。
                       // 收掉 bleed 是让两条路画同一张脸，不是为了改外观：环带内的截面、
                       // 呼吸的亮度与缩放都照旧（改动前后各拍一张图层路的图对过）。
                       artKey: "halo|\(diameter)|\(band)|\(r)|\(isDark)|\(fill)"
                           + "|\(style.haloBlurRatio)") {
                ZStack { paint.frame(width: diameter, height: diameter) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// 绕着环带的一圈余晖，整圈对称。
    ///
    /// **这一层和样稿不是一对一**（旧注释写着「样稿里不存在」，那句是拿 `grep -i bloom`
    /// 查出来的，而样稿给它起的名字是 `gw`——查错字符串不等于东西不存在）。样稿对应的是
    /// `diskwise-v2.6-crystal.html:1843-1856`：`stroke rgba(104,156,255,.085)`、
    /// `stroke-width BAND*0.50`、`blur(13px)`、`mix-blend-mode: screen`，画在**每段弧自己**的
    /// 位置与弧长上（`dasharray = eLen`，也就是只有动得了那几段有它）。
    /// App 这一层刻意不按段挂：给每段单独挂光，只有会亮的三块外面鼓出一圈，
    /// 整块盘的轮廓就不再是正圆，读者说不清哪里不对但一眼觉得这环画崩了。
    /// 代价由 `bloomReach*` 那两档的实测数管着。
    ///
    /// 每一档停靠点按「带的哪条沿 ± 几个带宽」定位（`BloomStop`），不按框的百分比。
    var bloomGlow: some View {
        let reach = rOut + band * (isDark ? style.bloomReachDark : style.bloomReachLight)
        // 末尾那道 `.clear at 1` 不能省：`RadialGradient` 在最后一个停靠点之后是
        // **把最后那一档颜色平推出去**，不是淡出。省掉的后果实测过一遍——
        // 浅皮环外沿那一圈 0.07 的灯色一路铺到 reach，白纸上 R/G 各掉 3 档、B 不动，
        // 也就是「余晖往外洇的那段」整圈发蓝。六皮逐字节对照当场红。
        let stops: [Gradient.Stop] = (isDark ? style.bloomStopsDark : style.bloomStopsLight).map {
            let base = $0.anchor == .inner ? rIn : rOut
            return .init(color: $0.opacity == 0 ? .clear : lamp.opacity($0.opacity),
                         location: (base + band * $0.offset) / reach)
        } + [.init(color: .clear, location: 1)]
        return Circle()
            .fill(RadialGradient(stops: stops, center: .center, startRadius: 0, endRadius: reach))
            .frame(width: reach * 2, height: reach * 2)
            .frame(width: diameter, height: diameter)
            .blur(radius: band * style.bloomBlurRatio)
            .blendMode(isDark ? .screen : .normal)
            .allowsHitTesting(false)
    }

    /// 盘自身的金属沿（样稿 `.wall`）：**整圈对称画，不按段画**。
    ///
    /// 为什么必须有它：段色只在「这段有字节」时才亮，空闲与虚线那几段的法向末端本来就淡，
    /// 于是环在那几处读成断了口（实测 r 206/209：样稿 141/144，真机只有 63/62）。
    /// 这道沿给的是「一整块盘的外轮廓」，它跟段落颜色无关，所以最暗的那几段也还连在盘上。
    ///
    /// 静态、无动画、渐变只栅格化一次——它不进任何逐帧路径，代价与 `track` 同级。
    var wallRim: some View {
        let w = band * (isDark ? style.wallWidthRatio : style.wallWidthRatioLight)
        let soft = band * (isDark ? style.wallSoftnessDark : style.wallSoftnessLight)
        // 心线半径 = 外沿 − 外探量 − 半个线宽。`wallOuterRatio` 是负的（沿探出环外），
        // 所以这里不用 `.padding`（它吃不下负内缩），改成「画在给足尺寸的框上、再摆回环心」。
        let centerline = rOut - band * style.wallOuterRatio - w / 2
        let rim = Circle()
            .stroke(AngularGradient(gradient: Gradient(stops: style.wallStops.map {
                .init(color: RingMaterial.wall(theme.palette.ink, $0, style, dark: isDark),
                      location: $0.at)
            }), center: .center,
            startAngle: .degrees(style.wallFromDegrees),
            endAngle: .degrees(style.wallFromDegrees + 360)),
            lineWidth: w)
            .frame(width: centerline * 2, height: centerline * 2)
            .frame(width: diameter, height: diameter)
            .opacity(isDark ? style.wallOpacityDark : style.wallOpacityLight)
        // 分两条路，不为别的，只为 `shipped` 那版一分钱开销都不多：`blur(0)` 在 SwiftUI
        // 里照样给这层开一张离屏缓冲，而六皮逐字节对照要求它仍是零改动。
        return Group {
            if soft > 0 {
                rim.blur(radius: soft)
            } else {
                rim
            }
        }
        .allowsHitTesting(false)
    }

    /// 扫描期那圈刻度（样稿 `.ticks`）：180 根、每 2° 一根，每逢 15° 那一根更长更亮。
    ///
    /// **只在「正在量」那几秒挂在树里**，量完当场撤——样稿就是这个开关
    /// （`:2887` 加上、`:2919` 撤掉）。画成一整张 `Canvas` 而不是 180 个 `Path` 视图：
    /// 这一层没有动画，一次栅格化就够，180 颗视图会把这些都记进布局账上。
    var dialTicks: some View {
        let outer = rOut - band * style.tickOuterRatio
        let short = outer - band * style.tickLengthRatio
        let long = outer - band * style.tickMajorLengthRatio
        let minor = RingMaterial.bore(theme.palette.ink,
            isDark ? style.tickOpacityDark : style.tickOpacityLight)
        let major = RingMaterial.bore(theme.palette.ink,
            isDark ? style.tickMajorOpacityDark : style.tickMajorOpacityLight)
        return Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            for d in 0..<180 {
                let isMajor = d % 15 == 0
                let a = CGFloat(d) * .pi / 90
                let tip = isMajor ? long : short
                var p = Path()
                p.move(to: CGPoint(x: c.x + outer * sin(a), y: c.y - outer * cos(a)))
                p.addLine(to: CGPoint(x: c.x + tip * sin(a), y: c.y - tip * cos(a)))
                ctx.stroke(p, with: .color(isMajor ? major : minor),
                           lineWidth: isMajor ? style.tickMajorWidth : style.tickWidth)
            }
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    /// 孔底那口井（样稿 `.bore`）：一块自己的底板 + 顶部一道内阴影 + 井口内外各一线。
    ///
    /// **它盖在弧上面**，这是样稿的 z 序（`ringdrop → wall → 弧 → bore → …`），也正是
    /// 那团洞里的雾本该待的位置：真机的 `haloGlow` 画在洞里、又没人盖它，于是孔底读成
    /// 一片发光的雾（实测 19–25 灰阶），而样稿的孔底是一口 4–8 的沉井——它的 `.halo`
    /// 也在，但被这块不透明底板压住了，只从弧的缝隙里透出一点。
    ///
    /// 盘心那三行数画在这之后（`Components.swift` 的 `dial` 里排最后），所以井是暗底、
    /// 字是亮字，顺序不能倒过来。
    var borePlate: some View {
        let r = rIn * style.boreRadiusRatio
        let stops = isDark ? style.boreStopsDark : style.boreStopsLight
        let inset = band * style.boreInsetWidthRatio
        let plate = ZStack {
            Circle()
                .fill(RadialGradient(stops: stops.map {
                    .init(color: RingMaterial.bore(theme.palette.shadow, $0.opacity),
                          location: $0.at)
                }, center: UnitPoint(x: 0.5, y: 0.32),
                startRadius: 0, endRadius: r * 1.36))
            // 井口顶部那道内阴影：一整圈墨、往下抬 3 px、糊开、最后裁回井口。
            // 方向别搞反：CSS 的 `inset 0 3px` 是把阴影**往下推**，于是墨留在洞的**上沿**，
            // 下沿那一圈整段被裁掉——井口因此是上暗下亮，读者才觉得这个洞有深度。
            Circle()
                .stroke(RingMaterial.bore(theme.palette.shadow,
                    isDark ? style.boreInsetDark : style.boreInsetLight), lineWidth: inset)
                .frame(width: r * 2, height: r * 2)
                .offset(y: band * style.boreInsetOffsetRatio)
                .blur(radius: inset / 2)
                .clipShape(Circle())
            // 深皮是井壁上反出来的近白细光；纸上那圈墨会读成黑线，所以浅皮换白沿。
            Circle()
                .stroke((isDark ? theme.palette.ink : Color.white).opacity(
                    isDark ? style.boreHairlineDark : style.boreHairlineLight), lineWidth: 1)
            // 井口外的 1 px 冷线：圆心框只给到 r*2 会把这道线咬进井里，所以框比井口宽 1 px，
            // 让描边落在 149→150，正是样稿那条外阴影的位置。
            Circle()
                .stroke(theme.palette.tint.opacity(
                    isDark ? style.boreRimDark : style.boreRimLight), lineWidth: 1)
                .frame(width: r * 2 + 1, height: r * 2 + 1)
        }
        .frame(width: r * 2, height: r * 2)
        return ZStack {
            // 顺序照样稿 `.bore` 那五条 box-shadow：写在**前面**的压在上面。样稿把蓝（20 px）
            // 写在黑（40 px）之前，所以 ZStack 里黑要排第一（最底），蓝排第二（贴着井口）。
            boreMouthInk(theme.palette.shadow,
                alpha: isDark ? style.boreOuterGlowDark : style.boreOuterGlowLight,
                sigma: band * style.boreOuterGlowRatio, at: r)
            boreMouthInk(theme.palette.tint,
                alpha: isDark ? style.boreMouthGlowDark : style.boreMouthGlowLight,
                sigma: band * style.boreMouthGlowRatio, at: r)
            plate
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    /// 井口往外的**一圈墨/蓝**（样稿 `.bore` 最后两条 box-shadow）：画成一条从井口沿半径
    /// 衰减的环带，**不是** `.shadow`。三条账都是量出来的：
    ///
    /// 1. CSS 的 `box-shadow` 投的是 **border-box 轮廓**，跟背景色自己的 alpha 无关；SwiftUI 的
    ///    `.shadow` 投的是**渲染之后的 alpha**。真机这块底板只有 0.45–0.78（样稿那块是实色），
    ///    同一句 α .80 的墨落出去要先被底板乘一遍——同一条亮线实测只吃掉 **.16**，样稿吃掉
    ///    **.32**（井撤掉与不撤各拍一张比出来，`/tmp/xline.py`，见差距盘点 §3.2）。
    ///    α 已经就是样稿那句，再抬就是假的，**要改的是画法不是数**。
    /// 2. 想拿实心轮廓补这一刀就得把落在洞里的那半裁掉。`.mask` 里用 `Color.clear` 挖洞
    ///    **挖不出透明**（2026-10-23 踩过：孔底六个半径全读 0.0，井被涂成纯黑，#73 那轮
    ///    修掉的「洞里一团雾」换了个形式回来）。所以不裁形状，直接按半径画尾巴。
    ///
    /// 画法本身反而更准：样稿 `blur 40px` 按 CSS 口径是两倍 σ，但**量到的是样稿成品图上
    /// 那条尾巴的形状**——`/tmp/xink2.py` 拿样稿 `done.png` 与 `.bore` 藏掉的 `dvar/nobore.png`
    /// 逐半径算等效不透明度 α(x) = 1 − 有井/无井（x = 半径 − 井口，蓝段那一列才是可信的，
    /// 底下够亮）：
    ///
    /// | x(pt) | 0 | 2 | 4 | 6 | 8 | 10 | 12 | 16 | 20 | 22 |
    /// |---|---|---|---|---|---|---|---|---|---|---|
    /// | 样稿 α | .30 | .29 | .24 | .21 | .18 | .13 | .11 | .074 | .036 | .024 |
    ///
    /// 这条坡按单支高斯拟出来 **σ ≈ 14**，不是那句 40 px 折算的 20。所以
    /// `boreOuterGlowRatio` 钉 0.23（= 14 / 60.5 带宽），照抄 CSS 口径反而把墨摊到两倍宽、
    /// 井口只压到 .18 而带芯压过头。那条蓝光必须留着且不能省：它按 α .17 / σ 10 在井口
    /// 抵掉 .083，于是 .80 × Φ(0) = .40 落成 .317——**正好是样稿量到的 .30–.32**。
    ///
    /// 第三层原因（这一版真正卡住的那道）：`palette.shadow` 自己带透明度，六套皮差着一个
    /// 量级（graphite .5、midnight .6、aurora .16、dawn .08、inkwash 0）。`Color.opacity(x)`
    /// 是**乘**上去的，所以 g20 井口只读到 α .180 = .80 × .5(皮) × .5(Φ)，而 `.80` 在样稿
    /// 那句里是绝对不透明度。停靠点一律走 `RingMaterial.bore`——借皮肤的色相、不借它的 alpha，
    /// 井底、内壁、刻度三处早就这么办了，这圈墨是第四个用它的地方。
    private func boreMouthInk(_ base: Color, alpha: Double, sigma: CGFloat, at r: CGFloat) -> some View {
        let outer = r + 3 * sigma
        let tail: [(at: Double, k: Double)] = [
            (0, 0.500), (1.0 / 6, 0.309), (1.0 / 3, 0.159), (0.5, 0.067),
            (2.0 / 3, 0.023), (5.0 / 6, 0.006), (1, 0),
        ]
        return BoreTail(inner: r, outer: outer)
            .fill(RadialGradient(stops: tail.map {
                .init(color: RingMaterial.bore(base, alpha * $0.k), location: $0.at)
            }, center: .center, startRadius: r, endRadius: outer),
                style: FillStyle(eoFill: true))
            .frame(width: diameter, height: diameter)
    }


    /// 最外那道发丝（样稿 `.hairline` 的 `inset 0 0 0 .8px`）：**盖在所有东西上面**，
    /// 亮段暗段被它连成同一个正圆。它那 26 px 的外发光不在这里，是 `bloomGlow` 的活。
    var outerHairline: some View {
        let w = band * style.hairlineWidthRatio
        let centerline = rOut - band * style.hairlineOuterRatio - w / 2
        return Circle()
            .stroke(RingMaterial.edge(theme.palette.ink, style, dark: isDark).opacity(
                isDark ? style.hairlineOpacityDark : style.hairlineOpacityLight), lineWidth: w)
            .frame(width: centerline * 2, height: centerline * 2)
            .frame(width: diameter, height: diameter)
            .allowsHitTesting(false)
    }

    /// 轨道：一整块盘的形状由它闭合。空闲那段本身不反光，
    /// 没有这条底，环就会在「空着的地方」断掉，读起来像图没画完。
    ///
    /// 第二条那一根 2 pt 的冷线是给**缝**画的：段与段之间那道没被任何弧盖住的地方，
    /// 原先只有这块半透明底，井口出来直接是一道 42 的暗边，环在那儿读成断了一截。
    /// 样稿那条内沿切面是一整圈连续的（最暗那格也有 98）。数与理由在
    /// `RingStyle.trackBevelDark` 上；挂在轨道里而不是新开一层，因为它只在没弧的地方露出来。
    var track: some View {
        ZStack {
            Circle()
                .stroke(isDark ? theme.palette.ink.opacity(style.trackOpacityDark)
                               : theme.palette.ink.opacity(style.trackOpacityLight),
                        lineWidth: band)
                .padding(band / 2)
            if (isDark ? style.trackBevelDark : style.trackBevelLight) > 0 {
                Circle()
                    .stroke(RingMaterial.bore(theme.palette.ink,
                        isDark ? style.trackBevelDark : style.trackBevelLight),
                            lineWidth: band * style.trackBevelWidthRatio)
                    .padding(band * (1 - style.trackBevelBiteRatio))
            }
        }
    }

    /// 预演那截「全部清空之后多出来的可用」：画在**带心线**上的一整圈绿光，
    /// 从 12 点钟顺时针走到 `fraction` 那么长。
    ///
    /// `fraction` 是整块盘的除法（可回收 ÷ 整盘），不是某一条弧的角范围——这一截说的
    /// 是「走完这一步，这块盘会空出多少」，跟那些字节原来住在哪儿无关。所以它横跨整圈，
    /// 压在退到后面的那几段**上面**（样稿也是这个顺序：那一组 `appendChild` 在最后）。
    ///
    /// 三笔从下到上：糊开的雾（保住「这一截有面积」）、实心弧（说出边界到哪儿）、
    /// 末端那颗点（「多出来的到这里为止」）。一律不吃事件——预演期间点的还是底下那几条弧。
    ///
    /// 生长不由这里发起：`fraction` 是外面一帧一帧递进来的（`RingGainArc.shown`），
    /// 这里只负责把它画出来。
    ///
    /// **只有会走的笔画到 `fraction`，会糊的笔一律铺满、靠透明度跟手**。这不是省事，
    /// 是量出来的：2026-10-22 这一层原先三笔全跟着 `fraction` 动（雾在长、弧带着 shadow、
    /// 点带着 shadow），同场配对（30 s，`DISKWISE_PERF_PREVIEW=1.6`，尾段 22.7 s）
    /// 每次按下空格就是 8–9 格 >100 ms、整段主线程 19.5 %；而把这一层摘掉
    /// （`DISKWISE_GAIN=off`）只剩 1–2 格、10 %。`.blur` 和 `.shadow` 都是渲染服务器
    /// **现算一张位图**，几何一变就得重算——一秒 60 帧就是 60 张。改成走几何不糊、
    /// 糊的不走几何之后，每帧只剩两条 stroke 和一个 `opacity` 数。
    /// 视觉上的取舍：光晕在生长那一秒是「整段渐显」而不是「贴着弧头长」，
    /// 边界仍由实心弧和末端点说清楚。
    func gainArc(fraction: CGFloat) -> some View {
        let radius = rOut - band * style.gainBiteRatio     // 光弧的心线
        let mistW = band * style.gainMistWidthRatio
        let arcW = band * style.gainArcWidthRatio
        let dotR = band * style.gainDotRatio
        let green = theme.palette.safeFG
        let frac = min(max(fraction, 0), 1)
        return ZStack {
            // 雾：**整段铺到位**，长度不动，只把透明度推到 `frac`。
            // 这一层的模糊位图因此只算一次，生长那一秒跟着变的只是一个合成数。
            Circle().trim(from: 0, to: 1)
                .stroke(green.opacity(isDark ? style.gainMistOpacityDark
                                             : style.gainMistOpacityLight),
                        style: StrokeStyle(lineWidth: mistW, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
                .blur(radius: band * style.gainMistBlurRatio)
                // 样稿这一层写的是 `mix-blend-mode: screen`。浅皮上没有 screen 可用，
                // 就只留那一档低的透明度走普通叠加（同 `glint` / 亮丝那条教训：
                // 纸上屏混合抬不出东西，只会把白底抹脏）。
                .blendMode(isDark ? .screen : .normal)
                .opacity(Double(frac))
            // 实心弧：走几何的是它，所以它不带 `shadow`——发光交给上面那层雾。
            Circle().trim(from: 0, to: frac)
                .stroke(green.opacity(isDark ? style.gainArcOpacityDark
                                             : style.gainArcOpacityLight),
                        style: StrokeStyle(lineWidth: arcW, lineCap: .round))
                .frame(width: radius * 2, height: radius * 2)
            // 末端那颗点跟着弧头走：它跟弧吃的是同一个 `frac`，所以生长那 1 秒里
            // 点是**骑在边界上**的，不是先跳到位再等弧追上来。同样不带 `shadow`。
            Circle().fill(RingMaterial.lit(green, dark: isDark, style))
                .frame(width: dotR * 2, height: dotR * 2)
                .frame(width: radius * 2, height: radius * 2, alignment: .top)
                .offset(y: -dotR)
                .rotationEffect(.degrees(Double(frac) * 360))
        }
        .frame(width: diameter, height: diameter)
        .allowsHitTesting(false)
    }

    /// 会搬走的那段自己发光：光晕严格跟着弧的角范围，
    /// 所以暗的那几段旁边是暗的——原型里 12→4 点钟那团暖光就是这么来的。
    ///
    /// **法向画在带子中间那道 0.60 宽的心线上，不铺满带宽**。这一笔是照样稿那层来的
    /// （`diskwise-v2.6-crystal.html:1828`：`r=179.55`、`stroke-width=BAND*0.60`、
    /// `blur(10px)`、`screen`），理由不是「像」，是**糊得出去与糊得出去的区别**：
    /// 源铺满带宽时它的外沿就是环的外沿，再 blur 一下，光必然越过外沿洇进账本那一侧
    /// （那里只有 24 pt 空档），六段洇成共用的雾，`.glint` 骑在雾上走就成了「一团会挪的光」。
    /// 源收到 197.8 之后，带 blur 也够不着 209.55，段与段之间在环外重新是黑的。
    ///
    /// `hovered` 由调用方递给来，不从 `RingFrame` 里读：指着谁每秒能变好几发，
    /// 而它一进 `RingFrame` 就等于让整帧环（轨道、标签、命中层、光）全部重算。
    /// 递进绘制函数之后，只有这一段自己重画。理由同 `visualBand` 末尾那条。
    @ViewBuilder func reclaimGlow(_ s: RingSlice, hovered: String?) -> some View {
        arcSlice(s, width: band * style.reclaimGlowWidthRatio,
                 style: AnyShapeStyle(s.seg.color),
                 outer: band * style.reclaimGlowOuterRatio)
            .blur(radius: band * style.reclaimGlowBlurRatio)
            .opacity(isDark ? style.reclaimGlowDark : style.reclaimGlowLight)
            // 悬停时这团光必须跟着段一起退：段压到 .26 而它不动，
            // 那几段旁边照样亮，等于「退到后面去」这件事只画了一半。
            // 预演那几秒同样跟着退——段压暗了而它不动，环外侧照样鼓出一圈光，
            // 读起来就是「画坏了」。
            // 两档**乘在同一条 opacity 上**，不给预演单开一个 `if`：理由与三版实测数
            // 都记在 `previewDim(_:)` 上。
            .opacity((hovered == nil || hovered == s.seg.label ? 1 : style.dimmedOpacity)
                     * previewDim(s))
            .allowsHitTesting(false)
    }

    /// 预演那几秒这一段的「退到后面」乘子；不在预演、或这段本来收不走 → 1。
    ///
    /// 为什么是乘透明度，而不是照抄样稿的 `filter: brightness() saturate()`，也不是
    /// 「在同一条弧上再压一道黑」：**2026-10-22 三种都实现过，同场配对跑
    /// `DISKWISE_PERF_PREVIEW=1.6`（30 s，尾段 22.7 s，数的是 >100 ms 的格数）**——
    /// 两层滤镜 11 格，压黑 10 和 13 格（复跑），摘掉这一层只剩 1–3 格。
    /// 差别不在**画什么**，在**换树形**：`if` 的两支一切换，六条带子加六团光就是十二个
    /// 子树整个重建一次，那一发 ~130 ms 是重建付的，不是像素付的。乘在本来就在链上的
    /// `.opacity` 上，切换只改一个数——而且静图那条路上这个乘子恒等于 1，
    /// 连「多一个修饰符」都没有，逐字节闸门（`tools/ring-gate.py`）不吃这笔钱。
    /// 深浅两档的数各是多少、为什么浅皮只收到一半，记在 `RingStyle.previewDimOpacity*`。
    private func previewDim(_ s: RingSlice) -> Double {
        guard frame.previewing, s.seg.reclaim > 0, !Self.dimOffByEnv else { return 1 }
        return isDark ? style.previewDimOpacityDark : style.previewDimOpacityLight
    }

    /// 一条弧。`outer` = 弧的**外沿**离环外沿缩进多少（0 = 贴住外沿）。
    ///
    /// 描边压在路径中线上，所以内缩量是 `outer + w/2` 而不是 `outer`：少算半个线宽，
    /// 整条弧就往外越出半个带宽（39pt 的带越出 20pt），把卡片的边啃掉一口——
    /// 上一版的环「画出卡片外」就是这么来的，不是 padding 写错了符号。
    ///
    /// ⚠️ 这层 `.padding` 会把**画布坐标系**一起缩小。所以给弧上色时凡是要按半径定位的
    /// 渐变（横截面、径向光），都必须按 padding 之后的真实内/外沿来算，不能拿 `diameter`
    /// 上的数硬套：这是原型 v2.5 那「外面 30 px 死区」的同一条坑（`objectBoundingBox`
    /// 不吃 stroke），SwiftUI 这边换了个写法照样踩。
    private func arcSlice(_ s: RingSlice, width w: CGFloat, style: AnyShapeStyle,
                          outer: CGFloat = 0, dashed: Bool = false,
                          span: CGFloat = 1) -> some View {
        // `span` < 1 只画这一段的前一截：样稿 `.seg .rec` 的宽度就是
        // `reclaim / value`，亮沿铺到哪儿，说到哪儿为止「这部分我收得走」。
        Circle()
            .trim(from: s.from * frame.reveal,
                  to: (s.from + (s.to - s.from) * min(max(span, 0), 1)) * frame.reveal)
            .stroke(style, style: StrokeStyle(lineWidth: w, lineCap: .butt,
                                              dash: dashed ? frame.style.dashPattern : []))
            .padding(outer + w / 2)
            .rotationEffect(.degrees(-90))
            .animation(theme.animation, value: s.to)
    }

    /// 一**段**环带的像素：底纹、段身、内侧暖沿、上膛描边。只管画，一律不接事件——
    /// 事件全在 `SweepRing.ringHitLayer`，因为「这段弧涂成什么样」和「这一点归谁」
    /// 是两件事。
    @ViewBuilder func visualBand(_ s: RingSlice, hovered: String?) -> some View {
        let hov = hovered == s.seg.label
        let _ = Self.dumpByEnv ? dump(s, hovered: hovered, hov: hov) : ()
        let rod = ZStack {
            if s.seg.dashed {
                // 斜纹底下先铺一层淡的。纯虚线在浅皮上是几条蓝纹夹着空洞，
                // 读起来像这一格漏画了——可这些字节明明**还占着盘**，
                // 空洞恰好说反了。淡底保住面积，斜纹只负责说「换了地方」。
                arcSlice(s, width: band,
                         style: AnyShapeStyle(s.seg.color.opacity(style.dashedUnderlayOpacity)))
            }
            arcSlice(s, width: band, style: arcPaint(s), dashed: s.seg.dashed)
            // 这里原来叠过一道「竖向顶光」（`topShade`：截面之上再压一层从 clear 到黑 0.34 的
            // 竖向渐变）。**2026-10-23 删掉**，两条各自独立的证据：
            // ① 样稿没有这一层——`diskwise-v2.6-crystal.html` 里 `linearGradient` 一个匹配都没有，
            //   段身就是 §3.6 记的那条 `radialGradient`（`gradientUnits=userSpaceOnUse`、同心），
            //   纯径向、零竖向分量。
            // ② 它画出来的也不是「竖向坡道」。`arcSlice` 先把渐变喂进 `.stroke`、之后才
            //   `.padding().rotationEffect(-90°)`，所以轴向跟着一起转了 90°，而
            //   `arcVerticalExtents` 算的是**屏幕**那套 y——两头对不上，每条弧被整条钳到坡道的
            //   某一端。实测（同一片固定角度集，摘掉它 vs 留着）：r195 70.7→105.3、
            //   r203 98.7→149.0（样稿 148.0）、r207 105.3→159.3。倍率 1/(1−0.34) 正好是配置里
            //   那档墨。它一直在替样稿的外沿补一笔它没有的沉，而「上半环亮、下半环沉进带子里」
            //   那句是假话——真机读的是**按弧**均匀，不是按角度连续。
            // 删掉它之后环上按角度变的那一档就没了，所以 `DISKWISE_LIGHTS` 不再有 `shade` 这把。
            // 可回收量：段身**内侧**的一道暖沿。多宽是材质（样稿 EDGE_W = 0.20 band，
            // 见 `RingStyle.crystal`），**多长才是账**——`span = reclaim / value`，
            // 所以这条沿铺到这段弧的哪儿为止，说的就是这段里收得走多少。
            // `reclaim` 为 0 就不画——画了收不走，那一格是在骗人点击。
            // `DISKWISE_LIGHTS=warm` 能单独摘掉它：删掉顶光之后**弧自己身上只剩它一处**是
            // 按段亮在 r149.1–161.3 那片上的（带宽 0.20 band 贴内沿，数记在 `RingStyle.crystal`）。
            // 要还的账在 `差距盘点.md` §3.6 第 1 条（按亮带对齐量，别拿固定角度集那两行——
            // 那两行是量具造的，已经作废）：带内半支真机比样稿暗 11～26 格、比样稿晚 1 pt 起头，
            // 而且彩度剖面方向相反（样稿从带内 +50 爬到带外 +96，真机一路 +48…+54 平着走）。
            // 没有开关就只能把这些归给截面那十档，而那十档是照抄样稿 `tube()` 的。
            if s.seg.reclaim > 0, !Self.lightsOff.contains("warm") {
                arcSlice(s, width: band * style.reclaimEdgeWidthRatio,
                         style: AnyShapeStyle(recEdge(s.seg)), outer: band * style.reclaimEdgeOuterRatio,
                         span: s.seg.value > 0 ? CGFloat(s.seg.reclaim) / CGFloat(s.seg.value) : 1)
            }
            if frame.isArmed(s.seg) {
                // 上膛描的是整段的**轮廓**（外沿 + 内沿各一道），不是把弧盖住：
                // 盖住就把这块弧占多大抹掉了，而人此刻要看的正是那个数。
                Group {
                    arcSlice(s, width: style.armStrokeWidth, style: AnyShapeStyle(theme.palette.ink))
                    arcSlice(s, width: style.armStrokeWidth, style: AnyShapeStyle(theme.palette.ink),
                             outer: band - style.armStrokeWidth)
                }
                .shadow(color: theme.palette.tint.opacity(frame.pulse ? style.armGlowOpacityPeak : style.armGlowOpacityRest),
                        radius: frame.pulse ? style.armGlowRadiusPeak : style.armGlowRadiusRest)
            }
        }
        // 样稿的悬停是**整段一起**反应的：底纹、段身、内侧暖沿、上膛描边同生同灭。
        // 只给段身上色的话，弹出来的那段会甩下三道没跟上的边，读起来像画坏了。
        // `svg.pick .seg{opacity:.26}` / `.seg.on path{transform:scale(1.038)}`：
        // 弹的是整段轮廓，因为 ZStack 的坐标原点就是环心（每条弧都占满 diameter 那一格）。
        // **命中层不吃这个缩放**：它按静止那圈半径算，弹出去的那 3.8% 不会再把
        // 光标「让」给隔壁段——那样会在内沿上来回抖。
        // 悬停与预演两档「退到后面」乘在**同一条** opacity 上：链子的形状不许跟着
        // 人按一下空格而变，理由与三版实测数都记在 `previewDim(_:)`。
        .opacity((hovered == nil || hov ? 1 : style.dimmedOpacity) * previewDim(s))
        .scaleEffect(hov ? style.hoverPopScale : 1)
        // 这一层**不挂隐式动画**，`hovered` 也**不进 `RingFrame`**。
        // 前者：悬停是这一页每秒能来好几发的动作，`.animation(value:)` 会把六条弧的补间
        // 排进同一条事务，每换一段就让整扇窗按动画时长重跑一遍 Auto Layout——2026-10-22
        // 配对实测，留着它时悬停那 18 s 的 p99 是 25.6 ms、>33.4 三次、主线程比静置高 6 个点。
        // 后者：状态一进 `RingFrame`，`SweepRing` 的整个 `dial` 都会跟着重算（轨道、六枚
        // 弧上数、命中层、四层光），`sample` 里那次 670 个样本的 `SweepRing.dial` 就是它。
        // 现在 `hovered` 只从带子的绘制函数这道门口进来，换一段只重画这一段的带子——
        // 「指着谁」本来就该跟手，慢半拍反而不像指着。
        .allowsHitTesting(false)
        // 段色全透明 = 这一格没有话要说，**整段不画**（截面也不画）。
        // 2026-10-24 逼出这一条的是「扫描中最外层一圈灰不喇唧」：扫描期环上是**一整圈**占位弧，
        // 段色写的就是 `.clear`（`OverviewView.scanningAccount`——量完之前环上不该有结论的颜色，
        // 只留暗轨）。但 crystal 的 `tubeArcsOpaque` 先把段色按它自己的 alpha 预合成到卡面、
        // 再把 alpha 钉成 1，于是 `.clear` 走这条路不是「什么都不画」，而是**「拿卡面当棒身」**：
        // 石墨皮 `#16181D` = (22,24,29) 当身子，外沿那两档 `warm = mix(身, #FFD2A2, .34)`
        // 算出来是 **(101,87,74)**，铺满 360° 一整圈。实测 3 点方向 r329 px 读到
        // **(98,87,75)、R−B +23**——差 3 格，符号和彩度都对上，就是这条暖沿本身
        // （12 点那一格正被扫描光束盖着，读不出材质）。拦住这条弧之后同一格是 (40,42,45)、R−B −5。
        // 所以它既不是光晕也不是盘沿：十一层光加上后来补的 `bands` 全摘都摘不掉，
        // 因为「alpha 0 就别上场」这件事当时没人管过。
        if Self.alpha(s.seg.color) > 0 {
            rod
        }
    }

    /// 段色在自己那一格上的 alpha。解析不出来按**不透明**处理：宁可多画一格，
    /// 也不要把一段真有账的弧画没了。只给 `visualBand` 那道门用。
    private static func alpha(_ c: Color) -> Double {
        Double(NSColor(c).usingColorSpace(.deviceRGB)?.alphaComponent ?? 1)
    }

    /// 只给 `dumpByEnv` 用：把这条弧真正喂进截面的那几样打一行。
    ///
    /// 去重键带上了「配方本身」而不是只按 `armKey`：扫描期那几发的 reclaim 还是 0、
    /// tone 全落 neutral、弧也在动，只按名字去重会把量具钉死在**没量完**那一帧上
    /// （2026-10-23 第一次跑就踩了：六条弧全打 `回收 0/…`）。
    private func dump(_ s: RingSlice, hovered: String?, hov: Bool) {
        let alpha = Double(NSColor(s.seg.color).usingColorSpace(.deviceRGB)?.alphaComponent ?? -1)
        let key = "\(s.seg.armKey)|\(s.seg.tone)|\(s.seg.reclaim)|"
            + String(format: "%.3f", alpha) + "|弧\(Int((s.from * 360).rounded()))"
        guard !Self.dumped.contains(key) else { return }
        Self.dumped.insert(key)
        func rgb(_ c: Color) -> String {
            guard let n = NSColor(c).usingColorSpace(.deviceRGB) else { return "解析不出RGB" }  // l10n-scan: skip
            return String(format: "r%.3f g%.3f b%.3f a%.3f",
                          n.redComponent, n.greenComponent, n.blueComponent, n.alphaComponent)
        }
        let stops = RingMaterial.tube(s.seg.color, style,
                                      dimBody: s.seg.tone == .hot || s.seg.tone == .cost,
                                      over: theme.palette.surface)
        let cs = crossStops
        let ext = arcVerticalExtents(s)
        let dim = (hovered == nil || hov ? 1 : style.dimmedOpacity) * previewDim(s)
        print("[slice] \(s.seg.label)  弧 \(String(format: "%.1f–%.1f°", s.from * 360, s.to * 360))"
            + "  tone \(s.seg.tone)  虚线 \(s.seg.dashed)  上膛 \(frame.isArmed(s.seg))  悬停 \(hov)"
            + "  回收 \(s.seg.reclaim)/\(s.seg.value)")
        print("        段色 \(rgb(s.seg.color))   lamp \(rgb(lamp))   截面 \(stops.count) 档"
            + "  首[\(stops.first.map { "u\(String(format: "%.2f", $0.at)) " + rgb($0.color) } ?? "空")]"
            + "  末[\(stops.last.map { "u\(String(format: "%.2f", $0.at)) " + rgb($0.color) } ?? "空")]")
        print("        crossStops \(cs.map { "\($0.count) 档" } ?? "nil（截面上不了）")"
            + "  竖向端点 \(String(format: "%.3f–%.3f", ext.0, ext.1))"
            + "  opacity \(String(format: "%.2f", dim))"
            + "  tubeArcsOpaque \(style.tubeArcsOpaque)  bodyScale \(style.tubeBodyScale)"
            + "  rIn \(rIn) rOut \(rOut) 带宽 \(band)")
    }

    /// 截面可用不可用：**今天线上那一版永远从这儿返回 nil**。
    ///
    /// 少于三档撑不出「亮—暗—亮」那根棒，那是配置写坏了而不是材质朴素，所以宁可退回单弧，
    /// 也不拿着两档硬画出一条谁都不像的带子。
    private var crossStops: [CrossStop]? {
        guard style.crossOn else { return nil }
        let list = isDark ? style.crossDark : style.crossLight
        return list.count >= 3 ? list : nil
    }

    /// 玻璃棒的横截面。
    ///
    /// 换算这一步是整个材质**最容易错、也最先错过**的地方。三条，都是量出来的：
    ///
    /// 1. `.padding(outer + w/2)` 把绘制的坐标空间缩成了 `diameter - band` 那一格。原型那边
    ///    同一个名字叫 `objectBoundingBox` 不含 stroke——v2.5 的带子外半截因此是一条死平色
    ///    （`redesign-v4/MATERIAL.md` 第 1 节，那一条承担了那一轮几乎全部收益）。
    /// 2. **`RadialGradient` 的 `startRadius`/`endRadius` 走的是点，不是包围盒比例**，
    ///    而同一个构造里的 `center: UnitPoint` 走的是包围盒。两边单位不一样，所以别照抄、
    ///    也别"统一换算"。这一条是两次失败换来的：先按 `diameter - band` 除、再按半边长除，
    ///    **两版六皮出图逐字节相同**——只有"两种写法都算出来的半径还比带子小得多、
    ///    整条带落在 `endRadius` 之外"才解释得通，而 `RadialGradient` 越过末尾是
    ///    **把最后一档平推出去**（跟 `.bloom` 同一个脾气），于是截面八档根本没上场：
    ///    深色皮实测截面比 1.06→1.02、带子整体变亮 21、彩度掉 12，读起来像一层起雾的塑料。
    /// 3. 半径直接给 `rIn`/`rOut`（点）之所以安全，是因为 padding 只**平移**不缩放：
    ///    缩小后的那一格仍然同心，从圆心到带子两条沿的实际距离就是 `rIn` 与 `rOut`。
    ///
    /// 于是 stop 的 `location` 恰好等于 `CrossStop.at`（0 = 内沿、1 = 外沿），配置里的数不用换算。
    /// 末尾不需要补 `.clear`：这条渐变铺到 `rOut` 就停，外面那段本来就不在带子里。
    private func crossSection(_ s: RingSlice) -> AnyShapeStyle? {
        let seg = s.seg
        // 深皮 + 这款材质带了混色表 → 走绝对颜色那条路。为什么非绝对不可，记在
        // `RingStyle.TubeStop` 上（灰弧那道冷亮线要 ×3.99，倍率那条被夹在 1）。
        if isDark, !style.tubeStops.isEmpty {
            let stops = RingMaterial.tube(seg.color, style,
                                          dimBody: seg.tone == .hot || seg.tone == .cost,
                                          over: theme.palette.surface)
            if !stops.isEmpty {
                return AnyShapeStyle(RadialGradient(
                    gradient: Gradient(stops: stops.map {
                        .init(color: $0.color, location: $0.at)
                    }),
                    center: UnitPoint(x: 0.5, y: 0.5),
                    startRadius: rIn, endRadius: rOut))
            }
        }
        guard let stops = crossStops else { return nil }
        return AnyShapeStyle(RadialGradient(
            gradient: Gradient(stops: stops.map {
                .init(color: RingMaterial.cross(seg.color, $0), location: $0.at)
            }),
            center: UnitPoint(x: 0.5, y: 0.5),
            startRadius: rIn, endRadius: rOut))
    }

    /// 这一段到底涂什么。规矩只有一句：**彩色只给动得了的弧**。
    ///
    /// 线上那一版里，动得了的那段涂「灯芯」渐变：一头亮一头沉，像一盏灯立在环上。
    /// **它在屏幕上到底朝哪头沉，没量过**——用的那根轴见 `arcVerticalExtents` 上那条账，
    /// 同一支坑已经埋掉过一层（`topShade`，2026-10-23 删）。
    /// 其余三段都不参与配色：洗淡的主色说「系统腾得动、我按不动」，
    /// 中性灰说「这地方占着，但这一屏不解决」，深浅两档灰把量到和没量到分开。
    ///
    /// 但**材质不给谁例外**——截面那一档对所有 `tone` 都上。看图抓到的理由：只给动得了的弧
    /// 做截面的话，同一个环上蓝段是玻璃棒、灰段是平带子，读起来像环上贴了两种材料；
    /// 而「这块能不能动」已经由颜色说完了，不必让材质再说一遍——材质讲的是「这是什么做的」，
    /// 颜色讲的是「这个动得了」，两条轴各管各的，混在一起就两条都读不清。
    /// `crossStops` 为 nil（= 线上那一版）时，上面那条按 `tone` 分档的老规矩原样生效。
    private func arcPaint(_ s: RingSlice) -> AnyShapeStyle {
        let seg = s.seg
        if let cx = crossSection(s) { return cx }
        if seg.tone == .hot || seg.tone == .cost {
            let (top, bottom) = arcVerticalExtents(s)
            return AnyShapeStyle(LinearGradient(
                stops: [.init(color: seg.color.opacity(style.hotHeadOpacity), location: 0),
                        .init(color: RingMaterial.shade(seg.color, style), location: 1)],
                startPoint: UnitPoint(x: 0.5, y: top), endPoint: UnitPoint(x: 0.5, y: bottom)))
        }
        return AnyShapeStyle(seg.color)
    }

    /// 这条弧在「屏幕上」占到的垂直区间，换算成单位坐标（0 = 框顶，1 = 框底）。
    ///
    /// **先记一条没还清的账**：`arcSlice` 是把渐变交进 `.stroke` 之后才
    /// `.padding().rotationEffect(-90°)` 的，而 trim 的 `from = 0` 在**旋转前**那格是 3 点钟。
    /// 也就是说涂色的那根轴跟着转了 90°，这一函数给的却是转完之后（屏幕）的 y。
    /// 2026-10-23 删掉的那层顶光（`topShade`）就是栽在这儿：实测它给每条弧的是**整条一致**的
    /// 一档墨（r203：0–100° 97.2、134–256° 153.0，逐 5° 平在 96.3–100.0），根本不是坡道。
    ///
    /// 现在只剩 `arcPaint` 里非 crystal 那一档还在用它。那一档在屏幕上的实际轴向
    /// **没量过**，别照着「上亮下沉」去调它——六套内置皮肤都点名 `crystal`，
    /// 所以今天用户看不着它，改动要先有一张同尺度图再说。
    private func arcVerticalExtents(_ s: RingSlice) -> (CGFloat, CGFloat) {
        let rf = (diameter / 2 - band / 2) / diameter      // 带中圈的半径 / 框宽
        let steps = max(2, Int((s.to - s.from) * CGFloat(style.arcGradientSampleStepsPerTurn)))
        var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
        for i in 0...steps {
            let a = (s.from + (s.to - s.from) * CGFloat(i) / CGFloat(steps)) * 2 * .pi
            let y = 0.5 - rf * cos(a)                      // from = 0 在正上方
            lo = min(lo, y); hi = max(hi, y)
        }
        return (max(0, lo), min(1, hi))
    }

    /// 内侧那道暖沿：段身再提亮一档，永远跟段同色相（为什么不用主色，
    /// 记在 `reclaimEdgeOpacity` 那段上）。
    private func recEdge(_ seg: GaugeSegment) -> Color {
        RingMaterial.lit(seg.color, dark: isDark, style).opacity(style.reclaimEdgeOpacity)
    }

    /// 弧上直接标数：让环和旁边那列账靠数对位，不必悬停才知道 16.4 是哪一段。
    /// 只标数不标名——最短那段弧只有几十 px，写名字就会出现「为什么这两段没名字」。
    /// 该不该标由外面判（`SweepRing.dial` 里那两条门槛读的是 `style.labelMinSpan`）。
    func arcLabel(_ s: RingSlice) -> some View {
        let deg = Double((s.from + s.to) / 2 * 360 - 90)
        let rad = deg * .pi / 180
        let r = diameter / 2 - band * style.labelBiteRatio
        return Text(arcValueText(s.seg.sizeShown))
            .font(theme.numeric(size: style.labelFontSize, weight: .regular)).monospacedDigit()
            .foregroundStyle(arcNumberColor(s.seg))
            .fixedSize()
            // 不加底。上一版给每个数垫一块卡片色的圆角底，于是六枚数变成六枚
            // 飘在环上的标签，环本身反倒成了背景——原型把底全去掉，数才长在弧上。
            .position(x: diameter / 2 + r * CGFloat(cos(rad)),
                      y: diameter / 2 + r * CGFloat(sin(rad)))
            .opacity(frame.reveal >= 1 ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: frame.reveal)
            .allowsHitTesting(false)
    }

    /// 弧上只写数、不写单位：圆心那格已经写了 GB，旁边那一列账每行都带单位，
    /// 环上再重复六遍会把六枚数挤成一片字。
    /// 但**不到 1 GB 的那段必须把单位写回来**——「512」放在 500 GB 的盘上会被读成 512 GB。
    private func arcValueText(_ shown: String) -> String {
        shown.hasSuffix(" GB") ? String(shown.dropLast(3)) : shown
    }

    /// 弧上那个数的颜色，跟着这一段的档走：亮段配亮字、灰段配灰字。
    private func arcNumberColor(_ seg: GaugeSegment) -> Color {
        switch seg.tone {
        case .hot:   return isDark ? style.labelInkHotDark.color() : style.labelInkHotLight.color()
        case .moved: return theme.palette.tint.opacity(isDark ? style.labelMovedDark : style.labelMovedLight)
        case .washed: return theme.palette.inkSecondary
        case .cost:  return costLabelInk(seg.color)
        case .neutral: return theme.palette.ink.opacity(isDark ? style.labelInkNeutralDark : style.labelInkNeutralLight)
        }
    }

    /// 代价四类的段色在六套皮里深浅不一（浅皮的绿/琥珀/红都压得很深，深皮反而偏亮），
    /// 固定用哪种墨都会有一半皮肤读不清。按段色自己的亮度选黑或白：
    /// 0.55 是 WCAG 对比度的分界附近，也是这四档色相里明暗真正翻面的那一带。
    private func costLabelInk(_ fill: Color) -> Color {
        let ns = NSColor(fill)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return .white }
        let lum = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
        // 这里的墨必须是**绝对**的黑白：深皮的 `ink` 本身是浅色，拿它压在亮绿的段上
        // 正是读不清的那一对。段色是这一档的绝对量，读数也该用绝对的黑白。
        return lum > 0.55 ? .black.opacity(0.82) : .white
    }

    /// 扫描期那两道光：宽光铺在边界**前**面，读数头钉在边界上、亮尾留在身后。
    ///
    /// 两笔都从同一个 `angle` 起算，位置全由「量到哪儿」给，不是动画编的——
    /// 边界停在哪儿，光就停在哪儿。走的是减弱动态与截图那一档（`scanBeam` 的静态分支）。
    func sweepBeam(_ angle: Double) -> some View {
        beamArt
            .rotationEffect(.degrees(angle - 90))
            .blendMode(isDark ? .screen : .normal)
    }

    /// 扫描期那道**一直在走**的光。样稿 `scan()` 把它转一圈 1700 ms
    /// （`SFX_CONF.scenes.scan.dur`，`diskwise-v2.6-crystal.html:4240`）就扫完了整圈，
    /// 因为稿子里的扫描是一段 1.7 秒的戏。真机的一次扫描要 8 秒到 3 分钟，
    /// 把光钉在字节边界上换来的是它每两秒跳一格——那就是他说的「没这个动画」。
    /// 所以这里搬的不是那个 1700，是**它在走**这件事：3 秒一圈，绕环交给
    /// `CALoopView` 的图层动画（同 `orbitGlint`，主线程一帧都不参与）。
    /// 进度不由这道光报：盘心那个数、`已量 N/M 处` 和环底下那截线才是进度，
    /// 光只回答「这台仪器还在转」。
    /// 截图/减弱动态：`DISKWISE_SCAN_BEAM=<度>` 把这一道钉在指定相位上取证（它和常驻反光
    /// 各有一只旋钮，钉在一起就分不清图里那团亮斑是谁）；只给 `DISKWISE_RING_SPIN=on`
    /// 时跟着反光那一格走；都没给就退回扫描边界——静图里也得看得见它。
    @ViewBuilder
    func scanBeam(_ boundary: Double) -> some View {
        if frame.scanBeamSpins {
            CALoopView(motion: .init(spinPeriod: Self.scanOrbitSeconds),
                       side: diameter,
                       // 不给 bleed：`beamArt` 自己按回了环带，环外一寸都不画，宿主就没有
                       // 需要多报的那一格。这一格原先留的是模糊裙边的余地，实测它漏到
                       // 环外成了皮带（见 `beamArt`），而且宿主按「直径 + 2·bleed」报尺寸，
                       // 等于往 `dial` 那棵 ZStack 里塞一颗比环大一圈的视图。
                       artKey: "scanbeam|\(diameter)|\(band)|\(isDark)|\(style)",
                       frozenAngle: SnapshotMode.scanBeamPhase
                           ?? (SnapshotMode.forceRingSpin ? SnapshotMode.ringGlintPhase : nil)) {
                // 峰值**不预先转正**：画面画在渐变自己的 0°（三点钟），绕到哪儿由
                // `CALoopHost` 那一处换算负责。这里再烤一个 `-90` 就会和它撞成 180° 偏差。
                beamArt
                    .frame(width: diameter, height: diameter)
            }
            .blendMode(isDark ? .screen : .normal)
        } else {
            sweepBeam(boundary)
        }
    }

    /// 光束画在 0°：绕环这件事只转图层，不逐帧重光栅化整圈渐变
    /// （把角度写进 `startAngle` 就是上一版悬停卡顿那个开销）。
    ///
    /// 那层 `mask` 不是装饰，是「严格走环带」这句话唯一的执行者。2026-10-23 他拍的
    /// 真机图上带外有一整圈铜色皮带（r326→372，18 个方位读数全是 R64 G56 B50，硬边），
    /// 稿子同位置是冷的。同构建、同皮肤、同窗口，只把光束从图层那条路
    /// （`DISKWISE_SCAN_BEAM=0`）换回静态那条路，环外立刻从 (60,54,48) 掉回 (20,22,28)：
    /// 暖圈只活在图层那一路。原因在光栅化：`beamArt` 第二笔带 `blur`，它的裙边本来要
    /// 洇出 frame，宿主为此留了一格 `bleed`（见 `CALoopView.bleed`），于是裙边被
    /// `ImageRenderer` 烤成一张位图时，那圈近乎透明的低 α 像素连 RGB 一起被钉死，
    /// 交给图层再 `screen` 上去就成了一整条不随方位变的暖灰带——宽度正好等于 `bleed`，
    /// 外沿正好断在 `rOut + bleed`。静态那一路的模糊是渲染服务器上现算的，看得见真实
    /// 背景，所以同一笔模糊在那儿是干净的。
    /// 稿子的 `#beam` 本来就没有模糊外溢：三层 `stroke-width: BAND` 的弧，硬边。
    /// 所以这里把光按回环带，而不是去猜那一圈暖该多亮。
    private var beamArt: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 1)
                .stroke(AngularGradient(gradient: beamGradient, center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: band, lineCap: .butt))
                .padding(band / 2)
            Circle()
                .trim(from: 0, to: 1)
                .stroke(AngularGradient(gradient: sweepHeadGradient, center: .center,
                                        startAngle: .degrees(0),
                                        endAngle: .degrees(360)),
                        style: StrokeStyle(lineWidth: band, lineCap: .butt))
                .padding(band / 2)
                .blur(radius: style.sweepHeadBlur)
        }
        .mask(beamBandMask)
    }

    /// 光束能落脚的地方就是环带那一条，两头都硬切——和稿子那条 `stroke` 的边界同一个数。
    /// 遮罩画在 `beamArt` 里而不是外面：图层与静态两条路共用这一张图，只此一处才管得住两边。
    private var beamBandMask: some View {
        Circle()
            .stroke(Color.white, lineWidth: band)
            .padding(band / 2)
    }

    /// 扫描光束绕一圈的秒数。稿子 `scan()` 那一圈 1.7 秒：探照灯按这个节奏扫，
    /// 读起来才像「在量」而不是「在巡边」。真机曾经钉 3 秒陪跑整趟扫描，
    /// 2026-10-25 他对着屏幕说慢——3 秒一圈的光走得比读数还懒，不像扫描像呼吸灯。
    /// 收回稿子那一档 1.7 秒。
    static let scanOrbitSeconds: Double = 1.7

    /// 扫完之后常驻的那道反光：只亮一圈的十分之一，9 秒一圈。
    ///
    /// 渐变**恒定画在 0°**，绕环这件事只动那个图层：转的是仿射，不是内容。
    /// 把角度写进 `AngularGradient.startAngle` 的话，每一帧都要重新光栅化整圈渐变
    /// ——那正是上一版悬停卡顿的开销来源。
    ///
    /// 真机：一帧画好，交给 `CALoopView` 的图层动画去转（主线程不参与）。
    /// 截图/连拍：相位是外面钉好的一个静态数，走 `rotationEffect` 那条路。
    @ViewBuilder
    func orbitGlint(_ angle: Double) -> some View {
        let ring = Circle()
            .trim(from: 0, to: 1)
            .stroke(AngularGradient(gradient: glintGradient, center: .center,
                                    startAngle: .degrees(0),
                                    endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: band, lineCap: .butt))
            .padding(band / 2)
        if frame.glintSpins {
            CALoopView(motion: .init(spinPeriod: frame.glintPeriod),
                       side: diameter,
                       bleed: band * style.glintBlurRatio,
                       artKey: "glint|\(diameter)|\(band)|\(isDark)|\(style)",
                       // 给了相位就钉在那一格取证；没给就是真机那条路——交给图层自己去转。
                       // 两张对照（钉 0° 与不钉）在环带内的差，就是「它真的在走」的证明。
                       frozenAngle: SnapshotMode.forceRingSpin
                           ? SnapshotMode.ringGlintPhase : nil) {
                // 样稿那条遮罩带边缘有 1.1% 的羽化（≈5 px），不是硬切。
                // 硬切在浅皮上读成「环上蹭了一道」，糊一分才像掠过表面的反光。
                ZStack {
                    ring
                        .blur(radius: band * style.glintBlurRatio)
                        .frame(width: diameter, height: diameter)
                }
                .mask(glintMask)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .blendMode(isDark ? .screen : .normal)
        } else {
            ring
                .rotationEffect(.degrees(angle - 90))
                .blur(radius: band * style.glintBlurRatio)
                .mask(glintMask)
                .blendMode(isDark ? .screen : .normal)
        }
    }

    /// 反光的地理边界：内侧从 `rIn` 再让 2% 带宽，外侧在深皮上一路放到金属沿的外沿。
    ///
    /// 样稿的遮罩是 `radial-gradient(closest-side, transparent 70.85%, #000 71.05%)`：
    /// 70.85% 的盘半径 ≈ 井口（`rIn / rOut` = 0.71），也就是说它**只**遮井口，带面、
    /// 金属沿、外沿全程都在光里。上一版把外沿收在金属沿的内沿（rOut − 0.0657 带宽），
    /// 亮头每次扫过都在离环边 6.6% 带宽处断掉——玻璃最该被点亮的那道沿反而没光。
    ///
    /// 浅皮仍然收在沿的内沿：浅皮走普通叠加、没有 screen，白光压过井口冷线和那道沿
    /// 会读成「光把环切断了」（浅皮实测过，见 `glintPeakLight` 那条）。
    private var glintMask: some View {
        let inner = rIn + band * style.glintMaskInnerBite
        let outer: CGFloat
        if isDark {
            outer = rOut - band * style.wallOuterRatio   // 沿的外沿（wallOuterRatio 为负 = 探出环外）
        } else {
            let wallW = band * style.wallWidthRatioLight
            outer = rOut - band * style.wallOuterRatio - wallW
        }
        return Circle()
            .stroke(Color.white, lineWidth: outer - inner)
            .frame(width: inner + outer, height: inner + outer)
            .frame(width: diameter, height: diameter)
            .blur(radius: band * style.glintMaskFeather)
    }

    private var glintGradient: Gradient {
        let peak = isDark ? style.glintPeakDark : style.glintPeakLight
        let stops: [Gradient.Stop] = [.init(color: .clear, location: 0),
                                      .init(color: .clear, location: style.glintLead)]
            + style.glintRamp.map { .init(color: peak.color($0.peakScale), location: $0.location) }
            + [.init(color: .clear, location: 1)]
        return Gradient(stops: stops)
    }

    /// 宽光：边界最亮，46° 之内收干（稿子三层嵌套弧叠出来的剖面）。
    private var beamGradient: Gradient {
        let head = isDark ? style.beamHeadDark : style.beamHeadLight
        let fade = min(0.5, (style.beamStops.last?.location ?? 0.128) + 0.017)
        return Gradient(stops:
            [.init(color: theme.palette.tint.opacity(head), location: 0)]
            + style.beamStops.map {
                .init(color: theme.palette.tint.opacity(head * $0.scale), location: $0.location)
            }
            + [.init(color: .clear, location: fade),
               .init(color: .clear, location: 1)])
    }

    /// 读数头：亮部钉在边界（location 1 = 边界那一格），身后 26° 渐隐，身前 28° 预照。
    private var sweepHeadGradient: Gradient {
        let peak = isDark ? style.sweepHeadOpacityDark : style.sweepHeadOpacityLight
        return Gradient(stops: style.sweepHeadStops.map {
            .init(color: style.sweepHeadInk.color(peak * $0.scale), location: $0.location)
        })
    }
}

// MARK: - 环上两根光（线框 / 能量流）

/// 扫描期那圈线框、量完之后那对能量流亮丝。
///
/// **叶子**：它自己订阅悬停信号，所以「指着哪条弧」只重算这一层，不经过
/// `SweepRing.dial`——同 `RingBands` / `RingNowLine` 那两条的理由（悬停每秒好几发，
/// 让整圈跟着重算是 670 个主线程样本的来历）。
///
/// 只挂在**活的那一圈**上：引导页那面示例环与下钻时收成的参照盘都不传 `hoverNote`，
/// 它们不是「此刻这块盘的账」，让它们跑光就是给没在量的东西配一根「正在流」的丝。
struct RingEdgeLightsBands: View {
    @ObservedObject var note: LedgerHoverSignal
    let fallback: String?
    let layers: RingLayers
    let slices: [RingSlice]
    /// 扫描中走线框那副数，量完走能量流。
    let scanning: Bool
    /// 走不走动画：减弱动态效果与截图那一趟给 false（亮丝不藏，钉在一档，见 `Recipe`）。
    let animate: Bool
    /// 预演那一档的通知线：流速倍率由它在叶子里现读，不经过 `SweepRing.dial`。
    @ObservedObject var preview: PreviewSignal
    /// 预演那几秒的流速倍率（样稿 `speedScale`：0.72）。平时一档恒为 1。
    let flowScale: Double
    /// 每量完一整圈 +1：线框沿每条弧走一笔。
    let flashTick: Int
    /// 入场那 0.9 秒不接：环还在从 12 点钟往里长，而这一层的路径只有「画完」这一档。
    let warm: Bool

    /// 量具：`DISKWISE_EDGE=off` 把这一整层摘掉。配对跑两次 PerfProbe（摘 / 不摘）
    /// 才量得出「这两根光到底花几个点」——同 `DISKWISE_RING_GLINT`、`_BREATH` 那两条规矩：
    /// 环上任何一层要加常驻动画，先留一个能摘掉它的开关。
    static let offByEnv: Bool = {
        (ProcessInfo.processInfo.environment["DISKWISE_EDGE"] ?? "").lowercased() == "off"
    }()

    var body: some View {
        let f = layers.frame
        RingEdgeLights(recipe: recipe(f: f, hover: note.label ?? fallback))
            // 样稿这三条 stroke 写的是 `mix-blend-mode: screen`——浅皮上没有 screen 可用，
            // 就换成压暗的主色走普通叠加（同 `glint` / `lit` 那条教训）。
            .blendMode(f.isDark ? .screen : .normal)
            .allowsHitTesting(false)
    }

    private func recipe(f: RingFrame, hover: String?) -> RingEdgeLights.Recipe {
        let s = f.style
        let d = f.diameter
        var r = RingEdgeLights.Recipe()
        r.isScanning = scanning
        r.side = d
        r.center = CGPoint(x: d / 2, y: d / 2)
        r.edgeRadius = f.rIn + f.band * s.flowEdgeBiteRatio
        r.wireRadius = f.rIn + f.band / 2
        // 样稿那一圈是 420 px，`RingStyle` 里那些长度就是按它算的比例；这里乘回本环的直径。
        r.headWidth = s.flowHeadWidthRatio * d
        r.tailWidth = s.flowTailWidthRatio * d
        r.wireWidth = s.wireWidthRatio * d
        r.headLen = s.flowHeadLenRatio * d
        r.tailRatio = s.flowTailLenRatio
        r.tailMax = s.flowTailLenMaxRatio * d
        r.gap = s.flowGapRatio * d
        r.tailBlur = s.flowTailBlurRatio * d
        r.wireGlow = s.wireGlowRatio * d
        // 浅皮那根丝换成样稿 `.mo-wire` 的冷白（206,232,255），不压暗：
        // 它只跑在带色的可回收弧上，冷白压在蓝带上是一道反光；深色版实拍是
        // 蓝带里一根深蓝短划，正是「玻璃上不该有的黑线」。
        let paperSpark = Color(red: 206.0 / 255, green: 232.0 / 255, blue: 1)
        r.headInk = ink(f.isDark ? RingMaterial.lampHot(f.theme.palette.tint, s) : paperSpark,
                        f.isDark ? s.flowHeadOpacityDark : s.flowHeadOpacityLight)
        r.tailInk = ink(f.isDark ? f.lamp : paperSpark,
                        f.isDark ? s.flowTailOpacityDark : s.flowTailOpacityLight)
        r.wireInk = ink(f.isDark ? RingMaterial.lampHot(f.theme.palette.tint, s) : paperSpark, 0.95)
        r.wireIdleOpacity = f.isDark ? s.wireIdleOpacityDark : s.wireIdleOpacityLight
        r.baseSeconds = s.flowBaseSeconds
        r.turnSeconds = s.flowTurnSeconds
        r.staggerSeconds = s.flowStaggerSeconds
        r.leadSeconds = s.flowLeadSeconds
        r.hoverSpeedScale = s.flowHoverSpeedScale
        r.wireSeconds = s.wireSeconds
        r.animate = animate
        // 预演那几秒整圈慢下来一点。这一档读的是叶子自己订阅的 `preview`，
        // 写在 `SweepRing.dial` 里就等于让一发空格重算整棵环。
        r.speedScale = preview.on ? flowScale : 1
        r.hoverLabel = hover
        r.flashTick = flashTick
        guard warm, s.edgeLightsOn, !Self.offByEnv else { return r }   // strands 留空 = 这一帧什么都不画

        if scanning {
            // 线框描的是**每一条已经量出一块**的弧：它说的是「这块轮廓还在长」。
            r.strands = slices.map { strand($0) }
        } else {
            // 能量流只给「现在收得走」的那几条（样稿同一条判据）。斜纹那段是已经在
            // 废纸篓里、还没让位的字节——它收不走，给它一根「在流」的丝是假账。
            r.strands = slices.filter { $0.seg.reclaim > 0 && !$0.seg.dashed }.map { strand($0) }
        }
        return r
    }

    private func strand(_ s: RingSlice) -> RingEdgeLights.Strand {
        RingEdgeLights.Strand(key: s.seg.armKey, label: s.seg.label,
                              from: Double(s.from * frameReveal),
                              to: Double(s.to * frameReveal))
    }

    /// 入场压缩那一段（`RingFrame.reveal`）：弧是压缩着画的，光得跟着画才不越界。
    private var frameReveal: CGFloat { layers.frame.reveal }

    /// `Color` → 图层要的四个分量。拿不到 sRGB 表示时退回样稿那一档冷白，
    /// 而不是退回 `.white`：退成纯白会在浅皮上画出一根看不见的丝（纸上白=没画）。
    private func ink(_ color: Color, _ opacity: Double) -> RingEdgeLights.Ink {
        guard let ns = NSColor(color).usingColorSpace(.deviceRGB) else {
            return RingEdgeLights.Ink(red: 0.62, green: 0.78, blue: 1.0, opacity: opacity)
        }
        return RingEdgeLights.Ink(red: Double(ns.redComponent), green: Double(ns.greenComponent),
                                  blue: Double(ns.blueComponent),
                                  opacity: opacity * Double(ns.alphaComponent))
    }
}
