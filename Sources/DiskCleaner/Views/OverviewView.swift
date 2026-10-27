import SwiftUI
import Combine
import DiskCleanerCore
import AppKit

// ── 空间总览：磁盘用量 + 主目录一级热点 ──
// 这一屏是磁盘清理类产品的门面，所以给了环形仪表：
// 一眼看清"整块盘被谁吃了"，比一根进度条有力得多。

// MARK: - 首次清理：候选 → 确认 → 结果

/// 首次清理走到哪一步。nil = 还在空间总览（环上那本账）。
enum CleanStage: Equatable {
    case candidates
    case confirm
    case result
}

/// 一处可以被搬进废纸篓的缓存。只收知识库标成 `safe` / `redo` 的位置：
/// `risky` 不进这条一键路径，`unknown` 连徽章都没有，更不该被默认勾上。
struct CleanCandidate: Identifiable, Equatable, Hashable {
    var path: String
    var name: String
    var size: Int64
    var tier: VerdictTier
    /// 归到环上哪一段账（`reclaimBucket` 的结果，或 `reclaimRestKey`）。
    var bucket: String
    var bucketLabel: String
    var whatif: String
    var rec: String
    var appID: String?
    var brand: String?
    var selected: Bool

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
}

/// 搬不动的一处。原因逐条留着：一条一条走 `trashItem`，失败就得点名说是谁、为什么。
struct CleanFailure: Identifiable, Equatable {
    var path: String
    var name: String
    var reason: String
    var id: String { path }
}

/// 已经搬进废纸篓的一处。结果页的收据按它列，撤销也按它找。
struct CleanReceipt: Identifiable, Equatable {
    var path: String
    var name: String
    var size: Int64
    var tier: VerdictTier
    var appID: String?
    var brand: String?
    var id: String { path }
}

/// 一次首次清理的完整结果。`beforeAvailable` 是动手前的可用空间：
/// 结果页那三笔账（已入废纸篓 / 当前可用 / 清空后可用）全从它和 `bytes` 推，
/// 不在界面上各算各的——同一屏三个数必须加得起来。
struct CleanRun: Equatable {
    var records: [TrashRecord]
    var receipts: [CleanReceipt]
    var failures: [CleanFailure]
    var bytes: Int64
    var beforeAvailable: Int64

    var afterClear: Int64 { beforeAvailable + bytes }
}

/// 鼠标停在哪一段上专用的那条通知线：
/// 不存第二份账，只把「此刻指着谁」这一件事单独发出去。
///
/// 为什么要单独一条：悬停从鼠标跨进一行到跨出去，每秒能来好几发；每一发要是都让
/// 整页重算，这台 Intel 上一次整页变更的价就是 60–100 ms（见 `PerfProbe` 的底价），
/// 手在环上扫一圈能把主线程吃满。而悬停真正要动的只有两处——环上那条弧和账本那一行，
/// 所以这条线上只该挂那两处。
final class LedgerHoverSignal: ObservableObject {
    @Published private(set) var label: String?
    /// 值真变了才写：`@Published` 写回同一个值也会发一次变更，而 AppKit 的 enter
    /// 事件不保证只来一次（重排、重挂都会再放一次）。
    func set(_ label: String?) {
        if self.label != label { self.label = label }
    }
}

/// 「此刻在不在预演那一档」专用的那条通知线。立这条线的理由跟 `LedgerHoverSignal`
/// 是同一条，只是这一发更贵：
///
/// 预演要改的画面有**五处**（盘心三行、六行小字末尾那截 `+N`、环底下那条决策条、
/// 环上退到后面的那几段、带心线上那截绿光弧）。原先这一档挂在 `OverviewModel` 的
/// `@Published` 上，一发空格就是**整页重算一次**。同场配对量过的数（30 s 探针、
/// `DISKWISE_PERF_PREVIEW=1.6`、尾段 22.7 s）：环那一档钉死不吃预演、页面照旧整页重算，
/// 尾段 p99 仍有 35.9 ms、最长一格 100.1 ms，而同场静帧地板的 p99 是 9.4 ms、最长一格
/// 100–157 ms 那几格是扫描尾巴自己的账。所以这一档不进模型那本 `@Published` 账，
/// 只发给挂在这条线上的那几颗叶子。
///
/// 叶子清单：`RingBands` / `RingGlowBands`（退到后面）、`RingEdgeLightsBands`（流速）、
/// `RingGainArcHost`（那截绿弧）、`RingCenterReadout`（盘心三行）、
/// `LedgerSubLine`（行里那截 `+N`）、`PreviewBarHost`（浮在环底那条）、
/// `AfterClearSlot`（环那一格让位给谁的那句话）。
///
/// **这一发还剩多少，2026-10-22 逐层分过账**（同一趟构建、同一棵合成家目录、
/// 每 0.4 s 压放一次空格、静帧对照在同一场）：全开尾段 p99 42.4 ms / 主线程 34.4 %，
/// 摘掉其中**任何一层**都回到 28–32 ms / 21.2–29.3 %（同场静帧 28.3 / 8.6）。
/// 四层的份额几乎一样（`+N` 角标 14.4、退到后面 13.4、亮丝 11.0、绿光弧 10.2 ms），
/// 所以贵的是**这几颗叶子的 `body` 各重跑一次**，不是哪一层画得狠——摘掉一颗就回到
/// 地板，是因为剩下的量正好压在同场噪声带里（跨趟绝对值不能比：同一档静帧的 p99
/// 在两趟之间是 9.4 与 28.3，那 19 ms 是这台机器上别的进程吃的）。
/// 另一笔要记清：**>100 ms 那几格多半不是预演添的**——那几趟里静帧对照自己就报 3–9 格，
/// 预演 3–9 格，同量级。
///
/// **同场配对、干净的一场（2026-10-22 收口，`DISKWISE_PERF=40 SKIP=10`，只看尾段 30 s）**：
/// 静帧 p50 8.3 / p99 9.3 / 最大 13.4 ms，`>33.4` 与 `>100` 各 0 格，主线程 1.8 %；
/// 每 1.6 s 压放一次空格 → p99 17.1 / 最大 59.6 / `>33.4` 7 格 / 主线程 15.5 %；
/// 每 0.4 s（约人手速三倍）→ p99 28.1 / 最大 51.3 / `>33.4` 25 格 / 主线程 27.8 %。
/// 两档预演都**没有一发 >100 ms**。拿 `PerfProbe.swift` 那条红线读这一场：p99 差 0.4 ms
/// 过线、`>100` 过线，**`>33.4` 没过**——一秒一按的节拍下每 30 秒 7 发，规则要的是 1 发。
/// 这一笔就这么记着，不许换成「最大才 60 ms，看不出来」结案；要结案只能走下面那条路。
/// 想再把这一发砍下去只剩一条路：让这几颗叶子在预演档**连 `body` 都不重跑**
/// （把退后乘子、`+N`、盘心句子交给 Core Animation 或 `Equatable` 子视图）。那要动环的
/// 材质与账本行这两处最敏感的画面代码，六套皮肤 × 十种语言的静图闸门得全部重拍——
/// 本轮没做，账记在这里。
final class PreviewSignal: ObservableObject {
    @Published private(set) var on = false
    /// 同 `LedgerHoverSignal.set`：写回同一个值也发一次变更，而「按住」这条路
    /// 可能被重复触发（连发已由 `SpaceHoldTap` 掐掉，这一条守的是别的入口）。
    func set(_ on: Bool) {
        if self.on != on { self.on = on }
    }
}

/// 环正下方那一格的闸门：预演、或刚从预演里给整圈上了膛，这一格**空着**（那句话由
/// 决策条说）；其余时候装「刚点出来的那句话」。
///
/// 闸门本身不换内容，换的是**订阅范围**：这一格要不要让位，读的仍是「此刻在不在
/// 全部清空之后那一档」，而这一档住在 `PreviewSignal` 上、不走 `@Published`。写在
/// 页面上，那一次重算的范围就是整页（`OverviewView.body` → `SweepRing.body` → `dial`，
/// 环上那棵大树加右边六行账全跟着走一遍）；挂在这一颗叶子上，重算只有这一格。
///
/// `armedAll` 由页面传：整圈上膛那一档本来就住在 `@Published armedPath` 上，页面跟着它
/// 重算是已有的账。这一格让位之后环底下还剩不还剩一句话，全在 `ringBelow(showBar:ring:armedLine:)`。
private struct AfterClearSlot<Content: View>: View {
    @ObservedObject var preview: PreviewSignal
    let armedAll: Bool
    /// 量具：`DISKWISE_BAR=off` 让这一格在这一档不装条子。见 `OverviewView.barOffByEnv`。
    let hide: Bool
    @ViewBuilder var content: (_ showBar: Bool) -> Content

    var body: some View {
        content(!hide && (armedAll || preview.on))
    }
}

/// 决策条（稿子⑫）的闸门：同一对判据，另一颗叶子。
///
/// 为什么不与上面那一格共用一颗：条子从前就坐在那一格里，于是它一出现就把环顶高 56 pt
/// ——那 56 pt 在样稿里没有（样稿 `.dbar` 是 `position:absolute`，环从头到尾不动），
/// 在账上是一发整窗排版（实测记在 `heroGeo` 上面）。搬成 overlay 之后两棵子树不再同格，
/// 判据却仍是同一句「此刻在不在全部清空之后」，所以照 `AfterClearSlot` 再立一颗，
/// 而不是把页面拖回来读这一位。
///
/// **这一颗不换树，只换透明度。** 搬成 overlay 之后重量（同一场、同一条 0.4 s 节拍）：
/// 环确实一动不动了（量它的那发临时探针从每发两响掉到只剩开跑那几秒布局定的几行；
/// 探针数完就摘了，写法见 `heroGeo`），
/// 可尾段 p99 48.2 对搬之前 48.8 —— 一点没省。把三档摆一起才看得清：
/// `off` 24.1 / `rect`（一块同高的空板，换树但不画东西）34.1 / 条子 48.8。
/// 贵的从来不是「环被顶高」，是**这一棵子树进树与出树那两下**：每一下都要过一遍
/// 整扇窗的 Auto Layout，跟它把谁顶高了没关系。所以这一档改成常驻：不进不出，
/// 出现与消失只是 `opacity` 这一个渲染量（样稿 `.dbar` 写的是
/// `transition:opacity .32s,transform .44s`，这里省掉 `transform` 是因为常驻之后
/// 它已没有要让位的活儿），加上 `allowsHitTesting` 与 `accessibilityHidden` 两道锁——
/// 一颗看不见又点不着的钮必须同时不吃鼠标、不进 VoiceOver，而它**不能绑 ⌘↵**：
/// 那颗钮的键位跟着 `armed` 走，见 `previewBar`。
///
/// 2026-10-22 同场复测（同一棵合成家目录、同一趟构建，静帧对照与预演档背靠背跑）：
/// **常驻这一档在静帧上不要钱**——`BAR=off`（子树根本不在）p99 9.5 / 主线程 9.5 %，
/// 常驻 p99 9.4 / 主线程 6.6 %，`>33.4` 那格 26 对 21。也就是说多留在树里的那一棵
/// 空板子既不吃主线程也不添长格，它换掉的正是每发空格那两下进出。
///
/// **淡入淡出同样不要钱**：原先怀疑挂在 `opacity` 上那发 `.animation(value:)` 是主线程
/// 没降的原因（`Components.swift` 里那颗勾选框记过同一件事），当场配对量下来是
/// 带淡入 p99 36.9 / 主线程 32.0 %，摘掉淡入 38.9 / 30.1 %——差在噪声里，无罪。
/// 所以淡入留着（它是对的：按下要看见数变，松手是收回），那颗开关摘掉了。
private struct PreviewBarHost<Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var preview: PreviewSignal
    let armedAll: Bool
    /// 量具：`DISKWISE_BAR=off` 让这一档**整棵子树都不进树**——它是上面那三档对照的
    /// 「off」臂，所以必须真的不建，而不是把 `opacity` 压成 0（见 `OverviewView.barMode`）。
    let hide: Bool
    @ViewBuilder var content: (_ on: Bool) -> Content

    var body: some View {
        if hide {
            EmptyView()
        } else {
            let on = armedAll || preview.on
            content(on)
                .opacity(on ? 1 : 0)
                // 退场比进场快一档：按下空格那一下要当场看见数变了，松手是「收回」，
                // 慢慢淡回去反而像还留着一半。
                .animation(reduceMotion ? nil : (on ? theme.animation : .easeOut(duration: 0.16)),
                           value: on)
                .allowsHitTesting(on)
                .accessibilityHidden(!on)
        }
    }
}

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class OverviewModel: ObservableObject {
    @Published var usage: VolumeUsage? = nil
    @Published var hotspots: [(name: String, path: String, size: Int64)] = []
    /// 排在列表封顶之后、但确实量到了的目录。列表不画满一屏，点开设的那行全在里面。
    @Published private(set) var restHotspots: [(name: String, path: String, size: Int64)] = []
    /// 一行都没摊到的那部分：单项低于下限的目录数与合计。没有这两个数，
    /// 「其他已统计」那块弧就有一截是账外之地——环形加起来等于盘，列表却对不上。
    @Published private(set) var unlistedCount = 0
    @Published private(set) var unlistedBytes: Int64 = 0
    @Published var scanning = false
    /// 已经量完的目录数。环形要等全部量完才谈得上「未扫描」，所以这个数得露出来。
    @Published private(set) var done = 0
    @Published private(set) var pending = 0
    /// 扫过的目录合计占多少。环形的「未扫描」= 已用 − 这个数，整张图的口径全靠它。
    @Published private(set) var covered: Int64 = 0
    /// 这趟扫描里打不开的目录，按「缺哪种权限」分开。合并进一块就说不清哪块能要回来。
    @Published private(set) var needFDA: [String] = []
    @Published private(set) var needAdmin: [String] = []
    /// 正在量的目录名。列表必须「动起来」：一趟整盘扫描里最慢的根能跑几分钟，
    /// 只在有目录量完时才刷新，画面就会长时间一片空白，看着像点了没反应。
    @Published private(set) var measuring: [String] = []
    /// 这一轮要量的全部位置，按排队顺序。账目列靠它把「排队中」逐个换成「已量完」——
    /// 只报 `measuring` 的话，队列里还没轮到的那几百处在这一屏上根本不存在。
    @Published private(set) var scanTargets: [(name: String, path: String)] = []
    /// 量完一处记一笔（路径 → 字节）。它是账目列判断「这一处轮到没有」的账本：
    /// 量到 0 字节的也记（`nil` 才是「还没轮到」）。
    @Published private(set) var measuredTargets: [String: Int64] = [:]
    /// 这个进程实测有没有「完全磁盘访问权限」。授权是在系统设置里点的，macOS 要 App
    /// 退出重开才落到进程上，所以「扫描里报了几处 EPERM」不能当授权状态用——
    /// 那样会对着已经勾过的人说「点这个按钮去开」。每轮扫描开始时重测一次。
    @Published private(set) var hasFDA = false
    /// 整块盘按 APFS 卷拆开的账。nil = 这台机器拆不出（演示树、非 APFS），
    /// 那时「没量到的地方」只能整体归成一块，不硬编明细。
    @Published private(set) var split: VolumeSplit? = nil
    @Published private(set) var started = false
    /// 环上「动得了多少」这本账落地的节拍：`settleCaches()` 每结算一次加一。
    /// 读的人只有总览那一屏的截图定帧钩子——水珠的判据是「这条弧 reclaim > 0」，
    /// 而 reclaim 比弧本身晚到（缓存体积要一台一台量回来）。
    @Published private(set) var reclaimPulse = 0
    /// 行内摊开的下一级，按父路径缓存。行视图会随滚动和导航重建，不缓存的话
    /// 每次滚回来都要重走一遍几十 G 的子树——那看着就像 App 卡死了。
    @Published private(set) var childRows: [String: [ChildEntry]] = [:]
    /// 此刻摊开在哪一段账上（值是 `GaugeSegment.armKey`）。nil = 没下钻，环画满幅。
    ///
    /// **放在模型里，不放视图的 `@State`。** 侧栏是 `switch` 切分支，页面视图随导航销毁：
    /// 摊开状态要是住在 `@State` 里，切走再回来它就没了，人看到的是「刚摊开的那一行
    /// 自己收起来了，得重新点一遍」——而下一级的账明明还在 `childRows` 里躺着。
    /// 白量一趟的错觉就是这么来的，代价是每次切页都要把那几下重新点回去。
    ///
    /// 跟 `armedPath` 同一条纪律：跨页要留的状态一律不放 `@State`（那边记着理由）。
    /// 一次性的是**量**这件事（`childRows` 认缓存），不是「摊开着」这个状态。
    @Published var drillKey: String? = nil
    @Published private(set) var childBusy: Set<String> = []
    private var childTasks: [String: Task<Void, Never>] = [:]
    private var task: Task<Void, Never>? = nil

    /// 扫描期回填的缓冲。窗口内量完几处只改这里，窗口到了才一次性写进上面那串
    /// `@Published`。为什么要攒：几百处目标就是几百轮整页重绘，而一次整页变更在这台
    /// Intel 上值 60–100 ms（见 `PerfProbe` 的底价）；扫描那几分钟主线程该留给量盘。
    /// 窗口取 0.2 秒：环上的弧仍看得出在长（每秒五拍），又不至于每量完一处就重画整页。
    /// 2026-10-22 在同一棵合成家目录（200 个一级目录 / 6 万个文件）上配对量：
    ///   每处当场发  15 s 里 >33.4 207 次、p99 89.7 ms、主线程 79.5%
    ///   0.2 s 窗口  >33.4   9 次、p99 14.9/17.7 ms、主线程 11.4/11.7%（两次跑）
    /// 还剩下的 4 次 >100 ms 全在起跑后 1.3 s 内，是首屏铺开那一笔，不在回填途中。
    private final class ScanBackfill {
        var done = 0
        var pending = 0
        var total: Int64 = 0
        var sized: [(name: String, path: String, size: Int64)] = []
        var measured: [String: Int64] = [:]
        var blame = DirScan()
        var measuring: [String] = []
        var measuringSet = Set<String>()
        var progressDirty = false
        var measuringDirty = false
    }

    private static let scanFillWindow: TimeInterval = 0.2
    private var backfill: ScanBackfill?
    private var backfillJob: DispatchWorkItem?

    /// 小于这个数不进列表：家目录一级有上百个点目录，绝大多数是几 KB 的配置夹。
    static let sizeFloor: Int64 = 100 * MB
    /// 列表封顶。再长就没人逐行扫了，多出来的体积并进环形的「其他已统计」。
    static let listCap = 20

    // MARK: 环上的「本次移入废纸篓」账

    /// 被本工具搬进废纸篓、还没让位的那些字节（源路径 + 当时量到的大小）。
    /// 由视图从 `store.trashHistory` 整串推进来：模型摸不到 store，而这条账环形每帧都要读。
    /// 它是 @Published：删一刀之后环要跟着挪账，靠别的字段顺带重画是靠不住的。
    @Published private(set) var moved: [(original: String, bytes: Int64)] = []

    /// 每条弧的**水位线**：`[路径: 量完它那一刻已有几笔记录]`。序号在水位线之前的那些
    /// 已经作废（新尺寸本来就不含它们），之后的照常扣。用集合记「量过了」会把**量完之后**
    /// 新搬走的那些一起作废掉——清完一轮再点重新扫描，环上就再也长不出废纸篓那条弧。
    private var voidedUpTo: [String: Int] = [:]

    /// 这一轮量过的全部路径，含没进列表的那些（低于 `sizeFloor` 的也算「量到过」）。
    /// 归位要靠它：不传全，从一个小目录里清掉的几百 G 就归不进任何弧。
    private var targetPaths: [String] = []

    private var cachedLedger: RingLedger?

    /// 删完一刀（`store.record` 之后）、撤销一次、或清空废纸篓之后，把整条历史重新推一遍。
    /// 不增量记账：撤销链本来就是「历史短了」，重新归一次位弧就自己回滚，
    /// 模型里不会留下第二本跟 store 对不上的账。
    /// 内容没变就不发变更：这一串是每帧对照着推的，回回都发布会让整页白重画一次。
    func setMoved(_ records: [(original: String, bytes: Int64)]) {
        let same = records.count == moved.count && zip(records, moved).allSatisfy {
            $0.original == $1.original && $0.bytes == $1.bytes
        }
        guard !same else { return }
        moved = records
        // 撤销/清空历史会让整串变短，水位线得跟着退：不退的话，下一笔新记录（序号落在
        // 旧水位线之后）会被当成「量过了」而凭空作废。
        for key in voidedUpTo.keys { voidedUpTo[key] = min(voidedUpTo[key]!, records.count) }
        cachedLedger = nil
        // 搬走之后重归一次缓存账：已经不在原处的那几处不许再算进「还能腾出」，
        // 不然主按钮上的数会比它真能搬走的大，第二下按下去才发现差了一截。
        rebuildCacheTargets()
    }

    /// 那条「本次移入废纸篓」的弧有多大、每条热点弧被搬走了多少。
    ///
    /// 缓存是为了每帧重算的环形：一趟重复文件清理能留下几百条记录，每帧拿它们
    /// 跟几十个路径重比一遍是白烧 CPU。列表一变（扫描中名次会重排）就作废。
    var movedLedger: RingLedger {
        if let cachedLedger { return cachedLedger }
        let l = ringMoveLedger(records: moved,
                               topPaths: Array(hotspots.prefix(3)).map { $0.path },
                               otherPaths: targetPaths,
                               voidedUpTo: voidedUpTo)
        cachedLedger = l
        return l
    }

    /// 交给环形的两条扣减，钳在对应那条弧此刻的体积以内。
    ///
    /// 为什么会超：一轮扫描跑到一半被停掉，有的弧已经重新量过（搬走的字节早就不在里面了），
    /// 账本却还记着那一笔。不钳就是 Core 那道守卫直接不拆——「其他已统计」和「没量到」
    /// 两条弧当场消失，环形画成一张缺角的图，那比数字偏一点严重得多。
    var ringDeduction: (top: Int64, rest: Int64) {
        let led = movedLedger
        let topSum = Array(hotspots.prefix(3)).reduce(Int64(0)) { $0 + $1.size }
        return (min(led.topOut, topSum), min(led.restOut, max(0, covered - topSum)))
    }

    /// 某条热点弧此刻画多大：量到的减去已经从这条弧上搬走的。
    /// 搬走不等于腾出——磁盘「已用」一个字节都没少，所以这些字节只能在弧之间挪家。
    func arcSize(of path: String) -> Int64 {
        let size = (hotspots + restHotspots).first { $0.path == path }?.size ?? 0
        return max(0, size - movedLedger.out(of: path))
    }

    /// 没进列表的那些小目录，此刻还在原处的合计。
    ///
    /// 尾巴那句对账用它而不是 `unlistedBytes`：后者是这一轮量到的原始数，而
    /// 「其他已统计」那条弧已经减掉了搬走的部分——从一个小目录里清掉几百 G 时，
    /// 按原始数加就会加出一个比弧还大的三段。
    var unlistedNet: Int64 {
        let listed = Set((hotspots + restHotspots).map { $0.path })
        var gone: Int64 = 0
        for (path, bytes) in movedLedger.perOther where !listed.contains(path) { gone += bytes }
        return max(0, unlistedBytes - gone)
    }

    /// 这一行底下被搬走了多少。行上那句「已移入废纸篓 X」用它，跟弧上减掉的是同一个数。
    func movedOut(of path: String) -> Int64 { movedLedger.out(of: path) }

    /// 这条弧动得了多少 = 它名下**知识库点名为安全、且此刻还在原处**的那几处缓存。
    ///
    /// 只认知识库这一条来源，不认「这目录没进保护名单所以整段算能清」。后者在真机上量出来是：
    /// 家目录 161 项里 151 项通过，招牌画面于是许诺「125.9 GB 动得了」，而那一按下去搬的是
    /// 27 GB 的私人备份、`~/.qoder`、几个正在跑的工程目录。**行上给不给删除键**和
    /// **工具替不替你点齐**是两件事：前者是人一个个挑，后者是产品许的诺，只能按白名单许。
    /// 少报的代价是这一屏再补几轮知识库；错报的代价是用户的东西没了。
    func reclaimable(of path: String) -> Int64 {
        min(arcSize(of: path), cacheTargets[path]?.reduce(Int64(0)) { $0 + $1.size } ?? 0)
    }

    /// 某一处**子目录**名下动得了多少：把每一桶里落在它名下的那几处加起来。
    ///
    /// `reclaimable(of:)` 的键只有列表里那几行（弧对应的目录），而 `~/Library/Caches`
    /// 住在 `~/Library` 那一桶里。直接拿它去查会得到 0，于是父行写着「12.0 GB 可回收」、
    /// 它名下每一行都写着「只能看」——2026-09-26 实拍摊开的 `~/Library` 那一屏到的正是这个。
    /// 桶里的目标过 `dropNested`（父项已计就不重复加子项），跨桶相加因此不会双算。
    func reclaimableUnder(_ path: String) -> Int64 {
        var sum: Int64 = 0
        for ts in cacheTargets.values {
            for t in ts where t.path == path || t.path.hasPrefix(path + "/") { sum += t.size }
        }
        return sum
    }

    /// 这条弧上点名要搬走的那几处。`take` 只搬这里列出来的，一处不多。
    func reclaimTargets(of path: String) -> [ReclaimTarget] {
        cacheTargets[path] ?? []
    }

    // MARK: 缓存可回收账（来自缓存页那本知识库，同一趟体积统计）

    /// 「其他已统计」那条弧的归账键。它不对应某一个目录，所以不能用路径当键。
    /// 值住在 Core（`reclaimRestKey`）：它和 `reclaimBucket` 是一对约定，自检要钉得住。
    static let restBucketKey = reclaimRestKey

    /// 按弧归好的缓存可回收目标。键是弧对应的目录路径，`restBucketKey` 收其余的。
    private(set) var cacheTargets: [String: [ReclaimTarget]] = [:]

    /// 「其他已统计」那条弧名下、列表里真的有一行的那些行（第 4 名往后）。
    private var restRows: [String] {
        Array(hotspots.dropFirst(3).map { $0.path } + restHotspots.map { $0.path })
    }

    /// 那条弧上点名要搬走的每一处：列表里第 4 名往后的每一行名下知识库判安全的那几处，
    /// 加上没落进任何一行的那几处（`__rest__` 桶）。
    ///
    /// 这里曾有过第二条来源——「整段就能搬走的行记那一行本身」。它在演示树上看着对
    /// （`~/.npm`、`~/.m2` 确实能整段搬），搬到真机上就把用户的备份工程一并计进了承诺，
    /// 所以删掉：这条弧的数与下面列表尾巴那句「本工具动得了」现在同源于知识库，一处不多。
    func restReclaimTargets() -> [ReclaimTarget] {
        var t: [ReclaimTarget] = []
        for p in restRows { t.append(contentsOf: cacheTargets[p] ?? []) }
        t.append(contentsOf: cacheTargets[Self.restBucketKey] ?? [])
        return t
    }

    /// 那条弧动得了多少：点名要搬的合计，钳在弧此刻的体积以内（理由同 `reclaimable(of:)`）。
    func restReclaimable(_ arc: Int64) -> Int64 {
        min(max(0, arc), restReclaimTargets().reduce(0) { $0 + $1.size })
    }

    /// 代价读法那两行勾选框名下的候选：`零代价` = 池里的 `safe`，`需重下` = `redo`。
    /// 池子本来就只收这两档，所以这两行加起来正好是主按钮许的诺；
    /// `不可逆` 从不进一键路径，它那一行因此没有框。
    func poolTargets(_ tier: VerdictTier) -> [ReclaimTarget] {
        cleanPool.filter { $0.tier == tier }
            .map { ReclaimTarget(path: $0.path, size: $0.size) }
    }

    /// 应用缓存与开发缓存两台模型。环形认的是「知识库里量出来的那几处」，
    /// 不分页——少接一台，一键腾出的数就会少掉整个开发工具那一坨。
    /// 强引用不成环：两台模型都不回头指总览，而三方都由 `ScanStore` 持有。
    private var cachesModels: [CachesModel] = []
    private var cachesSubs: [AnyCancellable] = []

    /// 由 `ScanStore` 在构造时接线：缓存页每落地一处体积，这边重归一次账。
    /// 订阅而不是轮询：体积是一条条异步量完的，靠定时刷会出现「弧上刚亮起来、数还是旧的」。
    ///
    /// 但「订阅」不等于「逐条响应」。缓存页一趟扫描能连发上百条变更，而每一条都要在
    /// **主线程**上把全部候选路径 stat 一遍、判一遍可删/受保（`rebuildCacheTargets`
    /// 接着 `rebuildCleanCandidates`）。实测扫描期这样能把主线程一口气压住 1.4 秒：
    /// 环还在转，整页却冻住。所以变更只立个记号，攒到结算点统一算一遍。
    func bind(caches: [CachesModel]) {
        cachesModels = caches
        cachesSubs = caches.map { model in
            model.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.cachesChanged() }
        }
    }

    /// 结算窗口：一个窗口最多算一遍。取 0.12 秒——远大于一帧（不至于每帧都在重算整本账），
    /// 又短到数换过去时人看不出延迟。
    private static let cachesSettleWindow: TimeInterval = 0.12
    private var cachesPending = false
    private var cachesSettle: DispatchWorkItem?

    private func cachesChanged() {
        cachesPending = true
        guard cachesSettle == nil else { return }   // 本轮窗口里已经排上了，不用再排
        // 结算排在窗口末尾、不跟着新变更往后挪。扫描期变更能连续几分钟，挪成「静默了才算」
        // 就变成环形一直停在旧数上——那正是这层订阅当初要防的事。
        let job = DispatchWorkItem { [weak self] in self?.settleCaches() }
        cachesSettle = job
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.cachesSettleWindow, execute: job)
    }

    private func settleCaches() {
        cachesSettle = nil
        guard cachesPending else { return }
        cachesPending = false
        // `cacheTargets` 没挂 `@Published`（它只在被读时用到），所以这一条得手动发：
        // 不发，环形和主按钮不会跟着重画。
        objectWillChange.send()
        rebuildCacheTargets()
        reclaimPulse += 1
    }

    /// 重新归一次缓存可回收账。扫描收尾、缓存体积落地、真搬走过东西，都要重跑这一趟。
    ///
    /// 三条规矩：
    /// 1. 只认知识库标 `safe` 的条目。`warn` 那些（整机备份、Docker 数据、废纸篓本身）
    ///    留给缓存页逐条勾着清，不进这颗一键按钮——那一按要搬十几处，不能拿它们赌。
    /// 2. 父项已计入就不重复加子项（`~/Library/Caches` 套着 `Homebrew` 是同一段字节）。
    /// 3. 按**列表里每一行**归，不只按前三名归——不然列表尾巴那句「能进废纸篓 / 只能看」
    ///    只能按「整处搬不搬得走」算，跟圆心上那个数当场打架。没落进任何一行的归到
    ///    `restBucketKey`，仍然算在「其他已统计」那条弧头上，一分不丢。
    func rebuildCacheTargets() {
        let fm = FileManager.default
        let rows = (hotspots + restHotspots).map { $0.path }
        let gone = movedBytesByKey
        var sizeOf: [String: Int64] = [:]
        for it in cachesModels.flatMap(\.items) {
            guard it.entry.level != "warn" else { continue }
            for (p, measured) in it.pathSizes {
                let sz = cacheBytesNow(p, measured: measured, gone: gone)
                guard sz > 0 else { continue }
                guard isDeletable(URL(fileURLWithPath: p)) else { continue }
                guard fm.fileExists(atPath: p) else { continue }   // 已经搬走的不许再报
                // 同一条路径被两处知识库命中时留第一次那个数（原来取 `hits.first`）。
                if sizeOf[p] == nil { sizeOf[p] = sz }
            }
        }
        var map: [String: [ReclaimTarget]] = [:]
        for p in dropNested(Array(sizeOf.keys)) {
            let key = reclaimBucket(of: p, in: rows) ?? Self.restBucketKey
            map[key, default: []].append(ReclaimTarget(path: p, size: sizeOf[p] ?? 0))
        }
        cacheTargets = map
        rebuildCleanCandidates()
    }

    /// 本工具已经搬走的那几处，路径先标准化好、按字节带着。
    ///
    /// 循环外算一次是有原因的：`cacheBytesNow` 要对**每个候选路径**扫一遍整条搬走历史，
    /// 历史几百条 × 候选几百处，放在函数里就是几十万趟 `URL` 构造。一趟重归账只标准化一次。
    private var movedBytesByKey: [(path: String, bytes: Int64)] {
        moved.map { (URL(fileURLWithPath: $0.original).standardizedFileURL.path, $0.bytes) }
    }

    /// 一处缓存此刻还在原处的字节：缓存页量到的那笔，减去已经被本工具搬走的。
    ///
    /// `pathSizes` 是缓存页那一趟量出来的快照。`~/Library/Caches` 这类父项的
    /// 安全子项被搬走之后，目录本身还在，旧数里却仍含着已经不在原处的字节——
    /// 不扣，结果页就会报出一笔「还剩」的假账（实测：搬完 7 处后仍挂着 1.9 GB）。
    /// 只减不重测：重扫之前宁可少报，不许错报。
    private func cacheBytesNow(_ path: String, measured: Int64,
                               gone: [(path: String, bytes: Int64)]) -> Int64 {
        let p = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = p + "/"
        var sum: Int64 = 0
        for m in gone where m.path == p || m.path.hasPrefix(prefix) { sum += m.bytes }
        return max(0, measured - sum)
    }

    // MARK: 首次清理：候选池、选择、执行

    /// 首次清理走到哪一步。nil = 还在总览。
    @Published private(set) var cleanStage: CleanStage? = nil
    /// 可以逐条勾选的缓存。和 `cacheTargets` **不是同一批**：那边只收 `safe`，
    /// 这里还要把 `redo` 摆出来让人自己决定——只报一半，用户会在缓存页看见
    /// 另一批能清的东西，却在这条「首次清理」的路上找不到它们。
    ///
    /// `didSet` 只做一件事：作废那份勾选索引。清单里每一行的勾和总览主按钮
    /// 读的是同一份账，这份账一变，两边必须跟着变，不能让两处各存一份状态。
    ///
    /// 它**不是 `@Published`**：清单里勾一行只该重画那一行和主按钮，不该把整棵视图树重建一遍。
    /// 代价是改池子的入口要自己发一次整页变更，漏一处的症状是「清单页按了没反应」，
    /// 所以下面那几处（清单勾选、重建、撤销回填）都留了指回这里的注释。
    private var poolBacking: [CleanCandidate] = [] {
        didSet { selectedFlagsCache = nil }
    }
    var cleanPool: [CleanCandidate] { poolBacking }
    /// 四类代价账的前三类。跟 `poolBacking` 一样**不是** `@Published`：
    /// 它在同一趟重建里算完，搭那次 `poolChanged()` 一起发，不许再立第二条变更线。
    private var costSumsBacking = CostSums()
    /// 悬停那条通知线。住在模型里而不是视图的 `@State` 里，只为一件事：
    /// 探针要能按手指走的那条路去指一行（见 `applyHoverToken`）。
    let hoverSignal = LedgerHoverSignal()
    /// 池子被勾选以外的途径改了：清单页的勾、知识库重建、搬完/撤销后回填。
    private func poolChanged() { objectWillChange.send() }
    @Published private(set) var cleanBusy = false
    @Published private(set) var cleanRun: CleanRun? = nil

    var cleanSelected: [CleanCandidate] { cleanPool.filter(\.selected) }
    var cleanPoolBytes: Int64 {
        contentsUnionSize(cleanPool.map { (path: $0.path, bytes: $0.size) })
    }
    var cleanSelectedBytes: Int64 {
        contentsUnionSize(cleanSelected.map { (path: $0.path, bytes: $0.size) })
    }
    var cleanScanning: Bool { cachesModels.contains { $0.scanning } }

    // MARK: 「这一笔」的合计（选哪几处在清理清单里做）

    /// 候选池里每一处此刻勾没勾、多大。懒算一份索引，池子一变就作废（见 `poolBacking`）：
    /// 总览那一列每屏要查七八行 × 每行几十处，逐行现扫整池就是几百趟重复比对。
    private var selectedFlagsCache: [String: (on: Bool, bytes: Int64)]?
    private var selectedFlags: [String: (on: Bool, bytes: Int64)] {
        if let c = selectedFlagsCache { return c }
        // 同一路径不该在池里出现两次（按路径归并且 `dropNested` 过），但字典不许赌：
        // `uniqueKeysWithValues` 撞上就 trap，这里留第一条。
        let c = Dictionary(cleanPool.map { ($0.path, ($0.selected, $0.size)) },
                           uniquingKeysWith: { a, _ in a })
        selectedFlagsCache = c
        return c
    }

    /// 「这一笔」此刻的合计：候选池里真勾着的那几处。
    ///
    /// 账本行首不再有勾选框（2026-10-22，按他的要求撤掉）：改选择只有清理清单一个入口。
    /// 这里仍要现读池子，因为清单里取消过的项关掉再回来还得算数；池里一处都找不到的段
    /// 按全额算——它本来就不由选择说话，剔掉会让按钮比同一屏的导语少一截。
    ///
    /// `all` = 池里每一处都还勾着，按钮照旧报「可回收的 n 处」；有人取消过就改报
    /// 「选中的 n 处」，免得同一屏两个数对不上。
    func pickedTotals(of segs: [GaugeSegment]) -> (bytes: Int64, places: Int, all: Bool) {
        var bytes: Int64 = 0, places = 0
        var all = true
        let flags = selectedFlags
        for seg in segs where seg.reclaim > 0 {
            var inPool = 0, on = 0
            var onBytes: Int64 = 0
            for p in seg.targets.map(\.path) {
                guard let f = flags[p] else { continue }
                inPool += 1
                if f.on { on += 1; onBytes += f.bytes }
            }
            if inPool == 0 {
                bytes += seg.reclaim
                places += seg.targets.count
            } else {
                bytes += min(seg.reclaim, onBytes)
                places += on
                if on != inPool { all = false }
            }
        }
        return (bytes, places, all)
    }

    /// 探针悬停用的那几段。只记「指着它会亮」的段：跟账本行 `onHover` 的闸门
    /// （`seg.value > 0`）同一道，不然探针会去指一行屏上根本没有悬停反应的行。
    private(set) var hoverLabels: [String] = []
    private var hoverCursor = -1
    func recordHoverLabels(_ labels: [String]) {
        hoverLabels = labels.filter { !$0.isEmpty }
    }

    /// 口令指一下某一段。探针走这里，落点和行/弧的 `onHover` 是同一个 `hoverSignal.set`：
    /// 探针不另置一份悬停状态，也不绕 `AppStore`——那一发会让每一页都重绘，
    /// 量到的就不是悬停的账了。
    ///
    /// `cycle` 按人手的节奏来：进一行、出一行，每一拍在两件事之间交替。只进不出
    /// 量的是「一直有人停着」，跟手扫过一列的真样子不是一回事。
    @discardableResult
    func applyHoverToken(_ token: String) -> Bool {
        let labels = hoverLabels
        guard !labels.isEmpty else { return false }
        switch token {
        case "none":
            hoverSignal.set(nil)
        case "cycle":
            if hoverSignal.label != nil {
                hoverSignal.set(nil)
            } else {
                hoverCursor = (hoverCursor + 1) % labels.count
                hoverSignal.set(labels[hoverCursor])
            }
        default:
            guard let i = Int(token), labels.indices.contains(i) else { return false }
            hoverSignal.set(labels[i])
        }
        return true
    }

    func openFirstClean() {
        disarm()
        cleanRun = nil
        rebuildCleanCandidates()
        cleanStage = .candidates
    }

    func closeFirstClean() {
        cleanStage = nil
        cleanRun = nil
        cleanBusy = false
    }

    func setCleanSelected(path: String, _ on: Bool) {
        guard let i = poolBacking.firstIndex(where: { $0.path == path }) else { return }
        poolBacking[i].selected = on
        // 清单页每一行那颗勾读的就是这一处，要的是整页变更（见 `poolBacking` 那条注释）。
        poolChanged()
    }

    func setAllCleanSelected(_ on: Bool) {
        for i in poolBacking.indices { poolBacking[i].selected = on }
        poolChanged()
    }

    /// 「只勾没影响的」：把 `redo` 全部撤掉，`safe` 全部勾上。
    /// 这不是「全选」的别名——两个按钮挨着放，做的事必须分得开。
    func selectCleanSafeOnly() {
        for i in poolBacking.indices { poolBacking[i].selected = poolBacking[i].tier == .safe }
        poolChanged()
    }

    func advanceToConfirm() {
        guard !cleanSelected.isEmpty else { return }
        cleanStage = .confirm
    }

    func backToCandidates() {
        cleanStage = .candidates
    }

    /// 逐条重归候选池与四类代价账。扫描收尾、缓存体积落地、真搬走过东西都走这里。
    ///
    /// 去重的口径比 `cacheTargets` 多一层：`safe` 和 `redo` 各自去嵌套之后，
    /// 还要把「`redo` 是某个 `safe` 候选的祖先或后代」的那些剔掉。`~/Library/Caches`
    /// 是 `redo`，它底下躺着几个 `safe`——不剔的话整条 `Caches` 会把那几处吞掉，
    /// 而按整条搬又比按处搬危险，正好和这条路径「一处一处看代价」的承诺相反。
    func rebuildCleanCandidates() {
        let fm = FileManager.default
        let rows = (hotspots + restHotspots).map { $0.path }
        let gone = movedBytesByKey
        var raw: [(path: String, size: Int64, item: CacheItem)] = []
        // 代价账要把 `risky` 也数进来：池子只摆 `safe`/`redo`，而「不可逆」那一类
        // 只在 `warn+data` 上——不收它，四类里的第三类永远是零。
        // 过筛与池子同一条（存在、可删、不受保、扣掉已搬走的），两本账才是同一块盘。
        var costItems: [CostItem] = []
        for it in cachesModels.flatMap(\.items) {
            let tier = it.entry.tier
            for (p, measured) in it.pathSizes {
                let sz = cacheBytesNow(p, measured: measured, gone: gone)
                guard sz > 0 else { continue }
                let url = URL(fileURLWithPath: p)
                guard fm.fileExists(atPath: p), isDeletable(url), !isProtected(url) else { continue }
                costItems.append(CostItem(path: p, bytes: sz, tier: tier))
                guard tier == .safe || tier == .redo else { continue }
                raw.append((p, sz, it))
            }
        }
        // 同一条路径被两条知识库条目命中时 `safe` 优先：保守的那一档是给人看的判词。
        var byPath: [String: (size: Int64, item: CacheItem)] = [:]
        for r in raw {
            if let prev = byPath[r.path] {
                if prev.item.entry.tier != .safe, r.item.entry.tier == .safe {
                    byPath[r.path] = (r.size, r.item)
                }
            } else {
                byPath[r.path] = (r.size, r.item)
            }
        }
        let safePaths = dropNested(byPath.filter { $0.value.item.entry.tier == .safe }.map(\.key))
        let safeSet = Set(safePaths)
        let redoPaths = dropNested(byPath.filter { $0.value.item.entry.tier == .redo }.map(\.key))
            .filter { rp in
                !safeSet.contains { sp in
                    sp == rp || sp.hasPrefix(rp + "/") || rp.hasPrefix(sp + "/")
                }
            }

        let previous = Dictionary(cleanPool.map { ($0.path, $0.selected) },
                                  uniquingKeysWith: { a, _ in a })
        var out: [CleanCandidate] = []
        for p in safePaths + redoPaths {
            guard let hit = byPath[p] else { continue }
            let entry = hit.item.entry
            let bucket = reclaimBucket(of: p, in: rows) ?? reclaimRestKey
            out.append(CleanCandidate(
                // `name`/`whatif`/`rec` 存的是 safety_db 里的中文原文，那同时就是本地化 key。
                // 缓存页取这三样时过了 `L()`（CachesView.swift:300），这一列没过的后果是
                // 英文界面下整张候选清单的条目名蹦回中文——2026-10-19 实拍英文候选页命中。
                // 在这里过一次而不是在各渲染处过：`CleanReceipt`/`CleanFailure` 抄的就是
                // 这个字段，结果页和失败行也得是本地化后的那一份。
                path: p, name: L(entry.name), size: hit.size, tier: entry.tier,
                bucket: bucket,
                bucketLabel: bucket == reclaimRestKey
                    ? L("其他已统计") : displayPath(URL(fileURLWithPath: bucket)),
                whatif: L(entry.whatif), rec: L(entry.rec),
                appID: entry.app, brand: entry.icon,
                selected: previous[p] ?? (entry.tier == .safe)))
        }
        let order = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
        out.sort {
            let a = order[$0.bucket] ?? Int.max
            let b = order[$1.bucket] ?? Int.max
            if a != b { return a < b }
            if ($0.tier == .safe) != ($1.tier == .safe) { return $0.tier == .safe }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.path < $1.path
        }
        let sums = costSums(of: costItems)
        if out != poolBacking || sums != costSumsBacking {
            costSumsBacking = sums
            poolBacking = out
            poolChanged()
        }
    }

    /// 四类代价账。O(1)：归账在重建那趟里已经算完，这里只把整盘容量配上去。
    /// 不许把这个计算挪进哪个 `body`——那是每帧几十上百次 stat。
    var costLedger: CostLedger? {
        usage.map { CostLedger(sums: costSumsBacking, total: $0.total) }
    }

    /// 真搬。一条一条走 `trashItem`，失败留在 `failures` 里点名。
    ///
    /// 搬走的当场从候选池里去掉；失败的那些留在池里，用户可以再试一次。
    /// 记录由调用方写进 `AppStore`（模型摸不到 store），所以这里收一个闭包。
    func performFirstClean(record: (TrashRecord) -> Void) -> CleanRun {
        let before = usage?.available ?? 0
        var records: [TrashRecord] = []
        var receipts: [CleanReceipt] = []
        var failures: [CleanFailure] = []
        var bytes: Int64 = 0
        cleanBusy = true
        defer { cleanBusy = false }
        for c in cleanSelected {
            do {
                let t = try trashItem(c.url)
                let r = TrashRecord(original: c.url, inTrash: t, size: c.size,
                                    displayName: c.url.lastPathComponent)
                record(r)
                records.append(r)
                receipts.append(CleanReceipt(path: c.path, name: c.name, size: c.size,
                                             tier: c.tier, appID: c.appID, brand: c.brand))
                bytes += c.size
            } catch {
                failures.append(CleanFailure(path: c.path, name: c.name,
                                             reason: error.localizedDescription))
            }
        }
        return CleanRun(records: records, receipts: receipts, failures: failures,
                        bytes: bytes, beforeAvailable: before)
    }

    func finishFirstClean(_ run: CleanRun) {
        cleanRun = run
        cleanBusy = false
        cleanStage = .result
        rebuildCleanCandidates()
    }

    /// 一处都没搬成：留在确认页，把原因摆在按钮旁边。不切结果页——
    /// 结果页只该在真的搬走之后出现。
    func noteFirstCleanFailure(_ run: CleanRun) {
        cleanRun = run
        cleanBusy = false
        rebuildCleanCandidates()
    }

    /// 撤销之后回到候选页，并把刚放回原处的那几处重新勾上。
    /// 不留在结果页：文件已经回来了，还挂着一张「已移入废纸篓」的账单就是假账。
    func reopenCandidatesAfterUndo(_ restored: Set<String>) {
        cleanRun = nil
        rebuildCleanCandidates()
        for i in poolBacking.indices where restored.contains(poolBacking[i].path) {
            poolBacking[i].selected = true
        }
        poolChanged()
        cleanStage = .candidates
    }

    func reopenCandidates() {
        cleanRun = nil
        rebuildCleanCandidates()
        cleanStage = .candidates
    }

    // MARK: 两段式确认（第一下上膛，第二下才真搬）

    /// 上了膛的那条弧，nil = 没上膛。状态在模型而不在视图的 @State：
    /// 挂在视图上，人切走一趟再回来计时器就蒸发了，弧上却还亮着亮沿假装「等你确认」。
    @Published private(set) var armedPath: String?

    private var armTask: Task<Void, Never>?

    /// 第一下：给这条弧上膛，并起 3.2 秒倒计时。换弧上膛先解除旧的。
    func arm(_ path: String) {
        disarm()
        armedPath = path
        armTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_200_000_000)
            guard !Task.isCancelled else { return }
            self?.disarm()
        }
    }

    /// 解除上膛：第二下搬完、点了别处、3.2 秒到点、重扫、切页都走这里。
    /// 顺带收掉预演（`previewing`）——离开「要动刀」这一档的两句话一起说才收得干净：
    /// 预演那个数是**还没发生的**，收不干净就是把它留在招牌上当成今天的可用空间。
    func disarm() {
        // 没上膛也没预演就不发变更：写在一个 `@Published` 上等于**再来一次整页
        // 重绘**，而点一条动不了的弧也会经过这里——它本来不该有「把整屏重画一遍」这个副作用。
        guard armedPath != nil || armTask != nil || previewing else { return }
        armTask?.cancel()
        armTask = nil
        armedPath = nil
        previewSignal.set(false)
    }

    // MARK: 预演（按住空格）

    /// 此刻正在看「全部清空之后」那一档。**状态仍旧只有一份、仍旧住在模型里**（同 `armedPath`
    /// 那条纪律：切走一趟再回来，这一档要么跟着蒸发、要么还亮着，两种都是假状态），
    /// 变的只是它**不走 `@Published`**：这一档要改的画面有五处，挂进整页那本账就是
    /// 一发空格重算一遍整页，实测数据记在 `PreviewSignal` 上面那段。
    /// 读的人照旧读 `model.previewing`，写的人只走下面那两个方法。
    ///
    /// 这是**整屏唯一一处还没发生的数**，所以每一条离开这一屏的路都要收掉它。收法与
    /// 卸膛合成一个动作（见 `disarm`）：预演与上膛本来就互斥——「全部清空后」和
    /// 「再点一次搬这一段」不能同时说，`beginPreview` 与 `arm` 各自进门都先卸对方。
    let previewSignal = PreviewSignal()
    var previewing: Bool { previewSignal.on }

    /// 进预演。能不能进由页面判（那本账在视图里算），这里只接结论。
    func beginPreview() {
        guard !previewing else { return }
        disarm()
        previewSignal.set(true)
    }

    /// 松开空格：只把预演收掉。
    ///
    /// 与 `disarm()` 分开的理由就一条：松手是**这一档自己的退路**，不该顺手把别的
    /// 状态一起清掉。极端情形是按住空格的同时用鼠标点了某一条弧（`arm` 会把预演顶掉，
    /// 于是此刻是「上了膛」而不是「在预演」），这一松手要是走 `disarm()`，那一发刚
    /// 上好的膛会跟着没——人看见的是「我按了个空格，你把我的确认取消了」。
    func endPreview() {
        guard previewing else { return }
        previewSignal.set(false)
    }

    /// 只刷磁盘余量——可用空间随时在变，进页面就该是新的；
    /// 热点体积要遍历整棵家目录，不能跟着一起重跑。
    func refreshUsage() { readVolume() }

    /// 盘容量和卷账一起读：环形用的是容器数，明细用的是分卷数，
    /// 两者不同源就会对不上账（自检卡的正是「五块加起来等于已用」）。
    /// 卷账走 `usedPhysical`：diskutil 报的是每个卷此刻真占掉的格子，
    /// 而界面上的「已用」是系统口径（可清除算可用），拿后者去减卷账会凭空少 10 GB。
    private func readVolume() {
        let u = volumeUsage()
        usage = u
        split = u.flatMap { volumeSplit(diskUsed: $0.usedPhysical) }
    }

    func refresh(scope: ScanScope) {
        task?.cancel()
        backfillJob?.cancel()
        backfillJob = nil
        // 旧一轮可能还有正在收尾的子任务：换掉 session 之后，它们对 `enterMeasuring`
        // / `exitMeasuring` 的调用会因为对不上号而作废，不会污染这一轮的在量名单。
        backfill = nil
        dropChildren()
        disarm()
        readVolume()
        scanning = true
        Prefs.shared.setGaugeRunning(true)
        started = true
        hasFDA = fullDiskAccessGranted()
        hotspots = []
        restHotspots = []
        // 水位线**不清零**：新一轮开跑那一刻，每条弧上最可信的尺寸仍然是上一次量到的那个，
        // 而它已经把旧账扣干净了。当场抹掉水位线等于让那些旧账复活，扫描途中那一截
        // 字节会被扣两遍（弧画小、废纸篓弧画大）。每条弧量完自己刷新自己的。
        cachedLedger = nil
        unlistedCount = 0
        unlistedBytes = 0
        covered = 0
        done = 0
        measuring = []
        needFDA = []
        needAdmin = []
        let targets = hotspotTargets(scope)
        scanTargets = targets.map { (name: $0.name, path: $0.path) }
        measuredTargets = [:]
        pending = targets.count
        let session = ScanBackfill()
        session.pending = targets.count
        backfill = session
        task = Task {
            targetPaths = targets.map { $0.path }
            await withTaskGroup(of: (Int, DirScan).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask {
                        await self.enterMeasuring(t.name, in: session)
                        let r = await dirSizeReport(URL(fileURLWithPath: t.path))
                        await self.exitMeasuring(t.name, in: session)
                        return (i, r)
                    }
                }
                // 组按完成顺序回，不是提交顺序——所以子任务必须把下标带回来。
                for await (i, r) in group {
                    if Task.isCancelled { break }
                    let t = targets[i]
                    guard backfill === session, let b = backfill else { break }
                    b.pending -= 1
                    b.done += 1
                    b.total += r.bytes
                    b.measured[t.path] = r.bytes
                    // 这一处的账现在是新量的了：量之前就已经搬走的那些当场作废，否则同一截
                    // 字节要扣两遍；量完之后新搬走的仍然要扣（见 Core 的 `voidedUpTo`）。
                    voidedUpTo[t.path] = moved.count
                    cachedLedger = nil
                    // 不设上限：这两串只被数个数拿去报「多少处读不动」。
                    // 掐到 60 条就等于对着 187 处说「有 60 处」，是个假数。
                    b.blame.merge(r)
                    if r.bytes > Self.sizeFloor {
                        b.sized.append((t.name, t.path, r.bytes))
                        b.sized.sort { $0.size > $1.size }
                    }
                    b.progressDirty = true
                    // 一处量完只登记，不发布：窗口到了由 `flushScanBackfill()` 一次写出去。
                    // 列表仍然「动」——每 0.2 秒一拍，环上的弧看得出在长。
                    scheduleScanFlush()
                    // 截图模式：热缓存下一趟整扫描不到半秒，「量到一半」那一帧根本截不到。
                    // 这里只把**回填的节拍**拉开，数字一个都不改——弧该长多大还长多大，
                    // 光该照在哪一格还照在哪一格，只是慢到快门跟得上。平时这个开关永远是关的。
                    if SnapshotMode.slowScanFill {
                        try? await Task.sleep(nanoseconds: 260_000_000)
                    }
                }
            }
            guard !Task.isCancelled, backfill === session else { return }
            // 收尾这一拍不再等窗口：把攒着的最后一处当场发出去，再把总账补齐。
            flushScanBackfill()
            let sizedBytes = session.sized.reduce(Int64(0)) { $0 + $1.size }
            let sizedCount = session.sized.count
            backfillJob?.cancel()
            backfillJob = nil
            backfill = nil
            scanning = false
            measuring = []
            // 走到这一行的唯一路径是上面那道 `!Task.isCancelled` 的守卫：这一轮是走完的，
            // 不是按停的。顶栏那句「量完 · …」只在这种时刻盖戳（见 `Prefs.noteGaugeFinished`）。
            Prefs.shared.noteGaugeFinished()
            // 环形加起来等于整块盘，列表这一头也必须能对上：摊到几行、剩下多少，
            // 当场说清。不然「其他已统计」那块弧里就有一截是谁都没报过的数。
            unlistedBytes = max(0, session.total - sizedBytes)
            unlistedCount = max(0, targets.count - sizedCount)
            // 「还能腾出多少」这个数不能只靠整段可搬：一台真机上大头在缓存里。
            // 量体积走的是缓存页同一本知识库、同一趟统计（`load` 自带只跑一次的闸），
            // 一处一处量回来之后，环形那道金弧和主按钮的数才有凭据。
            rebuildCacheTargets()
            cachesModels.forEach { $0.load() }
        }
    }

    func stop() {
        task?.cancel()
        // 停在窗口里的那几处不补发：账本来就不完整，留下最后一拍的数就够了。
        backfillJob?.cancel()
        backfillJob = nil
        backfill = nil
        scanning = false
        measuring = []
        // 按停的那一趟不盖「量完」的戳（见上面那道 `!Task.isCancelled` 守卫），
        // 但「还在跑」必须先撤——不然顶栏那一格再也没有落回来的时候。
        Prefs.shared.setGaugeRunning(false)
    }

    private func enterMeasuring(_ name: String, in session: ScanBackfill) {
        guard backfill === session, session.measuringSet.insert(name).inserted else { return }
        session.measuring.append(name)
        session.measuringDirty = true
        scheduleScanFlush()
    }

    private func exitMeasuring(_ name: String, in session: ScanBackfill) {
        guard backfill === session, session.measuringSet.remove(name) != nil else { return }
        session.measuring.removeAll { $0 == name }
        session.measuringDirty = true
        scheduleScanFlush()
    }

    /// 攒到窗口末尾再发布。跟缓存账的 `cachesSettleWindow` 同一条纪律：窗口**不跟着
    /// 新变更往后挪**——扫描能连续几分钟，挪成「静默了才算」就变成界面一直停在旧数上。
    private func scheduleScanFlush() {
        guard backfillJob == nil, let session = backfill else { return }
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.backfill === session else { return }
            self.backfillJob = nil
            self.flushScanBackfill()
        }
        backfillJob = job
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.scanFillWindow, execute: job)
    }

    /// 把缓冲一次性写进 `@Published`。只写这一拍真变过的那几组，少发几条无用的变更。
    private func flushScanBackfill() {
        guard let b = backfill else { return }
        if b.progressDirty {
            pending = b.pending
            done = b.done
            covered = b.total
            measuredTargets = b.measured
            needFDA = b.blame.needFullDiskAccess
            needAdmin = b.blame.needAdmin
            hotspots = Array(b.sized.prefix(Self.listCap))
            restHotspots = Array(b.sized.dropFirst(Self.listCap))
            b.progressDirty = false
        }
        if b.measuringDirty {
            measuring = b.measuring
            b.measuringDirty = false
        }
    }

    // MARK: 量下一级

    /// 量某一行的下一级。量过就直接回缓存，反复点不会重走子树。
    ///
    /// 走 `dirLevel` 的「只要目录」那一档，和文件夹详情页同一份实现。别在这里另写一份
    /// 「只列子目录、掐掉 0」的简化版：量到 0 在这些位置上几乎都是「读不动」，
    /// 一掐就会出现「总览里怎么点都看不见、详情页里却躺着」的目录。
    func measureChildren(of path: String) {
        guard childRows[path] == nil, childBusy.insert(path).inserted else { return }
        childTasks[path] = Task { [weak self] in
            let rows = await dirLevel(URL(fileURLWithPath: path),
                                      includeFiles: false, fileLimit: 0).entries
            // 中途重扫过：这趟是被掐断的，只量到几格，不能当成完整答案挂上去。
            guard !Task.isCancelled, let self else { return }
            self.childRows[path] = rows
            self.childBusy.remove(path)
            self.childTasks[path] = nil
        }
    }

    /// 重扫把摊开的下级一起作废：盘的账会走样，隔着一轮扫描还挂着旧数字，
    /// 等于让人拿上一次的账做今天的决定。
    private func dropChildren() {
        childTasks.values.forEach { $0.cancel() }
        childTasks = [:]
        childRows = [:]
        childBusy = []
    }

    /// 整盘比用户区多扫的那几处，用显示名（演示树会剥掉假家目录前缀）。
    var extraScanRoots: [String] {
        systemScanRoots().filter { $0.lastPathComponent != "Applications" }
            .map { systemRootName($0) }
    }

    /// 扫描对象 = 家目录一级（点目录算在内）+ /Applications + 范围内的系统根。
    ///
    /// 点目录必须算：开发机上最能吃盘的往往就是 ~/.omlx、~/.ollama 这类模型仓库，
    /// 只扫可见目录等于把整机最大的一块藏起来——实测一台机器上因此少报了 42GB，
    /// 而当时列表第一名只有 39.7GB。
    ///
    /// 顺序是「便宜的排前面」，不是随手写的：并发跑的是系统自己那几条工作线程，
    /// 谁先提交谁先占住一条。/Library、/private 这种整棵系统目录一跑就是几分钟，
    /// 放在队首会把线程全占满，家目录里几百毫秒就完事的小目录反而排不上，
    /// 实测整盘档因此出现「已量完 0 / 163」卡两分钟、列表一片空白。
    ///
    /// 去重按 `seen` 走，先到先得：演示树把 /Applications 挂在假家目录底下，
    /// 同一个 path 进两遍不是重复一行那么简单——列表以 path 作 ForEach 的 id，
    /// 第二条会占住行高却什么都不画，环形还会把它算两遍。
    private func hotspotTargets(_ scope: ScanScope) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ path: String) {
            guard seen.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted
            else { return }
            out.append((name, path))
        }
        let home = homePath()
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for k in kids.sorted() {
                // 废纸篓不进热点列表，跟别的扫描任务同一套规矩（见 ScanJobs）：
                // 环形上它搬走的字节有自己那条弧，列表里再量它一次就是把同一块字节记两遍。
                if k == ".Trash" { continue }
                let p = (home as NSString).appendingPathComponent(k)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    add("~/\(k)", p)
                }
            }
        }
        add("/Applications", applicationsDir())
        if scope == .disk {
            for r in systemScanRoots() where r.lastPathComponent != "Applications" {
                add(systemRootName(r), r.path)
            }
        }
        return out
    }

    /// 系统根的显示名用真实路径。演示树里 `<假家目录>/Library` 要显示成 `/Library`，
    /// 截图里的名字才跟真机一致。
    private func systemRootName(_ url: URL) -> String {
        guard homeIsDemo else { return url.path }
        let home = homePath()
        guard url.path.hasPrefix(home + "/") else { return url.path }
        return String(url.path.dropFirst(home.count))
    }
}

/// 环那一片的悬停订阅者**不在这里**：它已经拆成 `SweepRing` 里那几颗叶子
/// （`RingBands` / `RingGlowBands` / `RingNowLine`），页面和环的 body 都不订阅信号。
///
/// 收窄的经过（2026-10-22 配对实测，全部走 `PerfProbe` 的同一条注入路）：
/// 整页订阅时主线程 32–33%、p99 44–49 ms、每 24 s 约 100 次 >33.4 ms；
/// 收窄到这层 + 账本行三颗小叶子之后主线程 ~26%、p99 25–27 ms；
/// 最后把 `SweepRing.body` 也摘出去（搬去 CA 之前）：静置 17.3/17.6、悬停 19.6/19.9。
/// 环上那两条永续循环搬进 `CALoopView` 之后（见 `RingLayers` 文件顶），静置落到 1.5–1.7%、
/// p99 ~10 ms；终版悬停两对：静置 1.5/1.7、悬停 4.3/4.4，静置 1.5/1.6、悬停 4.4/4.5
/// （涨 2.7–2.9 个点），p99 悬停 13.5–14.0，>33.4 和 >100 都是零次——红线四条全过
/// （数见 `PerfProbe` 顶部）。
/// 搬走常驻循环才现形的一笔：圆心那行悬停说明原先排在 VStack 末尾，出现/消失带着整扇窗
/// 重跑 Auto Layout（悬停 p99 17.9、>33.4 23 次/24 s）；挪进布局之外的 overlay 才有上面这组数。

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var model: OverviewModel
    /// 这一圈按空间还是按代价读。存在偏好里，不是 `@State`：
    /// 换页回来还该是刚才那副面孔，而它是「这个人习惯怎么看盘」，不是一次性动作。
    @ObservedObject private var prefs = Prefs.shared

    /// 此刻是不是「按代价」。扫描中一律不是：四类账要等缓存清单量完，
    /// 扫描态那一圈报的是进度，跟读法无关。
    private var costReading: Bool { !model.scanning && prefs.overviewRead == .cost }

    /// 换读法：旧的上膛、摊开、悬停都只属于上一副面孔，得当场收掉。
    /// 不收的话，环换了一套段而 `armedPath` / `drillKey` 还指着旧段的键——
    /// 圆心会写「确认移入废纸篓」却找不到那一段，环还会缩成参照盘。
    private func setReadMode(_ mode: OverviewRead) {
        guard mode != prefs.overviewRead else { return }
        model.disarm()
        setDrill(nil)
        setHover(nil)
        arcNote = nil
        prefs.setOverviewRead(mode)
    }

    /// 页头那颗「按空间 / 按代价」。形状照样稿 `.readseg`：两片字、不带图标，
    /// 选中的那片用皮肤的淡主色——它必须和顶栏那颗「重新扫描」一眼分得开：
    /// 一颗是换看法、一颗是再量一遍，长得一样就是请人点错。
    ///
    /// 扫描中整颗不动：那一圈报的是进度，四类账要等缓存清单也量完才有分母。
    private var readSwitch: some View {
        HStack(spacing: 2) {
            ForEach(OverviewRead.allCases, id: \.self) { mode in
                let on = prefs.overviewRead == mode
                let label = mode == .space ? L("按空间") : L("按代价")
                Button { setReadMode(mode) } label: {
                    Text(label)
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(on ? theme.palette.tint : theme.palette.inkSecondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? theme.palette.tintSoft : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LF("%1$@：%2$@", L("读法"), label))
                .help(mode == .space
                      ? L("按空间：这一圈是「谁占了地方」")
                      : L("按代价：同一块盘，清掉它分别要付什么"))
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(theme.palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(theme.palette.separator, lineWidth: 1))
        .opacity(model.scanning ? 0.45 : 1)
        .allowsHitTesting(!model.scanning)
        .fixedSize()
        .animation(theme.animation, value: prefs.overviewRead)
    }

    /// 这一页原本三段：环旁边这本账、下面「没量到的地方」、再下面「最占地方的文件夹」。
    /// 同一批目录在三个地方各说一遍，而下面那两段讲的其实就是这本账里两段的下一级——
    /// 于是把那两段搬进它们各自对应的那一行，整页只剩一段，下钻就地完成。
    ///
    /// 摊开在哪一段读 `OverviewModel.drillKey`，不是这里的 `@State`：键取 `armKey`
    /// 不取路径（「其他已统计」「没量到」这两条弧没有路径，拿路径当键它们永远摊不开），
    /// 而**它要跨页留着**——切走再回来还摊在原处，理由见那个属性的注释。
    /// 鼠标停在面包屑那两个字上（决定那支 `←` 显不显形）。跟悬停那条线同一条纪律：
    /// 值真变了才写，AppKit 的 enter 不保证只来一次。它只影响这一块面包屑，
    /// 所以留在 `@State` 里没有整页的账。
    @State private var crumbHover = false
    /// 点动不了的弧时当场说清为什么。静默吞掉一次点击是最坏的结局：
    /// 人会以为是画面坏了，而不是「这一段这个工具不碰」。
    @State private var arcNote: String?
    /// 悬停键唯一的写入口。守卫「值真变了才写」在 `LedgerHoverSignal.set` 里：
    /// 写回同一个值也会发一次变更，而 AppKit 的 enter 事件不保证只来一次。
    /// **整页不再订阅它**：指着谁只由 `HoverRing` 和账本那几行里的小叶子接住。
    private func setHover(_ key: String?) {
        // 这一下只是在写信号，不碰任何 `@State`：悬停仍然不触发整页重排。
        // 换到新的一段才「咔」一声；离开（nil）不响——手指离开不该还要报一声。
        let changed = model.hoverSignal.label != key
        model.hoverSignal.set(key)
        if changed, key != nil { Sound.shared.play(.tick) }
    }

    /// 英雄卡那个命名坐标系。环心与废纸篓那一格都量在它里面，飞行才对得上——
    /// 量在两个坐标系里（一个局部一个全局），窗口一挪起点终点就分家。
    static let heroSpace = "overview.hero"

    /// 英雄卡里环与废纸篓那一格此刻的矩形，加上环上每一段弧的角区间。
    ///
    /// 这两份由 `heroFrame(_:in:)` 和 `SweepRing` 在**布局之后**报上来：触发那一刻去现量
    /// 量到的可能还是上一帧的框，而水珠的起点、落点和竖槽都要宽度，只报一个中心不够。
    ///
    /// 为什么不写成 `@State private var heroRects: [String: CGRect]`：**布局会跟着画面里
    /// 任何一次位移重来，而 @State 一写就是整页 `body` 重跑**。2026-10-22 归因出来的正是
    /// 这一条（同一棵合成家目录、30 s 探针、`DISKWISE_PERF_PREVIEW=0.4`、尾段 22.7 s）：
    /// 预演那一档环底下要装 102 pt 高的决策条，整块环被顶高 56 pt，按压一次来回两发位移，
    /// 每一发都写一次 @State（当时挂的是一发临时探针，往 stderr 报环那一格的 `y`；
    /// 数报完就摘了，结论留在这一段）。摘掉条子（`DISKWISE_BAR=off`）尾段 p99 73.6 → 20.4 ms、
    /// >33.4 ms 那格 88 → 19，而摘掉的既不是那几行字也不是那两颗钮——是**这一发回写**。
    ///
    /// 后来条子搬成了浮在环底下的 overlay（见 `PreviewBarHost`），位移从此不再有：
    /// 同一发探针量到环那一格的 `y` 只剩下开跑那几秒布局定的那几个值。留着这一段的理由
    /// 是它记的是**为什么这只盒子不能用 `@State` 存几何**——那笔账对以后任何一层都还成立。
    ///
    /// 读它的只有两处（`reclaimBurst` / `fireSnapshotBurstIfAsked`），都是按下去那一刻
    /// 现读，没有任何视图要订阅它，所以它不该带着「会触发重绘的存储」这层身份。
    ///
    /// 用 `@State` 装一只**类**：这里要的只是跨 body 的同一只盒子（@State 的初值一辈子
    /// 只用一次），而不是订阅。往里写走的是引用类型的属性、不是 @State 的 setter，
    /// 所以一次重绘都不触发。
    @State private var heroGeo = HeroGeo()

    /// 上面那两份几何的盒子。
    private final class HeroGeo {
        /// 环与废纸篓那一格在英雄卡命名坐标系里的矩形。
        var rects: [String: CGRect] = [:]
        /// 环上每一段弧的角区间。这一份是**画出来的**几何，页面不按 `regions(for:)`
        /// 再切一遍——那个函数会剔掉零值段，下标对不上弧。
        var arcs: [String: GaugeRegion] = [:]
        /// 环带厚度，跟弧表同一趟报上来（`RingArcMap.band`）。回收动效的每一档半径
        /// 都从它推，页面不许再按「环框宽的百分之几」估一遍。
        var band: CGFloat = 0
    }
    /// 正在演的那一趟回收。宿主按 `ReclaimBurst.id` 认新旧，
    /// 所以换掉这个值就是下一趟，同样的值重画不会重放。
    @State private var burst: ReclaimBurst?

    /// 废纸篓那一格的条子**正在等水珠落地**。只有回收那一趟把数顶上去时才有这段等待
    /// （见 `trashTray` 的动画）；别的改动没有水珠可等，等一下就读成「卡了一下」。
    @State private var trayLanding = false

    /// 候选页这一行摊没摊开「代价 / 路径」。一次只摊一行：这一列本来就长，
    /// 两行同时摊着会把下一组挤出视野。
    @State private var cleanDetail: String?

    /// 「本次移入废纸篓」那条虚线弧。它不落在这屏里——那些字节已经在废纸篓，
    /// 要真让位得去废纸篓页交给访达，所以点它跳的是**另一页**。
    private static let trashAnchor = "overview.gotoTrash"
    /// 「其他已统计」那条弧名下、还在封顶列表里的那些行（第 4 到第 20 行）。
    private var restGroupRows: [(name: String, path: String, size: Int64)] {
        Array(model.hotspots.dropFirst(3))
    }

    /// 摊开/收起某一段的明细。**一次只摊一段**：两段同时摊着的话，这一列读不出
    /// 「现在看的是谁」，而这一屏刚撤掉下面那两段列表，靠的就是这一段一段地摊。
    private func setDrill(_ key: String?) {
        withAnimation(reduceMotion ? nil : theme.animation) {
            model.drillKey = (model.drillKey == key) ? nil : key
        }
    }

    /// 只摊开、不来回翻：截图钩子（`DISKWISE_DRILL` / `DISKWISE_JUMP`）要的是「这一处摊开的样子」，
    /// 拿 toggle 去点它会随上一次的落点翻成收起，拍出来就是一张没有明细的图。
    private func openDrill(_ key: String) {
        guard model.drillKey != key else { return }
        withAnimation(reduceMotion ? nil : theme.animation) { model.drillKey = key }
    }

    /// 一个具体目录该摊在哪一行上。前三名各自是一条弧，键就是路径；
    /// 第 4 名往后全住在「其他已统计」那一行名下，摊它们得先摊开那一行。
    private func openChildDrill(_ path: String) {
        guard model.hotspots.prefix(3).contains(where: { $0.path == path }) else {
            openDrill(SegmentDrill.restGroup.key)
            return
        }
        model.measureChildren(of: path)
        openDrill(path)
    }

    /// 行首那个 `▸`。摊开某一段的下一级时顺手把量这趟派出去——`measureChildren`
    /// 自己认缓存，反复点不会重走子树。
    private func toggleDrill(_ seg: GaugeSegment) {
        if case .children(let path)? = seg.drill, model.drillKey != seg.armKey {
            model.measureChildren(of: path)
        }
        setDrill(seg.armKey)
    }

    /// 环与账之间那道间距（样稿 `.hero` 的 gap）。
    static let heroGap: CGFloat = 24
    /// 决策条浮在环下沿再往下 10 pt。只有这一个数是常量：条子的高由内容定（窄窗里那两行
    /// 会折行），浮着的偏移按**顶边**算，不去量它自己有多高。
    static let barGap: CGFloat = 10
    /// 右边这本账**压不动**的那一档：2026-09-28 在同一屏（900×700，`minWidth` 还是 900 的那一版）
    /// 逐颗点图量出来的——这一列给到 336 时，行尾那枚「GB」仍然顶在窗口边上溢出约 14 pt
    /// （`liveC/s232-900`）。336 是按各件宽度加出来的（内边距 8×2、记号槽 12、色块 8、
    /// 两道 12 间距、条子下限 136、`Spacer(minLength: 6)`、行尾 `›` 8 加 12、那枚数 ~78），
    /// 加出来比实拍少 20 pt：那枚数用的是 21 pt 的 `SizeNumber`，我按 17 pt 估的。
    ///
    /// 行首那一格是 16 pt 的槽（里面坐一颗 8 pt 色块，见 `RingLedgerRow.leadingSlot`），
    /// 比只放 8 pt 色块多要 8 pt → 356 抬到 364。这一档是环形那头的对手：它涨多少，
    /// 窗口收到窄档时环的直径就让多少，所以改行首那一格的尺寸必须同时改这里。
    static let ledgerFloor: CGFloat = 364
    /// 「没量到」那一行在 364 之上还要再要 48 pt（那颗带字的「去授权」比只有图标的宽这些）。
    /// 这一列窄到装不下时，那颗钮收成只有图标（`RingLedgerRow.grantCompact`），整行回到 364。
    static let ledgerGrantWidest: CGFloat = 412
    /// 环的最大直径。`ringDiameter` 与下面那个封顶宽共用这一个数。
    static let ringCap: CGFloat = 420
    /// 右边这本账的最大宽度。稿子 `.sidecol{width:364px;flex:none}` 是定宽的，
    /// 窗口变宽多出来的份落在留白上，不落在控件上；真机放到 480 是因为行尾比稿子
    /// 多一枚「去授权」（`ledgerGrantWidest`）。
    static let ledgerCap: CGFloat = 480
    /// 招牌那一屏（环 + 间距 + 这本账）的封顶宽。超过它窗口再宽也不再摊给这一栏，
    /// 多出来的份还给留白——封顶落在 `overviewPage` 的整列上，不只落在这块卡上。
    static let heroCap: CGFloat = ringCap + heroGap + ledgerCap
    /// 环这一档怎么算。**它不再是一个常量，而是「内容宽 − 间距 − 账压不动那一档之后剩下的」**：
    /// 写死 420 的那一版，窗口一窄就是整列数被推出窗口边硬切
    /// （2026-09-28 实拍：`39.7 GB` 只剩 `39.7 G`、「停止」只剩「停」）。
    ///
    /// 这一版只留**一个**约束：账先拿走它压不动的那 356，剩下的全给环，封顶 420。
    /// 上一版在这里多设了一档 430（账「想占」的那一档），于是默认窗口（内容 808）
    /// 环当场从 420 掉到 354——招牌那一屏上「这一圈 = 整块盘」的那句话被自己削掉了
    /// 六分之一，而他看到的就是这个（2026-09-28：「圆环是缩小了……很丑」）。
    /// 少的那 66 pt 本来就该从条子的满幅 232 里出，不该从环上出：条子短了仍然读得出
    /// 长短，环小了就不再是画面主角了。
    ///
    /// 兜底 132：参照盘就是这一档，它是这条渲染链上验证过能画出来的最小盘。
    ///
    /// - 上限 420：量出来的，不是凑的。样稿 `A-sweep.html` 的环外沿 412 CSS px、窗口
    ///   1180 px，占比 0.349；本机窗口 1278 pt 折算过来是 446。取 420 是被窗口高度 707
    ///   卡住的——再大整块英雄卡就顶到页头。上一版写 340（占比 0.266），实拍下来环缩成
    ///   画面里的一个小圆、旁边一列字撑满，「这一圈 = 整块盘」这句招牌话当场不成立。
    /// - 260 那一档不再是死线：弧上那六枚数要求 `diameter >= 260`（`Components.swift` 的
    ///   `arcLabel` 闸门），收到它以下弧上就没数了——名字、数、占比全交给右边那一列。
    ///   这一版只让环收到账压不动的那一档为止，所以窗口窄到环掉下 260 时，
    ///   读数的那副担子已经整个在那一列上了，环退成形状。
    /// - 参照盘 132：样稿 `r05-drill` 里 `.card.recede .ring` 就是 132 CSS px，
    ///   窗口 1278 pt 折算过来一比一。它还要留得住圆心那枚「可用」的数（0.21 倍直径
    ///   ＝27.7 pt，比旁边账目行的 17 pt 大），再小就退化成一个装饰饼图了。
    ///   下钻时这本账摊到了下一级，宽度全给它，环不参与分摊。
    private func ringDiameter(_ avail: CGFloat) -> CGFloat {
        if ringIsReference { return 132 }
        return min(Self.ringCap, max(132, avail - Self.heroGap - Self.ledgerFloor))
    }
    /// 这本账实际拿到的那一列有多宽——`heroColumn` 要靠它决定行尾那颗「去授权」
    /// 留字还是收成图标，而这一列的宽只有算环的这里知道。
    ///
    /// 它不再等于「窗口给剩下的一切」：整页在 `overviewPage` 里被 `heroCap` 封了顶，
    /// 所以传进来的 `avail` 最宽就是 `heroCap`，这一列最宽也就是 `ledgerCap`。
    private func ledgerWidth(_ avail: CGFloat) -> CGFloat {
        avail - Self.heroGap - ringDiameter(avail)
    }
    /// 环的**居中框高度**：按窗口算，不跟着右边这本账的高度走。
    ///
    /// 账摊到下一级时那一列能长到一千多点，而 HStack 会把自己拿到的整整一列高也提给
    /// 环这一格，于是 `.frame(maxHeight: .infinity, alignment: .center)` 把环拖到整列
    /// 中点——默认那扇 700 pt 高的窗里环心落在视线以下，读起来就是「环缩小了，还窝在
    /// 左下角」（2026-09-28 实拍）。
    ///
    /// 框 = 视口高 − 88。那 88 是这一屏要让给别处的：卡顶 16 + 卡片底下 `scopeNote`
    /// 与 `coverageLine` 那两行（各一行小字，实测约 56）+ 下沿呼吸 16。收它不是为了把
    /// 环抬高，是为了环居中的参照物是**窗口这一屏**，不是账目列的高度。
    /// 账比这个框短时它只是上限（仍按账居中，看不出差别）；长过它时环停在窗口正中。
    static let ringBoxInset: CGFloat = 88
    private func ringBox(_ viewportH: CGFloat, _ ring: CGFloat) -> CGFloat {
        max(ring, viewportH - Self.ringBoxInset)
    }
    /// 环上只有一处按直径等比的东西撑不住小盘：弧上那六枚数。带厚 19 pt、那段弧的
    /// 弧长十几 px，11 pt 的数会叠成一片字。参照盘不承担读数，数全在右边那一列。
    private var ringIsReference: Bool { model.drillKey != nil }
    /// 环上「其他已统计」那块弧的数，用列表这一头的段复述时要用同一个数。
    /// nil = 还没量完或分段算术不成立，那时不画分界线也不写对账。
    /// 扣减必须跟 `ringAccount` 同源：两处各算一遍，分界线上那个数就跟弧对不上了。
    private var restArcValue: Int64? {
        guard let u = model.usage else { return nil }
        let topSum = model.hotspots.prefix(3).reduce(Int64(0)) { $0 + $1.size }
        let ded = model.ringDeduction
        guard let s = ringSplit(covered: model.covered, used: u.used, topSum: topSum,
                                movedOutTop: ded.top, movedOutRest: ded.rest),
              s.restMeasured > 0 else { return nil }
        return s.restMeasured
    }
    private var darkSkin: Bool { (theme.scheme ?? colorScheme) == .dark }

    // MARK: 弧上那一下点击（两段式确认的状态机入口）

    /// 点一条弧，或点环旁对应的那一行账目。规矩跟原型一致：
    /// 动得了的弧要**点两下**，中间那一下只是上膛；动不了的那一下就把话说清。
    private func tapArc(_ seg: GaugeSegment) {
        // 第二下：同一条弧还亮着，就真搬。认的是 `armKey` 不是 `path`——
        // 「其他已统计」那条弧没有路径，拿路径当键的话它永远上不了膛。
        if let armed = model.armedPath, armed == seg.armKey, seg.reclaim > 0 {
            model.disarm()
            Sound.shared.play(.snap)
            let moved = take(seg)
            // 动效演的是**真搬走的**那一笔：一处都没搬动就不演，
            // 一把水珠飞进废纸篓而那本账没动，比不演更让人怀疑账错了。
            if moved > 0 {
                if !reduceMotion {
                    burst = reclaimBurst(seg, moved)
                    trayWaitsForLanding()
                }
                // 声音跟着那一趟的节拍走，不是三声一起按下去：响指是「确认」，
                // 收拢是「字节离开弧」，天亮是「落进废纸篓、账已改」。
                Sound.shared.play(.gather, after: ReclaimTimeline.releaseAt)
                Sound.shared.play(.dawn, after: ReclaimTimeline.dawnAt)
            }
            return
        }
        // 上膛期间点别的弧：先解除，再按那条弧自己的规矩办事。
        model.disarm()
        guard seg.reclaim > 0 else {
            arcNote = refuseNote(for: seg)
            // 指着某个具体目录的弧不就地摊：那句「为什么动不了」写在环形底下，
            // 摊开下级会把这句顶出视野。没有目录可摊的那几条弧（其他已统计 / 没量到）
            // 反过来——就地摊开就是答案，明细本来在这一本的哪一段名下已经说清了。
            if seg.path == nil {
                if seg.drill != nil { setDrill(seg.armKey) }
                else if seg.jumpTo == Self.trashAnchor { store.jumpTo = .trash }
            }
            return
        }
        arcNote = nil
        model.arm(seg.armKey)
        Sound.shared.play(.arm)
    }

    // MARK: 按住空格：预演「全部清空之后」（稿子③ 那一整块）

    /// 这一屏此刻是不是在「全部清空之后」那一档——**这个判据不再由页面算**。
    ///
    /// 盘心那三行、每一行小字末尾那截 `+N`、环底下那条决策条共用的是同一件事：
    /// 「这一笔还没发生的账正在被看着」。它们原先读同一个 `showingAfterClear`，而那一位
    /// 读 `model.previewing`——于是它一翻，整页重算一次（实测记在 `PreviewSignal` 上面）。
    /// 现在这几处画面各由自己那颗叶子判：环上是 `RingLayers.previewed` / `RingGainArcHost` /
    /// `RingEdgeLightsBands`，盘心是 `RingCenterReadout`，行里是 `LedgerSubLine`，
    /// 环底下那一格是 `AfterClearSlot`（它只管让位），浮在环底下的条子是 `PreviewBarHost`。
    /// 「松手就回去」要一处不漏，靠的还是同一条纪律：
    /// 每一颗叶子读的都是**同一根线**（`model.previewSignal`），上一档 `armedPath == "*"`
    /// 的那一位由页面补，因为那一档本来就在 `@Published` 上。
    ///
    /// 量具：`DISKWISE_BAR=off` 让那条决策条在预演/整圈上膛时不进树（稿子⑫）。
    /// 摘的是「浮在环底下的那一棵子树」这一下。它跟 `DISKWISE_CHIPS`（六行末尾那截绿字）、
    /// `DISKWISE_GAIN`（环上那截亮弧）、`DISKWISE_RINGDIM`（退到后面的那几段）是分开的四笔账：
    /// 2026-10-22 就是靠这几颗开关逐层量出「贵的是账那一列被重排」，然后把条子从账列里
    /// 搬出来的。规矩同 `DISKWISE_EDGE`。
    static let barMode: String = {
        (ProcessInfo.processInfo.environment["DISKWISE_BAR"] ?? "").lowercased()
    }()

    /// 这一圈的盘心此刻吃不吃预演那三行。空串 = 不吃（判据全在 `RingCenterReadout` 里）。
    ///
    /// 三条拒绝都和 `holdPreview` 那三句「为什么不让你按」同一判据：扫描中、正在量缓存、
    /// 代价读法。页面跟着 `scanning` 重算，所以这里读它是免费的。
    private var previewCenterRefused: Bool {
        model.scanning || model.cleanScanning || costReading
    }

    /// 预演那一档盘心的口径行。第一行仍是整块盘的分母（数从哪儿来必须当场看得见），
    /// 第二行说的是**这一笔还没发生**——这一屏只有这一档写的是未来的数，
    /// 所以它必须自己把「松手就回去」讲明白，不然人会把 26.8 抄下来当成今天的可用。
    private func previewCenterCap(_ acct: RingAccount) -> String {
        LF("整块盘 %1$@ · 已用 %2$@", acct.totalShown, acct.usedShown)
            + "\n" + L("这一笔还没发生 · 松开空格就回去")
    }

    /// 环正下方那一格装什么：装「点了一条动不了的弧，为什么动不了」那一句，
    /// 或「单条弧上了膛，这一按真会搬走哪些处」那份名单；整圈那一档让它空着
    /// （条子在那时浮在环底下，见 `heroCard` 里的 `PreviewBarHost`）。
    ///
    /// 上膛那一档**在这里念名单**（`armedLine`）：样稿 `?arm` 上只有盘心那两行
    /// （「确认移入废纸篓」/「再点一次才移进废纸篓 · 3 秒不点自动取消」）和那圈描边，
    /// 圆心写的是字节数，却没说这几字节是**哪些目录**——人只看见「缓存」两个字就得
    /// 凭想象决定要不要按第二下。2026-10-25 他对着这一屏说「不知道自己到底回收的是啥」，
    /// 于是把名单补在这一格：它念的不是盘心那句「下一步」的重复，而是盘心没有的信息
    /// （具体哪几处、共几处、多少字节）。手势不变，第二下才真搬。
    ///
    /// 这一格是 `inkSecondary` 的一行 plain text，不是带警告底的框：它跟「为什么动不了」
    /// 那句共用同一张嘴、同一种样式，眼睛此刻就在环底下，话就落在这儿。
    ///
    /// 从前这句跟在整张卡片的下面：默认那扇 700 pt 高的窗里它落在 807 pt 处，而
    /// 「点一条动不了的弧，当场把话说清」是这一屏唯一的反馈——2026-09-28 实拍：
    /// 1280x800 的 `-refused` 与静图零差异，换成 1500 高才看见那句话。
    /// 眼睛在环上，话就得落在环底下。
    @ViewBuilder
    private func ringBelow(showBar: Bool, ring: CGFloat, armedLine: String?) -> some View {
        if showBar {
            // 这一格这一档**什么都不装**。条子已经浮到环底下了（见 `heroCard` 里那颗
            // `PreviewBarHost`），这里剩下的活儿只有替它让位。
            EmptyView()
        } else if let armedLine {
            Text(armedLine)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ring, alignment: .leading)
        } else if let note = arcNote {
            Text(note)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: ring, alignment: .leading)
        }
    }

    /// 空格落下这一跳：先问这一屏能不能预演，不能就把话说清；能才进那一档。
    ///
    /// 判据读的是**页面上这一本账**（`ringAccount(u)`），不写进 `OverviewModel`：那本账
    /// 在视图里算，模型只知道自己那堆扫描状态。叫模型重算一遍就是养出第二本账，而这一屏
    /// 最容易塌的就是同屏两个数打架（见 `RingAccount` 上面那段）。
    ///
    /// 挡住的时候话仍旧只走 `arcNote` 那一格：它本来就是「点了一条动不了的弧，当场把
    /// 话说清」那张嘴，钉在环正下方、眼睛此刻就在的地方。给它另开一格等于同一屏两句
    /// 「为什么不行」排队念。
    private func holdPreview() {
        // 连发已被 `SpaceHoldTap` 掐掉（只认第一发），这一条挡的是别处再调进来。
        guard !model.previewing else { return }
        if model.scanning {
            arcNote = L("这一圈还没量完：「全部清空之后」要有账才量得出来。")
            return
        }
        if model.cleanScanning {
            arcNote = L("正在量缓存…")
            return
        }
        // 代价读法不预演。那一屏的 `reclaimable` 是「零代价＋需重下」两类的可勾字节，
        // 而它整圈本来就不接上膛（`select == nil`）——预演条上那颗「就这样清」在代价
        // 读法里没有对应的动作，画一颗按不动的钮比不画更糟。
        if costReading {
            arcNote = L("代价读法不预演：那四类说的是「清掉要付什么」，不是「一口气能收走多少」。")
            return
        }
        guard let u = model.usage else { return }
        guard ringAccount(u).reclaimable > 0 else {
            arcNote = L("这一圈里没有本工具动得了的东西")
            return
        }
        arcNote = nil
        // 与「进清理清单」同一声：那一下也是「先看清楚，刀还没落」。
        Sound.shared.play(.preview)
        model.beginPreview()
    }

    /// 「就这样清」那一颗钮的两次按下——与弧上那两下同一条规矩：第一下上膛，第二下才搬。
    ///
    /// 走的是 `model.arm(SweepRing.armAll)` 这条**已有**的上膛路：整圈描边、3.2 秒自己
    /// 解除，条子上那颗钮跟着翻成「确认移入废纸篓 ⌘↵」。这里只是把
    /// 「点两次那一条弧」换成「点两次这条钮」，不另写一把确认刀。
    private func tapCleanAll(_ acct: RingAccount) {
        if model.armedPath == SweepRing.armAll {
            model.disarm()
            Sound.shared.play(.snap)
            let moved = takeAllReclaimable(acct)
            // 与单条弧同一条纪律：一处都没搬动就不演那趟飞行。
            if moved > 0, let seg = acct.hot.max(by: { $0.reclaim < $1.reclaim }),
               !reduceMotion {
                burst = reclaimBurst(seg, moved)
                trayWaitsForLanding()
                Sound.shared.play(.gather, after: ReclaimTimeline.releaseAt)
                Sound.shared.play(.dawn, after: ReclaimTimeline.dawnAt)
            }
            return
        }
        guard acct.reclaimable > 0 else {
            arcNote = L("这一圈里没有本工具动得了的东西")
            return
        }
        arcNote = nil
        model.arm(SweepRing.armAll)
        Sound.shared.play(.arm)
    }

    /// 为什么这一段动不了。三种原因得用三句话说，揉成一句「动不了」等于没说。
    private func refuseNote(for seg: GaugeSegment) -> String {
        if let hint = seg.hint { return hint }
        guard let path = seg.path else {
            return LF("%@：这一圈里的账，不是一个能整个搬走的位置。", seg.label)
        }
        let url = URL(fileURLWithPath: path)
        if isProtected(url) {
            return LF("%@ 是受保护的位置，整个搬走会伤到系统或你自己的资料。里面的东西能清——去别的清理页挑。", seg.label)
        }
        return LF("%@ 不在本工具动手的范围内（家目录、应用程序与 /tmp、/var/tmp 之外）。", seg.label)
    }

    /// 圆心那行副读（样稿 `.mid .now`）：鼠标停在谁身上，就把「是谁 · 占多少 · 我收得走多少」
    /// 写在盘心。眼睛此刻在环上，让人扭头去右边那列字里找同名的那一行就是惩罚读图的人。
    ///
    /// 只有两行，而且第二行是固定长度的短句：**不拿 `sub` 当这句话**。`sub` 是给右边那列
    /// 宽行写的整句解释（「密封系统卷等，任何清理工具都动不了」），塞进内孔就折成三行、
    /// 末行压到环带上把弧上的数盖住。动不了的那一段为什么动不了，此刻就在它旁边被点亮的那一行里。
    ///
    /// 两处中文都写成裸字面量、不放进 `\(...)`：对账脚本扫不到插值里的词条，会把它判成死键。
    private func centerNowLine(_ seg: GaugeSegment) -> String {
        if seg.reclaim > 0 {
            let can = LF("%1$@ 可回收", seg.reclaimShown)
            // 整段都动得了就不把同一个数念两遍：屏幕上「6.3 GB · 6.3 GB 可回收」读起来像
            // 出了 bug，而它想说的只是「这一段 6.3 全收得走」。比的是**印出来的**那两个字符串，
            // 不是字节——差一个字节但都显示成 6.3 的话，人看见的还是重复。
            return seg.label + "\n"
                + (seg.sizeShown == seg.reclaimShown
                    ? can : seg.sizeShown + " · " + can)
        }
        return seg.label + "\n" + L("这一段没有可回收的东西")
    }

    /// 第二下：把这条弧上点名的那几处搬进废纸篓，一处一次 `trashItem`。
    ///
    /// 只搬 `targets` 里列出来的那些——它们每一处都过了知识库 `safe` + 还在原处两道筛。
    /// 以前这里还有一条「弧上没点名就整处搬走」的路，配上「没进保护名单就算能搬」的判定，
    /// 一键按钮于是会把用户的备份目录整段拖走，所以整条拿掉。
    /// 不一次性标记：任何一处失败都得当场看见是哪一处、为什么，
    /// 不然人就只剩「软件把我东西弄丢了」这一种解释。
    ///
    /// 返回**真搬走的字节**，不是应该搬走的：这一趟有几处没搬动是常态（沙箱里的
    /// 诊断报告、别的 App 正在用的目录），拿去飞那一枚筹码的必须是到手的那个数。
    @discardableResult
    private func take(_ seg: GaugeSegment) -> Int64 {
        takeTargets(seg)
    }

    /// 一处一处搬，成功了几处、搬走多少字节、第一处失败为什么，三样都要留到最后那句话里。
    ///
    /// 「已移入废纸篓 12 处（8.4 GB），另有 3 处没搬动」这种句子必须是**真数**：
    /// 那句「还能腾出 22 GB」是按钮许的愿，搬完对不上而原因没说，这一屏就再没人信了。
    @discardableResult
    private func takeTargets(_ seg: GaugeSegment) -> Int64 {
        let r = moveTargets(seg.targets)
        var line = LF("已把「%1$@」名下的 %2$@移入废纸篓（%3$@）。这些字节还占着盘，去废纸篓页交给访达清空才真让位。",
                      seg.label, cnt(r.ok, "处"), human(r.bytes))
        line += failTail(r)
        store.notice = line
        return r.bytes
    }

    /// 预演条上那颗「就这样清」的第二下：把这一圈里动得了的**每一段**名下点名的处搬走。
    ///
    /// 一句汇总，不是六句：这一趟是一次动作，弹六条提示等于让人逐条核对一趟已经按完的账。
    /// 处数与字节全取**真搬到的**那些（`moveTargets` 的账），跟按钮上许的「共 N 处」
    /// 对不上时，那句「另有 x 处没搬动」必须自己把差额说出来。
    @discardableResult
    private func takeAllReclaimable(_ acct: RingAccount) -> Int64 {
        var all = MoveReceipt()
        for seg in acct.hot {
            let r = moveTargets(seg.targets)
            all.ok += r.ok; all.bytes += r.bytes; all.failed += r.failed
            if all.why.isEmpty { all.why = r.why }
        }
        var line = LF("已把这一圈里动得了的 %1$@移入废纸篓（%2$@）。这些字节还占着盘，去废纸篓页交给访达清空才真让位。",
                      cnt(all.ok, "处"), human(all.bytes))
        line += failTail(all)
        store.notice = line
        return all.bytes
    }

    /// 一处一处搬。成功了几处、搬走多少字节、第一处失败为什么，三样都要留到最后那句话里。
    ///
    /// 抽出来给两条路共用：一条弧的第二下（`takeTargets`）与预演条的第二下
    /// （`takeAllReclaimable`）。搬文件这件事只该有一份实现——两把刀迟早有一天砍得不一样。
    ///
    /// 「已移入废纸篓 12 处（8.4 GB），另有 3 处没搬动」这种句子必须是**真数**：
    /// 那句「还能腾出 22 GB」是按钮许的愿，搬完对不上而原因没说，这一屏就再没人信了。
    private func moveTargets(_ targets: [ReclaimTarget]) -> MoveReceipt {
        var r = MoveReceipt()
        for t in targets {
            do {
                let moved = try trashItem(t.url)
                store.record(TrashRecord(original: t.url, inTrash: moved,
                                         size: t.size,
                                         displayName: t.url.lastPathComponent))
                r.ok += 1
                r.bytes += t.size
            } catch {
                r.failed += 1
                if r.why.isEmpty { r.why = failReason(error) }   // 只留第一处的原因，句子才不失控
            }
        }
        return r
    }

    /// 一趟搬运的清点结果。
    private struct MoveReceipt {
        var ok = 0
        var bytes: Int64 = 0
        var failed = 0
        var why = ""
    }

    /// 有处数没搬动时挂在最后那句话说的那半句。两处（一条弧 / 整圈）共用同一条尾巴，
    /// 免得同一件失败在两个入口长成两种说法。
    private func failTail(_ r: MoveReceipt) -> String {
        guard r.failed > 0 else { return "" }
        // 系统给的那句原因自带句号（「你没有许可。」），照搬进模板就是「许可。。」。
        let cause = r.why.hasSuffix("。") || r.why.hasSuffix(".")
            ? String(r.why.dropLast()) : r.why
        return cause.isEmpty ? LF("另有 %1$d 处没搬动。", r.failed)
                             : LF("另有 %1$d 处没搬动，第一处的原因是：%2$@。", r.failed, cause)
    }

    // MARK: 上膛那一刻把名单念出来（第一下点亮 → 看清将搬什么 → 第二下才搬）

    /// 上膛（第一下）时，把「这一按真会搬走什么」当场念清楚：处数 + 字节 + 头几处的名字。
    ///
    /// 从前这一档只有圆心那个字节数和「再点一次才移进废纸篓」，人看不见名单，只能凭
    /// 「缓存」两个字想象自己要丢什么——2026-10-25 他对着这一屏说「很容易给人一种错觉，
    /// 不知道自己到底回收的是啥」。双击这个手势一字不改，只是第一下从「盲按两下」变成
    /// 「看一眼名单再确认」：搬哪些处、共几处、多少字节，全在第二下落刀之前摆出来。
    ///
    /// 名字取 `displayPath`（家目录缩成 ~），最多念三处，多的用「…」收口——这一格只有环
    /// 那么宽，念全了会折成一堵字，反而读不出重点。处数与字节都是**真会搬的那几处**
    /// （`seg.targets` / `acct.hot` 的 targets），跟第二下 `moveTargets` 搬的是同一批，
    /// 所以念出来的数和搬完那句「已移入废纸篓 N 处」对得上（差的只是当场没搬动的那几处，
    /// 那部分由 `failTail` 自己说）。
    private func pendingMoveLine(targets: [ReclaimTarget], label: String) -> String? {
        guard !targets.isEmpty else { return nil }
        let bytes = targets.reduce(Int64(0)) { $0 + $1.size }
        return LF("将移入废纸篓：%1$@ %2$@ · %3$@（%4$@）",
                  label, cnt(targets.count, "处"), human(bytes), namesTail(targets))
    }

    /// 头几处的名字，拼成「A、B、C…」。超过三处只念前三、尾巴一个省略号。
    private func namesTail(_ targets: [ReclaimTarget]) -> String {
        let names = targets.prefix(3).map { displayPath($0.url) }
        return names.joined(separator: "、") + (targets.count > 3 ? "…" : "")
    }

    /// 单条弧上膛时，环底下那一格要念的名单。整圈那一档（`armAll`）返回 nil——
    /// 它的名单由浮在环底下的预演条自己念（见 `previewBar`），同一屏不必念两遍。
    private func armedPendingLine(_ acct: RingAccount) -> String? {
        guard let armed = model.armedPath, armed != SweepRing.armAll else { return nil }
        guard let seg = acct.segs.first(where: { $0.armKey == armed }) else { return nil }
        return pendingMoveLine(targets: seg.targets, label: seg.label)
    }

    /// 这一趟回收的动效参数：被点的那一段弧、环那一格、废纸篓那一格、真搬走的字节。
    ///
    /// 两个矩形还没到手时不演（第一次进页面、布局还没落定）：那时候只能从猜出来的
    /// 点起飞，水珠会从卡片外头飞进来。宁可这一趟只有账变，也不要一条对不上的轨迹。
    private func reclaimBurst(_ seg: GaugeSegment, _ moved: Int64) -> ReclaimBurst? {
        guard let arc = heroGeo.arcs[seg.armKey],
              let ring = heroGeo.rects["ring"], let tray = heroGeo.rects["tray"] else { return nil }
        return ReclaimBurst(arc: arc, ring: ring, band: heroGeo.band, tray: tray,
                            bytes: moved, tint: SweepRing.lamp(theme.palette.tint))
    }

    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时演一格回收（0 = 水珠刚浮现，1 = 已落进废纸篓）。
    ///
    /// 这一趟不写真账：不调 `take`，只按环上此刻真能回收的那一段搭参数，
    /// 跟按两下会看到的那条轨迹同源。弧表与两个矩形都到手之后才发。
    ///
    /// 矩形换了要重发：取证这一趟里窗口会从 820 长到 852，环那一格跟着换尺寸换位置，
    /// 而 `ReclaimFXHost.layout()` 每轮都按**当前**矩形重画那一格定帧——攥着旧矩形，
    /// 拍出来的就是上一版布局的那一圈水珠。平时（非截图）这一句走不进来。
    private func fireSnapshotBurstIfAsked() {
        guard SnapshotMode.flightPhase != nil else { return }
        guard let u = model.usage, !model.scanning else { return }
        let acct = costReading ? costAccount(u) : ringAccount(u)
        guard let seg = (acct.ringSegs ?? acct.segs).first(where: { $0.reclaim > 0 }) else { return }
        guard let arc = heroGeo.arcs[seg.armKey],
              let ring = heroGeo.rects["ring"], let tray = heroGeo.rects["tray"] else { return }
        if let old = burst, old.ring == ring, old.tray == tray, old.arc == arc, old.band == heroGeo.band {
            return
        }
        burst = ReclaimBurst(arc: arc, ring: ring, band: heroGeo.band, tray: tray,
                             bytes: seg.reclaim, tint: SweepRing.lamp(theme.palette.tint))
    }

    /// 真机那一趟还在飞的时候，把矩形换成此刻量到的那一份。
    ///
    /// 只换字段、不换 `id`：`id` 一换，宿主会当成新的一趟从头排队；留着同一个 `id`，
    /// 它才认得出这是「同一趟的环挪了家」，走 `rebake` 那条重排。
    /// 为什么需要：凡是飞行途中改动滚动视口高的事都会让环挪家——环居中的那一片按视口高算
    /// （`ringBox(viewportH, ring)` 用在 `:3192`，`viewportH` 就是 `:1863` 那颗 `gate.size.height`），
    /// 视口一矮，**环在卡片自己的局部坐标里就挪了位**——整页一起平移不算错位，动效和环同属
    /// 这一张卡，平移是一起吃的；错位吃的正是这一格局部矩形没跟着换。而这一趟吃的是按下时
    /// 量到的那份矩形，一趟只 2.7 秒，够它错到底。
    ///
    /// 曾经命中的一条是回收提示条：它那时排在整页**上面**、占版面一行，一进来就把视口矮掉
    /// 一截。现在它按设计稿浮在内容区底沿（`.dbar`/`.pgtip` 都是 `position:absolute`，不占
    /// 版面），那条根因已经拔掉；留着这一手是为剩下的那些——主要是拖窗口下沿。
    /// 重排的窗口和代价由宿主把着，见 `ReclaimFXHost.rebake`。
    /// 收敛：只有真的不一样才写 `burst`，写完这一次布局不会再报同一个数。
    private func reliveBurstIfMoved() {
        guard burst != nil, SnapshotMode.flightPhase == nil,
              let ring = heroGeo.rects["ring"], let tray = heroGeo.rects["tray"] else { return }
        if burst?.ring == ring, burst?.tray == tray, burst?.band == heroGeo.band { return }
        burst?.ring = ring
        burst?.tray = tray
        burst?.band = heroGeo.band
    }

    /// 把 store 那本废纸篓账推给模型：环形每一帧都要读它，模型自己摸不到 store。
    ///
    /// 整串重推、不做增量：撤销链的形状就是「历史短了一截」，重新归一次位弧自己就回滚，
    /// 模型里不会留下第二本跟 store 对不上的账。
    private func syncMovedLedger() {
        model.setMoved(store.trashHistory.map { ($0.original.path, $0.size) })
    }

    /// 页面左右内边距。`pagePadding()` 里那个 20 在这里要参与算术（环按内容宽算），
    /// 所以这一屏不复用它：两处各写一个 20，改一处就会把账挤出窗口边。
    static let pagePad: CGFloat = 20

    private var scrollContent: some View {
        // ScrollView 在 macOS 13 会把**内容的理想宽**当成自己的宽报上去：900 pt 窗里
        // 内容列只有 664，它却按 ~716 排版，于是行尾那列数和页头那颗「重新扫描」
        // 一起被推出窗口边（2026-09-28 实拍）。所以先把它钉在外层给的那一档上——
        // 环的尺寸从这一档算，算完不会再回头改变这一档（上一版直接量 ScrollView，
        // 量到的就是它自己撑出来的宽，实测每轮 +3.5 pt 不收口）。
        GeometryReader { gate in
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metric.sectionGap) {
                    // 整页只剩这一段：环形旁边这本账，加上它自己摊开的下一级。
                    // 「没量到的地方」和「最占地方的文件夹」从前是它下面的另两段，
                    // 讲的却就是这本账里两段的明细——搬进它们各自那一行之后整段删掉。
                    if let u = model.usage {
                        heroCard(u, avail: gate.size.width - 2 * Self.pagePad,
                                viewportH: gate.size.height)
                            .padding(.horizontal, Self.pagePad)
                    }
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(width: gate.size.width, alignment: .leading)
            }
            .frame(width: gate.size.width, height: gate.size.height, alignment: .topLeading)
        }
    }

    var body: some View {
        Group {
            if let stage = model.cleanStage {
                firstCleanPage(stage)
            } else {
                overviewPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 结果页的账要跟着这一刀走；总览页自己那条 onChange 在流程开着时不在树上。
        .onChange(of: store.trashHistory) { _ in syncMovedLedger() }
        // 首次清理那几屏的截图口令。走的是页面上那几颗按钮自己的方法（见 `runFirstClean`），
        // 不是另画一条「看起来像确认页」的假路。
        .onChange(of: store.overviewClean) { token in handleCleanCommand(token) }
        // 切走这一页就把流程收掉：半截的选择和已经搬走的东西都不该带进下一页。
        .onDisappear {
            model.closeFirstClean()
            model.disarm()
            setHover(nil)
            arcNote = nil
        }
    }

    private func handleCleanCommand(_ token: String?) {
        guard let token else { return }
        store.overviewClean = nil
        switch token {
        case "open":
            model.openFirstClean()
        case "confirm":
            model.advanceToConfirm()
        case "run":
            runFirstClean()
        case "undo":
            undoFirstClean()
        case "close":
            model.closeFirstClean()
            store.notice = nil
        default:
            break
        }
    }

    /// 确认页那颗「移进废纸篓」：一次真搬。搬完把环的账、可用空间、顶部提示一起更新。
    private func runFirstClean() {
        guard model.cleanStage == .confirm, !model.cleanBusy, !model.cleanSelected.isEmpty
        else { return }
        Sound.shared.play(.snap)
        let run = model.performFirstClean { store.record($0) }
        if run.records.isEmpty {
            model.noteFirstCleanFailure(run)
            store.notice = run.failures.first.map { LF("没有搬动任何一处：%@", $0.reason) }
                ?? L("没有可搬动的候选")
            return
        }
        Sound.shared.play(.gather, after: ReclaimTimeline.releaseAt)
        Sound.shared.play(.dawn, after: ReclaimTimeline.dawnAt)
        model.finishFirstClean(run)
        syncMovedLedger()
        store.notice = run.failures.isEmpty
            ? LF("已移入废纸篓 %1$d 处，共 %2$@", run.records.count, human(run.bytes))
            : LF("已移入 %1$d 处，%2$d 处没搬动", run.records.count, run.failures.count)
        model.refreshUsage()
    }

    /// 结果页那颗「撤销本次移入」：倒序放回，再回到候选页（文件已经回来了，
    /// 还挂着一张「已移入」的账单就是假账）。
    private func undoFirstClean() {
        guard let run = model.cleanRun else { return }
        Sound.shared.play(.undo)
        let r = store.undoBatch(run.records)
        model.reopenCandidatesAfterUndo(Set(r.restored.map { $0.original.path }))
        syncMovedLedger()
        store.notice = r.failed == 0
            ? LF("已撤销本次移入，放回 %d 处", r.restored.count)
            : LF("还有 %1$d 处没放回：%2$@", r.failed, r.firstError ?? "")
        model.refreshUsage()
    }

    // MARK: - 首次清理三屏（候选 / 确认 / 结果）

    /// 三屏共用一副骨架：顶上一条「现在在哪一步」，页头，环 + 右栏，底下动作条。
    /// 环就是总览那一枚，只换圆心三行；弧、光、动效一律不碰。
    private func firstCleanPage(_ stage: CleanStage) -> some View {
        VStack(spacing: 0) {
            cleanBanner(stage)
                .pagePadding()
                .padding(.top, 10)

            cleanHeader(stage)
                .pagePadding()
                .padding(.top, 12)
                .padding(.bottom, 4)

            cleanBody(stage)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            cleanDock(stage)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func closeCleanPage() {
        cleanDetail = nil
        model.closeFirstClean()
    }

    // MARK: 横幅 / 页头

    private func cleanBanner(_ stage: CleanStage) -> some View {
        let symbol: String
        let text: String
        let ink: Color
        switch stage {
        case .candidates:
            symbol = "eye"
            text = L("选择中 · 只做选择，不动文件；取消勾选不会删除任何东西")
            ink = theme.palette.inkSecondary
        case .confirm:
            symbol = "lock.shield"
            text = L("确认 · 还没有动任何文件；这一步只核对，不写入")
            ink = theme.palette.inkSecondary
        case .result:
            // 处数与字节由这条横幅下面两样东西各自报过一遍：全局提示条（「已移入废纸篓
            // 3 处，共 1.2 MB」）和右栏「本次动作」那一档。横幅再报第三遍，同一屏就长出
            // 三条一模一样的话（2026-10-19 实拍）。这里只留提示条没说的那半句。
            symbol = "checkmark.circle.fill"
            text = L("空间还没释放——清空废纸篓后才是真的腾出来")
            ink = theme.palette.safeFG
        }
        return HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { closeCleanPage() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("回到总览"))
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(theme.controlShape().fill(theme.palette.surfaceAlt))
        .overlay(theme.controlShape().stroke(theme.palette.separator, lineWidth: 1))
    }

    private func cleanHeader(_ stage: CleanStage) -> some View {
        PageHeader(symbol: "internaldrive", title: cleanTitle(stage),
                   subtitle: cleanSubtitle(stage), variant: .display) {
            ThemeButton(kind: .ghost, symbol: "arrow.left", title: L("返回总览")) {
                closeCleanPage()
            }
        }
    }

    private func cleanTitle(_ stage: CleanStage) -> String {
        switch stage {
        case .candidates: return LF("可回收的 %1$@", human(model.cleanPoolBytes))
        case .confirm: return LF("确认这 %d 处", model.cleanSelected.count)
        case .result: return L("已移入废纸篓")
        }
    }

    private func cleanSubtitle(_ stage: CleanStage) -> String {
        switch stage {
        case .candidates:
            return LF("散在 %d 处。默认只勾没影响的；先看每一处的代价，再取消你不想清的。",
                      model.cleanPool.count)
        case .confirm:
            let n = model.cleanSelected.count
            let after = afterShown(cleanAvailable, plus: model.cleanSelectedBytes)
            guard let after else {
                return LF("将移入废纸篓的就是这 %d 处。可用不会当场变大——清空废纸篓后才会真正腾出来。",
                          n)
            }
            return LF("将移入废纸篓的就是这 %1$d 处。可用不会当场变大——清空废纸篓之后才是 %2$@。",
                      n, after)
        case .result:
            let before = model.cleanRun?.beforeAvailable ?? model.usage?.available ?? 0
            let bytes = model.cleanRun?.bytes ?? 0
            let after = afterShown(before, plus: bytes)
            if let n = model.cleanRun?.failures.count, n > 0 {
                guard let after else {
                    return LF("其中 %d 处没搬动，原因在右边点名。字节还在盘上——去废纸篓清空后才会真正腾出来。", n)
                }
                return LF("其中 %1$d 处没搬动，原因在右边点名。字节还在盘上——清空废纸篓后可用才会从 %2$@ 变成 %3$@。",
                          n, human(before), after)
            }
            guard let after else {
                return L("字节还在盘上——去废纸篓清空后才会真正腾出来。")
            }
            return LF("字节还在盘上——去废纸篓清空，可用才会从 %1$@ 变成 %2$@。",
                      human(before), after)
        }
    }

    /// 「可用会从 A 变成 B」里的 B：**只有印出来的两个数真的不同才成立**。
    ///
    /// 1.2 MB 加在 117.3 GB 上，两边 `human()` 出来都是 117.3 GB，那句话当场变成
    /// 「可用才会从 117.3 GB 变成 117.3 GB」（2026-10-19 实拍命中）。字节是真的涨了，
    /// 只是不到这块盘的显示精度——此时该说的是「清空后才会腾出来」，不是报一个假变化。
    private func afterShown(_ before: Int64, plus bytes: Int64) -> String? {
        let a = human(before)
        let b = human(before + bytes)
        return a == b ? nil : b
    }

    // MARK: 环 + 右栏

    private func cleanBody(_ stage: CleanStage) -> some View {
        GeometryReader { gate in
            let ring = cleanRingSide(gate.size)
            HStack(alignment: .top, spacing: 30) {
                cleanRingColumn(stage, ring: ring)
                    .frame(width: ring)

                Group {
                    switch stage {
                    case .candidates: cleanCandidatesColumn
                    case .confirm: cleanConfirmColumn
                    case .result: cleanResultColumn
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, Self.pagePad)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .frame(width: gate.size.width, height: gate.size.height, alignment: .topLeading)
        }
    }

    private func cleanRingSide(_ size: CGSize) -> CGFloat {
        // 宽和高谁先不够就收谁：环最小 210（再小盘心那三行就排不下），
        // 最大 330（样稿那一档；再大右栏就只剩一条缝）。
        let byHeight = size.height - 8
        let byWidth = size.width * 0.4
        return max(210, min(330, min(byHeight, byWidth)))
    }

    @ViewBuilder
    private func cleanRingColumn(_ stage: CleanStage, ring: CGFloat) -> some View {
        if let u = model.usage {
            let acct = ringAccount(u)
            SweepRing(segments: acct.segs,
                      centerTop: cleanCenterTop(stage),
                      centerValue: cleanCenterValue(stage, acct),
                      centerCap: cleanCenterCap(stage, acct, u),
                      diameter: ring,
                      // 这三屏里弧只负责报账，不接点选：勾选在右边那一列，
                      // 上膛的手势留在总览，免得同一屏出现两套「再点一下」。
                      select: nil,
                      armed: nil,
                      tapCenter: nil,
                      scanning: model.scanning,
                      scanProgress: scanFraction(u))
                .frame(width: ring, height: ring)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            VStack(spacing: 9) {
                ProgressView().controlSize(.small)
                Text(L("正在读这块盘的账…"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
            .frame(width: ring, height: ring)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func cleanCenterTop(_ stage: CleanStage) -> String {
        switch stage {
        case .candidates: return L("已选")
        case .confirm: return L("将移走")
        case .result: return L("可用")
        }
    }

    private func cleanCenterValue(_ stage: CleanStage, _ acct: RingAccount) -> String {
        switch stage {
        case .candidates, .confirm: return human(model.cleanSelectedBytes)
        case .result: return acct.availableShown
        }
    }

    /// 两行分开取词再拼，不把换行写进词条：词表闸门会把换行折成空格，
    /// 而运行时查词用的是原文的换行——一条带换行的 key 永远查不到译文。
    ///
    /// 每一行都得短到能在内孔里排下。上一版把「当前可用 … · 清空后 …」写成一句，
    /// 2026-10-19 实拍确认页那一屏时 `GB` 被甩成孤零零第三行——字号早已按直径等比
    /// （Components.swift 的 cap 那条），剩下的超长只能靠分行解决。
    private func cleanCenterCap(_ stage: CleanStage, _ acct: RingAccount, _ u: VolumeUsage) -> String {
        var lines: [String]
        var after: String?
        switch stage {
        case .candidates:
            lines = [LF("%1$d 处 · 占整盘 %2$@", model.cleanSelected.count, cleanPercentText),
                     LF("当前可用 %@", acct.availableShown)]
            after = afterShown(cleanAvailable, plus: model.cleanSelectedBytes)
        case .confirm:
            lines = [LF("%1$d 处 · 还没有动文件", model.cleanSelected.count),
                     LF("当前可用 %@ 不变", acct.availableShown)]
            after = afterShown(cleanAvailable, plus: model.cleanSelectedBytes)
        case .result:
            lines = [LF("整块盘 %1$@ · 已用 %2$@", acct.totalShown, acct.usedShown),
                     LF("本次入篓 %@", human(model.cleanRun?.bytes ?? 0))]
            after = afterShown(model.cleanRun?.beforeAvailable ?? acct.available,
                               plus: model.cleanRun?.bytes ?? 0)
        }
        if let after { lines.append(LF("清空后 %@", after)) }
        return lines.joined(separator: "\n")
    }

    private var cleanAvailable: Int64 { model.usage?.available ?? 0 }

    private var cleanPercentText: String {
        guard let total = model.usage?.total, total > 0 else { return "—" }
        let pct = Double(model.cleanSelectedBytes) / Double(total) * 100
        return String(format: "%.1f%%", pct)
    }

    // MARK: 候选列

    private var cleanGroups: [CleanGroup] {
        var order: [String] = []
        var map: [String: [CleanCandidate]] = [:]
        for c in model.cleanPool {
            if map[c.bucket] == nil { order.append(c.bucket) }
            map[c.bucket, default: []].append(c)
        }
        return order.map { key in
            let items = map[key] ?? []
            return CleanGroup(key: key,
                              label: items.first?.bucketLabel ?? "",
                              items: items,
                              bytes: contentsUnionSize(items.map { (path: $0.path, bytes: $0.size) }))
        }
    }

    private func cleanTierStats(_ tier: VerdictTier, in items: [CleanCandidate]) -> (n: Int, bytes: Int64) {
        let hit = items.filter { $0.tier == tier }
        return (hit.count, hit.reduce(Int64(0)) { $0 + $1.size })
    }

    private var cleanCandidatesColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(L("可回收明细"))
                    .font(theme.prose(size: 14, weight: .semibold))
                    .foregroundStyle(theme.palette.ink)
                Text(LF("%d 处", model.cleanPool.count))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkSecondary)
                Text("·")
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                Text(human(model.cleanPoolBytes))
                    .font(theme.numeric(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.inkSecondary)
                Spacer(minLength: 8)
                cleanShortcut(L("只勾没影响的")) { model.selectCleanSafeOnly() }
                cleanShortcut(L("全不选")) { model.setAllCleanSelected(false) }
            }
            .padding(.bottom, 5)

            Text(L("默认只勾了没影响的；要重新下载的那些要你自己动手勾。"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            if model.cleanPool.isEmpty {
                cleanEmpty(
                    model.cleanScanning ? L("正在量缓存…") : L("没有可回收的缓存"),
                    model.cleanScanning
                        ? L("量完这一列才谈得上选；这一步仍然没有动任何文件。")
                        : L("这一圈里能动的都已经在废纸篓，或者这一轮还没量到。"))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(cleanGroups.enumerated()), id: \.element.key) { i, g in
                            cleanGroupHeader(g)
                                .padding(.top, i == 0 ? 0 : 12)
                            ForEach(g.items) { c in
                                CleanPickRow(
                                    candidate: c,
                                    detailOpen: cleanDetail == c.path,
                                    onToggle: { model.setCleanSelected(path: c.path, $0) },
                                    onDetail: {
                                        cleanDetail = (cleanDetail == c.path) ? nil : c.path
                                    })
                                    .padding(.bottom, 6)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func cleanGroupHeader(_ g: CleanGroup) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(theme.palette.tint)
                .frame(width: 6, height: 6)
            Text(g.label)
                .font(theme.bodyFont(.caption).weight(.medium))
                .foregroundStyle(theme.palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(LF("%d 处", g.items.count))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
            Text("·")
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(human(g.bytes))
                .font(theme.numeric(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkTertiary)
            Spacer(minLength: 6)
        }
        .padding(.bottom, 5)
    }

    private func cleanShortcut(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func cleanEmpty(_ title: String, _ hint: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 24)
            Image(systemName: "checkmark.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(title)
                .font(theme.prose(size: 14, weight: .medium))
                .foregroundStyle(theme.palette.inkSecondary)
            Text(hint)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 确认列

    private var cleanConfirmColumn: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Text(L("将移入废纸篓"))
                        .font(theme.prose(size: 14, weight: .semibold))
                        .foregroundStyle(theme.palette.ink)
                    Text(LF("%d 处", model.cleanSelected.count))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                    Text("·")
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Text(human(model.cleanSelectedBytes))
                        .font(theme.numeric(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.inkSecondary)
                    Spacer(minLength: 6)
                }
                .padding(.bottom, 6)

                ForEach(Array(model.cleanSelected.enumerated()), id: \.element.path) { i, c in
                    cleanPreviewRow(c, showRule: i > 0)
                }

                cleanCostSection
                    .padding(.top, 14)

                cleanNextStepsCard
                    .padding(.top, 14)

                if let f = model.cleanRun?.failures, !f.isEmpty {
                    // 上一次跑完但没有一处搬成时停在这一屏：失败原因必须留在原地。
                    Text(LF("上一次没有搬动任何一处：%d 处都失败了。", f.count))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.warnFG)
                        .padding(.top, 12)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func cleanPreviewRow(_ c: CleanCandidate, showRule: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RowIconView(icon: .path(c.url), side: 22,
                            appID: c.appID, brand: c.brand)
                    .frame(width: rowIconSide, height: rowIconSide)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(displayPath(c.url))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                if let b = verdictBadge(c.tier) {
                    ThemeBadge(text: b.text, tone: b.tone)
                }
                Text(human(c.size))
                    .font(theme.numeric(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.ink)
                    .frame(width: 78, alignment: .trailing)
            }
            .padding(.vertical, 7)
            if showRule {
                Rectangle()
                    .fill(theme.palette.separator)
                    .frame(height: 1)
            }
        }
    }

    private var cleanCostSection: some View {
        let tiers: [(VerdictTier, String)] = [
            (.safe, L("会自己长回来 / 可再下载")),
            (.redo, L("下次构建 / 启动会重建")),
            (.risky, L("这次没有动这类")),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("代价"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .padding(.bottom, 2)
            ForEach(Array(tiers.enumerated()), id: \.offset) { _, tier in
                let stats = cleanTierStats(tier.0, in: model.cleanSelected)
                HStack(spacing: 8) {
                    if let b = verdictBadge(tier.0) {
                        ThemeBadge(text: b.text, tone: b.tone)
                    }
                    Text(LF("%1$@ · %2$d 处", human(stats.bytes), stats.n))
                        .font(theme.bodyFont(.caption))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.inkSecondary)
                    Spacer(minLength: 8)
                    Text(tier.1)
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var cleanNextStepsCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("接下来会发生什么"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
            HStack(alignment: .top, spacing: 0) {
                cleanStep(L("现在"),
                          LF("%d 处仍在盘上", model.cleanSelected.count),
                          LF("可用 %@ 不变", human(cleanAvailable)),
                          ink: theme.palette.inkSecondary)
                Rectangle()
                    .fill(theme.palette.separator)
                    .frame(width: 1)
                    .padding(.horizontal, 12)
                cleanStep(L("点下去"),
                          L("移进废纸篓"),
                          L("随时可以撤销"),
                          ink: theme.palette.inkSecondary)
                Rectangle()
                    .fill(theme.palette.separator)
                    .frame(width: 1)
                    .padding(.horizontal, 12)
                cleanStep(L("清空之后"),
                          LF("可用 %@", human(cleanAvailable + model.cleanSelectedBytes)),
                          L("清空不可撤销"),
                          ink: theme.palette.danger)
            }
            .padding(12)
            .background(theme.controlShape().fill(theme.palette.surfaceAlt))
            .overlay(theme.controlShape().stroke(theme.palette.separator, lineWidth: 1))
        }
    }

    private func cleanStep(_ label: String, _ value: String, _ sub: String, ink: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(value)
                .font(theme.prose(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(sub)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 结果列

    private var cleanResultColumn: some View {
        let run = model.cleanRun
        let receipts = run?.receipts ?? []
        let failures = run?.failures ?? []
        let bytes = run?.bytes ?? 0
        let before = run?.beforeAvailable ?? cleanAvailable
        let after = before + bytes
        let remain = model.cleanPool
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Text(L("本次动作"))
                        .font(theme.prose(size: 14, weight: .semibold))
                        .foregroundStyle(theme.palette.ink)
                    Text(LF("%d 处", receipts.count))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                    Text("·")
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Text(human(bytes))
                        .font(theme.numeric(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.inkSecondary)
                    Spacer(minLength: 6)
                }
                .padding(.bottom, 1)

                cleanResultCard(L("已移入废纸篓"), human(bytes),
                                LF("%d 处 · 清空后才真正腾出", receipts.count),
                                link: receipts.isEmpty ? nil : L("去清空 →")) {
                    store.jumpTo = .trash
                    closeCleanPage()
                }

                cleanResultCard(L("当前可用"), human(before),
                                L("没变——字节还在废纸篓里"), link: nil, action: nil)

                cleanResultCard(L("清空废纸篓后"), human(after),
                                LF("+%@ 才真正回到可用", human(bytes)), link: nil, action: nil)

                if !remain.isEmpty {
                    HStack(spacing: 6) {
                        Text(remain.count == 1
                             ? LF("还剩 %1$@ 可回收 · %2$d 处（%3$@）",
                                  human(model.cleanPoolBytes), remain.count,
                                  remain.first?.name ?? "")
                             : LF("还剩 %1$@ 可回收 · %2$d 处",
                                  human(model.cleanPoolBytes), remain.count))
                            .font(theme.bodyFont(.caption))
                            .foregroundStyle(theme.palette.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Button {
                            cleanDetail = nil
                            model.reopenCandidates()
                        } label: {
                            Text(L("去看看 ›"))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkSecondary)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }

                if !failures.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LF("%d 处没搬动", failures.count))
                            .font(theme.bodyFont(.caption).weight(.semibold))
                            .foregroundStyle(theme.palette.warnFG)
                        ForEach(failures) { f in
                            Text(LF("%1$@：%2$@", f.name, f.reason))
                                .font(theme.bodyFont(.caption2))
                                .foregroundStyle(theme.palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.controlShape().fill(theme.palette.warnBG))
                    .padding(.top, 4)
                }

                if !receipts.isEmpty {
                    HStack(spacing: 6) {
                        Text(LF("这次移入的 %d 处", receipts.count))
                            .font(theme.bodyFont(.caption).weight(.medium))
                            .foregroundStyle(theme.palette.inkSecondary)
                        Spacer(minLength: 8)
                        Text(L("都在废纸篓里，可随时恢复"))
                            .font(theme.bodyFont(.caption2))
                            .foregroundStyle(theme.palette.inkTertiary)
                    }
                    .padding(.top, 6)

                    VStack(spacing: 0) {
                        ForEach(Array(receipts.enumerated()), id: \.element.id) { i, r in
                            cleanReceiptRow(r, showRule: i > 0)
                        }
                    }
                }

                if !receipts.isEmpty {
                    Text(LF("清空废纸篓不可撤销。现在不清理也可以——这 %d 处会一直留在废纸篓里，直到你决定清空。",
                            receipts.count))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(theme.controlShape().stroke(theme.palette.separator, lineWidth: 1))
                        .padding(.top, 2)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func cleanResultCard(_ label: String, _ value: String, _ sub: String,
                                 link: String?, action: (() -> Void)?) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                Text(value)
                    .font(theme.numeric(size: 25))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.ink)
                Text(sub)
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
            Spacer(minLength: 8)
            if let link, let action {
                Button(action: action) {
                    Text(link)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(theme.controlShape().fill(theme.palette.surfaceAlt))
        .overlay(theme.controlShape().stroke(theme.palette.separator, lineWidth: 1))
    }

    private func cleanReceiptRow(_ r: CleanReceipt, showRule: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RowIconView(icon: .path(URL(fileURLWithPath: r.path)), side: 22,
                            appID: r.appID, brand: r.brand)
                    .frame(width: rowIconSide, height: rowIconSide)
                Text(r.name)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 10)
                Text(r.tier == .safe ? L("没影响") : L("要重新下载"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(r.tier == .safe ? theme.palette.safeFG : theme.palette.warnFG)
                Text(human(r.size))
                    .font(theme.numeric(size: 11.5))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.inkSecondary)
                    .frame(width: 78, alignment: .trailing)
            }
            .padding(.vertical, 6)
            if showRule {
                Rectangle()
                    .fill(theme.palette.separator)
                    .frame(height: 1)
            }
        }
    }

    // MARK: 底部动作条

    private func cleanDock(_ stage: CleanStage) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 14) {
                cleanDockLeft(stage)
                    .frame(maxWidth: .infinity, alignment: .leading)
                cleanDockAction(stage)
                cleanDockRight(stage)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, Self.pagePad)
            Text(cleanDockNote(stage))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.top, 11)
        .padding(.bottom, 12)
        .background(theme.palette.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.palette.separator).frame(height: 1)
        }
    }

    @ViewBuilder
    private func cleanDockLeft(_ stage: CleanStage) -> some View {
        switch stage {
        case .candidates:
            let n = model.cleanSelected.count
            let safe = cleanTierStats(.safe, in: model.cleanSelected)
            let redo = cleanTierStats(.redo, in: model.cleanSelected)
            let risky = cleanTierStats(.risky, in: model.cleanSelected)
            VStack(alignment: .leading, spacing: 2) {
                Text(LF("已选 %1$d 处 · %2$@", n, human(model.cleanSelectedBytes)))
                    .font(theme.prose(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.ink)
                Text(LF("没影响 %1$@ · 要重新下载 %2$@ · 会丢数据 %3$@",
                        human(safe.bytes), human(redo.bytes), human(risky.bytes)))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .lineLimit(1)
            }
        case .confirm:
            VStack(alignment: .leading, spacing: 2) {
                Text(LF("这 %1$d 处 · %2$@", model.cleanSelected.count,
                        human(model.cleanSelectedBytes)))
                    .font(theme.prose(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.ink)
                Text(LF("不会删除，只移进废纸篓 · 当前可用 %@", human(cleanAvailable)))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .lineLimit(1)
            }
        case .result:
            let run = model.cleanRun
            let n = run?.receipts.count ?? 0
            let bytes = run?.bytes ?? 0
            let before = run?.beforeAvailable ?? cleanAvailable
            VStack(alignment: .leading, spacing: 2) {
                Text(LF("已移入 %1$d 处 · %2$@", n, human(bytes)))
                    .font(theme.prose(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.ink)
                Text(LF("当前可用 %1$@ 没变 · 清空后 %2$@",
                        human(before), human(before + bytes)))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func cleanDockAction(_ stage: CleanStage) -> some View {
        switch stage {
        case .candidates:
            let n = model.cleanSelected.count
            ThemeButton(kind: .lamp,
                        title: n > 0 ? LF("下一步：确认这 %d 处 →", n) : L("一件都没选"),
                        isDisabled: n == 0) {
                cleanDetail = nil
                model.advanceToConfirm()
            }
        case .confirm:
            ThemeButton(kind: .lamp,
                        title: LF("移进废纸篓 · %@ →", human(model.cleanSelectedBytes)),
                        isDisabled: model.cleanBusy || model.cleanSelected.isEmpty) {
                runFirstClean()
            }
        case .result:
            ThemeButton(kind: .lamp, title: L("去废纸篓清空 →")) {
                store.jumpTo = .trash
                closeCleanPage()
            }
        }
    }

    @ViewBuilder
    private func cleanDockRight(_ stage: CleanStage) -> some View {
        switch stage {
        case .candidates:
            VStack(alignment: .trailing, spacing: 2) {
                Text(LF("已入废纸篓 %@", human(model.moved.reduce(Int64(0)) { $0 + $1.bytes })))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                Text(LF("当前可用 %@", human(cleanAvailable)))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkSecondary)
            }
        case .confirm:
            VStack(alignment: .trailing, spacing: 3) {
                Button {
                    cleanDetail = nil
                    model.backToCandidates()
                } label: {
                    Text(L("← 返回修改"))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text(LF("已入废纸篓 %@", human(model.moved.reduce(Int64(0)) { $0 + $1.bytes })))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
        case .result:
            VStack(alignment: .trailing, spacing: 3) {
                Button { undoFirstClean() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("撤销本次移入"))
                            .font(theme.bodyFont(.caption))
                    }
                    .foregroundStyle(theme.palette.inkSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .overlay(Capsule().stroke(theme.palette.separator, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(model.cleanRun == nil)
                Text(L("直到清空前都可撤销"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
        }
    }

    private func cleanDockNote(_ stage: CleanStage) -> String {
        switch stage {
        case .candidates: return L("还没有动任何文件 · 下一步只是核对")
        case .confirm: return L("只移进废纸篓，不直接删除 · 清空后才真正让位")
        case .result:
            return LF("清空之后，这 %@ 才真正回到可用",
                      human(model.cleanRun?.bytes ?? 0))
        }
    }

    /// 页头钉在滚动区外面：它是这一屏的标题，滚走了就没人知道自己在哪页。
    /// 下面仍然只有一个 ScrollView——macOS 13 的 ScrollView 会把内容的完整高度
    /// 当成自己的理想尺寸报上去，套两层就会把 detail 列顶成一千六百多点。
    /// 页头单独抽成一坨：它和下面整页 `VStack` 混在一个表达式里时，Swift 的类型推导
    /// 会当场罢工（`unable to type-check this expression in reasonable time`，2026-10-23）。
    /// 页头自己的账（扫描态换字、徽章给不给）也该只管自己这一屏的顶上。
    private var overviewHeader: some View {
        // 扫描中页头自己报「在干什么」：这一屏剩下的时间全花在等，标题还写
        // 「空间总览」会让人以为结果是现成的。副标题那句「只读」是承诺，
        // 每一秒都得在屏幕上——扫描态下这一页一个写盘动作都没有。
        PageHeader(symbol: "internaldrive",
                   title: model.scanning ? L("正在扫描") : L("空间总览"),
                   // 稿子这句是「一圈 = 这块盘的真实字节」。上一版把它换成了一句操作说明，
                   // 而下面「没量到的」「各段之和」已经把这些话各说了一遍——页头只该说
                   // 这一屏在量什么，不该替下面的账先说结论。
                   subtitle: model.scanning
                       ? L("先量完，再决定——只读，不改任何文件。")
                       : (prefs.overviewRead == .cost
                           ? L("按代价读：零代价、需重下、不可逆、不碰——加上空闲，五段相加就是整块盘。")
                           : L("一圈 = 这块盘的真实字节")),
                   variant: .display,
                   // 页头右侧只剩读法开关。`ViewThatFits` 留着是给长译文兜底：
                   // 装不下时开关退到下一行右对齐，而不是把副标题挤断、顶出窗口边。
                   wrapsControls: true,
                   // 稿子页头副标题后面那枚小徽章（`.phead .sub .cost`）。它讲的是
                   // 颜色没有文字标签这件事：弧为什么是亮的，不写出来就得由人猜。
                   //
                   // 扫描中不给——那一趟还没量完，「现在就能收走」是句还没兑现的话。
                   // 稿子另外两枚尾句（「还占着盘 · 清空后才让位」「废纸篓已清空」）
                   // 不往这儿搬：那两句话底栏的废纸篓那一格和清理结果页各说了一遍，
                   // 页头再说就是同一屏第三遍。
                   subBadge: model.scanning ? nil : L("亮起来的那几段，现在就能收走")) {
            // 「重新扫描」不在这儿：稿子把它放在顶栏 `.tb-right`（量完 → 菜单 → 扫描 → 声音 → ?）。
            // 页头再放一颗蓝主钮，等于把同一个动作在同一屏说两遍——上一版那颗还把副标题
            // 顶到了第二行。页头这一格只留「换看法」的开关，它跟顶栏那颗放在一起才分得清。
            readSwitch
        }
    }

    private var overviewPage: some View {
        VStack(spacing: 0) {
            overviewHeader
                .pagePadding()
                .padding(.top, 14)
                .padding(.bottom, 2)

            // 演示树必须占满一条视线，不能只靠覆盖率那行末尾的小字：假家目录配真盘
            // 容量、或者配一块 96 GB 的假盘，缩略图里跟真机一模一样，挑图的人（包括
            // 我自己）就会拿一张假账去说「这才几十 G」。
            if demoDisclosed {
                HStack(spacing: 8) {
                    Image(systemName: "theatermask.and.paintbrush")
                        .font(.system(size: 12))
                    Text(L("演示数据：这一屏的目录、文件和整块盘的容量都是造的，不是你机器上的真实账。"))
                        .font(theme.bodyFont(.caption))
                    Spacer(minLength: 8)
                }
                .foregroundStyle(theme.palette.warnFG)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(theme.controlShape().fill(theme.palette.warnBG))
                .pagePadding()
            }

            scrollContent
        }
        // 整页封顶宽并居中。稿子那一屏是定宽的（`.ringbox{width:420px;flex:none}` +
        // `.sidecol{width:364px;flex:none}`），窗口拉宽多出来的份在稿子里是**留白**，不是
        // 控件。真机先只在招牌那一屏上封顶，结果页头的「空间总览」还贴着窗口左沿、
        // 环却往中间挪了一截，两者不再同一条左基线——所以这一刀落在整列上：
        // 页头、招牌、下面的小节一起收进同一个宽度里，左沿仍然对齐，只是这一整列
        // 在窗口里居中。2026-10-24 实拍：1700 宽时账本被摊到 950 pt，「查看回收」
        // 那枚按钮成了一块 950×35 的板。
        .frame(maxWidth: Self.heroCap + 2 * Self.pagePad, alignment: .leading)
        // 默认 `.center` alignment 负责把这一列水平摆正，纵向照旧铺满。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            syncMovedLedger()
            model.started ? model.refreshUsage() : model.refresh(scope: store.scope)
            // 假手指（`DISKWISE_PREVIEW=on`）的第二把落点：这一趟用的是**缓存好的扫描**，
            // `scanning` 从没翻过真，上面那条 onChange 一辈子不来，于是量到的是一张静图。
            if SnapshotMode.previewHold && !model.scanning { holdPreview() }
        }
        // 搬进废纸篓、撤销、清空之后环形要挪账。整条历史重新推一遍（见 `syncMovedLedger`）。
        .onChange(of: store.trashHistory) { _ in syncMovedLedger() }
        // 重扫一轮就把下钻收回：模型的 `dropChildren()` 同时作废了摊开出来的下级账，
        // 键还留着的话那一格会空摊着，看着像「扫到一半把东西弄丢了」。
        .onChange(of: model.scanning) { go in
            // 扫描这一趟开跑与收尾各一声。它不跟着环上的进度走——那会响成一片，
            // 只在「开始」和「量完了」两个边界各报一次。
            Sound.shared.play(go ? .scanStart : .scanEnd)
            if go { setDrill(nil); return }
            fireSnapshotBurstIfAsked()
            // 性能配对要把「按住空格」这一档钉住整趟测量：真机上是手指按着不放，
            // 测量链路里没有手指。`DISKWISE_PREVIEW=on` 就是那只假手指——它走的仍是
            // `holdPreview()` 这条真路（同一套判据、同一个 `beginPreview`），
            // 不是另画一张「看起来像预演」的皮，所以量到的代价就是那一档真正的代价。
            if SnapshotMode.previewHold { holdPreview() }
        }
        // 「动得了多少」比弧本身晚落地（缓存体积一台一台量回来才结算，见 `settleCaches`）。
        // 上面那三处都不在这一趟之后：矩形与弧表早就算好了，扫描收尾那一刻每一段的
        // reclaim 还是 0，`fireSnapshotBurstIfAsked` 走到 `reclaim > 0` 那道判据就 returns，
        // 于是 `DISKWISE_FLIGHT` 拍出来的永远是「没有水珠」那一格
        // （2026-10-24 实拍 `dump612`：同一张上 `~/Library` 那条弧已经写着回收 10.0 GB）。
        .onChange(of: model.reclaimPulse) { _ in fireSnapshotBurstIfAsked() }
        // 弧表与两个矩形报上来的时候直接叫那一格定帧（见 `heroCard` 末尾那两个
        // `onPreferenceChange`）：这两份几何不再是 @State，没有 `onChange` 可挂了。
        // 切走这一页就解除上膛：弧都不在眼前了，还留着「等你确认」那道白边，
        // 回来时人会以为自己上一刀点到了一半。悬停指针与那句「为什么动不了」同理，
        // 都是当前这一屏的事，带不进下一页。
        .onDisappear {
            model.disarm()
            setHover(nil)
            arcNote = nil
        }
        // 稿子③那只「按住空格」的接收器。挂在**这一页**而不是窗口上（跟 `EscapeTap` 相反）：
        // 它要吞掉空格的 keyDown，而空格在别的页面上本来就是「按下聚焦的那颗按钮」——
        // 挂在窗口层就等于在全部七页把那条 AppKit 规矩换掉了。切走这一页，监视器跟着拆，
        // 别的页照旧。
        //
        // 这一页上换掉的那条规矩说清楚：空格改给预演，因此这一屏的按钮靠鼠标点；
        // 已经上膛的整圈那一下另配 ⌘↵（跟着条子上那颗钮走，见 `previewBar`）。
        // 预演本身不搬任何东西，第二下才搬，所以这一换不会
        // 把「不小心按下去就丢文件」换来换去——恰恰相反，把空格按下就搬东西那条路堵掉了。
        .background(SpaceHoldTap(onHold: { holdPreview() },
                                 onRelease: { model.endPreview() }))
        .onChange(of: store.overviewDrill) { name in
            guard let name else { return }
            store.overviewDrill = nil
            guard let hit = (model.hotspots + model.restHotspots).first(where: { $0.name == name })
            else { return }
            openChildDrill(hit.path)
        }
        .onChange(of: store.overviewRing) { token in
            guard let token else { return }
            // 「扫描途中」那一帧：重跑一趟，让光束有东西可钉。
            if token == "rescan" {
                store.overviewRing = nil
                model.refresh(scope: store.scope)
                return
            }
            // 钩子动了哪一条弧、为什么没动，全部报到 stderr：拍出来一张和静图零差异的
            // 「拒绝解释」时，这一行是唯一能分清「界面没画」还是「画在了折出去的地方」的东西。
            @MainActor func say(_ what: String) {
                store.overviewRing = nil
                FileHandle.standardError.write("    · ring \(token): \(what)\n".data(using: .utf8)!)
            }
            guard let u = model.usage else { return say("还没有账，这一钩子跳过了") }  // l10n-scan: skip
            store.overviewRing = nil
            // 稿子③那一档的静图。走的是空格落下那**同一条路**（`holdPreview`，连它所有
            // 拒绝的分支一起），松手那一发走同一个 `endPreview`——不是另搭一个「看起来
            // 像预演」的状态。stderr 那行说清到底进没进：「拍出来跟静图零差异」有两种原因，
            // 这一行是唯一分得清「界面没画」和「画在了折出去的地方」的东西。
            if token == "preview" || token == "previewoff" {
                if token == "preview" { holdPreview() } else { model.endPreview() }
                return say("previewing = \(model.previewing)")        // l10n-scan: skip
            }
            let segs = ringAccount(u).segs
            // 挑哪条弧不写死名字：演示树会改，而这一钩子要验的是「动得了的弧点两下」
            // 这件事本身，不是某一条弧。
            let hit = token == "refuse"
                ? segs.first { $0.path != nil && $0.reclaim == 0 } ?? segs.first { $0.path == nil }
                : segs.first { $0.reclaim > 0 }
            guard let hit else { return say("环上没有符合条件的弧") }   // l10n-scan: skip
            say("按的是「\(hit.label)」，reclaim \(hit.reclaim)")       // l10n-scan: skip
            tapArc(hit)
        }
        .onChange(of: store.overviewJump) { token in
            guard let token else { return }
            store.overviewJump = nil
            // 走的是账目行行首那颗 `▸` 完全相同的路径，截图验的就是这条真链路。
            switch token {
            // `restnote` 是旧名：那句对账不再躺在列表尾巴，它就在「其他已统计」摊开之后
            // 的最后一段上，两个口令现在指同一处。
            case "rest", "restnote": openDrill(SegmentDrill.restGroup.key)
            case "gap": openDrill(SegmentDrill.gapRows.key)
            default: openChildDrill(token)
            }
        }
        // 截图连拍要「摊开 → 再收回去」两拍都在一段里跑完，而收起在真机上是再点同一行，
        // 这一路没有键鼠点不到它。这里走的就是那颗行首 `▸` 的同一个 `setDrill`。
        .onChange(of: store.overviewCollapsePulse) { _ in setDrill(nil) }
        // 这里原来挂着一发一秒一跳的 `scanTick` 时钟，只为圆心那句「还剩约 N 秒」现算
        // 剩余时间。那句倒计时 2026-10-24 删了（没根据，见 `centerCap` 扫描态那条），
        // 时钟跟着走：扫描期每一秒一次的 `@State` 写回，正是 #52/#56 一路在削的那类整页重绘。
    }

    /// `avail` = 这一屏给英雄卡的那一档宽度（已经扣掉页面左右内边距），
    /// `viewportH` = 滚动视口的高。环的尺寸由 `avail` 算（见 `ringDiameter(_:)`），
    /// 它居中的那一片由 `viewportH` 算（见 `ringBox(_:_:)`）——两个都来自窗口，不来自内容。
    private func heroCard(_ u: VolumeUsage, avail: CGFloat, viewportH: CGFloat) -> some View {
        // 扫描中单独一本账：只把**量到的**画成弧，没轮到的部分留暗轨（见 `scanningAccount`）。
        // 正常态那本账里的「没量到 / 系统可清除 / 空闲」在扫描中是结论，不是进度。
        // 「按代价」换的不是配色，是分法：同一块盘按清掉要付什么切成四段（见 `costAccount`）。
        let acct = model.scanning ? scanningAccount(u)
                 : (costReading ? costAccount(u) : ringAccount(u))
        // 截图旋钮 DISKWISE_HOVER=<第几段>：真机的悬停是鼠标进来的，静态图里没有鼠标，
        // 没有这个钩子这一条响应就只能靠嘴说它存在。**它只是一格定值**：
        // 整页不再读悬停状态，读它的是环那一层（`HoverRing`）和账本行里的小叶子。
        let hovFallback = SnapshotMode.ringHover.flatMap { i in
            acct.segs.indices.contains(i) ? acct.segs[i].label : nil
        }
        let ring = ringDiameter(avail)
        // 卡片只装招牌那一屏（环 + 右侧这本账）。样稿里 `.acct` 那根账带子是主行的
        // **兄弟节点**，不在窗口卡里面：Ring 是「画面」，账带子是「画面下的图注」。
        // 上一版把四样东西全塞进同一张卡，于是卡的边界把招牌画面和它的说明切成了
        // 一个盒子，环再怎么放大都仍像表单里的一行——尊贵感首先来自「这块是单独一幅」。
        return VStack(alignment: .leading, spacing: 16) {
            ThemedCard(chromeless: true) {
                // 顶部对齐：这一行里谁高谁矮由右边那本账说了算，环那一格只拿到
                // `ringBox` 那么高的一片。若 HStack 自己再居中，那片会被整列顶到
                // 中点以下——环就又沉到左下角（2026-09-28 实拍：扫描中账目一长，
                // 环框虽然只有 612 高，整框却被 1000 高的账压到 y=194 起）。
                HStack(alignment: .top,
                       spacing: ringIsReference ? 18 : Self.heroGap) {
                    VStack(alignment: .center, spacing: 10) {
                        // 环按 `ringDiameter(avail)` 画成一个**定宽**的方格，右边那一列
                        // 拿走剩下的。为什么不交给布局系统分摊：它分摊的时候不按两边的
                        // 下限收口——2026-09-28 给账目列写了 `minWidth: 350`，结果环反而
                        // 从 317 长到 342、账被挤到 300，那列数照样出界。
                        // `avail` 是 `scrollContent` 里钉住的那一档（ScrollView 自己会按
                        // 内容的理想宽长，量它等于量自己，实测每轮 +3.5 pt 不收口）。
                        Color.clear
                            .frame(width: ring, height: ring)
                            .overlay {
                                GeometryReader { g in
                                    SweepRing(segments: acct.ringSegs ?? acct.segs,
                                              centerTop: centerTop(acct),
                                              centerValue: centerValue(acct),
                                              // 盘心躺不下那两行口径的两档，都撤掉它：
                                              // 参照盘内孔只有 93 pt；收到 260 以下那一档实测
                                              // 「整块盘 96.0 GB · 已用 80.0 GB」折成三行、孤字「GB」
                                              // 掉在中间（2026-09-28 实拍：最小窗 + 侧栏拖满，环 236，
                                              // `cliff312/side280-zh`；上一版按 336 压账时环 220 同形）。
                                              // 260 与弧上那六枚数走同一道闸：盘小到这个数，读数的活
                                              // 就整个交给右边那一列。这两个数不是被删了：卡片底下
                                              // `coverageLine` 那一行从头到尾都在写整块盘 / 可用 / 已用。
                                              centerCap: (ringIsReference || ring < 260) ? "" : centerCap(acct),
                                              diameter: g.size.width,
                                              // 量完之前不进上膛那条路：S0 的规矩是这一屏一个清理动作都不出现。
                                              // 代价读法整圈不接上膛：点的是「一类字节」，
                                              // 没有「把这一类整块挪走」这回事——那一按该进候选清单。
                                              select: costReading ? nil : { (seg: GaugeSegment) in
                                                  guard !model.scanning else { return }
                                                  tapArc(seg)
                                              },
                                              armed: model.armedPath,
                                              tapCenter: { model.disarm(); arcNote = nil },
                                              scanning: model.scanning,
                                              // 预演（按住空格）交给环的那一条通知线：
                                              // 段带退到后面、带心线上长出一截绿光弧、两根亮丝慢一档、
                                              // 盘心换一套句子。这里**不传「在不在预演」这个布尔**——
                                              // 传了就得有视图订阅它，而能吃下这一发的视图只有整页那么大。
                                              // 分账用的开关各在叶子自己身上：`DISKWISE_RINGDIM`（退到后面）、
                                              // `_GAIN`（绿弧）、`_EDGE`（亮丝）。原先那颗一刀切掉整圈的
                                              // `DISKWISE_RINGPREV` 已经没东西可切了，2026-10-22 摘掉。
                                              preview: model.previewSignal,
                                              // 预演那三行（只有页面算得出来，见 `SweepRing.centerTopPreview`）。
                                              // 数取 `afterClearShown`——与静帧那行「全部清空后可用 x」**同一个属性**，
                                              // 不在这里再算一遍：两处各算一次就会差出 0.1，而这一屏那 0.1
                                              // 是说得出却对不上的账。
                                              // 扫描与代价读法给空串 = 这一圈不吃预演：前者盘心正被「正在扫描 /
                                              // 已量 x/y」占着，后者压根不让进这一档（`holdPreview`）。
                                              centerTopPreview: previewCenterRefused ? "" : L("全部清空后"),
                                              centerValuePreview: previewCenterRefused ? "" : acct.afterClearShown,
                                              centerCapPreview: previewCenterRefused ? "" : previewCenterCap(acct),
                                              scanProgress: scanFraction(u),
                                              // 悬停只交给环上那几颗订阅叶子，不再经过
                                              // 页面、也不再经过 `SweepRing.body`。
                                              hoverNote: model.hoverSignal,
                                              hoverFallback: hovFallback,
                                              onHover: { model.hoverSignal.set($0) },
                                              // 上了膛的那几秒这句要让位：圆心的 `cap` 那时写的正是
                                              // 「再点一次才移进废纸篓」，两句话叠着念就是四行字压到环带上。
                                              // 参照盘也让位——眼睛此刻在右边那列明细上，盘心那两行小字
                                              // 在 93 pt 的内孔里只会糊成一团，而它说的名字就在被点亮的行上。
                                              // 扫描中同样让位：那两行正在报进度，再叠一句悬停读数就是四行。
                                              // 预演中同样让位由叶子自己判（`RingNowLine`）：盘心那个数是
                                              // 「全部清空之后」，鼠标划过弧就把它换成「这一条 6.3 GB」——
                                              // 预演的那一眼还没看完。这一位要是读 `model.previewing`，
                                              // 整页就得跟着空格重算一次。
                                              centerNowEnabled: !(ringIsReference || model.armedPath != nil
                                                                  || model.scanning || costReading),
                                              centerNowLine: { centerNowLine($0) })
                                }
                            }
                            // 水珠从这一格的**外沿**起飞（角度按被点的那段弧算，见
                            // `ReclaimFXHost.geometry`），冲击波与光圈也以它为心。
                            // 报整格矩形，不报圆心：水珠的起点、槽位和落点都要宽度。
                            .heroFrame("ring", in: Self.heroSpace)
                            // 稿子⑫那条决策条：浮在环底下这一片**空白**里，不排在环下面。
                            //
                            // 为什么不是排在下面（这一版改的就是这一处）：排下去就是这一格
                            // 从 0 长到 102，环跟着被顶高 56——样稿 `.dbar` 是
                            // `position:absolute` + `opacity`/`translateY`，环从头到尾不动，
                            // 动的一直是条子自己。两头都对上：画面按样稿走，代价也不再是
                            // 一次整窗排版（`heroGeo` 上面记着那一发值多少）。
                            //
                            // 宽只到环那一格，不铺满整张卡。试过铺满（= `avail`，正好是
                            // 环 + `heroGap` + 那本账）：右边这本账比环高，条子落在环下沿
                            // 那一带时正压在账目列的「See 16 reclaimable locations」那一颗
                            // 上，2026-10-22 实拍 `bar2` 那一对图。样稿敢铺满是因为它的
                            // `.sidecol` 只有 420 高、底下是空的；我们这一列六行账 + 一颗钮
                            // + 废纸篓那一格，底下不空。
                            .overlay(alignment: .topLeading) {
                                PreviewBarHost(preview: model.previewSignal,
                                               armedAll: model.armedPath == SweepRing.armAll,
                                               hide: Self.barMode == "off") { _ in
                                    // 顶边落在环下沿再往下 10：按环自己的高走，不按那一片
                                    // 空白的高走。空白是 `ringBox` 给的（窗口越高它越大），
                                    // 贴着框底画就成了「条子离环越来越远」。
                                    // 高由内容定，所以这里只推顶边——写死一档高度的话，
                                    // 窄窗里那两行一折行就被剪掉半句。
                                    previewBar(acct, width: ring)
                                        .offset(y: ring + Self.barGap)
                                }
                            }
                        // 环正下方那一格：装哪句话、什么时候让位，连同「为什么必须落在环
                        // 底下」的实拍，都记在 `ringBelow(showBar:ring:armedLine:)` 的注上。
                        // 稿子⑫那条决策条的账本记在两处：它原先坐在右边那本账的最后，
                        // 2026-10-22 逐层配对量下来那一格付不起（`DISKWISE_PERF_PREVIEW=0.4`
                        // 同一场，尾段 >100 ms——只换账目列那一格 46 格、整圈全开 55 格、
                        // 两处都不动 13 格、同场静帧 0 格）。贵的不是那几行字，是**账那一列
                        // 被重排**：列高一变整张卡跟着变，滚动内容重排一次在这台 Intel 上
                        // 就是几十到一百多毫秒。于是搬到环这一格；搬过来之后同一发空格还剩
                        // 一笔账——这一格从 0 长到 102 把环顶高 56，那 56 pt 每一发都要走
                        // 一整扇窗的 Auto Layout。数与拆法记在 `heroGeo` 上面。
                        //
                        // 现在这一格**不换子树了**：条子浮在环底下（上面那颗 `PreviewBarHost`），
                        // 环一动不动，样稿 `.dbar` 那句 `position:absolute` 才是它本来的样子。
                        // 这一格剩下的活儿只有一件：整圈那一档（预演、或刚从预演里给整圈上了
                        // 膛）把上面那句话压住——那时确认在条子上那颗钮，条子说的就是
                        // 「再点一次才搬」，同一屏不必再有第二句。
                        // 其余时候这里只压「点动不了的弧那句为什么」，退掉这一档之后它自己回来。
                        //
                        // 「此刻压不压」由 `AfterClearSlot` 自己判：判据是预演那一根线，
                        // 写在页面上就是整页重算一次（环那棵大树加右边六行账全跟着走），
                        // 挂在叶子上重算的范围就只有这一格。
                        AfterClearSlot(preview: model.previewSignal,
                                       armedAll: model.armedPath == SweepRing.armAll,
                                       hide: Self.barMode == "off") { showBar in
                            ringBelow(showBar: showBar, ring: ring,
                                      armedLine: armedPendingLine(acct))
                        }
                    }
                    // 环的居中框来自窗口，不来自这一本账（见 `ringBox(_:_:)`）。
                    // 参照盘那一档例外：它是「自己下面这本账的缩略」，必须贴着账顶，
                    // 所以仍旧钉在顶上、不吃框。
                    .frame(maxHeight: ringIsReference ? .infinity : ringBox(viewportH, ring),
                           alignment: ringIsReference ? .top : .center)

                    heroColumn(acct, ledgerWidth(avail))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }

            // 覆盖范围必须写在画面里：环形那块灰是「没量过」，不点明的话
            // 只会读成「我的盘没东西可清了」，而这是本页最容易误导人的一处。
            Text(scopeNote)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)

            if model.started && model.done > 0 {
                coverageLine(u)
            }
        }
        // 水珠的坐标基准钉在整张卡上，不钉在环或某一列上：起点在环里、终点在右边那一列
        // 底下的废纸篓格子里，两处分属两棵子树。量在各自的局部坐标里就对不上了。
        .coordinateSpace(name: Self.heroSpace)
        .onPreferenceChange(HeroRectKey.self) { rects in
            // 写进盒子，不写 @State：见 `heroGeo`。
            heroGeo.rects = rects
            fireSnapshotBurstIfAsked()
            reliveBurstIfMoved()
        }
        .onPreferenceChange(RingArcMapKey.self) { map in
            heroGeo.arcs = map.spans
            heroGeo.band = map.band
            // 弧表与两个矩形都是布局之后才报上来的，和「量完」谁先谁后不定：两份都盯着，
            // 谁后到就由谁把那一格定帧发出来（`burst == nil` 兜住只发一次）。
            // 只有截图那一趟（`DISKWISE_FLIGHT`）真走得进来，平时这一句就是一次布尔判断。
            fireSnapshotBurstIfAsked()
            reliveBurstIfMoved()
        }
        // 铺在最上层、不接鼠标（`ReclaimFXHost.hitTest` 返回 nil），
        // 环、账本行、按钮的点击都照旧落在它们自己身上。
        .overlay {
            ReclaimFXLayer(burst: burst)
        }
    }

    /// 此刻摊开着的那一段账（nil = 没摊开）。按 `armKey` 现查，不留下指针：
    /// 段每帧都是新构造的，攥着上一帧那份就是拿旧账做今天的决定。
    private func drilledSegment(_ acct: RingAccount) -> GaugeSegment? {
        guard let key = model.drillKey else { return nil }
        return acct.segs.first { $0.armKey == key }
    }

    /// 摊开之后「现在看的是谁」写在账目列顶端。**返回挂在上级名自己身上**：
    /// 上一级此刻就是「整圈」，所以点「空间总览」二字就收回去，鼠标进来才显出那支 `←`。
    /// 单独造一颗返回钮是糊弄——它不在任何人会去点的位置上。
    private func drillCrumb(_ seg: GaugeSegment) -> some View {
        HStack(spacing: 7) {
            Button { setDrill(seg.armKey) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 10, weight: .semibold))
                        .opacity(crumbHover ? 1 : 0)
                        .animation(theme.animation, value: crumbHover)
                        // 槽位常驻 12 pt：只切透明度的话那两个字会横移，看着像字在抖。
                        .frame(width: 12, alignment: .trailing)
                    Text(L("空间总览"))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(crumbHover ? theme.palette.ink : theme.palette.inkTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { v in if crumbHover != v { crumbHover = v } }
            .accessibilityLabel(L("收起明细，回到整圈"))

            Text("›")
                .font(theme.numeric(size: 12))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(seg.label)
                // 段名是这一屏此刻的标题，但它不能抢导语那句「几处多少 GB 动得了」——
                // 导语才是被先读的那一句。所以给 13 pt 中等字重，不给 display 字号。
                .font(theme.prose(size: 13, weight: .medium))
                .foregroundStyle(theme.palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
        }
    }

    /// 环右边那一列：面包屑（摊开时）、这一圈的账、一个动作、一句防误删的话。
    /// 顺序就是读的顺序——先说是谁，再给按钮。
    ///
    /// 这一列是整页**唯一**的清单：环形旁边这本账之外不再有第二段列表，
    /// 每一段的下一级都摊在自己那一行下面。
    private func heroColumn(_ acct: RingAccount, _ column: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let d = drilledSegment(acct) {
                drillCrumb(d)
            }

            // 这本账上面不再垫一句导语（2026-10-23 撤）。那句话把「几处动得了 / 其余先不动 /
            // 没量到的另算」在账本上行之前先说了一遍，而账本每一行、各段之和、环心都已经
            // 各说了一遍——页头下面于是堆着四层字。样稿这一格本来就是空的：`.ledger`
            // 直接顶在页头下面。缺的那半句由两处接住：可勾的读法在行尾，没量到的自己是一行。
            VStack(alignment: .leading, spacing: 0) {
                // 小节头。判据跟导语同一条：扫描中这一列还没有一本完整的账，
                // 「几类现在能清」在那个时候是一个正在变的数（见上面那段注释）。
                if !model.scanning { ledgerHead(acct) }
                // 逐行画分隔线（样稿 `.row+.row::before`），第一行不画。
                // 上一版靠 3pt 的行距把六行分开：没有线的时候那六行是六片浮着的字，
                // 有了线才读得出「这是一本账的六笔」。
                ForEach(Array(acct.segs.enumerated()), id: \.offset) { idx, seg in
                    let open = model.drillKey == seg.armKey
                    RingLedgerRow(seg: seg,
                                  fraction: Double(seg.value) / Double(max(1, acct.total)),
                                  armed: model.armedPath != nil
                                    && (model.armedPath == SweepRing.armAll || model.armedPath == seg.armKey),
                                  // 亮/暗不再由整页算好传进来：这一行里只有底光、暗态
                                  // 和行尾那枚数订阅悬停线（见 `HoverSpotlight`），
                                  // 行体自己不为「指着谁」重算。
                                  hoverNote: model.hoverSignal,
                                  showRule: idx > 0,
                                  // 扫描中那些「排队中」「正在量…」的行不在环上，指着它们
                                  // 不该让整圈暗下去；只有真画了弧的行才接悬停。
                                  onHover: seg.value > 0 ? { v in setHover(v ? seg.label : nil) } : nil,
                                  // 量完之前这一列一个动作都不给：不上膛、不摊明细、不去授权。
                                  // 代价读法里整行也没有上膛这一说（环上 `select` 已是 nil），
                                  // 不给 `tap`，行名那一块才只是一块名字。
                                  tap: (model.scanning || costReading) ? nil : { tapArc(seg) },
                                  expanded: open,
                                  onExpand: model.scanning || seg.drill == nil
                                    ? nil : { toggleDrill(seg) },
                                  onGrant: (!model.scanning && seg.drill == .gapRows && canGrantFDA)
                                    ? { openFullDiskAccessPane() } : nil,
                                  // 两个出口只在摊开时给：这一行是「还没进去的那一层」。
                                  // 收起时露出口会把它撑宽——`ledgerFloor` 那条注释记着代价
                                  // （列宽给到 336 时行尾那个数就顶出窗口 14 pt）——
                                  // 而且抢在「先摊开看看里面是什么」这一步前面。
                                  // 整条规则写在 `DrillRow` 那段注释里。
                                  onReveal: (!model.scanning && open && seg.path != nil)
                                    ? { NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: seg.path!)]) } : nil,
                                  onDeepDive: (!model.scanning && open && seg.path != nil)
                                    ? { store.deepDive(into: seg.path!) } : nil,
                                  grantCompact: column < Self.ledgerGrantWidest,
                                  // 稿子⑪：这一行名下还能腾出多少，跟着预演一起接进小字末尾。
                                  // 这六截加起来 = 这一圈动得了的总数 = 条子上那颗钮真会搬走的那一笔
                                  // （「比现在多」里还含着已经在废纸篓、等访达清空的那几 G，不在这里）。
                                  // 摘掉它做对照的开关在行自己身上：`RingLedgerRow.gainRunOffByEnv`。
                                  // 「刚从预演里给整圈上了膛」那一档由这一位补上（页面跟着
                                  // `armedPath` 重算，空格那一发由 `preview` 那条线自己走）。
                                  afterClearAll: model.armedPath == SweepRing.armAll,
                                  preview: model.previewSignal)
                    if open {
                        drillPanel(seg)
                            .padding(.top, 2)
                            .padding(.bottom, 12)
                            .transition(.opacity)
                    }
                }
                // 那句「各段之和」是这一列的分母，坐在最后一行的数下面才对得上账。
                // 扫描中它换成「已读 x / y · 只读」：这一列此刻还没有分母，
                // 报一个「各段之和」等于把半截账说成整本。
                Group {
                    if model.scanning {
                        Text(LF("已读 %1$@ / %2$@ · 只读",
                                human(model.covered), human(acct.total)))
                    } else {
                        Text(lampRun(LF("各段之和 %1$@", segmentsSumText(acct)),
                                     segmentsSumText(acct),
                                     SweepRing.lamp(theme.palette.tint),
                                     base: theme.palette.inkTertiary))
                    }
                }
                    .font(theme.bodyFont(.caption))
                    .monospacedDigit()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 9)
                // 四类账唯一的破绽：用量还没跟上扫描快照时，四类加起来会比整盘多。
                // `CostLedger` 把多出来的那截记在 `overdrawn` 上而不是印一个负的「不碰」，
                // 那这里就得把多出来的数说出来——不说，这一列就是一张加不起来的图。
                if costReading, let led = model.costLedger, !led.balanced {
                    Text(LF("用量与扫描快照对不上：四类比整块盘多出 %@。", human(led.overdrawn)))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.warnFG)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                PickMainButton(model: model, acct: acct) {
                    arcNote = nil
                    cleanDetail = nil
                    // 进清单这一下是「先把刀放下、看清楚」：一声下行的预演音，
                    // 与真正搬走那声「响指」正好反过来。
                    Sound.shared.play(.preview)
                    model.openFirstClean()
                }
                if !model.scanning { trashTray(acct) }
                if model.scanning {
                    Text(L("扫完之前，底栏不会出现任何清理动作"))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            if !model.scanning && model.armedPath == nil && acct.reclaimable > 0 {
                // 代价读法整圈不接上膛（`select == nil`），那句「点一段两次」在那儿是假话；
                // 换成同一位置的「这一笔怎么定」，否则那圈色块看起来像能直接点走。
                //
                // 这一格在预演那一档**不换**（稿子⑫那一条挪到环底下了，见 `heroCard` 里那处）。
                // 留在这儿不动是本意的：这一列从头到尾说同一句话，按空格时长这本账的行不跳位。
                VStack(alignment: .leading, spacing: 4) {
                    Text(costReading
                         ? L("代价读法下环上不接上膛：要清什么在清理清单里逐处确认；「不可逆」从不进一键。")
                         : L("点一段两次才收走那一段（防误删）· 3 秒不点自动撤；点动不了的段只会告诉你它为什么动不了。"))
                        .fixedSize(horizontal: false, vertical: true)
                    // 稿子 `#footHint` 的第二行（`<kbd>空格</kbd> 预演清完的样子`）：
                    // 空格这一把在真机上早就绑好了（`SpaceHoldTap`，钮上还带着角标），
                    // 缺的只是把它说出来——一个没人知道的键位等于没有这个键位。
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        KeyCap(text: L("空格"))
                        Text(L("预演清完的样子 · 只进废纸篓，随时可撤销"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
            }
        }
    }

    /// 预演那一档的决策条（稿子⑫）：一笔还没发生的账 + 两次按下 + 一句退路。
    /// **浮在**环的正下方那一片空白里（`PreviewBarHost`），不排在环下面——样稿 `.dbar`
    /// 就是 `position:absolute`，条子出现时环不动。它为什么先离开右边那本账、后又离开
    /// 环下面那一格，两笔实测数都记在 `heroCard` 里那一处调用上。
    ///
    /// 「就这样清」走的是弧上那同一把刀：第一下 `arm(SweepRing.armAll)` 上膛（整圈描边、
    /// 3.2 秒自己解除），第二下才搬。这里不另写一条「一键清理」——两条路砍得不一样，
    /// 迟早有一天一边搬得动一边搬不动。
    ///
    /// 那盏灯的颜色只在这一条上出现（那颗主钮），跟环上那截光弧、盘心那个数、每一行小字
    /// 末尾那截 `+N` 是同一种：这一档在屏幕上说的每一件事，都用同一种颜色认领。
    private func previewBar(_ acct: RingAccount, width: CGFloat) -> some View {
        let armed = model.armedPath == SweepRing.armAll
        // 「比现在多」拿**印出来的**两个数相减，与盘心那两行同源：各按字节四舍五入一次，
        // 这一条就跟盘心差出 0.1（`RingAccount` 上面记着这类实拍）。
        let more = diffShown(acct.afterClearShown, acct.availableShown)
            ?? human(acct.reclaimable + acct.inBin)
        // 竖着排：这一条只有环那么宽（`maxWidth: ring`，最小那档实测 236 pt），
        // 横排的两句话加两颗钮在那个宽度里一定折，折了就说不完这句话。
        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(LF("全部清空后可用 %1$@ · 比现在多 %2$@", acct.afterClearShown, more))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                // 「撤销」说的是**这一步搬走的那些**，不是上面那个差值——差值里还含着
                // 已经在废纸篓、等访达清空的那几 G，那部分不靠这颗钮，也不归这颗钮管。
                //
                // 上膛之后这两行**一个字都不改**，只换那颗钮（`就这样清` → `确认移入废纸篓 ⌘↵`）：
                // 「已选中 N 处、再点一次才搬、3 秒不点自动取消、搬走后还能找回」这四件事实由
                // 这一条（处数、字节、头几处的名字、找回）、那颗钮（再点一次）和盘心那一档
                // （自动取消）分说完了，少一件这一屏就少一句实话。
                //
                // 名单那半句（`· X GB（名1、名2、名3…）`）是 2026-10-25 补的：从前这一条只写
                // 「点名的 N 处」，人不知道这 N 处是**哪些目录**就得决定要不要按第二下——
                // 跟单条弧上膛那份名单同一条道理，只是整圈这一档的名单由这条浮着的预演条念，
                // 不由环底下那一格念（那一格在整圈档让位，见 `ringBelow`）。
                Text(LF("这一步点名的 %1$@ · %2$@（%3$@），搬走后都能在废纸篓页撤销",
                        cnt(acct.places, "处"), human(acct.reclaimable),
                        namesTail(acct.hot.flatMap { $0.targets })))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                ThemeButton(kind: .lamp,
                            title: armed ? L("确认移入废纸篓") : L("就这样清"),
                            // 第二下才配 ⌘↵：这一屏「回车=确认」只对已经上膛的那一把，
                            // 第一下（上膛）不绑键，否则回车就成了「先举刀」的暗门。
                            // 常驻的那几档更要守这条：静帧里这颗钮是看不见的，
                            // 再绑上 ⌘↵ 就是一颗吃掉回车却什么都不做的键。
                            shortcut: armed ? KeyboardShortcut(.return, modifiers: .command) : nil,
                            keyHint: armed ? "⌘↵" : nil) {
                    tapCleanAll(acct)
                }
                // 退路那颗钮**两档都在**。从前它只在预演那一档出现（上了膛之后「松开返回」
                // 是一句假话——空格此刻没按着），而现在这一整棵子树常驻，少一颗钮就是换树，
                // 换树正是这一档付不起的那一笔（见 `PreviewBarHost`）。话照旧各说各的：
                // 预演里退路是松开空格，上了膛之后那一按该走的是卸膛，于是给它一句真话。
                ThemeButton(kind: .ghost, title: armed ? L("取消") : L("松开返回")) {
                    armed ? model.disarm() : model.endPreview()
                }
                .help(armed ? L("取消") : L("松开空格也回到现在这一档"))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: width, alignment: .leading)
        .background(theme.controlShape().fill(theme.palette.safeFG.opacity(0.07)))
        .overlay(theme.controlShape().stroke(theme.palette.safeFG.opacity(0.22), lineWidth: 1))
    }

    /// 账本列的小节头：左边给这一列一个名字，右边一次说完「分了几类、其中几类现在动得了」。
    ///
    /// 「现在能清」数的是 `reclaim > 0` 的那几类——跟弧上不给动不了的段画「点我」亮沿
    /// 是同一条判据（见 `GaugeSegment.reclaim`），所以这句话不会跟环上对不上账。
    /// 代价读法下它是「4 类 · 2 类现在能清」：不可逆与不碰那两类 reclaim 恒为 0。
    private func ledgerHead(_ acct: RingAccount) -> some View {
        let clean = acct.segs.filter { $0.reclaim > 0 }.count
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(L("这本账"))
                .font(theme.bodyFont(.caption2).weight(.semibold))
                .kerning(1.5)
                .foregroundStyle(theme.palette.inkTertiary)
            Spacer(minLength: 8)
            Text(LF("%1$d 类 · %2$d 类现在能清", acct.segs.count, clean))
                .font(theme.numeric(size: 10))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
        }
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.palette.separator).frame(height: theme.metric.stroke)
        }
    }

    /// 主按钮：从「直接搬」改成入口。这一下不写盘，只把可回收的摆成一列，
    /// 让人先看每一处的代价，再决定勾哪几处（样稿 S1→S2）。
    ///
    /// 按钮上的数必须和环上那本账是**同一个来源**，否则同一屏隔两行长出两个「可回收」。
    /// 样稿那张 mock 里只有一个数（2.3 GB / 6 处），真机上有两套：环上「动得了」只认
    /// 知识库标 safe 的那几处（这台量到 2.4 GB / 11 处），清单还要把 `redo`（删了要重新
    /// 下载）摆出来让人自己决定，于是 27.2 GB / 32 处。拿清单那套写字节（环上 2.4 /
    /// 按钮 27.2）或写处数（环上 11 / 按钮 32）都会在招牌画面上打架——2026-10-19 中英
    /// 两边实拍各命中一次。所以这里取 `acct.places`，与环上同一个数；清单页头那句
    /// 「默认只勾了没影响的」负责解释多出来的那几行为什么也在列。
    ///
    /// 样稿那颗主钮写的是「把可回收的 **10.8 GB** 移进废纸篓」，两笔都不照搬（2026-10-22）：
    /// 一是话——这一下不写盘，它是入口，写成"移进废纸篓"会让人以为按完就没了；二是字节——
    /// 勾满时这里只报处数，合计留给确认页那颗灯钮（那一屏只许有一个总数），只在人自己挑过
    /// 一部分时才报字节，因为那时"选中的这堆有多少"是本屏唯一还没人报过的数。
    ///
    /// 选择在清理清单里做，所以**一个都没选中时这颗按钮也得能按**：它是回到那张
    /// 清单的唯一入口。禁用只有两种：还在量、或者这一圈本来就没有能收的东西。
    private struct PickMainButton: View {
        @ObservedObject var model: OverviewModel
        let acct: RingAccount
        let run: () -> Void

        /// 此刻「这一笔」的合计：现读池子，不读上一次整页算账时留下的那一份旧值。
        private var live: (bytes: Int64, places: Int, all: Bool) {
            model.pickedTotals(of: acct.segs)
        }
        private var sub: Bool { !live.all }
        private var count: Int { sub ? live.places : acct.places }
        private var empty: Bool { count == 0 && acct.places == 0 }
        private var can: Bool { !model.scanning && !model.cleanScanning && !empty }

        // 全选中时沿用原来那句话，一个字的门槛都不给老用户添。
        //
        // 扫描中禁用态不能写「这一圈里没有可回收的」：这句话是在报结论，而账还没量完。
        // S0 的规矩是当场说清「为什么按不动」——量完才能动手。
        private var title: String {
            if model.scanning { return L("量完才能动手") }
            // 盘量完了、缓存清单还在量。此时下面几行已经报出「可回收」，
            // 按钮却写「没有可回收的」——同一屏两句话打架，只是因为它还没数完。
            if model.cleanScanning { return L("正在量缓存…") }
            if empty { return L("这一圈里没有可回收的") }
            if count == 0 {
                // 东西都在，是人自己在清单里把它们都拿掉了。这里必须还能点开那张清单。
                return L("打开清理清单挑要清的 →")
            }
            return sub ? LF("查看选中的 %1$d 处、共 %2$@ →", count, human(live.bytes))
                       : LF("查看可回收的 %d 处 →", count)
        }

        var body: some View {
            ThemeButton(
                kind: .lamp,
                title: title,
                isDisabled: !can,
                // 样稿 `.act{width:100%}`：这一栏多宽它就多宽，右边不给空白。
                // 原来它按标签长短收（实拍 159.5 pt，栏宽 363），于是主钮读起来像
                // 账本里的一行而不是一屏的出口——出口是要人按的，不是给人挑的。
                fillsWidth: true
            ) { run() }
            .accessibilityHint(L("先看清单，再决定清哪些"))
        }
    }

    /// 起一趟回收时叫一声：接下来那一格里，废纸篓的条子要等水珠落地才动。
    ///
    /// 判的是「这一次 `frac` 变化是不是那趟飞行带起来的」。用时间窗而不是把条子的值
    /// 直接按着不放：`frac` 由账推（`inBin / (reclaimable + inBin)`），页面手里没有
    /// 那条写入的口子，也不该再造一条。窗比 `dawnAt` 多出 0.2 秒：账落数走的是后台
    /// 回填那一拍，可能比第一颗水珠砸进篓子那一下晚半拍，窗掐得太准会让那半拍走快档。
    private func trayWaitsForLanding() {
        trayLanding = true
        DispatchQueue.main.asyncAfter(deadline: .now() + ReclaimTimeline.dawnAt + 0.2) {
            trayLanding = false
        }
    }

    /// 废纸篓那一格：搬进来的已经占着盘，进度条说的是「这堆里已经收了多少」。
    /// 「清空」不在这页按——真要字节让位得去废纸篓页交给访达，所以这颗是指路牌。
    private func trashTray(_ acct: RingAccount) -> some View {
        let has = acct.inBin > 0
        let frac = fraction(acct.inBin, of: acct.reclaimable + acct.inBin)
        let lampColor = SweepRing.lamp(theme.palette.tint)
        return HStack(spacing: 9) {
            Text(L("废纸篓"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(SweepRing.greyInk(theme: theme, dark: darkSkin)
                        .opacity(darkSkin ? 0.13 : 0.18))
                    // 斜纹填充，不是实心条：样稿写的是 `repeating-linear-gradient(115deg, …)`。
                    // 实心进度条在说「已经完成」，而这 4 px 说的是「收进来的还占着盘、
                    // 只是换了个格子住」——纹就是这两态的区别，抹平了就只剩颜色在说。
                    //
                    // **满幅画纹、再拿宽度当遮罩裁**，不把宽度写进绘制循环里：后者一变
                    // 就是一次重绘，而 `Canvas` 不参与插值——那一格永远是**跳**满的，
                    // 点完看不出东西在往里走。改成遮罩之后动的是那个宽度，宽度是可插值的。
                    Canvas { ctx, size in
                        var x: CGFloat = -size.height
                        while x < size.width {
                            var p = Path()
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height * 0.6, y: 0))
                            ctx.stroke(p, with: .color(lampColor.opacity(0.8)), lineWidth: 2)
                            x += 6
                        }
                    }
                    .mask(alignment: .leading) {
                        // 动画挂在**遮罩自己**的宽度上，不挂给上面那个 ZStack——挂给 ZStack
                        // 等于把整棵子树的几何都收进这一条动画的管辖：换读法时账本从七行缩成
                        // 四行、这一行当场往上挪，而 `frac` 的分母也同时换了（就是下面那行
                        // `%1$@ / %2$@` 里后半个数），
                        // 于是「挪位置」被当成一次可插值的几何变化，条子按 1.04 秒的延迟慢慢
                        // 爬到新格子，左边的「废纸篓」和右边的数却当场到位。2026-10-24 实拍
                        // 错开两百多 pt：条子落在原位置下方的空地里，他那句「需要几秒钟才能
                        // 对齐文字废纸篓」量的就是这一段。挂在遮罩上，能动的只剩这个宽度。
                        Rectangle()
                            .frame(width: geo.size.width * frac)
                            // **只有回收那一趟**值得让它等：水珠到 `releaseAt`（1.04 秒）才真
                            // 离开带面，第一颗在 `dawnAt`（2.09 秒）落进篓子——条子正好摊在
                            // 这两格之间，落定的那一响也就是摊满的那一下。点完当场跳满等于说
                            // 那趟飞行没发生过。
                            //
                            // 但这一档不能挂给**每一次**变化：换读法也在改 `frac`，而那一刻
                            // 没有水珠在飞，等 1.04 秒读起来就是「卡了一下」。那种时候按稿子
                            // 的 `.abar i{transition:width .5s}` 走。「减弱动态效果」下不飞，
                            // 条子也就不等。
                            .animation(trayLanding && !reduceMotion
                                ? .easeInOut(duration: ReclaimTimeline.dawnAt - ReclaimTimeline.releaseAt)
                                    .delay(ReclaimTimeline.releaseAt)
                                : .easeInOut(duration: 0.5), value: frac)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 4)
            Text(LF("%1$@ / %2$@", human(acct.inBin),
                    human(acct.reclaimable + acct.inBin)))
                .font(theme.numeric(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(has ? SweepRing.lampHot(theme.palette.tint)
                                     : theme.palette.inkTertiary)
                .fixedSize()
            Button { store.jumpTo = .trash } label: {
                Text(L("去清空"))
                    .font(theme.prose(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .overlay(Capsule().stroke(theme.palette.separator, lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!has)
            .opacity(has ? 1 : 0.32)
        }
        // 这一格就是落点。报整行矩形：水珠只落在左半段（右半段是数与按钮，
        // 溅上去读作「按钮坏了」），而那半段的宽度只有这一格知道。
        .heroFrame("tray", in: Self.heroSpace)
    }

    private func fraction(_ v: Int64, of total: Int64) -> CGFloat {
        total <= 0 ? 0 : CGFloat(max(0, v)) / CGFloat(total)
    }

    // MARK: 就地摊开的明细：这一页唯一的下一级

    /// 摊开某一行之后，那一行名下画什么。三种载荷的数都已经在页面上算好了，
    /// 这里只说「点开是哪一种」——所以下钻既不跳页，也不需要第二段列表。
    @ViewBuilder
    private func drillPanel(_ seg: GaugeSegment) -> some View {
        switch seg.drill {
        case .children(let path)?: childrenPanel(seg.label, path: path)
        case .restGroup?:         restGroupPanel()
        case .gapRows?:           gapPanel()
        case nil:                 EmptyView()
        }
    }

    /// 第一种载荷：某个目录的下一级。量这一趟是点开时才派出去的（`toggleDrill`），
    /// 量过走缓存；正在量时先给一行话——那几秒空着，看着就像「点开啥也没有」。
    private func childrenPanel(_ title: String, path: String) -> some View {
        let rows = model.childRows[path] ?? []
        let busy = model.childBusy.contains(path)
        let whole = model.arcSize(of: path)
        let rest = max(0, whole - rows.reduce(Int64(0)) { $0 + $1.size })
        // 整列连尾巴那句一起过一次统一分档，钉在父行那个数上：这一列 ＋ 那句 = 上面
        // 那一行。逐行 `human()` 会各飘 0.1，那句对账就永远加不回来。
        let texts = addableHumanColumn(rows.map { $0.size } + [rest], total: whole)
        return VStack(alignment: .leading, spacing: 5) {
            if busy && rows.isEmpty {
                busyLine(LF("正在量「%@」的下一级", title))
            }
            ForEach(Array(rows.enumerated()), id: \.element.path) { i, c in
                DrillRow(icon: .path(URL(fileURLWithPath: c.path)),
                         name: c.name, path: c.path,
                         size: c.size,
                         sizeText: c.unreadable && c.size == 0 ? "—" : texts[i],
                         reclaim: min(c.size, model.reclaimableUnder(c.path)),
                         ruler: whole,
                         fraction: Double(c.size) / Double(max(1, rows.first?.size ?? 1)))
            }
            if !busy {
                if rows.isEmpty {
                    tailLine(rest > MB
                        ? L("这一层的空间全在它自己的文件里，没有读得出的子目录。用行尾那颗「访达显示」去盘上看。")
                        : L("这一层没有读得出的子目录。"))
                } else if rest > MB {
                    tailLine(LF("这一层自己的文件合计 %@，没逐行列出。", texts[rows.count]))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 第二种载荷：「其他已统计」那条弧名下的位置。弧上画的是第 4 名往后的**合计**，
    /// 这一头逐行点名，最后那句把没点到的补齐——几段相加就是弧上那个数。
    ///
    /// 这一堆从前摊在页面底下另一张列表里，隔着一次滚动，于是「大头你一直找不到」：
    /// 弧上有 221.9 GB，屏幕上只看得见 21.2 GB，剩下 200 GB 停在上方没人框它。
    /// 现在它就在自己那条弧对应的那一行底下，对账就地完成。
    private func restGroupPanel() -> some View {
        // 第 4 名到列表封顶，再接封顶之外那些（两处各自按大小排，拼起来仍是降序）。
        let rows = restGroupRows + model.restHotspots
        let nets = rows.map { model.arcSize(of: $0.path) }
        let listed = nets.reduce(Int64(0), +)
        let small = model.unlistedNet
        let total = restArcValue ?? listed + small
        // 尾巴那句里「这几处」那个数取**印出来的这几行**之和（`sumShown`），不拿字节加：
        // 人核对的是屏幕上这一列，差的那 0.1 要记在「每行都各自四舍五入过」上。
        let texts = addableHumanColumn(nets + [small], total: total)
        let listedText = sumShown(Array(texts.prefix(rows.count))) ?? human(listed)
        var parts: [String] = []
        if !rows.isEmpty {
            parts.append(LF("这里这 %1$d 处 %2$@", rows.count, listedText))
        }
        if rows.isEmpty || small > 0 {
            parts.append(LF("%1$d 处不到 %2$@ 的小目录 %3$@", model.unlistedCount,
                            human(OverviewModel.sizeFloor), texts[rows.count]))
        }
        let note = parts.isEmpty ? nil
            : LF("环形上「其他已统计」那条弧 %1$@，就是这几段相加：%2$@。",
                 human(total), parts.joined(separator: " ＋ "))
        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.element.path) { i, r in
                DrillRow(icon: .path(URL(fileURLWithPath: r.path)),
                         name: r.name, path: r.path, size: r.size,
                         sizeText: texts[i],
                         reclaim: model.reclaimable(of: r.path),
                         ruler: total,
                         fraction: Double(nets[i]) / Double(max(1, nets.first ?? 1)))
            }
            if !model.scanning, let note {
                tailLine(note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 第三种载荷：「没量到」那块灰弧的卷账。整块盘的账拆到能命名的每一卷，
    /// 各写一句为什么在这块弧上、动不动得了。只报一个总数等于没回答。
    @ViewBuilder
    private func gapPanel() -> some View {
        if let u = model.usage {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(Array(gapRows(u).enumerated()), id: \.offset) { _, row in
                    // 图形跟另外两种载荷同一格：这一屏摊出来的每一行都有那一格，
                    // 只有「没量到」那几行没有，读起来就像那几行不属于这张表。
                    HStack(alignment: .top, spacing: 10) {
                        RowIconView(icon: .symbol(row.symbol))
                            .frame(width: rowIconSide, height: rowIconSide)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.title)
                                    .font(theme.bodyFont(.caption))
                                    .foregroundStyle(theme.palette.ink)
                                Text(row.tag)
                                    .font(theme.bodyFont(.caption2))
                                    .foregroundStyle(row.actionable
                                                     ? theme.palette.tint : theme.palette.inkTertiary)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(row.actionable
                                                                ? theme.palette.tintSoft
                                                                : theme.palette.surfaceAlt))
                                Spacer(minLength: 8)
                                Text(human(row.bytes))
                                    .font(theme.numeric(size: 13))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.palette.inkSecondary)
                                    .fixedSize()
                            }
                            Text(row.reason)
                                .font(theme.bodyFont(.caption2))
                                .foregroundStyle(theme.palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.leading, drillIndent - rowIconSide - 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func busyLine(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "hourglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 3)
        .padding(.leading, drillIndent)
    }

    /// 明细尾巴那句对账。它必须和上面那几行**同缩进**：差一截的话这句就悬在
    /// 列表外面，读不出它说的是哪一组。
    private func tailLine(_ text: String) -> some View {
        Text(text)
            .font(theme.bodyFont(.caption2))
            .foregroundStyle(theme.palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)
            .padding(.leading, drillIndent)
    }

    // MARK: 圆心那三行

    /// 圆心那句问话。第一眼要回答的是「这块盘现在什么情况」，不是「本工具能清多少」：
    /// 后者是导语和按钮的话。把它顶在圆心，快满的机器只留下一个比已用小三十倍的数，
    /// 人一眼读成「我这盘挺空」——正好读反。
    /// 扫描和上膛那两态仍然抢圆心，因为它们说的是此刻这件事，不是盘的常态。
    ///
    /// 这里**不写预演那一档**：那一档要说另一笔账（「全部清空后」，稿子⑩），句子由
    /// `centerTopPreview` 单独给、`RingCenterReadout` 自己挑。页面一读 `model.previewing`
    /// 就得订阅它，一发空格于是变成整页重算——`PreviewSignal` 上面记的正是这一笔。
    private func centerTop(_ acct: RingAccount) -> String {
        if model.scanning { return L("正在扫描") }
        if model.armedPath != nil { return L("确认移入废纸篓") }
        return L("可用")
    }

    private func centerValue(_ acct: RingAccount) -> String {
        // 扫描中圆心的主数从「已量字节」换成百分比：样稿 S0 要的是「还剩多久」，
        // 而 286.8 GB 这个数离开下面那行 494.4 就没有参照物。带空格的写法让
        // `heroNumber` 把 `%` 收到三分之一档，跟 GB 同一个处理。
        if model.scanning { return "\(scanPercent(acct.total)) %" }
        if let armed = model.armedPath {
            // 上膛那一刻圆心写的是**这一按真会搬走的量**，不是那条弧的体积：
            // 「确认移入废纸篓 23.2 GB」而它名下只有 13 GB 收得走，那一按下去数对不上。
            if armed == SweepRing.armAll { return human(acct.reclaimable) }
            return acct.segs.first { $0.armKey == armed }?.reclaimShown ?? human(0)
        }
        return acct.availableShown
    }

    /// 那个数的口径。圆心只放一个数，就必须当场说清它是**从哪儿到哪儿**：
    /// 「可用 14.9」不配「整块盘 494.4 · 已用 479.5」这半句，就只是一个让人安心的数。
    /// 第二行留给出完力之后的样子——「还能腾出」没消失，只是从招牌降成承诺。
    private func centerCap(_ acct: RingAccount) -> String {
        if model.scanning {
            // 处数摆最前：一趟整盘扫描里「十五处走了三处」比「读掉几 G」更直接地说清
            // 这一圈还没量完。字节会骗人——一处 `~/Library` 顶得掉三成进度，
            // 走完它像走完了全程，其实后面还有十二处没轮到。
            // 那句「还没量完」不是废话：圆心那个大数字是**量盘**的百分比，
            // 而这一屏别处出现的百分比（页头那颗）说的也是它——先说清这一圈是活的，
            // 人才不会把 7% 读成「只回收了 7%」。
            // 字节数与整盘分母都不在这里重复：账目列底下那句「已读 x / y · 只读」带着它们，
            // 同一屏摆两处同样的除法只是噪声。
            //
            // 这里原来还有**第二行**「还剩约 N 分钟 · 只读」，2026-10-24 删了。那个数是拿
            // `covered / 分母` 线性反推的，两头都不成立：
            // ① **分母不可达**——这一圈量的是 69 处目标目录，不是整块已用空间。真机走完那一趟
            //    `covered` 只到 90 G，而盘上已用 286.8 G，所以剩余时间永远收敛不到 0；
            // ② **每处的耗时差一个量级**——头一处 `~/Desktop` 自己就占 37 G，换成按处数推一样歪。
            // 实测那一趟 **86 秒**走完，圆心写的却是「还剩约 3 分钟」（2026-10-24 实拍那张：
            // 18 % · 已量 66/69 处 · 还剩约 3 分钟）。一句没根据的倒计时比一句「不知道」更坏——
            // 人就在这行字前面把软件关掉了。
            // 样稿扫描态的圆心本来就只有一行（`diskwise-v2.6-crystal.html:2904`、`:2915`
            // 两处 `coreCap.textContent='已量 N/M 处 · 这一圈还没量完'`），没有剩时间这一说。
            return LF("已量 %1$d/%2$d 处 · 这一圈还没量完",
                      model.done, model.scanTargets.count)
        }
        if model.armedPath != nil {
            return L("再点一次才移进废纸篓 · 3 秒不点自动取消")
        }
        // 代价读法不写「全部清空后可用」：这里的 `reclaimable` 是零代价＋需重下两类的
        // 可勾字节，跟按空间那本账的 `reclaimable`（只认 safe）不是同一个数。
        // 同一屏摆两个「清空后可用」，就是这一屏最容易塌的那种假账。
        if costReading {
            return LF("整块盘 %1$@ · 已用 %2$@", acct.totalShown, acct.usedShown)
        }
        let head = LF("整块盘 %1$@ · 已用 %2$@", acct.totalShown, acct.usedShown)
        // 还能搬走的 + 已经在废纸篓还没让位的，加回可用才是「走完这一步之后」。
        // 一笔都没有时不写这句空话，只把这一圈的结论留下。
        return head + "\n" + (acct.reclaimable + acct.inBin > 0
            ? LF("全部清空后可用 %1$@", acct.afterClearShown)
            : L("这一圈里没有本工具动得了的东西"))
    }

    /// 扫描百分比：按**整块盘**算，不按已用。样稿 S0 的圆心是 286.8 / 494.4 = 58%，
    /// 读数头也停在这条边界上——两处拿同一个分母，图才和数对得上。
    private func scanPercent(_ total: Int64) -> Int {
        Int((Double(model.covered) / Double(max(1, total)) * 100).rounded())
    }

    /// 量盘这一圈走到哪儿了：按**量到的字节**算，不按时间编一段动画。
    ///
    /// 它只喂 `SweepRing.scanProgress` 一个入口，那条上挂着两样东西：环底下那截进度条，
    /// 和减弱动态/静图里那道光的落点（`RingLayers.scanBeam` 的静态分支）。圆心那个百分比
    /// 走的是 `scanPercent`，同一个分子分母各算各的。真机上那道光**不吃这条**——它匀速绕环，
    /// 理由和节拍都记在 `scanOrbitSeconds` 那条上：进度由数报，光只报「还在转」。
    private func scanFraction(_ u: VolumeUsage) -> Double {
        min(1, max(0, Double(model.covered) / Double(max(1, u.total))))
    }

    /// 这一行要把整块盘的账一路减到底：494 = 可用 128 + 已用 366，已用 = 量到 320 + 量不到 46。
    /// 只报「已量到 320.6，占已用 85%」不够——人手里记的是「我这盘 500 G」，
    /// 看到 320 就以为我们说整块盘只有 320，那一瞬间工具就变成在骗人。
    /// 可用必须写成「空闲 + 可清除」两段：只报那个跟系统对齐的大数，等于把
    /// 10 GB 还占着盘的东西说成空的。差额去哪了不在这里逐块说，点开「没量到」那一格点名。
    /// 可清除是 0 时不再写这一项：环形上本来就不画 0 字节的弧（见 `ringAccount`），
    /// 句子却照抄模板就会拍出一张「系统可清除 0 B」的图——那是在演示一个不存在的东西。
    private func coverageLine(_ u: VolumeUsage) -> some View {
        let pct = Int((Double(model.covered) / Double(max(1, u.used)) * 100).rounded())
        // 「已用 = 量到 + 量不到」是这一句自己许的账，所以三个数由**印出来的字**互相加减，
        // 不各拿字节四舍五入（那样三项能差出 0.1）。已用那格还跟圆心共用同一条算法。
        let availT = human(u.available), usedT = diffShown(human(u.total), availT) ?? human(u.used)
        let gapT = human(max(0, u.used - model.covered))
        let tail = LF("已用 %1$@。已用里这一轮量到 %2$@（%3$d%%），剩下的 %4$@ 点开「没量到」那一行逐块点名。",
                      usedT, diffShown(usedT, gapT) ?? human(model.covered), pct, gapT)
        let text: String
        if u.purgeable > 0 {
            text = LF("整块盘 %1$@：可用 %2$@（空闲 %3$@ ＋ 系统可清除 %4$@），",
                      human(u.total), availT, human(u.free), human(u.purgeable)) + tail
        } else {
            text = LF("整块盘 %1$@：可用 %2$@（全是空闲），",
                      human(u.total), availT) + tail
        }
        return Text(text)
            .font(theme.bodyFont(.caption))
            .foregroundStyle(theme.palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 「没量到」那一格的卷账

    /// 一行差额：名字、多大、为什么是这么个去向、这个工具动得了动不了。
    private struct GapRow {
        let title: String
        let tag: String
        var reason: String
        let bytes: Int64
        /// 这一块有没有能要回来的部分——决定画不画那颗「去授权」。
        let actionable: Bool
        /// 行首那一格。这几块都没有路径可查（不是盘上的某个文件夹），走类别符号那一档。
        let symbol: String
    }

    /// 这一格能不能靠「去授权」要回来——决定画不画那颗按钮。
    ///
    /// 判据是实测探针（`model.hasFDA`），不是扫描里报了几处 EPERM：系统设置里勾完，
    /// macOS 要 App 退出重开才把授权落到进程上，而这趟扫描往往正是重开之前跑的。
    /// 只数 EPERM 就会对着已经勾过的人说「再点那颗去授权」，那是把人往回踢。
    private var canGrantFDA: Bool {
        !HomeAccess.runsSandboxed && !model.hasFDA && !model.needFDA.isEmpty
    }

    /// 环形上那块「没量到的地方」灰的去向。
    ///
    /// 不能只报一个总数：470 GB 已用里没量到的三百多 G，绝大部分既不是「扫不动」也不是
    /// 「没东西可清」，而是这台盘的账本来就不在用户区——只读系统卷、VM 卷、引导分区，
    /// 加上真正能追回来的那部分（打不开的目录、没扫到的位置）。揉成一块灰，
    /// 用户只会读成「我的盘白清了」，那是这一屏最容易误导人的一处。
    private func gapRows(_ u: VolumeUsage) -> [GapRow] {
        let dataVolume = model.split?.dataVolume ?? u.used
        // 「系统可清除」此刻在环形上单列成一条弧、在数字上归进了「可用」，
        // 但它物理上就躺在数据卷的 CapacityInUse 里。不减掉的话，同一块 10 GB
        // 会在「没量到的地方」和「可清除」各报一次。拆不出卷账时不知道它落在哪一
        // 卷，那就宁可不减，也不凭猜想挪账。
        let purgeableInData: Int64 = model.split == nil ? 0 : u.purgeable
        let first = GapRow(title: model.split == nil ? L("没量到的部分") : L("数据卷里没量到的部分"),
                           tag: gapFirstRowTag,
                           reason: gapFirstRowReason,
                           bytes: max(0, dataVolume - min(model.covered, dataVolume) - purgeableInData),
                           actionable: canGrantFDA || HomeAccess.runsSandboxed,
                           symbol: "questionmark.folder")
        var rows = [first]
        if let s = model.split {
            rows.append(GapRow(
                title: L("macOS 系统卷"), tag: L("删不动"),
                reason: L("只读、签名封存，由 SIP 看着。任何清理工具都动不了它，真要瘦只能等系统更新自己整理。"),
                bytes: s.sealedSystem, actionable: false, symbol: "lock.rectangle.on.rectangle"))
            rows.append(GapRow(
                title: L("虚拟内存与休眠镜像"), tag: L("系统自己收回"),
                reason: L("内存吃紧时 macOS 借硬盘喘息，深度休眠前还会把整份内存写下来。关掉占内存的应用就会缩，不该由工具去删。"),
                bytes: s.virtualMemory, actionable: false, symbol: "memorychip"))
            rows.append(GapRow(
                title: L("启动与恢复分区"), tag: L("删不动"),
                reason: L("开不了机时才用得上，属于固件的地盘。恢复卷平时不挂载，也一起算在这一行。"),
                bytes: s.bootAndRecovery, actionable: false, symbol: "arrow.counterclockwise.circle"))
            rows.append(GapRow(
                title: L("卷之间的未归属占用"), tag: L("对不到目录"),
                reason: L("APFS 容器自己的元数据，加上各卷共享的那点取整差。这一坨对不到具体文件夹，只能整体看着。"),
                bytes: s.unattributed, actionable: false, symbol: "circle.dashed"))
        }
        return rows.filter { $0.bytes > 0 }
    }

    /// 第一行那颗标签：三种真实状态各有各的说法，不能一律写「授权能补一部分」。
    private var gapFirstRowTag: String {
        if HomeAccess.runsSandboxed { return L("授权能补一部分") }
        if model.needFDA.isEmpty { return L("对不到目录") }
        return canGrantFDA ? L("授权能补一部分") : L("已授权仍读不到")
    }

    /// 第一行怎么说：能拆卷账时这一格确定是「你的文件」，拆不出时不能这么断言，
    /// 里面还混着系统自己的分区。沙盒版不提「切整盘」——那颗开关在沙盒里根本不存在。
    private var gapFirstRowReason: String {
        var text: String
        if HomeAccess.runsSandboxed {
            text = L("沙盒只放行了你授权过的目录，其余位置量不到。这不是盘上的死账：授权范围里的东西量到之后都能进废纸篓。")
        } else if model.split == nil {
            text = demoDisclosed
                ? L("演示树只画得出这一块。真机上这里会按卷点名：系统卷、虚拟内存、引导分区各占多少，一眼分清哪些能追回来。")
                : L("这一轮没扫到、或目录打不开的都归在这里。这台机器的分卷账拆不出来，所以没法替你把系统分区单独挑出去。")
        } else {
            // 剩余里混着两种东西：补授权就能量到、量到之后能删的；以及只有 root 读得动、
            // 任何清理工具都删不动的。混成一句「都能进废纸篓」是吹牛。
            text = L("这一轮量不到的都归在这里：要么是读不动的目录，要么是盘上对不到具体文件夹的账。")
        }
        // 读不动的那几处按探针分开说。已经勾过的人还让他去勾，比不提示更糟——
        // 他会认定这个工具量不动自己的盘。
        if !model.needFDA.isEmpty {
            text += " " + (HomeAccess.runsSandboxed
                ? LF("沙盒读不到的目录 %1$d 处。", model.needFDA.count)
                : canGrantFDA
                    ? LF("其中 %1$d 处缺「完全磁盘访问权限」：点「没量到」那一行行尾的「去授权」，勾完要退出这个 App 再打开才生效，然后重扫一轮。",
                         model.needFDA.count)
                    : LF("完全磁盘访问权限已经开着，其中 %1$d 处仍然读不到——那是系统自己看着的位置，重启或提权都换不回来。",
                         model.needFDA.count))
        }
        if !model.needAdmin.isEmpty {
            text += " " + LF("另有 %1$d 处只有管理员能读，工具不提权，也就量不出它们多大。",
                             model.needAdmin.count)
        }
        return text
    }

    private func openFullDiskAccessPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private var scopeNote: String {
        if HomeAccess.runsSandboxed {
            return L("覆盖范围：你授权过的目录。系统区在沙盒里读不到，所以单列为「没量到的地方」。")
        }
        // 把扫了哪几处点名念出来：只说「整块盘上普通用户可读的位置」，
        // 用户就不知道这一趟到底走过了哪些地方、剩下的差额是谁的。
        return LF("覆盖范围：家目录（含隐藏项）与 /Applications，另外 %1$d 处盘上普通用户读得动的位置（%2$@）。剩下的「没量到」是密封系统卷、引导与恢复分区，和只有 root 读得动的系统数据——那几块任何清理工具都动不了。",
                  model.extraScanRoots.count, model.extraScanRoots.joined(separator: "、"))
    }

    /// 环形这一屏的账本：弧、以及从同一批数派生出的四句话。
    ///
    /// 只算一次。导语、圆心、主按钮、废纸篓那条进度共用「还能腾出多少」——各算各的
    /// 话收走一处就会有一处停在旧数上，而这一屏最容易塌的就是同屏两个数打架。
    /// 恒等式：reclaimable + measuredIdle + untouched + inBin + free + purgeable == total。
    private struct RingAccount {
        var segs: [GaugeSegment] = []
        /// 环上真正画的那些段。跟 `segs` 只在扫描中分家：账目列要七行都读得出来
        /// （其中几行还是「排队中」、值为 0），而环上那几行没有角度——照 `segs` 画
        /// 会被 `ringArcs` 按可见值归一，把整圈分给还没量完的那几段。
        /// nil = 就用 `segs`。
        var ringSegs: [GaugeSegment]? = nil
        /// 弧上还搬得走的总和
        var reclaimable: Int64 = 0
        /// 量到了、但这一屏动不了的（前三名剩下的 + 其他已统计剩下的）
        var measuredIdle: Int64 = 0
        /// 这一轮压根没量到的
        var untouched: Int64 = 0
        /// 已经搬进废纸篓、还没让位的
        var inBin: Int64 = 0
        var free: Int64 = 0
        var purgeable: Int64 = 0
        var total: Int64 = 0
        /// 圆心那个「可用」：跟下面那行对账、跟系统设置 ▸ 储存空间同一个口径。
        var available: Int64 { free + purgeable }
        /// 「已用」= 整块盘 − 上面那个可用。两处必须共用一次减法，否则同一屏两本账。
        var used: Int64 { total - available }
        /// 走完这一步之后系统会写多少可用：还能搬走的 + 已经在废纸篓还没让位的。
        var afterClear: Int64 { available + reclaimable + inBin }

        // ── 屏幕上那几串字：格内加减法一律拿**印出来的字**算，不拿字节 ──────────
        // 实拍那一屏印的是「可用 14.2」「可回收 18.6」「全部清空后可用 32.7」：
        // 真值各自偏低（14.1x ＋ 18.5x = 32.7x），字节加法一步没错，错在屏幕上
        // 那三串字加不起来。差 0.1 要记在「每项都各自四舍五入过」上，不能记成两个口径。
        var totalShown: String { human(total) }
        var availableShown: String { human(available) }
        var usedShown: String { diffShown(totalShown, availableShown) ?? human(used) }
        /// 导语里「没量到的另算」那个数：拿**那一行印出来的字**，不拿字节现算。
        /// 这一列是按最大余数分到「各行相加 = 整块盘」上的，哪一行都可能比裸 `human()`
        /// 多或少 0.1；导语自己 `human()` 一次，同一屏就会长出两个数。
        /// 2026-09-28 实拍命中：搬走一项后「本次移入废纸篓」进了列、拿走那份余数，
        /// 导语印 32.6 而「没量到」那行印 32.7。
        var untouchedShown: String {
            segs.first { $0.drill == .gapRows }?.sizeShown ?? human(untouched)
        }
        /// 导语里「已量到的其余先不动」那个数：从**印出来的**整盘往下减，减到只剩这一笔。
        /// 导语那三个数自己就得加得起来（动得了 + 其余 + 没量到 + 已在废纸篓 + 可用 = 整盘），
        /// 各拿字节 `human()` 一次就会差 0.1 —— 2026-09-28 实拍：右边那列印的是
        /// 13.4 + 6.3 + 5.1 + 24.3 − 10.4 = 38.7，而导语印 38.6。
        var measuredIdleShown: String {
            var left: String? = usedShown
            for p in [untouchedShown, human(inBin), human(reclaimable)] {
                left = left.flatMap { diffShown($0, p) }
            }
            return left ?? human(measuredIdle)
        }
        var afterClearShown: String {
            sumShown([availableShown, human(reclaimable), human(inBin)]) ?? human(afterClear)
        }
        /// 动得了的那几段
        var hot: [GaugeSegment] { segs.filter { $0.reclaim > 0 } }
        /// 导语里那个「几处」：按**点名下过单的位置**数，不按弧数。
        /// `~/Library` 名下十几处缓存算十几处——一句「3 处 22 GB 动得了」配一张要点
        /// 十几下的清单，那个 3 就是假数。动得了的弧必然带着点名的处（数就是从它们来的），
        /// 所以这里只数 `targets`，不再给「整段算一处」留口子。
        var places: Int {
            hot.reduce(0) { $0 + $1.targets.count }
        }
    }

    /// 扫描中的那本账：**账目列只报量到的，环上那一条弧都不画**。
    ///
    /// 跟 `ringAccount` 分家的理由不是省事，是那本账里绝大多数属性此刻还不存在：
    /// 「没量到 / 系统可清除 / 空闲」是量完之后的结论，扫描中把它们写成有值的行
    /// 等于先报一个还没算出来的答案。所以账目列只有前三名和「其他已统计」是真数，
    /// 其余几行留着「排队中」占位；整圈由一段透明填充补满。
    ///
    /// 环上那一条都不画是样稿说了算的：`scan()` 一进门就把每条弧 `opacity=0`，
    /// 量完才由 `reveal()` 按 105 ms 一档逐段贴回来。扫描那一屏环带只回答一个问题
    /// ——「这一圈还没量完」——答它的是暗轨、刻度、那道读数头和盘心下面那截进度线，
    /// 不是字节。
    ///
    /// 这里曾把量完的前三名画成亮弧（值是真的，先看见先安心）。2026-10-23 真机实拍
    /// 把它否了：那一屏扫到 42% 时环上是 40.5 / 38.9 GB 两条暗灰弧 + 「其他已统计」
    /// 81.0 GB 一整块灯芯蓝（还带着 40.5、38.9 两枚弧上数），另外半圈是死黑轨道。
    /// 带中圈逐道量下来最亮 L 161、最暗 L 18——一圈里亮差 9 倍，他看到的就是「颜色严重不均」。
    /// 量完之前环上没有结论，也就不该有结论的颜色。
    ///
    /// 账目列固定七行（前三 + 其他 + 没量到 + 系统可清除 + 空闲），跟量完那一屏
    /// 是同一本账的名字；屏幕上是**这一行**从「排队中」换成「已量完」，不是一个新列表。
    private func scanningAccount(_ u: VolumeUsage) -> RingAccount {
        let dark = darkSkin
        // 量到了、还不许说能收：跟正常态那档「动不了」同一个灰（配方在「环上的墨」），
        // 不借灯色许愿。
        let measured = SweepRing.blockedInk(theme: theme, dark: dark)
        let ghost = theme.palette.inkTertiary
        let lamp = SweepRing.lamp(theme.palette.tint)
        let top = Array(model.hotspots.prefix(3))
        let topSum = top.reduce(Int64(0)) { $0 + $1.size }
        let rest = max(0, model.covered - topSum)
        var out: [GaugeSegment] = []
        for h in top {
            let can = model.reclaimable(of: h.path)
            out.append(GaugeSegment(
                label: h.name, value: h.size,
                color: measured, tone: .neutral,
                sub: can > 0 ? LF("已量完 · 可回收 %1$@", human(can))
                             : L("已量完 · 不整体搬走"),
                path: h.path))
        }
        // 还没轮到前三名的那几行不能从列表里消失：用队列里的名字占住同一个槽，
        // 每量完一处就换成那一处。空槽和「排队中」一起消失，读者看到的是同一行在变。
        var taken = Set(top.map(\.path))
        var slots = 3 - top.count
        for t in model.scanTargets where slots > 0 {
            guard !taken.contains(t.path), model.measuredTargets[t.path] == nil else { continue }
            taken.insert(t.path)
            out.append(GaugeSegment(label: t.name, value: 0, color: ghost,
                                    tone: .neutral, sub: L("排队中")))
            slots -= 1
        }
        if rest > 0 {
            // 弧在长，数不写：这枚数每一秒都在跳，印在环上会被当成结论。
            out.append(GaugeSegment(label: L("其他已统计"), value: rest,
                                    color: lamp, tone: .hot,
                                    sub: L("正在量… · 这一条弧还没闭合"),
                                    drill: .restGroup, hidesArcValue: true))
        } else {
            out.append(GaugeSegment(label: L("其他已统计"), value: 0, color: ghost,
                                    tone: .neutral, sub: L("排队中")))
        }
        out.append(GaugeSegment(label: L("没量到"), value: 0, color: ghost,
                                tone: .neutral, sub: L("排队中 · 密封系统卷")))
        out.append(GaugeSegment(label: L("系统可清除"), value: 0, color: ghost,
                                tone: .neutral, sub: L("排队中")))
        out.append(GaugeSegment(label: L("空闲"), value: 0, color: ghost,
                                tone: .neutral, sub: L("排队中")))
        for i in out.indices { out[i].sizeText = out[i].value > 0 ? human(out[i].value) : "—" }
        // 整圈一段透明：环上此刻只该有暗轨。`label` 留空，弧上那枚数与命中映射本就
        // 按「有没有名字」筛（`Components.swift` 的 `arcLabel` 门槛），所以不会有人
        // 在半圈空气上读到一个 500 GB。
        let ringSegs: [GaugeSegment] = [GaugeSegment(label: "", value: u.total,
                                                     color: .clear, tone: .neutral)]
        model.recordHoverLabels(out.filter { $0.value > 0 }.map(\.label))
        return RingAccount(segs: out, ringSegs: ringSegs, reclaimable: 0,
                           measuredIdle: model.covered, untouched: 0, inBin: 0,
                           free: u.free, purgeable: u.purgeable, total: u.total)
    }

    /// 环形分段 = 前 3 大热点 + 其余量到的 + 这一轮没量到的 + 可清除 + 空闲，加起来正好等于整块盘。
    ///
    /// 上色只有一条规矩：**彩色只给动得了的弧**。前三名一人一色的六色数据系列铺满一圈，
    /// 读出来是「这盘被六样东西吃掉了」，而这一屏要回答的只有一件事——哪儿能腾出手来。
    /// 所以动得了的那几段共用主色（灯芯渐变），量到动不了的、没量到的都是灰两档（深皮是蓝灰），
    /// 系统可清除用洗淡的主色（有色、但按不动），废纸篓是主色加虚线。
    ///
    /// 「没量到的」必须单列。以前把「排在列表 5-20 名」和「压根没扫」揉成一块灰色
    /// 「其他已用」，实测一台机器上那块占 70%，于是用户自然要问「怎么才列出这么点」——
    /// 因为图上根本分不清是没扫到，还是扫了觉得不值一提。
    ///
    /// 「其他已统计」这块弧要能在下面的列表里逐段对上：它 = 第 4 名到列表封顶 + 展开的
    /// 其余若干处 + 没到下限的那些小目录，列表尾巴当场把这三段报出来。以前这块弧按
    /// 「用户区」的账画、列表按「整盘」的账列，两个口径同屏，谁也对不上谁——那是这一屏
    /// 最快塌掉的地方，所以范围开关整个撤掉了。
    ///
    /// 除了「空闲」和「系统可清除」，每一块弧都带着自己那一段的明细：点下去就地摊开，
    /// 要么是这个目录的下一级，要么是「其他已统计」名下的那些位置，要么是「没量到」的卷账。
    /// 环形上凭空出现一块说不清是谁的弧，就是这一屏最不该留下的缺口。
    private func ringAccount(_ u: VolumeUsage) -> RingAccount {
        let dark = darkSkin
        let top = Array(model.hotspots.prefix(3))
        // 交给 Core 的 topSum 必须是**这一轮量到的原始数**：`ringSplit` 用
        // 「covered − topSum」算出其余量到的，这里换成净数就等于把搬走的那几 G
        // 又还给「其他已统计」，同一截字节被算两遍，整圈当场对不上已用。
        let topSum = top.reduce(Int64(0)) { $0 + $1.size }
        let netTopSum = top.reduce(Int64(0)) { $0 + model.arcSize(of: $1.path) }
        let ded = model.ringDeduction
        // 三档不上色的底：动得了的段用主色，其余只能靠灰的深浅分层。每档为什么是那个
        // 透明度、实拍量到哪几个数，全记在 `Components.swift` 的「环上的墨」那一段上
        // （首次运行那一屏的示例环读的是同一份配方，所以它不再长在这里）。
        let blocked = SweepRing.blockedInk(theme: theme, dark: dark)   // 量到了，动不了
        let unmeasured = SweepRing.unmeasuredInk(theme: theme, dark: dark)  // 压根没量到
        let freeArc = SweepRing.freeInk(theme: theme, dark: dark)      // ≈ 轨道，闭合整圈
        var out: [GaugeSegment] = []
        // 分段算术由 Core 的纯函数把关（自检钉的是「四块加起来等于已用」）；
        // 不成立就两块都不画，宁可留一块大的「没量到」也不画一张对不上的图。
        let split = ringSplit(covered: model.covered, used: u.used, topSum: topSum,
                              movedOutTop: ded.top, movedOutRest: ded.rest)
        // 先把每条弧动得了多少全算出来，再一次性定「可回收」那一列印成什么样：
        // 各行各自四舍五入会各自往上飘，屏幕上就成了「12.0 + 6.3 + 4.2 = 22.5」而圆心写
        // 22.4。这一列必须加得起来，因为它和圆心那个数是同一笔账。
        let topCan = top.map { model.reclaimable(of: $0.path) }
        let restCan = split.map { model.restReclaimable($0.restMeasured) } ?? 0
        let canParts = topCan + [restCan]
        let canTexts = addableHuman(canParts, total: canParts.reduce(Int64(0), +))
        let restText = canTexts[topCan.count]
        var reclaim: Int64 = 0
        for (i, h) in top.enumerated() {
            // 弧上画的是「还在原处的」，不是「这一轮量到的」：搬走 5G 之后弧就该小 5G，
            // 而下面列表里那一行报的是同一个数。两个口径同屏是这一屏最快塌掉的地方。
            let size = model.arcSize(of: h.path)
            let can = topCan[i]
            reclaim += can
            out.append(GaugeSegment(
                label: h.name, value: size,
                color: can > 0 ? SweepRing.lamp(theme.palette.tint) : blocked,
                tone: can > 0 ? .hot : .neutral,
                sub: hotArcNote(can: can, text: canTexts[i],
                                movedOut: model.movedOut(of: h.path)),
                path: h.path, reclaim: can, reclaimText: canTexts[i],
                targets: model.reclaimTargets(of: h.path),
                drill: .children(h.path)))
        }
        let topReclaim = reclaim
        var restReclaim: Int64 = 0
        var restMeasured: Int64 = 0
        var untouched: Int64 = 0
        var trash: Int64 = 0
        if let s = split {
            restMeasured = s.restMeasured
            untouched = s.untouched
            trash = s.trash
            if s.restMeasured > 0 {
                // 这条弧以前恒记 0，于是它明明占着一整段角度却总是灰的。可缓存并不因为
                // 「没挤进前三名」就变成不能清的东西：真机上这条弧名下能清出好几 G，
                // 弧上却写着「动不了」，而缓存页下一秒就把它们列成可勾——招牌画面报的数
                // 比自家另一页小，那就是错。
                let can = restCan
                restReclaim = can
                reclaim += can
                out.append(GaugeSegment(
                    label: L("其他已统计"), value: s.restMeasured,
                    color: can > 0 ? SweepRing.lamp(theme.palette.tint) : blocked,
                    tone: can > 0 ? .hot : .neutral,
                    sub: can > 0 ? LF("%1$@ 可回收 · 这一条弧是第 4 名往后的那些位置",
                                      restText)
                                 : L("第 4 名往后，点开这一行就是它们的名字"),
                    reclaim: can, reclaimText: restText,
                    targets: model.restReclaimTargets(), drill: .restGroup))
            }
            if s.trash > 0 {
                // 虚线：这些字节还占着盘，只是换了地方。画成实线就是在说「已经腾出来了」，
                // 而真正让位要等用户在废纸篓页交给访达。
                out.append(GaugeSegment(label: L("本次移入废纸篓"), value: s.trash,
                                        color: SweepRing.movedInk(theme: theme, dark: dark),
                                        tone: .moved,
                                        sub: L("还占着盘 · 去废纸篓页才让位"),
                                        jumpTo: Self.trashAnchor, dashed: true,
                                        hint: L("去废纸篓页：这些字节还占着盘，在那里交给访达清空才真让位")))
            }
            if s.untouched > 0 {
                // 正在扫的时候这块不是结论，是进度：叫成「没量到的地方」会让人以为
                // 这一坨永远清不动，而它下一秒就会缩。
                out.append(GaugeSegment(label: model.scanning ? L("还没量到") : L("没量到"),
                                        value: s.untouched, color: unmeasured, tone: .neutral,
                                        sub: L("密封系统卷等，任何清理工具都动不了"),
                                        drill: .gapRows))
            }
        }
        // 系统记作可用、此刻却还占着盘的那一块（快照、缓存）。必须单列：
        // 「可用」跟系统设置对齐之后，环形里就得有一块弧代表它，
        // 否则前 3 ＋ 其他 ＋ 整盘 ＋ 量不到 ＋ 可用加起来不等于整块盘，图又成了装饰。
        if u.purgeable > 0 {
            out.append(GaugeSegment(label: L("系统可清除"), value: u.purgeable,
                                    color: SweepRing.lamp(theme.palette.tint)
                                        .opacity(dark ? 0.26 : 0.20),
                                    tone: .washed,
                                    sub: L("系统随时自己腾，不用这个工具动手")))
        }
        // 这条弧叫「空闲」不叫「可用」：上面那个「可用」是系统口径（含可清除），
        // 两条弧一个代表空闲、一个代表可清除，加起来才等于那个可用。
        out.append(GaugeSegment(label: L("空闲"), value: u.free,
                                color: freeArc, tone: .neutral,
                                sub: L("已经空着的地方")))
        // 这一列右边明写着「各段之和 494.4 GB」——那是一句算术承诺：各行印出来的数
        // 必须真加得出它。逐行 `human()` 做不到，2026-09-25 真机实拍那一列加成 494.5。
        // 交给 Core 把整列统一到总数的单位、按最大余数分掉那几格；传 `u.total` 而不是
        // 各行之和，是在这里顺手验一次那条恒等式——不成立就整列退回逐行 `human()`，
        // 宁可各说各的，也不许凑出一列加得起来的假账。
        let sizeTexts = addableHumanColumn(out.map { $0.value }, total: u.total)
        for i in out.indices { out[i].sizeText = sizeTexts[i] }
        // 「这一笔」的两个数由 `pickedTotals` 现读池子：清单里取消过的项关掉再回来
        // 还得算数，这本账不替它缓存一份旧值。
        model.recordHoverLabels(out.filter { $0.value > 0 }.map(\.label))
        return RingAccount(segs: out, reclaimable: reclaim,
                           measuredIdle: max(0, netTopSum - topReclaim)
                                        + max(0, restMeasured - restReclaim),
                           untouched: untouched, inBin: trash,
                           free: u.free, purgeable: u.purgeable, total: u.total)
    }

    /// 「按代价」那一本账：同一块盘，按**清掉它要付什么**切成四段。
    ///
    /// 不照样稿给原来那批弧换一套色——那本账四行混着两个分母（零代价按整段体积、
    /// 需重下按可收量），四行加起来 62.4 GB 而盘是 96 GB。这里四段是**字节的划分**：
    /// 每一段字节归给覆盖它的最轻那一档，四段相加正好是整块盘（`CostLedger` 的恒等式，
    /// SelfTest 钉着）。所以环上的角度、行尾的数、行尾「各段之和」是同一次除法。
    ///
    /// 前两类里池子真有的那些处才带 `reclaim`：它们进清理清单，改的就是主按钮那一笔，
    /// 和缓存页是同一批路径。不可逆与不碰 `reclaim = 0`——它们不进一键，
    /// 给一条能点的弧就是把「本工具不碰」说成了一个选项。
    ///
    /// 桶里的字节：`free` 是池里 `safe` 那些处，`poolTargets` 与 `CostLedger` 同源，
    /// 所以「零代价」那一行的数就是那几处的合计。`redo` 会少一截可能：某个 `redo`
    /// 父项底下压着 `safe` 子项时，池子只摆子项（按整条搬更危险），父项自己不摆——
    /// 那一截仍归「需重下」，但不在这一笔里，行内小字会说清。
    private func costAccount(_ u: VolumeUsage) -> RingAccount {
        let ledger = model.costLedger ?? CostLedger(sums: CostSums(), total: u.total)
        let freeTargets = model.poolTargets(.safe)
        let redoTargets = model.poolTargets(.redo)
        let freePickable = freeTargets.reduce(Int64(0)) { $0 + $1.size }
        let redoPickable = redoTargets.reduce(Int64(0)) { $0 + $1.size }
        let freeBytes = ledger.bytes(.free)
        let redoBytes = ledger.bytes(.redo)
        let irreversible = ledger.bytes(.irreversible)
        let off = ledger.bytes(.off)
        // 空闲从「不碰」里拆出来单独成段（2026-10-27 他圈的 460.2 那一格）：
        // 空闲不是文件，谈不上删，跟「本工具不动这些文件」是两回事；混在一起时
        // 这一档动辄占九成的盘，读起来就像识别坏了。拆开后「不碰」只算真正不动的
        // 已用字节（系统区、没量到、知识库不认得的），空闲自己一行、弧上更淡一档。
        // 账本层不动：`off` 的恒等式照旧，这里只是把补集里空闲那一截换一行摆。
        let idle = min(u.free, off)
        let untouched = off - idle
        var out: [GaugeSegment] = [
            GaugeSegment(label: L("零代价"), value: freeBytes,
                         color: costColor(.free), tone: .cost,
                         sub: freePickable >= freeBytes
                              ? L("缓存与构建产物 · 都能一键收走，删了会自己长回来")
                              : LF("缓存与构建产物 · 其中 %1$@ 这次收得走，删了会自己长回来",
                                   human(freePickable)),
                         reclaim: freePickable, targets: freeTargets,
                         hint: L("零代价：缓存与构建产物，删了会自己长回来。勾上就进这一笔。"),
                         costClass: true),
            GaugeSegment(label: L("需重下"), value: redoBytes,
                         color: costColor(.redo), tone: .cost,
                         sub: costRedoNote(redoPickable, of: redoBytes),
                         reclaim: redoPickable, targets: redoTargets,
                         hint: L("需重下：删了要重新下载或重建。勾上就进这一笔；缓存页默认不勾它。"),
                         costClass: true),
            GaugeSegment(label: L("不可逆"), value: irreversible,
                         color: costColor(.irreversible), tone: .cost,
                         sub: L("删了就没了 · 一键清从不碰它，要清得在缓存页逐条确认"),
                         hint: L("不可逆：删了就没了。一键清从不碰它。"),
                         costClass: true),
            GaugeSegment(label: L("不碰"), value: untouched,
                         color: costColor(.off), tone: .cost,
                         sub: L("系统区、没量到与知识库不认得的已用字节 · 本工具不动"),
                         hint: L("不碰：系统区、没量到，以及知识库不认得的字节。空闲不算在内。"),
                         costClass: true),
            GaugeSegment(label: L("空闲"), value: idle,
                         color: costColor(.off).opacity(0.4), tone: .cost,
                         sub: L("已空着的地方 · 不是文件，谈不上删"),
                         hint: L("空闲：已空着的地方，不是文件。"),
                         costClass: true),
        ]
        let sizeTexts = addableHumanColumn(out.map { $0.value }, total: u.total)
        for i in out.indices { out[i].sizeText = sizeTexts[i] }
        model.recordHoverLabels(out.filter { $0.value > 0 }.map(\.label))
        return RingAccount(segs: out, reclaimable: freePickable + redoPickable,
                           measuredIdle: 0, untouched: 0,
                           inBin: model.movedLedger.trashArc,
                           free: u.free, purgeable: u.purgeable, total: u.total)
    }

    /// 「需重下」那一行的小字：只有池里漏掉一截父项时才报「其中多少」。
    /// 那一截**不在这一笔里**，但不能写成「回缓存页逐条看」——池子本来就没有它，
    /// 那句会把一个不存在的入口指给用户。
    private func costRedoNote(_ pickable: Int64, of bytes: Int64) -> String {
        if pickable <= 0 { return L("删了要重新下载或重建 · 这次不收它") }
        if pickable >= bytes { return L("删了要重新下载或重建 · 都能一键收走") }
        return LF("删了要重新下载 · 其中 %1$@ 这次收得走，其余不在这一笔里", human(pickable))
    }

    /// 四类的颜色。用皮肤自己的语义色，六套皮各自成立：绿=删了会自己长回来，
    /// 琥珀=要重下，红=不可逆，灰=不碰。不另配一份绝对色——那会让换肤时
    /// 这一圈与全站的语义色脱节。
    private func costColor(_ tier: CostTier) -> Color {
        switch tier {
        case .free: return theme.palette.safeFG
        case .redo: return theme.palette.warnFG
        case .irreversible: return theme.palette.danger
        case .off: return theme.palette.inkTertiary
        }
    }

    /// 行尾「各段之和」印什么。代价四类相加是 `CostLedger.accounted`：平时恒等于整盘，
    /// 用量快照落后时才会多出来（多出多少由紧挨着的那行警告说明）。
    private func segmentsSumText(_ acct: RingAccount) -> String {
        if costReading, let led = model.costLedger { return human(led.accounted) }
        return human(acct.total)
    }

    /// 前几名各自那一行小字。三种情况三句话说，别拿一句套三种：
    /// 一分都没动的说「还剩多少能搬」，搬走过一部分的要额外报已经少了一截，
    /// 而整个目录搬不走的**不能写成「0 B 可回收」**——那是把「这里头有能清的东西、
    /// 只是不按整个目录清」说成了「这里没东西」，而下面那列恰恰列着它的缓存。
    ///
    /// `text` 是外面按「这一列加起来要等于圆心总数」分配好的那个字符串，不在这里现算
    /// `human(can)`——各行独立四舍五入会飘出 0.1，那一列就和圆心对不上了。
    private func hotArcNote(can: Int64, text: String, movedOut: Int64) -> String {
        if can <= 0 { return L("不整体搬走 · 点开这一行看明细") }
        if movedOut > 0 {
            return LF("%1$@ 可回收 · 已搬走 %2$@", text, human(movedOut))
        }
        return LF("%1$@ 可回收", text)
    }

}

// MARK: - 摊开后的下一级行

/// 明细往右缩进多少：跟上方账目行的**名字**对齐在同一条竖线上（行内边距 8 +
/// 行首那一格 16 + 间距 12 + 展开槽 12 + 间距 12）。明细行、条子、尾巴那句对账共用这
/// 一个数——差一截的话那句对账就悬在列表外面，读不出它说的是哪一组。
///
/// 行首那一格是 16 pt 的槽（色块居中），这一档跟着从 52 抬到 60：
/// 两个数必须由同一份行首尺寸说话，否则明细比名字低半截。
private let drillIndent: CGFloat = 60

/// 摊开后的一行明细。行解剖跟账目行同一副：图形在名字左边、名字在上、条子在下、
/// 数在右肩，只有真动得了的那一档给灯色。
///
/// 那个数由调用方整列过一次 `addableHumanColumn` 再传进来，不在这里 `human()`：
/// 这一列底下明写着「合计 x GB」那句对账，各行独立四舍五入会各自往上飘，
/// 那句就永远加不回来——同一屏两本账是这一页塌过的每一次的形状。
private struct DrillRow: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: AppStore
    /// 行首那一格：这一行的下一级就是一个真实目录，走同一套三档判图（归属 App →
    /// 品牌标 → 系统通用图）。原先这一列只有文字，24 格里 24 个名字，认不出谁是谁的。
    var icon: RowIcon
    var name: String
    var path: String
    /// 原始字节数。右边那句判词要不要说话由它决定（见 `verdictCell`）。
    var size: Int64
    var sizeText: String
    /// 这一格名下真能搬走的。判据跟环形、账目列同一个口径（知识库白名单），
    /// 不是「整处搬不搬得走」——后者会让明细说「只能看」而同一列写着「3.1 GB 可回收」。
    var reclaim: Int64
    /// 这一**列**的尺：父行那个数（右侧那一列就是按它统一分档的）。
    ///
    /// 不传的话两把尺并排印：2026-09-26 实拍「其他已统计」摊开那一屏，一行印的是
    /// 「943.7 MB 可回收　0.9 GB」——读起来像可回收的比整处还多。取整列那把尺之后
    /// 小到不足一个刻度的写成「< 0.1 GB」，跟左边那一列同一套规矩。
    var ruler: Int64
    var fraction: Double

    @State private var hovering = false

    /// 右边那句话。三件事按硬事实排序：本工具挡着的说「本工具不碰」；知识库点名要搬的报数；
    /// **知识库不认识的，够大才说**。
    ///
    /// 最后那条的阈值不是抠门：这一列本来就属于「一眼扫过去」的账目，
    /// 一屏九十行里八十几行挂同一句「不认得」，那句话就不再是信息了。
    /// 而这一页也没有任何按行删除的动作——真正需要「不认识 ≠ 能删」这句话的场景
    /// 是勾选那一栏，那在文件夹详情页，那儿由页尾那句一次说清。
    private var verdictCell: String {
        if !isDeletable(URL(fileURLWithPath: path)) { return L("本工具不碰") }
        if reclaim > 0 { return LF("%1$@ 可回收", human(reclaim, inRulerOf: ruler)) }
        guard size >= GB else { return "" }
        return VerdictIndex.shared.verdict(for: path).known ? "" : L("本工具不认得")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            RowIconView(icon: icon)
                .frame(width: rowIconSide, height: rowIconSide)
            VStack(alignment: .leading, spacing: 6) {
                // 名字就是入口：点它进「文件夹详情」，一层层往下看。
                // 这一页自己只摊得开一层（就地手风琴），再往下走是另一页的事——
                // 分工：总览负责「看账」，下钻页负责「找文件」。
                //
                // 名字后面常驻一颗小箭头。这一行的版式跟上面账目行几乎一样，少了它，
                // 线索就只剩「悬停时名字变色＋下划线」——而人不会先把鼠标在每个名字上扫一遍
                // 再决定点哪儿。箭头用的是下钻页行内那颗同一个字符，一处的意思一处用。
                Button {
                    store.drill(into: path)
                } label: {
                    HStack(spacing: 4) {
                        Text(name)
                            .font(theme.bodyFont(.caption))
                            .foregroundStyle(hovering ? SweepRing.lamp(theme.palette.tint)
                                                      : theme.palette.ink)
                            .underline(hovering, color: SweepRing.lamp(theme.palette.tint))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(hovering ? SweepRing.lamp(theme.palette.tint)
                                                      : theme.palette.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(LF("进入 %@ 往下看", displayPath(URL(fileURLWithPath: path))))
                // 条子定宽、不铺满：贴到行尾的长条会被读成分隔线，
                // 而这一列上面那六行的条子就是这个宽度，两档尺没意义。
                //
                // 但**下限必须软**，跟上面那六行同一个 `barFloor`：这一行的尾巴上同时住着
                // 徽章、那句「可回收」、体积和一颗按钮，而这一列在最小窗（1000）下只有
                // 五百多点——条子按 232 不让时，被挤出窗口边的就是尾巴上那几件
                // （2026-10-01 实拍：`Logs` 那行「访达显示」四个字竖成一列、`Caches` 那行
                // 按钮被压成一条）。条子短了仍读得出长短，按钮没了就真没了。
                ProportionBar(fraction: fraction,
                              color: reclaim > 0 ? SweepRing.lamp(theme.palette.tint)
                                                 : theme.palette.inkTertiary,
                              track: theme.palette.surfaceAlt,
                              height: 3, trackWidth: 232,
                              minTrackWidth: RingLedgerRow.barFloor)
            }
            Spacer(minLength: 10)
            // 判词徽章跟右边那两样是**三条轴**：这一枚说「知识库认不认得它、删了要付什么代价」，
            // 下一句说「删不删得动」，最后那个数说「有多大」。挤在一起就只能留一条，
            // 而「删得动、知识库却不认识」恰恰是最需要被说出来的那一类。
            //
            // 徽章从 `verdictBadge` 来，跟缓存页、文件夹详情共用一份：同一句话在这三处
            // 必须长得一样，各自 `switch` 一遍，迟早有一处漏改。
            if let b = verdictBadge(VerdictIndex.shared.verdict(for: path).tier) {
                ThemeBadge(text: b.text, tone: b.tone)
            }
            // 动不了的必须当场说「本工具不碰」。一列全是数、没有这一句，
            // 人就只剩「按下去大概能删」这一种预期，而那正是错的那种。
            //
            // 但这四个字只管**本工具够不着**这件事，不能拿它顶替「知识库不认得」：
            // `~/Library/Group Containers` 里躺着几十 G 的虚拟机磁盘，删得动，
            // 只是这本知识库里没有它。两件事挤成同一句话，读的人会把
            // 「我不认识」当成「你不能删」——而这两个结论要求的下一步动作正好相反。
            Text(verdictCell)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(reclaim > 0 ? SweepRing.lamp(theme.palette.tint)
                                             : theme.palette.inkTertiary)
                .fixedSize()
            SizeNumber(shown: sizeText, size: 15,
                       color: reclaim > 0 ? theme.palette.ink : theme.palette.inkSecondary)
            ThemeButton(kind: .ghost, title: L("访达显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .help(LF("在访达里打开 %@", path))
            // 这一行**不再挂**「深挖」。
            //
            // 从前这一行上并排住着两个「往下走」的动作：点名字进「文件夹详情」（看这一层），
            // 点「深挖」去「大文件」页（扫这一棵子树里最大的那些文件）。能力不同，界面上却
            // 没有一个字说得出差别——用户看到的只是同一行上两颗都能往里走的按钮。
            //
            // 现在这条路只留一步：点名字进去看这一层。「在这一棵里找大文件」挪到文件夹详情页
            // 页头（那颗按钮管的就是同一件事），于是「一层层看」和「找大文件」成了同一条路上的
            // 两步，而不是同一行上的两个入口。
            //
            // 账目行那颗「深挖」留着不动：那一行点下去是摊明细，它进不去任何地方，
            // 「深挖」是它唯一往下的出口——一颗按钮该不该在，看的是这一行还有没有别的路。
        }
        .padding(.vertical, 3)
        // 图形落在名字左边那一格，缩进要让出图形位（26 + 间距 10）：
        // 名字仍跟上面账目行的名字在同一条竖线上，尾巴那句对账也才对得上这一列。
        .padding(.leading, drillIndent - rowIconSide - 10)
        // 整行都能点。名字只占行首那一小截，右边一大片是空的，落在空处的那一下
        // 不该没反应——「点了没动」和「这儿不能点」在这屏上长得一模一样。
        // 行内那颗「访达显示」是 Button，自己会先接住落在它身上的点击。
        .contentShape(Rectangle())
        .onTapGesture { store.drill(into: path) }
        .onHover { hovering = $0 }
    }
}

// MARK: - 候选列

/// 候选列里的一组：同一个账本行（弧）名下的可回收处。
private struct CleanGroup {
    var key: String
    var label: String
    var items: [CleanCandidate]
    var bytes: Int64
}

/// 候选页的一行。勾选框留在最左、始终全亮；名字、路径、数和「明细」一起退后，
/// 这样「取消勾选」这件事一眼能看见，而没选中的那几行也不会从列里消失。
private struct CleanPickRow: View {
    @Environment(\.theme) private var theme
    var candidate: CleanCandidate
    var detailOpen: Bool
    var onToggle: (Bool) -> Void
    var onDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { candidate.selected }, set: onToggle))
                    .toggleStyle(ThemeCheckStyle(side: 16))
                    .labelsHidden()

                HStack(spacing: 10) {
                    RowIconView(icon: .path(candidate.url), side: 22,
                                appID: candidate.appID, brand: candidate.brand)
                        .frame(width: rowIconSide, height: rowIconSide)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(candidate.name)
                                .font(theme.bodyFont(.callout))
                                .foregroundStyle(theme.palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let b = verdictBadge(candidate.tier) {
                                ThemeBadge(text: b.text, tone: b.tone)
                            }
                        }
                        Text(displayPath(candidate.url))
                            .font(theme.bodyFont(.caption2))
                            .foregroundStyle(theme.palette.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 8)

                    Text(human(candidate.size))
                        .font(theme.numeric(size: 12.5))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.ink)
                        .fixedSize()

                    Button(action: onDetail) {
                        HStack(spacing: 3) {
                            Text(L("明细"))
                                .font(theme.bodyFont(.caption))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 8, weight: .semibold))
                                .rotationEffect(.degrees(detailOpen ? 90 : 0))
                        }
                        .foregroundStyle(theme.palette.inkTertiary)
                        .frame(width: 46, alignment: .trailing)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .opacity(candidate.selected ? 1 : 0.45)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            if detailOpen {
                VStack(alignment: .leading, spacing: 5) {
                    if let hint = verdictHint(for: candidate.path) {
                        Text(hint)
                            .font(theme.bodyFont(.caption2))
                            .foregroundStyle(theme.palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PathLine(path: candidate.path)
                }
                .padding(.leading, rowLeadInset)
                .padding(.trailing, 11)
                .padding(.bottom, 9)
            }
        }
        .background(theme.controlShape().fill(
            theme.palette.surfaceAlt.opacity(candidate.selected ? 1 : 0.55)))
        .overlay(theme.controlShape().stroke(theme.palette.separator, lineWidth: 1))
    }
}
