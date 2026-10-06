import SwiftUI
import AppKit
import DiskCleanerCore

// ── 文件夹详情（逐层下钻）──────────────────────────────────────────────────
//
// 「大文件」页只给 TOP 榜，而榜上大半是系统区的、删不了；总览那本账能摊开一层就到头。
// 于是「桌面那个文件夹底下到底装着什么」一直无处可去。这一页补的就是那个洞：
// 从任意一个文件夹进去，每层把**子目录和文件混排**列出来，点目录继续往下走。
//
// 两条边界，刻意不越：
//   1. 可删性一律走 `isDeletable`（同大文件页），不另立规矩。本工具不碰的位置照样列出来——
//      但**能钻进去看**，这正是这一页存在的理由。
//   2. 每进一层才量一层（`dirLevel`），不预先递归整棵树：~/Library 一级四十多个目录，
//      预先递归就是替用户决定「哪支值得看」。
//
// 这一层那一列的数由 `addableHumanColumn` 整列过一次，所以「列出来的几行 ＋ 尾巴那句」
// 正好等于这一层的合计——同一屏两本账是这个 App 塌过的每一次的形状。

@MainActor
final class FolderDrillModel: ObservableObject {
    /// 当前这一层的路径。
    @Published private(set) var path: String = ""
    /// 面包屑里属于这条路径的那几格，一路都能点。最后一条就是 `path`。
    ///
    /// **不含最左那格「空间总览」**：那一格固定由视图摆在最前面（规则见 `crumbChain`）。
    @Published private(set) var crumbs: [String] = []
    @Published private(set) var level: DirLevel? = nil
    @Published private(set) var busy = false
    /// 这一轮量的是谁。「正在量」那几秒里如果不说是哪儿，读起来跟「点坏了」一样。
    @Published private(set) var pendingPath: String = ""
    @Published var selected: Set<String> = []

    /// 现场读数。这一层慢在**逐个量子目录**（一级几十个，每个都是一棵子树），
    /// 所以要说的不只是「正在量 ~/Library」，还有「这四十多个目录走到第几个了」。
    private(set) var progress = ScanProgress()

    /// 文件最多列这么多行。**只掐文件**：`/Applications` 那种一级几百个，
    /// 全列出来没人逐行扫，多出来的并进尾巴那句。目录不受这条管——这一页里
    /// 少一个目录就是少一条往下走的路，而「往下走」正是它存在的理由。
    static let fileCap = 200

    private var cache: [String: DirLevel] = [:]
    private var task: Task<Void, Never>? = nil
    /// 只给截图链路用（`DISKWISE_DRILL_INTO=1`）：第一层量完自动钻一次，
    /// 好把「面包屑 ＋ 深一层」这一屏拍进图里。
    private var autoDescended = false
    /// 自动钻那一趟交给外面走。钻进一层也是一次跳转，得记进导航历史——
    /// 在模型里直接 `open` 的话，拍出来的那一屏按返回是回不去的，图就成了假证词。
    var onAutoDescend: ((String) -> Void)?

    var rows: [ChildEntry] { level?.entries ?? [] }
    var selectedEntries: [ChildEntry] { rows.filter { selected.contains($0.path) } }
    var selectedBytes: Int64 { selectedEntries.reduce(Int64(0)) { $0 + $1.size } }

    /// 还能不能往上退。**问的不是「还有没有父目录」**：`/Applications`、`/Library`
    /// 这类顶层上面就是空间总览，盘顶 `/` 不算一站（理由见 `drillParent`）。
    /// 也就是说只要进来过目录，这颗按钮就有地方可去，落点由 `drillParent` 现算。
    var canGoUp: Bool { !path.isEmpty }

    /// 进一个目录。同一处再点一次不重量（缓存直接回填）。
    ///
    /// 整页停在哪一层由 `store.folderDrillPath` 说了算，所以只有视图的 `start()`
    /// 该调它——行的点击、面包屑、「上一级」全都先落到那个字段上。
    func open(_ target: String) {
        guard !target.isEmpty else { return }
        if target == path, level != nil, !busy { return }
        path = target
        rebuildCrumbs()
        selected.removeAll()
        load(target)
    }

    /// 重扫一轮就把整本缓存作废：盘的账会走样，隔着一轮还挂着旧数字，
    /// 等于让人拿上一次的账做今天的决定。
    func invalidate() {
        task?.cancel()
        cache = [:]
        level = nil
        if !path.isEmpty { load(path) }
    }

    /// 删完重量这一层：行少了、合计也变了，就地剔行会让尾巴那句对不上。
    func reload() {
        cache[path] = nil
        if !path.isEmpty { load(path) }
    }

    private func load(_ target: String) {
        task?.cancel()
        if let hit = cache[target] {
            level = hit
            busy = false
            return
        }
        level = nil
        // 一趟一层，读数与清单也跟着重来：上一层的账挂在这一层上是另一本账。
        progress = ScanProgress()
        busy = true
        pendingPath = target
        let limit = Self.fileCap
        let prog = progress
        task = Task { [weak self] in
            let lv = await dirLevel(URL(fileURLWithPath: target), includeFiles: true,
                                    fileLimit: limit, progress: prog)
            guard !Task.isCancelled, let self, self.path == target else { return }
            self.cache[target] = lv
            self.level = lv
            self.busy = false
            if SnapshotMode.drillAutoDescend, !self.autoDescended,
               let first = lv.entries.first(where: { $0.isDir }) {
                self.autoDescended = true
                self.onAutoDescend?(first.path)
            }
        }
    }

    /// 这一条从头到尾都是 `crumbChain` 定的（它在 Core 里，也归自检管），这里只管
    /// 「还没进任何目录时不摆一条空的」。规则本身见那边的说明：每一格都是这一级自己，
    /// 家目录折叠成 `~`，最左那格「空间总览」不在这个数组里。
    private func rebuildCrumbs() {
        crumbs = path.isEmpty ? [] : crumbChain(for: path)
    }
}

struct FolderDrillView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: FolderDrillModel
    @State private var confirm = false
    @State private var err: String? = nil

    /// 删除飞行：起点（勾中的行）与落点（CleanBar 那颗按钮）都在这里面收着。
    @StateObject private var flight = TrashFlightController()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "folder", title: L("文件夹详情"),
                           subtitle: L("一层层往里走，看清每个文件夹和文件占了多少"),
                           variant: .display) {
                    // 「在这一棵里找大文件」从这里走：总览那一页不再并排摆两颗「往下走」的
                    // 按钮（点名字进这一层 ＋ 深挖去大文件页），路上只留一步——先进来看这一层，
                    // 想找大文件再按这一颗。两个动作分两层，各自的位置就都说得清了。
                    ThemeButton(kind: .compact, symbol: "scope",
                                title: L("深挖"),
                                isDisabled: model.path.isEmpty) {
                        store.deepDive(into: model.path)
                    }
                    .help(LF("只扫 %@ 这一棵，去大文件页列它名下最大的那些文件", model.path))
                    // 面包屑之外还得有一颗常驻的：深到十几层时，「往上退一层」是
                    // 这一页里唯一一个不用先看清自己在哪儿就能按的动作。
                    //
                    // 「上一级」和面包屑一样是一次**跳转**，得记进外面那本导航历史，
                    // 所以落点在 store 里算（`goUpFromDrill`），不在这里直接 `open`
                    // 绕开那一本账——绕开的话按返回会退到「进这一页之前」，而不是上一层文件夹。
                    ThemeButton(kind: .compact, symbol: "arrow.up",
                                title: L("上一级"),
                                isDisabled: !model.canGoUp) {
                        store.goUpFromDrill()
                    }
                    .help(goUpHint)
                }
                crumbsBar
                ControlStrip {
                    if model.busy {
                        LoadingRow(text: LF("正在量「%@」", shortLabel(model.pendingPath)),
                                   progress: model.progress)
                    } else if let lv = model.level {
                        Text(LF("这一层量到 %@", human(lv.total)))
                        ThemeBadge(text: LF("%1$@ · %2$@",
                                            cnt(lv.dirCount, "个文件夹"),
                                            cnt(lv.fileCount, "个文件")),
                                   tone: .neutral, symbol: "folder")
                    } else {
                        Text(L("从一个文件夹进来，就能一层层往下看"))
                    }
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            content

            Spacer(minLength: 0)   // 清理条钉在窗口下沿，见 `CleanBar`

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: model.level?.total ?? 0),
                     errorText: err, selection: selectAll,
                     flightTarget: true) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onChange(of: flight.anchors) { _ in fireSnapshotFlightIfAsked() }
        // 页刚进来时 `anchors` 只出现过一次（那时这一层还没量完），光靠它这一次钩子会早退；
        // 行数从 0 变成 N 是「量完了」的信号，补在这里，钩子才有第二次机会。
        .onChange(of: model.rows.count) { _ in fireSnapshotFlightIfAsked() }
        .onAppear {
            // 截图链路自动钻的那一趟也交给外面走：同一本历史才认得出它。
            model.onAutoDescend = { store.drill(into: $0) }
            start()
        }
        .onChange(of: store.folderDrillPath) { _ in start() }
        // 后退时落点可能和来处**恰好是同一个值**（中间那一段被截掉了），
        // 值没变上面那条就不响，界面会停在原来的子目录上不动，所以每一步都再对一次账。
        .onChange(of: store.navPulse) { _ in start() }
        // 总览按了「重新扫描」：这一页进过的每一层都成了上一轮的账，整本作废。
        // 不接这一条会怎样：退回来还是旧数字，而这个工具的全部立身之本就是数是真的。
        // 反过来说，**除了这一下**，进过的层就一直留着——那不叫漏扫，叫缓存。
        .onChange(of: store.rescanPulse) { _ in model.invalidate() }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "项"),
                               human(model.selectedBytes, inRulerOf: model.level?.total ?? 0))) {
            doClean()
        }
    }

    // MARK: 主体

    /// 「上一级」那颗按钮的说明文字。顶层目录的上一格是空间总览而不是某个文件夹，
    /// 说明里就得写空间总览——不然鼠标一停，说的和按下去的落点是两回事。
    /// 用的是既有的「回到「%@」」那一句（全局返回按钮也读它），不另造一条文案。
    private var goUpHint: String {
        drillParent(of: model.path) == nil
            ? LF("回到「%@」", L("空间总览"))
            : L("退到上一层文件夹")
    }

    @ViewBuilder private var content: some View {
        if model.path.isEmpty {
            EmptyState(symbol: "folder", title: L("还没选文件夹"),
                       hint: L("回空间总览，点一行文件夹的名字进来；也可以从大文件那页点「查看所在文件夹」。"))
                .frame(maxHeight: .infinity)
        } else if model.busy && model.rows.isEmpty {
            ScanChecklist(progress: model.progress)
        } else if !model.busy && model.rows.isEmpty {
            EmptyState(symbol: "folder", title: L("这一层没有读得出的东西"),
                       hint: L("可能是空目录，或它需要「完全磁盘访问权限」才读得动。"))
                .frame(maxHeight: .infinity)
        } else {
            PageLedger(tiers: tiers, rows: model.rows.count, note: nil)
            List(model.rows) { r in
                ItemRow(selected: selection(r),
                        icon: .path(r.url),
                        name: r.name,
                        sub: subLine(r),
                        hint: verdictHint(for: r.path),
                        sizeText: sizeCell(r),
                        fraction: Double(r.size) / Double(maxSize),
                        badge: isDeletable(r.url) ? nil : ItemBadge(text: L("本工具不碰"), tone: .neutral),
                        badge2: rowBadge(r),
                        selectable: isDeletable(r.url),
                        lit: isDeletable(r.url),
                        lockedHint: isDeletable(r.url) ? nil : outsideScopeHint,
                        onOpen: r.isDir ? { store.drill(into: r.path) } : nil,
                        onReveal: { reveal(r.path) },
                        // 文件行的路径只有摊开才看得见，而摊开这件事批量拍图这一路点不到，
                        // 所以由视图自己置位——改的是同一个 `expanded`，不是另画一张展开样。
                        preopen: SnapshotMode.expandsRow(r.name)) {
                    PathLine(path: r.path)
                }
                // 删掉的那几行先转淡，让筹码从它身上起飞；收行交给飞完之后的 `reload`。
                .opacity(flight.leaving.contains(r.path) ? 0.30 : 1)
                // 只有勾上的行才报起点：这一层可能几百行，全挂 GeometryReader 是白量。
                .heroAnchorGlobal(TrashFlightController.rowAnchor(r.path),
                                  enabled: model.selected.contains(r.path))
            }
            .ledgerCard()
            ListNote(text: tailNote)
            if let vn = verdictNote {
                ListNote(text: vn)
            }
        }
    }

    // MARK: 判词（知识库）

    /// 这一行的判词。命不中就不给徽章——**不在这一行上说「不认识」**：
    /// 一屏九十多行里九十行都会挂上那三个字，那就不是信息，是背景噪音了，
    /// 而且真正要说的话（「不在这本知识库里」）本来就是一整层的事，见 `verdictNote`。
    ///
    /// 徽章本身在 `SharedViews.verdictBadge`，跟缓存页、总览共用一份：
    /// 这页只说「哪些行不挂」。
    private func rowBadge(_ r: ChildEntry) -> ItemBadge? {
        verdictBadge(VerdictIndex.shared.verdict(for: r.path).tier)
    }

    /// 这一层的判词总账：知识库认得的那几处里，有多少是**指得出再生成路径**的。
    ///
    /// 这是「哪些放心删」在这页上的正面回答；剩下那些不在知识库里的必须一起说出来，
    /// 而且要说清「不在 ≠ 能删」——只报认得的那几项，等于把不认识的默认洗成安全。
    ///
    /// 「删了要重新下载」和「删了会丢数据」分开数、分开说。原先它们合在「要先看一眼」一句里，
    /// 于是 40 GB 的模型权重和 3 台模拟器的数据在页尾是同一句话，用户没法据此决定
    /// 先动哪个——而这页唯一的作用就是帮他做这个决定。
    private var verdictNote: String? {
        guard !model.rows.isEmpty else { return nil }
        var safe = 0, redo = 0, risky = 0, unknown = 0
        var safeBytes = Int64(0)
        for r in model.rows {
            switch VerdictIndex.shared.verdict(for: r.path).tier {
            case .safe:    safe += 1; safeBytes += r.size
            case .redo:    redo += 1
            case .risky:   risky += 1
            case .unknown: unknown += 1
            }
        }
        var parts: [String] = []
        if safe > 0 {
            parts.append(LF("删了没影响的 %1$@合计 %2$@",
                            cnt(safe, "项"), human(safeBytes, inRulerOf: model.level?.total ?? 0)))
        }
        if redo > 0 {
            parts.append(LF("%1$@删了要重新下载", cnt(redo, "项")))
        }
        if risky > 0 {
            parts.append(LF("%1$@删了会丢数据", cnt(risky, "项")))
        }
        if unknown > 0 {
            parts.append(LF("另有 %1$@不在这本知识库里：不在不等于能删，勾之前先看路径",
                            cnt(unknown, "项")))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ") + "。"
    }

    private var crumbsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(L("空间总览"), active: false) { store.resetNav(to: .overview) }
                ForEach(Array(model.crumbs.enumerated()), id: \.element) { i, p in
                    Text("›")
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                    crumb(shortLabel(p), active: i == model.crumbs.count - 1) {
                        store.drill(into: p)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func crumb(_ text: String, active: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(text)
                .font(theme.bodyFont(.caption).weight(active ? .semibold : .regular))
                .foregroundStyle(active ? theme.palette.ink : theme.palette.inkSecondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(theme.controlShape().fill(active ? theme.palette.surfaceAlt : Color.clear))
                .contentShape(theme.controlShape())
        }
        .buttonStyle(.plain)
        .disabled(active)
        .help(text)
    }

    // MARK: 数

    /// 这一层的账：分「本工具能清 / 本工具不碰」两堆，跟大文件页同一口径。
    private var tiers: [LedgerTier] {
        let sp = listedSplitOf(model.rows, bytes: { $0.size }, lit: { isDeletable($0.url) })
        return [LedgerTier(label: L("本工具能清"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("本工具不碰"), bytes: sp.viewOnly, tone: .cold)]
    }

    private var maxSize: Int64 { max(1, model.rows.map(\.size).max() ?? 1) }

    /// 整列连尾巴那句一起过统一分档，钉在这一层的合计上：几行印出来的数
    /// 加上尾巴那句，正好等于页头那个「这一层量到」。
    private var shown: [String: String] {
        guard let lv = model.level else { return [:] }
        let rest = lv.unlistedBytes
        let texts = addableHumanColumn(model.rows.map(\.size) + [rest], total: lv.total)
        var out: [String: String] = [:]
        for (r, s) in zip(model.rows, texts) { out[r.id] = s }
        return out
    }

    /// 这一行的数字。**整个读不动**的那几行给破折号，不给 `0 B`——它们的 0 是「没量到」，
    /// 不是「没有」，写成 0 就等于替系统那几十个 GB 担保说「这儿是空的」。
    /// 但只是**一部分**读不动的（子树里有一块受保护，外面照样量到了几十个 GB）照常给数字，
    /// 那一行的破绽由副标题去说：把 `Application Support` 显示成破折号，是从一处错
    /// 改成另一处错。
    private func sizeCell(_ r: ChildEntry) -> String {
        if r.unreadable && r.size == 0 { return "—" }
        return shown[r.id] ?? human(r.size)
    }

    /// 尾巴那句：没逐行列出来的那些。**不能省**——省了用户就会把这一列去加页头那个数，
    /// 加不上就以为数字是编的。
    private var tailNote: String {
        guard let lv = model.level else { return "" }
        var parts = [LF("这一层量到 %@", human(lv.total))]
        if lv.unlistedCount > 0 {
            parts.append(LF("另有 %1$@（%2$@）没逐行列出",
                            cnt(lv.unlistedCount, "项"), human(lv.unlistedBytes)))
        }
        // 读不动的那几块压根没进 total，不在这儿说一句，页头那个数就是个偏小的数，
        // 而偏小在这个 App 里比偏大更危险：那是在说「这儿没什么可看的」。
        // 两类分开数：「整个量不到」和「量到一部分」对那个合计数的影响不是一回事。
        let stuck = model.rows.filter { $0.unreadable && $0.size == 0 }.count
        if stuck > 0 {
            parts.append(LF("其中 %1$@读不动，没算进这一层", cnt(stuck, "个文件夹")))
        }
        let partial = model.rows.filter { $0.unreadable && $0.size > 0 }.count
        if partial > 0 {
            parts.append(LF("%1$@只量到一部分", cnt(partial, "个文件夹")))
        }
        return parts.joined(separator: " · ") + "。"
    }

    /// 行内副标题：目录报「多少个文件 + 最近改动」，文件报「最近改动」。
    /// 光有字节数的话，10 GB 的一堆碎缓存和 10 GB 的单个镜像长得一样，
    /// 而前者能一条条判、后者不能。
    private func subLine(_ r: ChildEntry) -> String? {
        if r.unreadable && r.size == 0 { return L("读不动，数字没算进来") }
        var line: String?
        if r.isDir {
            line = contentsLine(r.files, r.newest)
        } else if let n = r.newest {
            line = LF("最近改动 %@", shortDate(n))
        }
        if r.unreadable {
            line = [line, L("有读不动的地方")].compactMap { $0 }.joined(separator: " · ")
        }
        return line
    }

    private func selection(_ r: ChildEntry) -> Binding<Bool> {
        Binding(get: { model.selected.contains(r.path) },
                set: { on in
                    if on { model.selected.insert(r.path) } else { model.selected.remove(r.path) }
                })
    }

    /// 「全选」只管勾得动的那几行：本工具不碰的行选上也删不掉，全选后按清理只会换一屏报错。
    private var selectAll: SelectAll? {
        let open = model.rows.filter { isDeletable($0.url) }
        guard !open.isEmpty else { return nil }
        return SelectAll(allSelected: open.allSatisfy { model.selected.contains($0.path) },
                         unselectable: model.rows.count - open.count) { on in
            if on {
                model.selected = Set(open.map(\.path))
            } else {
                model.selected.removeAll()
            }
        }
    }

    // MARK: 动作

    private func start() {
        guard let p = store.folderDrillPath else { return }
        // 正在量的就是这一层就别打断它：`open` 会取消在跑的任务、重开一趟，
        // 而上面两条 onChange 有可能落在同一层上各响一次。
        if p == model.path && model.busy { return }
        model.open(p)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func doClean() {
        err = nil
        let targets = model.selectedEntries
        let rows = targets.map { (key: $0.path, bytes: $0.size) }
        // 起点终点都得在清选区**之前**取：行一不勾就不再报锚点，按钮一禁用落点也跟着变。
        // 「减弱动态效果」与截图模式下不飞：凭空出现又消失比没有更难解释，而结果一样给全。
        // 这一页收行要重扫这一层，不是当场发生，所以 `fade`：先转淡，筹码落地再收。
        let fly = flight.launch(rows: rows,
                                animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion),
                                fade: true)
        model.selected.removeAll()

        var ok = 0
        var errs: [String] = []
        for r in targets {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
        }

        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "项", failed: errs.count)

        // 行先转淡、筹码飞完再重载：不然筹码还在半路、行已经没了，那条路又白走了。
        let gone = Set(targets.map(\.path))
        DispatchQueue.main.asyncAfter(deadline: .now() + TrashFlightController.settleDelay(fly)) {
            [weak model, weak flight] in
            model?.reload()
            flight?.settle(gone)
        }
    }

    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时把这一页的飞行也钉住拍一张。
    ///
    /// 候选行只有本工具清得动的那几行（钩子不写真账，但起点得是真会飞的那几行）；
    /// 具体怎么勾、怎么发筹码在 `TrashFlightController.fireSnapshotIfAsked`。
    private func fireSnapshotFlightIfAsked() {
        guard let lv = model.level, !model.busy, !lv.entries.isEmpty else { return }
        let open = Array(model.rows.filter { isDeletable($0.url) }.prefix(2))
        guard let first = open.first else { return }
        flight.fireSnapshotIfAsked(candidates: open.map { (key: $0.path, bytes: $0.size) },
                                   selected: model.selected.contains(first.path)) {
            model.selected = Set(open.map(\.path))
        }
    }
}

/// 面包屑/状态行里那一小截名字：家目录缩成 `~`，其余取尾段。
/// **盘顶不特别处理**：`/` 不再是面包屑的一格，它也只会出现在「正在量」那行里，
/// 那时尾段本来就是 `/`。
private func shortLabel(_ path: String) -> String {
    if path.isEmpty { return "" }
    if path == homePath() { return "~" }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
}
