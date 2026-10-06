import SwiftUI
import DiskCleanerCore

/// 一枚「正飞往废纸篓」的字节筹码。
///
/// 为什么要有它：搬一趟是**在盘上**发生的，而界面上原先只有两处会跟着变——环上那条虚线弧
/// 当场长出来、废纸篓那一格当场填满——两处都在原地跳一下，中间那段路没人走过。
/// 点完那一秒里眼睛还钉在按钮上，看到的就是「什么也没发生」，然后一句通知从顶上飘下来。
/// 这条轨迹补的就是中间那一段：字节从哪儿离开、落到哪儿去，一眼看见。
///
/// 起点取**环心**而不是按钮：这一屏全部立身之本是「环上每一段 = 盘上一块真字节」，
/// 而刚被搬走的那一块原先就画在环里、数就写在环心。让它从环心出发是那句话的续写；
/// 从按钮出发就退化成「这个按钮做了点什么」的通用反馈，跟盘上的账没关系了。
struct TrashFlight {
    /// 飞一趟多久。0.62 是量出来的：短于 0.5 眼睛只看见闪一下，长于 0.8 就成了「在等它」。
    /// 废纸篓那一格的进度条也读这个数——两边同时起、同时到，才像同一件事。
    static let travel: Double = 0.62

    let id = UUID()
    /// 这一枚上写的体积。跟按钮上那个数走同一个 `human()`，两处不会分头换单位。
    var text: String
    /// 起点终点都在英雄卡那个命名坐标系里（`OverviewView.heroSpace`）。
    /// 一个用局部、一个用全局，窗口一挪两枚就对不齐，所以量的时候说好用同一个。
    var from: CGPoint
    var to: CGPoint
    /// 起飞延迟：一次搬多处时几枚错开飞，成一串而不是叠成一坨。
    var delay: Double = 0
    /// **只给连拍那一趟用**：起飞那一刻的连拍时钟（`SnapshotMode.filmClock`）。
    ///
    /// 拍片器是一格一格手动推墙钟的，`withAnimation` 那套在那里完全不动——真机上的
    /// 0.62 秒在连拍里要摊成六七帧，只能改成「按连拍时钟现算画到哪儿」。
    /// 不给这个值时（真机、静图）进度照旧由 `withAnimation` 插值。
    var bornClock: Double? = nil
}

/// 飞行图层：铺在英雄卡上，跟着 `[TrashFlight]` 增删自己起落。
struct TrashFlightLayer: View {
    var flights: [TrashFlight]
    /// 落地的那一枚自己报上来，由持有者把它摘掉。
    var onLanded: (UUID) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(flights, id: \.id) { f in
                TrashFlightChip(flight: f) { onLanded(f.id) }
            }
        }
        // 整层不许接鼠标：它铺在卡片上，接下来就是「账目行怎么点都不动了」这种最难查的事。
        .allowsHitTesting(false)
    }
}

private struct TrashFlightChip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var flight: TrashFlight
    var onLanded: () -> Void

    /// 行程 0→1。截图模式下钉在 `SnapshotMode.flightPhase` 上：这东西全程都在动，
    /// 静帧判定永远等不到它停，只能钉住相位再拍（同 `DISKWISE_RING_GLINT` 那条规矩）。
    @State private var progress: CGFloat = 0

    var body: some View {
        ChipBody(progress: shown, flight: flight)
            .onAppear { launch() }
    }

    /// 这一帧画在行程的哪一格。
    ///
    /// 两条路：真机上由 `withAnimation` 一路插值到 1（`progress`）；连拍那一趟按连拍时钟现算
    /// ——墙钟在那里是拍片器一格一格手动推的，`withAnimation` 那套根本不动。
    /// 到了 1 之后不用管：那一枚的透明度本来就是 0，它自己看不见了。
    private var shown: CGFloat {
        guard let born = flight.bornClock else { return progress }
        return CGFloat(min(1, max(0, (SnapshotMode.filmClock - born) / TrashFlight.travel)))
    }

    private func launch() {
        if let pinned = SnapshotMode.flightPhase {
            progress = pinned
            return
        }
        // 连拍那一趟：这一枚的进度归 `shown` 算，这里不推它。每落一帧之前拍片器会喊一次
        // 重画，行程就跟着走一格（见 `SnapshotMode.runFilm` 的 `roll`）。
        if flight.bornClock != nil { return }
        // 「减弱动态效果」下不飞，也不留一枚停在半路的筹码：凭空出现、又凭空消失，
        // 比没有这条轨迹更难解释。这一趟的结果——环上的账和那句通知——一个都没少。
        guard !reduceMotion, !SnapshotMode.active else {
            DispatchQueue.main.async { onLanded() }
            return
        }
        withAnimation(.easeInOut(duration: TrashFlight.travel).delay(flight.delay)) {
            progress = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + flight.delay + TrashFlight.travel + 0.04) {
            onLanded()
        }
    }
}

/// 真正画那枚筹码的一层。**它自己得是 `Animatable`**——这点是整条轨迹成不成立的关键：
/// `withAnimation` 只插值得了可动画的属性，`position` 插出来的是**直线**，
/// 抛物线得按进度自己算，而进度要有中间值才谈得上「一路」。
/// 走 `Animatable` 而不是 `TimelineView`，是因为环上那道反光已经吃过一次教训：
/// 永续的每帧重算会把截图那边的静帧判定拖到上限。这里只有飞的那 0.6 秒在动。
private struct ChipBody: View, Animatable {
    @Environment(\.theme) private var theme

    var progress: CGFloat
    let flight: TrashFlight

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = Double(progress)
        // 抛一下再落。抬多高按两点之间的距离给、封顶 54：两处挨得近时也看得出是「抛」，
        // 离得远时不会顶出卡片上边。
        let span = Double(abs(flight.to.x - flight.from.x) + abs(flight.to.y - flight.from.y))
        let lift = min(54.0, 16.0 + span * 0.16) * sin(t * .pi)
        // 起飞时淡入、落进废纸篓那一下收小淡出。两头都得有，不然就是「凭空出现／凭空消失」。
        let appear = min(1, t / 0.10)
        let leave = max(0, (1 - t) / 0.18)
        return chip
            .opacity(min(appear, leave))
            .scaleEffect(1 - 0.3 * CGFloat(max(0, (t - 0.7) / 0.3)))
            .position(x: flight.from.x + (flight.to.x - flight.from.x) * progress,
                      y: flight.from.y + (flight.to.y - flight.from.y) * progress - CGFloat(lift))
    }

    private var chip: some View {
        HStack(spacing: 5) {
            Image(systemName: "trash")
                .font(.system(size: 9, weight: .semibold))
            Text(flight.text)
                .font(theme.numeric(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(theme.palette.ink)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .fixedSize()
        .background(Capsule().fill(theme.palette.surface))
        .overlay(Capsule().strokeBorder(SweepRing.lamp(theme.palette.tint), lineWidth: 1))
        .shadow(color: SweepRing.lamp(theme.palette.tint).opacity(0.30), radius: 5, y: 2)
        .accessibilityHidden(true)
    }
}

// MARK: - 锚点

/// 英雄卡里两个锚点的量法：飞行从环心出发、落到废纸篓那一格，而这两处坐标只有布局系统知道。
///
/// 走 `PreferenceKey` 往下收，不在触发那一刻用 `GeometryReader` 现量：触发时视图已经在
/// 这一趟的重画里了，现量到的框可能还是上一帧的，起点就会偏一下。
struct HeroAnchorKey: PreferenceKey {
    static var defaultValue: [String: CGPoint] = [:]
    static func reduce(value: inout [String: CGPoint], nextValue: () -> [String: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// 往 `HeroAnchorKey` 报一个锚点（量的是中心）。
    func heroAnchor(_ name: String, in space: String) -> some View {
        background(
            GeometryReader { g in
                let f = g.frame(in: .named(space))
                Color.clear.preference(key: HeroAnchorKey.self,
                                       value: [name: CGPoint(x: f.midX, y: f.midY)])
            }
        )
    }

    /// 往 `HeroAnchorKey` 报一个锚点，量的是**屏幕全局**坐标。
    ///
    /// 列表页的起点在 `List` 里，跨 NSView 背板量到某个命名坐标系会差一截
    /// （实测起点比那一行低了近一行）；一律走 `.global`，落到飞行图层时再按图层
    /// 自己的 global 原点换算回局部坐标，中间不经过任何命名坐标系。
    func heroAnchorGlobal(_ name: String) -> some View {
        background(
            GeometryReader { g in
                let f = g.frame(in: .global)
                Color.clear.preference(key: HeroAnchorKey.self,
                                       value: [name: CGPoint(x: f.midX, y: f.midY)])
            }
        )
    }

    /// 同上，按需开关。列表里几百行全挂一颗 `GeometryReader` 是白量——
    /// 只有**勾上的那几行**才需要报起点，不勾的行不报。
    @ViewBuilder
    func heroAnchorGlobal(_ name: String, enabled: Bool) -> some View {
        if enabled { heroAnchorGlobal(name) } else { self }
    }

    /// 同上，但按落点是否要飞行来开关（`CleanBar` 那张带子用）。
    @ViewBuilder
    func heroAnchorGlobalIf(_ name: String, enabled: Bool) -> some View {
        if enabled { heroAnchorGlobal(name) } else { self }
    }
}

// MARK: - 列表页共用的飞行

extension TrashFlight {
    /// 列表页的落点锚名：`CleanBar` 那颗「移进废纸篓」。
    static let targetAnchor = "trash"

    /// 一行一枚筹码的上限。超过就并成一枚写合计——几十枚一起飞只剩噪声，
    /// 跟总览「已经有几枚在空中就够」同一条理由。真数一个都没少，都进了那句通知。
    static let perRowLimit = 4

    /// 一次删除要飞的筹码。起点是每行此刻在屏幕上的位置（`heroAnchorGlobal` 量出来的），
    /// 终点是那颗真会动手的按钮。两处都必须是量出来的，不是猜的。
    ///
    /// 少时一行一枚、各写自己的体积（看得出谁走了）；多时并成一枚写合计（从最上面那行出发）。
    static func volley(sources: [(point: CGPoint, bytes: Int64)], to: CGPoint) -> [TrashFlight] {
        guard !sources.isEmpty else { return [] }
        if sources.count <= perRowLimit {
            return sources.enumerated().map { i, s in
                TrashFlight(text: human(s.bytes), from: s.point, to: to, delay: Double(i) * 0.08)
            }
        }
        let total = sources.reduce(Int64(0)) { $0 + $1.bytes }
        return [TrashFlight(text: human(total), from: sources[0].point, to: to)]
    }

    /// 把起点终点从屏幕全局坐标换算到飞行图层自己的局部坐标。
    func offsetBy(_ o: CGPoint) -> TrashFlight {
        var f = self
        f.from = CGPoint(x: from.x - o.x, y: from.y - o.y)
        f.to = CGPoint(x: to.x - o.x, y: to.y - o.y)
        return f
    }
}

/// 列表页的飞行舞台：锚点收集 + 飞行图层。
///
/// 锚点一律是**屏幕全局**坐标（见 `heroAnchorGlobal`）：起点在 `List` 里，跨 NSView
/// 背板量命名坐标系会差一截。这里拿图层自己的 global 原点把它们换算回局部坐标再画，
/// 中间不经过任何命名坐标系——那一截差正是从这里来的。
///
/// 页面只留两个 `@State`（`flights` / `anchors`）加一句 `.flightField(...)`。
struct FlightField: ViewModifier {
    @Binding var flights: [TrashFlight]
    @Binding var anchors: [String: CGPoint]

    func body(content: Content) -> some View {
        content
            .onPreferenceChange(HeroAnchorKey.self) { anchors = $0 }
            .overlay {
                GeometryReader { g in
                    let origin = g.frame(in: .global).origin
                    TrashFlightLayer(flights: flights.map { $0.offsetBy(origin) }) { id in
                        flights.removeAll { $0.id == id }
                    }
                }
            }
    }
}

extension View {
    func flightField(flights: Binding<[TrashFlight]>,
                     anchors: Binding<[String: CGPoint]>) -> some View {
        modifier(FlightField(flights: flights, anchors: anchors))
    }
}

/// 列表页删除飞行的状态与动作。各页 `@StateObject` 一个，省得三处 `@State` 各写一遍、
/// 各写错一处。行上的起点用 `rowAnchor(_:)`，落点是 `TrashFlight.targetAnchor`（`CleanBar` 报的）。
@MainActor
final class TrashFlightController: ObservableObject {
    /// 此刻在空中飞的筹码。
    @Published var flights: [TrashFlight] = []
    /// 行的起点、CleanBar 的落点，由 `heroAnchorGlobal` 报上来（屏幕全局坐标）。
    @Published var anchors: [String: CGPoint] = [:]
    /// 正在离开的那几行：先转淡，收行之后再摘掉。只有**晚一步才收行**的页面用到它，
    /// 其余页面那一行当场就没了，转淡没有意义（见 `launch(rows:animate:fade:)`）。
    @Published var leaving: Set<String> = []

    /// 行起点的锚名。`key` 是这一行自己的稳定标识（路径 / id）。
    static func rowAnchor(_ key: String) -> String { "row:\(key)" }

    /// 一次删除的飞行：从这几行发筹码、飞到 `CleanBar` 那颗「移进废纸篓」上。
    ///
    /// `rows` 每项是 `(行标识, 这一行要带走的字节)`；标识必须和行上 `heroAnchorGlobal` 报的名一致。
    /// `animate` 为假（「减弱动态效果」或截图模式）时不飞——凭空出现又消失比没有更难解释，
    /// 而结果一样给全。
    ///
    /// `fade` 管的是「行先转淡、等筹码落地再收」：只有收行**不是当场**发生的页面要它
    /// （文件夹详情页收行要重扫这一层）。行当场就消失的页面不要——那一行已经不在了，
    /// 转淡给谁看；筹码从它原来的位置起飞，起点在 `launch` 这一下已经量好。
    @discardableResult
    func launch(rows: [(key: String, bytes: Int64)], animate: Bool, fade: Bool = false) -> Bool {
        guard animate, let to = anchors[TrashFlight.targetAnchor] else { return false }
        let sources = rows.compactMap { r -> (point: CGPoint, bytes: Int64)? in
            anchors[Self.rowAnchor(r.key)].map { (point: $0, bytes: r.bytes) }
        }
        guard !sources.isEmpty else { return false }
        flights.append(contentsOf: TrashFlight.volley(sources: sources, to: to))
        if fade {
            withAnimation(.easeInOut(duration: TrashFlight.travel)) {
                leaving.formUnion(rows.map(\.key))
            }
        }
        return true
    }

    /// 飞完把转淡的这几行摘掉（收行之后调用）。
    func settle(_ done: Set<String>) { leaving.subtract(done) }

    /// 收行要等多久：飞了就等它落地，没飞就立刻。
    static func settleDelay(_ waiting: Bool) -> Double {
        waiting ? TrashFlight.travel + 0.12 : 0
    }

    /// 这一屏此刻该不该飞：不是「减弱动态效果」，也不在截图模式里。
    static func canAnimate(reduceMotion: Bool) -> Bool {
        !reduceMotion && !SnapshotMode.active
    }

    /// 截图钩子（`DISKWISE_FLIGHT=<0~1>`）：把这一页的飞行也钉住拍一张。
    ///
    /// 跟总览同一条理由——它整个 0.62 秒都在动，静帧判定永远等不到它停，只能钉住相位。
    /// 起点终点都得是**量出来的**：所以先勾上候选行（锚点要「勾中的行」才报），
    /// 下一帧锚点到手再补筹码。这一趟不写真账（就没有真的 `trashItem`），也不会真删。
    ///
    /// `candidates` 是这一页前两行（`key`/`bytes`），`selected` 说此刻勾上没有，
    /// `select` 是把它们勾上那条路——按的是行上那个勾选框自己改的那份状态。
    @discardableResult
    func fireSnapshotIfAsked(candidates: [(key: String, bytes: Int64)],
                             selected: Bool,
                             select: () -> Void) -> Bool {
        guard SnapshotMode.flightPhase != nil, flights.isEmpty, !candidates.isEmpty else { return false }
        if !selected { select(); return true }
        let sources = candidates.compactMap { c -> (point: CGPoint, bytes: Int64)? in
            anchors[Self.rowAnchor(c.key)].map { (point: $0, bytes: c.bytes) }
        }
        guard let to = anchors[TrashFlight.targetAnchor], !sources.isEmpty else { return false }
        flights.append(contentsOf: TrashFlight.volley(sources: sources, to: to))
        return true
    }
}
