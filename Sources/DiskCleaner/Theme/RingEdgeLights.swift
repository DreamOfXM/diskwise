import SwiftUI
import AppKit
import DiskCleanerCore

// ── 环上两根光 ───────────────────────────────────────────────────────────────
//
// 样稿 `diskwise-v2.6-crystal.html` 里它们是三条 stroke：
//
//   `.mo-wire`  扫描期「先有轮廓、再有实体」：一条 1.15 px 的亮线沿弧心线走一遍（一笔，走完就没）
//   `.mo-flow`  量完之后跑在**收得走**那段边上的头：1.35 px、锐、近白
//   `.mo-tail`  拖在头后面的尾：3.4 px、糊、只有头三成亮度
//
// 两条都是**永续**的（一颗亮点绕着弧跑，一圈接一圈）。这就是它们必须住在 Core Animation
// 里的唯一理由：SwiftUI 侧任何形式的永续动画都要主线程每帧重算视图树，后果实测写在
// `RingLayers.swift` 顶部那段（摘掉两条永续循环，常驻主线程 17–20% → 1.7%）。
// `lineDashPhase` 与 `opacity` 都是渲染服务器自己会插值的图层属性：发条装一次，之后
// 主线程一帧都不碰。只有**路径**跟着账变（弧在长）才重设 `path`——那是跟着数据走，
// 不是跟着帧率走。
//
// 样稿那三条全靠 `mix-blend-mode: screen` 才在暗底上成立。图层没有 screen
// （`CABlendMode` 只有 normal / plusLighter / multiply），所以浅皮不能共用同一组数：
// 纸上给一根近白的丝等于没给。于是深皮用**灯芯**（近白），浅皮用压暗的主色，
// 两边各一档不透明度，数都记在 `RingStyle`。
//
// 这里**不接任何事件**：宿主 `hitTest` 直接返回 nil。环上唯一的追踪层还是
// `SweepRing.ringHitLayer`（那条 NSTrackingArea 的教训记在它身上）。

/// 环上两根光的宿主：扫描期那圈线框 + 量完之后那对能量流亮丝。
struct RingEdgeLights: NSViewRepresentable {
    /// 一条弧的角区间。0…1、0 = 12 点钟顺时针，跟 `GaugeRegion` 同一个口径。
    struct Strand: Equatable {
        /// 身份：`GaugeSegment.armKey`。图层按它复用，换弧不重建旧层。
        var key: String
        /// 悬停认的是 label（整圈就这一套名字，见 `RingBands`）。
        var label: String
        var from: Double
        var to: Double
    }

    struct Ink: Equatable {
        var red: Double
        var green: Double
        var blue: Double
        var opacity: Double
    }

    /// 一帧的全部输入。**等值即同一支舞**：它不变就不重装发条——悬停每秒能来好几发，
    /// 每次重算都把亮丝打回弧头，读起来就是「光在跳」而不是「光在走」。
    struct Recipe: Equatable {
        /// 线框（扫描中）还是能量流（量完）。这一层只挂在活的那一圈上，没有第三种。
        var isScanning = false
        var side: CGFloat = 0
        /// 环心在**宿主**坐标里的位置。宿主布局尺寸就是 `side`（= 环直径）：
        /// 光的边靠图层不裁切洇出去，不把框撑大——撑大会把整块环顶偏。
        var center = CGPoint.zero
        /// 亮丝半径（样稿 `EDGE_R`）与线框半径（样稿 `R`，弧的心线）。
        var edgeRadius: CGFloat = 0
        var wireRadius: CGFloat = 0

        var headWidth: CGFloat = 0
        var tailWidth: CGFloat = 0
        var wireWidth: CGFloat = 0
        /// 头那颗亮点沿弧的划长（样稿 `HEAD = 7.5`）。
        var headLen: CGFloat = 0
        /// 尾拖到弧长的几分之几、最长拖到多少（样稿 `min(L*0.52, 62)`）。
        var tailRatio: CGFloat = 0
        var tailMax: CGFloat = 0
        var gap: CGFloat = 0
        var tailBlur: CGFloat = 0
        var wireGlow: CGFloat = 0

        var headInk = Ink(red: 1, green: 1, blue: 1, opacity: 1)
        var tailInk = Ink(red: 1, green: 1, blue: 1, opacity: 1)
        var wireInk = Ink(red: 1, green: 1, blue: 1, opacity: 1)
        /// 线框常驻那一档的亮度（扫描期整圈都描着；一笔走完那档是 `wireFlashInk` 的 .95）。
        var wireIdleOpacity: Double = 0.9

        /// 一圈几秒：`base + turn × 这一段的占比`。样稿 `2600 + span°×55`。
        var baseSeconds: Double = 2.6
        var turnSeconds: Double = 19.8
        /// 各条弧错开多少秒、起跑前让开多少秒（样稿 `delay = -(i*900 + 350)`）。
        var staggerSeconds: Double = 0.9
        var leadSeconds: Double = 0.35
        /// 悬停那一条快多少（样稿 0.62 倍时长）。
        var hoverSpeedScale: Double = 0.62
        /// 一次性线框那一笔走多久（样稿 430 ms）。
        var wireSeconds: Double = 0.43

        var strands: [Strand] = []
        /// 鼠标指着哪条弧。nil = 没指着。
        var hoverLabel: String? = nil
        /// 预演那几秒整圈的流速倍率（1 = 平时，0.72 = 预演）。**挂在图层组的 `speed` 上**，
        /// 不乘进动画时长——理由与实测读数都记在 `apply` 里那一段。
        var speedScale: Double = 1
        /// 走不走动画：「减弱动态效果」与截图那一趟给 false。亮丝**不藏**，钉在
        /// `stillPhase` 那一档——同 `SweepRing.canAnimate` 那条纪律：静止态在真机上
        /// 长什么样，截图就得是什么。
        var animate = true
        var stillPhase: CGFloat = 0.28
        /// 每量完一整圈 +1：线框沿每条弧走一笔。
        var flashTick = 0
    }

    var recipe: Recipe

    func makeNSView(context: Context) -> Host {
        let host = Host(frame: .zero)
        host.apply(recipe)
        return host
    }

    func updateNSView(_ host: Host, context: Context) { host.apply(recipe) }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Host,
                      context: Context) -> CGSize? {
        CGSize(width: recipe.side, height: recipe.side)
    }

    /// 一条弧的路径。`from`/`to` 是 0…1 占比、0 = 12 点钟顺时针，与 `GaugeRegion`
    /// 和 `Circle().trim(...).rotationEffect(.degrees(-90))` 同一个口径。
    ///
    /// 为什么手写 `addArc` 而不是拿 `Circle` 的 trim：图层要的是**一条描边的线**，
    /// 而 SwiftUI 的 trim 变不出 CGPath。
    ///
    /// 为什么**折线采样**而不是 `addArc`：`addArc` 的 `clockwise` 那个标志吃坐标系的
    /// y 轴朝向，而 `y-down` 这一条是宿主 `isFlipped` 换来的——一旦记错，线框就画到
    /// 环的另一侧去（弧在右下、光在左上），而它错的不是数值、是这条弧归谁看。
    /// 采样点没有方向约定：`φ = 起点 + 占比 × 一圈`，落在哪儿就是哪儿。
    /// 每一段不超过 2°：在 r=348 上弦高误差 0.05 px，肉眼与取证的像素差都量不出来。
    static func arcPath(center: CGPoint, radius: CGFloat, from: Double, to: Double) -> CGPath {
        let span = max(0, to - from)
        let path = CGMutablePath()
        guard span > 0, radius > 0 else { return path }
        let steps = max(2, Int((span * 360) / 2))
        let turn = 2 * Double.pi
        var pts: [CGPoint] = []
        pts.reserveCapacity(steps + 1)
        for i in 0...steps {
            let f = from + span * Double(i) / Double(steps)
            let a = f * turn
            pts.append(CGPoint(x: center.x + radius * CGFloat(sin(a)),
                               y: center.y - radius * CGFloat(cos(a))))
        }
        path.addLines(between: pts)
        return path
    }

    // MARK: - 宿主

    final class Host: NSView {
        /// 让图层坐标跟 SwiftUI 一致（y 朝下）：路径那两条半径换算只写一遍。
        override var isFlipped: Bool { true }

        private let gTail = CALayer()
        private let gHead = CALayer()
        private let gWire = CALayer()
        private let gFlash = CALayer()
        private var tails: [String: CAShapeLayer] = [:]
        private var heads: [String: CAShapeLayer] = [:]
        private var wires: [String: CAShapeLayer] = [:]

        /// 上一帧的配方，与每条弧**装上去那次**的弧长和时长。
        private var installed: Recipe?
        private var paced: [String: (length: CGFloat, duration: Double)] = [:]
        private var lastFlash = 0
        private var flashWork: DispatchWorkItem?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = false
            // 从底往上：尾（糊、宽）→ 头（锐、细）→ 线框 → 一次性那一笔。
            for g in [gTail, gHead, gWire, gFlash] {
                g.masksToBounds = false
                layer?.addSublayer(g)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Host is code-only") }   // l10n-scan: skip

        /// 环上的事件全归 `SweepRing.ringHitLayer`。这一层只是垫在弧上的一根光，
        /// 不许挡在鼠标前面（NSView 不认 SwiftUI 的 `allowsHitTesting`）。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            for g in [gTail, gHead, gWire, gFlash] { g.frame = bounds }
        }

        func apply(_ r: Recipe) {
            guard r.side > 0, r.center != .zero else { return }
            let previous = installed
            installed = r
            let fresh = syncGroups(r)

            // 「换了配方」= 装发条与涂色那些数变了。路径变了**不算**：那只重设 `path`。
            // 分成这两条是因为它们的更新频率差着一个量级：账每 0.2 s 来一轮，
            // 而配方只在换皮肤/换尺寸/扫描与量完互换时才来一次。每次更新都重涂一遍
            // 等于把每一层都标脏，渲染服务器就再去算一张模糊位图——那是白付的钱。
            let restyled = previous == nil
                || previous!.isScanning != r.isScanning
                || previous!.animate != r.animate
                || previous!.side != r.side
                || previous!.center != r.center
                || previous!.edgeRadius != r.edgeRadius
                || previous!.wireRadius != r.wireRadius
                || previous!.headWidth != r.headWidth
                || previous!.tailWidth != r.tailWidth
                || previous!.wireWidth != r.wireWidth
                || previous!.headLen != r.headLen
                || previous!.tailRatio != r.tailRatio
                || previous!.tailMax != r.tailMax
                || previous!.gap != r.gap
                || previous!.tailBlur != r.tailBlur
                || previous!.wireGlow != r.wireGlow
                || previous!.headInk != r.headInk
                || previous!.tailInk != r.tailInk
                || previous!.wireInk != r.wireInk
                || previous!.wireIdleOpacity != r.wireIdleOpacity
                || previous!.hoverSpeedScale != r.hoverSpeedScale
            // 涂色看两件事：配方变了，或这一轮**新长出来**几条弧。分开算是因为
            // `fresh` 不一定带着 `restyled`：入场那 0.9 秒走完，`warm` 一翻就把 strands
            // 从 0 变成 3，而样式字段一个都没动。那一轮新建的层要是没人涂色，拿的就是
            // `CAShapeLayer.strokeColor` 的默认值——不透明黑，画在暗底环上等于没画。
            // 实测就是这样：量完那一趟亮丝一根都不露，上膛那一趟却全在（那一趟顺带
            // 改了配方里的某个数，把 `restyled` 顶成了 true，涂色才跟着发生）。
            let styled = restyled || fresh
            if restyled { paced.removeAll() }
            // 整组开关，而不是把每条 bead 的透明度各写一遍：扫描期亮丝整对都不该亮，
            // 一组两处赋值，比 N 条弧各两处少 N−1 次赋值，而且渲染服务器会整棵子树跳过。
            gTail.opacity = r.isScanning ? 0 : 1
            gHead.opacity = r.isScanning ? 0 : 1
            gWire.opacity = r.isScanning ? 1 : 0
            // 预演那几秒整圈流速的倍率。**挂在图层组上，不乘进动画时长**：
            // `CALayer.speed` 只是本图层子树的时间缩放，改它既不重装发条也不重涂色，
            // 正在跑的相位接着走。乘进时长就要 `paced.removeAll()` 再逐条重挂——
            // 每条弧 4 个动画对象，外加把 head/tail/wire 的 `shadowRadius` 重涂一遍
            // （每次重涂 = 渲染服务器现算一张模糊位图）。2026-10-22 同场配对（30 s，
            // `DISKWISE_PERF_PREVIEW=1.6`，尾段 22.7 s）量的就是它：整开 9–12 格 >100 ms，
            // 摘掉绿弧 12 格、摘掉段带那两层滤镜 8 格、两个都摘 10 格，都还在；
            // 只有把**整圈**钉死不吃预演那一档才回到 2 格 = 同场静帧的地板。
            // 这一串数说清了后来真正要修的那件事：贵的不是环上哪一层，是「一发空格 =
            // 整页重算」——量它的那颗开关（`DISKWISE_RINGPREV=off`）已经跟着修法一起摘掉，
            // 修在 `PreviewSignal` 那几颗叶子上。这里只留「流速挂图层组、不重装发条」这一条。
            // 静止那一趟（减弱动态效果、截图）钉回 1：那一条根本没有发条可缩放。
            let flow = r.animate ? Float(max(0.05, r.speedScale)) : 1
            if gTail.speed != flow { gTail.speed = flow; gHead.speed = flow }

            for (i, strand) in r.strands.enumerated() {
                let span = max(0, strand.to - strand.from)
                let arcLen = 2 * .pi * r.edgeRadius * CGFloat(span)
                let flow = !r.isScanning && arcLen > 1

                if let tail = tails[strand.key], let head = heads[strand.key] {
                    if styled {
                        // 笔色必须显式给：`CAShapeLayer.strokeColor` 默认是**不透明白**，
                        // 而这一层画在暗底环上，不写这两行等于在弧上抹两道白scratch。
                        tail.lineWidth = r.tailWidth
                        tail.strokeColor = cg(r.tailInk)
                        head.lineWidth = r.headWidth
                        head.strokeColor = cg(r.headInk)
                        // `CALayer.shadowOpacity` 的默认值是 **0**：只给 `shadowColor` /
                        // `shadowRadius` 等于什么都没画（第一版实测就是一根硬边粗线，糊不开）。
                        tail.shadowOpacity = 1
                        tail.shadowColor = cg(r.tailInk)
                        tail.shadowRadius = r.tailBlur
                        tail.shadowOffset = .zero
                        // 头**不发光**：样稿那 1.35 px 要的就是一个锐边。给它加一层模糊，
                        // 读起来只剩「尾变粗了」，两条丝糊成一大块——而每一层 shadow 都是
                        // 渲染服务器现算一张位图，头这条最没必要付这笔钱。
                        head.shadowOpacity = 0
                    }
                    let path = RingEdgeLights.arcPath(center: r.center, radius: r.edgeRadius,
                                                      from: strand.from, to: strand.to)
                    tail.path = path
                    head.path = path
                    let tailLen = min(arcLen * r.tailRatio, r.tailMax)
                    let pattern = arcLen + r.gap
                    if flow {
                        tail.lineDashPattern = [ NSNumber(value: Double(tailLen)),
                                                 NSNumber(value: Double(pattern)) ]
                        head.lineDashPattern = [ NSNumber(value: Double(r.headLen)),
                                                 NSNumber(value: Double(pattern)) ]
                        let dur = duration(r, index: i, span: span)
                        let was = paced[strand.key]
                        if r.animate {
                            if was?.length != arcLen || was?.duration != dur || restyled {
                                pace(r, tail: tail, head: head, index: i, arcLen: arcLen,
                                     tailLen: tailLen, duration: dur)
                                paced[strand.key] = (arcLen, dur)
                            }
                        } else {
                            tail.removeAllAnimations()
                            head.removeAllAnimations()
                            let f = Double(r.stillPhase)
                            // 钉在「这一圈走了 f」那一档：静态图里也得看得见亮丝在哪。
                            head.lineDashPhase = Double(r.headLen) - f * Double(arcLen + r.headLen)
                            tail.lineDashPhase = Double(tailLen) - f * Double(arcLen + tailLen)
                            head.opacity = 1
                            tail.opacity = Float(r.tailInk.opacity * 0.85)
                        }
                    } else if paced[strand.key] != nil {
                        // 只有上一帧还在跑才值得撤：扫描期每一轮回填都走到这里，
                        // 每轮对每条弧发两次 `removeAllAnimations` 是白干的活。
                        // 撤掉发条之后停在哪一档不用管——整组 `gTail`/`gHead` 此刻是 0。
                        tail.removeAllAnimations()
                        head.removeAllAnimations()
                        paced[strand.key] = nil
                    }
                }

                if let wire = wires[strand.key] {
                    if styled {
                        wire.lineWidth = r.wireWidth
                        wire.strokeColor = cg(r.wireInk)
                        wire.shadowColor = cg(r.wireInk)
                        wire.shadowOpacity = 1
                        wire.shadowRadius = r.wireGlow
                        wire.shadowOffset = .zero
                        wire.opacity = Float(r.wireIdleOpacity)
                    }
                    wire.path = RingEdgeLights.arcPath(center: r.center, radius: r.wireRadius,
                                                       from: strand.from, to: strand.to)
                }
            }

            if r.flashTick != lastFlash {
                lastFlash = r.flashTick
                // 静态那两趟（减弱动态、截图）不演这笔：它 430 ms 就没了，
                // 拍出来只会是一张半亮的环。
                if r.animate, !r.isScanning, let snap = installed, snap.strands.isEmpty == false {
                    traceOnce(snap)
                }
            }
        }

        /// 一条弧一圈几秒：样稿那条式子，再乘悬停倍率。
        ///
        /// **不乘 `speedScale`**：预演那一档的整圈流速改走 `CALayer.speed`（见 `apply`
        /// 里那一段）。乘进时长就等于要重发一次条，而重发条是实测出来的那发卡顿。
        /// 悬停那一档原样留着：`hoverLabel` 不进「换配方」的判据，换一段本来就不重发条，
        /// 这个倍率只在别的原因发条时顺带生效——那是另一笔账，不在这一发里顺手改。
        private func duration(_ r: Recipe, index: Int, span: Double) -> Double {
            var scale = 1.0
            if let hover = r.hoverLabel, r.strands.indices.contains(index),
               r.strands[index].label == hover {
                scale = r.hoverSpeedScale
            }
            return max(0.4, (r.baseSeconds + r.turnSeconds * span) * scale)
        }

        /// 保证每条弧在三个组里各有一层，并清掉本轮已不存在的那些。
        /// 返回值 = 这一轮**新建了层**：新建就得涂色，见 `apply` 里 `styled` 那条。
        private func syncGroups(_ r: Recipe) -> Bool {
            var fresh = false
            let keys = Set(r.strands.map { $0.key })
            for group in [tails, heads, wires] {
                for (key, layer) in group where !keys.contains(key) {
                    layer.removeAllAnimations()
                    layer.removeFromSuperlayer()
                }
            }
            tails = tails.filter { keys.contains($0.key) }
            heads = heads.filter { keys.contains($0.key) }
            wires = wires.filter { keys.contains($0.key) }
            for strand in r.strands {
                if tails[strand.key] == nil { tails[strand.key] = addBead(to: gTail); fresh = true }
                if heads[strand.key] == nil { heads[strand.key] = addBead(to: gHead); fresh = true }
                if wires[strand.key] == nil { wires[strand.key] = addBead(to: gWire); fresh = true }
            }
            return fresh
        }

        private func addBead(to group: CALayer) -> CAShapeLayer {
            let l = CAShapeLayer()
            l.fillColor = nil
            l.lineCap = .round
            group.addSublayer(l)
            return l
        }

        /// 给一条弧装发条：一颗亮点从弧头走到弧尾，两头各淡出一次，无限重复。
        ///
        /// 头与尾共用**同一个**时长、同一个 `timeOffset`，所以前沿永远锁在一起
        /// （样稿那段注释说的就是这件事：两条弧划长不同，偏移量必须各算各的）。
        private func pace(_ r: Recipe, tail: CAShapeLayer, head: CAShapeLayer,
                          index: Int, arcLen: CGFloat, tailLen: CGFloat, duration: Double) {
            let offset = r.leadSeconds + Double(index) * r.staggerSeconds
            let headEnd = Double(r.headLen) - Double(arcLen + r.headLen)
            let tailEnd = Double(tailLen) - Double(arcLen + tailLen)

            for (layer, from, to, fade) in [(tail, Double(tailLen), tailEnd, 0.85),
                                            (head, Double(r.headLen), headEnd, 1.0)] {
                let phase = CABasicAnimation(keyPath: "lineDashPhase")
                phase.fromValue = from
                phase.toValue = to
                phase.duration = duration
                phase.repeatCount = .infinity
                phase.timeOffset = offset
                phase.beginTime = CACurrentMediaTime()
                phase.timingFunction = CAMediaTimingFunction(name: .linear)
                layer.add(phase, forKey: "dw.flow-phase")

                let fadeAnim = CAKeyframeAnimation(keyPath: "opacity")
                fadeAnim.values = [0, fade, fade, 0]
                fadeAnim.keyTimes = [NSNumber(value: 0), NSNumber(value: 0.10),
                                     NSNumber(value: 0.80), NSNumber(value: 1)]
                fadeAnim.duration = duration
                fadeAnim.repeatCount = .infinity
                fadeAnim.timeOffset = offset
                fadeAnim.beginTime = CACurrentMediaTime()
                layer.add(fadeAnim, forKey: "dw.flow-fade")

                // 模型值 = 动画被撤掉那一瞬间该停的样子：刚起步那一档。
                layer.lineDashPhase = from
                layer.opacity = Float(fade)
            }
        }

        /// 一笔走完就收：整圈只留一个定时器，不按弧各排一个。
        private func traceOnce(_ r: Recipe) {
            flashWork?.cancel()
            gFlash.sublayers?.forEach {
                $0.removeAllAnimations()
                $0.removeFromSuperlayer()
            }
            var tailEnd = r.wireSeconds
            for strand in r.strands {
                let wireLen = 2 * r.wireRadius * CGFloat(max(0, strand.to - strand.from)) * .pi
                guard wireLen > 1 else { continue }
                let l = CAShapeLayer()
                l.path = RingEdgeLights.arcPath(center: r.center, radius: r.wireRadius,
                                                from: strand.from, to: strand.to)
                l.fillColor = nil
                l.lineCap = .round
                l.strokeColor = cg(r.wireInk)
                l.lineWidth = r.wireWidth
                l.lineDashPattern = [NSNumber(value: Double(wireLen)),
                                     NSNumber(value: Double(wireLen))]
                l.lineDashPhase = Double(wireLen)      // 一笔都没走的那一档
                l.shadowColor = cg(r.wireInk)
                l.shadowOpacity = 1
                l.shadowRadius = r.wireGlow
                l.shadowOffset = .zero
                l.opacity = 0
                gFlash.addSublayer(l)

                // 每条弧按它自己的起点角错开——样稿那句 `delay = (a1/360)*SCAN_DUR`
                // 说的是「扫到哪儿、描到哪儿」，这里扫的顺序就是弧排的顺序。
                let begin = CACurrentMediaTime() + Double(strand.from) * 0.35
                let draw = CABasicAnimation(keyPath: "lineDashPhase")
                draw.fromValue = Double(wireLen)
                draw.toValue = 0
                draw.duration = r.wireSeconds
                draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.28, 0.8, 0.3, 1)
                let fade = CAKeyframeAnimation(keyPath: "opacity")
                fade.values = [0, 0.95, 0.95, 0]
                fade.keyTimes = [NSNumber(value: 0), NSNumber(value: 0.04),
                                 NSNumber(value: 0.62), NSNumber(value: 1)]
                fade.duration = r.wireSeconds
                for a in [draw, fade] {
                    a.beginTime = begin
                    a.fillMode = .forwards
                    a.isRemovedOnCompletion = false
                }
                l.add(draw, forKey: "dw.wire-draw")
                l.add(fade, forKey: "dw.wire-fade")
                tailEnd = max(tailEnd, r.wireSeconds + Double(strand.from) * 0.35)
            }
            guard gFlash.sublayers?.isEmpty == false else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.gFlash.sublayers?.forEach {
                    $0.removeAllAnimations()
                    $0.removeFromSuperlayer()
                }
            }
            flashWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + tailEnd + 0.1, execute: work)
        }

        private func cg(_ ink: Ink) -> CGColor {
            NSColor(srgbRed: CGFloat(ink.red), green: CGFloat(ink.green),
                    blue: CGFloat(ink.blue), alpha: CGFloat(ink.opacity)).cgColor
        }
    }
}
