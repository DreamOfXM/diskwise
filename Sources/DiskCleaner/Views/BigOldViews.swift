import SwiftUI
import DiskCleanerCore

// ── 知识库覆盖总账（大文件 / 很久没动 共用）──

/// 一列文件里，知识库认得多少、认得的各要付什么代价，剩下多少压根不在库里。
///
/// 为什么要单说这一句：行内徽章只在**认得**时才挂，于是「没有徽章」里混着
/// 「认得且安全」和「不认识」两种完全不同的情形。不把这层说破，用户会把整列读成
/// 「都没问题」——**不在知识库里不等于能删**，而这正是这两页最不能给错的一句话。
///
/// 句子跟文件夹详情页那一句是同一组（那边叫 `verdictNote`）：同一句话在两个列表页
/// 长得不一样，就是在教用户「这两处说的不是一回事」。差别只在换算尺——那页钉在
/// 「这一层的合计」上，这两页没有那一层，没影响项合计就摊在这一列自己的合计上。
private func fileVerdictNote(_ rows: [FileRow], ruler: Int64) -> String? {
    guard !rows.isEmpty else { return nil }
    var safe = 0, redo = 0, risky = 0, unknown = 0
    var safeBytes = Int64(0)
    for r in rows {
        switch VerdictIndex.shared.verdict(for: r.url.path).tier {
        case .safe:    safe += 1; safeBytes += r.size
        case .redo:    redo += 1
        case .risky:   risky += 1
        case .unknown: unknown += 1
        }
    }
    var parts: [String] = []
    if safe > 0 {
        parts.append(LF("删了没影响的 %1$@合计 %2$@",
                        cnt(safe, "项"), human(safeBytes, inRulerOf: ruler)))
    }
    if redo > 0 { parts.append(LF("%1$@删了要重新下载", cnt(redo, "项"))) }
    if risky > 0 { parts.append(LF("%1$@删了会丢数据", cnt(risky, "项"))) }
    if unknown > 0 {
        parts.append(LF("另有 %1$@不在这本知识库里：不在不等于能删，勾之前先看路径",
                        cnt(unknown, "项")))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ") + "。"
}

// ── 大文件 TOP ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class BigFilesModel: ObservableObject {
    @Published var rows: [FileRow] = []
    @Published var scanning = false
    @Published var limit = 30
    @Published var skipDev = true
    @Published var scopeNote: String? = nil
    /// 本轮实际用的范围，页头拿它贴标签：范围变了但没重扫时不能继续顶着旧标签说真话
    @Published private(set) var scope: ScanScope = .user
    /// 本次会话里扫过没有——区分「还没扫」和「扫了但没有」
    @Published private(set) var started = false
    /// 满足条件的文件总数（`all` 只是它最大的那 200 个，`rows` 又是 `all` 的前缀）
    @Published private(set) var count = 0
    /// 现场读数：整盘范围一趟几分钟，这段时间里它是唯一能证明「在动」的东西。
    private(set) var progress = ScanProgress()
    private var task: Task<Void, Never>? = nil
    /// 遍历有界保留的候选集（最多 200 条）；rows 只是它的前 limit 条
    private var all: [FileRow] = []
    private var customDirs: [URL]? = nil

    var selected: [FileRow] { rows.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }

    /// 「全选」只管勾得动的那几行：本工具不碰的行选上也删不掉，全选后按清理只会换一屏报错。
    /// 一行都勾不动时返回 nil，按钮不画——画一颗点了没反应的按钮比没有更糟。
    var selectAll: SelectAll? {
        let open = rows.filter(\.deletable)
        guard !open.isEmpty else { return nil }
        return SelectAll(allSelected: open.allSatisfy(\.selected),
                         unselectable: rows.count - open.count) { on in
            for i in self.rows.indices where self.rows[i].deletable {
                self.rows[i].selected = on
            }
            self.syncBack()
        }
    }

    /// 总览跳过来的定向扫描；dirs == nil 回到默认范围
    func scan(scope: ScanScope, dirs: [URL]? = nil, note: String? = nil) {
        task?.cancel()
        scanning = true
        started = true
        rows = []
        all = []
        customDirs = dirs
        scopeNote = note
        self.scope = scope
        progress = ScanProgress()
        let skip: Set<String> = skipDev ? ["node_modules", ".git", "Caches"] : []
        let targets = dirs ?? defaultScanDirs(scope: scope)
        task = Task {
            let r = await walkFiles(dirs: targets, top: 200, skipNames: skip,
                                      progress: self.progress)
            if !Task.isCancelled {
                self.count = r.matched
                self.all = r.rows
                self.applyLimit()
                self.scanning = false
            }
        }
    }

    func rescan(scope: ScanScope) { scan(scope: scope, dirs: customDirs, note: scopeNote) }

    func stop() { task?.cancel(); scanning = false }

    /// 改「前 N」不重扫：勾选同步回候选集，再切一刀
    func applyLimit() {
        syncBack()
        rows = Array(all.prefix(limit))
    }

    /// 删完就地把没了的条目剔掉，不值得为此重走一遍全盘
    func pruneMissing() {
        syncBack()
        let before = all.count
        all.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        // 「扫到多少个」跟着减，否则对账句会一直说只列了前 N 个，而那时已经列全了
        count = max(all.count, count - (before - all.count))
        rows = Array(all.prefix(limit))
    }

    /// rows 永远是 all 的前缀，按下标对齐写回
    private func syncBack() {
        for i in rows.indices where i < all.count { all[i] = rows[i] }
    }
}

struct BigFilesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: BigFilesModel
    @State private var confirm = false
    @State private var err: String? = nil
    /// 删除飞行：起点（勾中的行）与落点（CleanBar 那颗按钮）都在这里面收着。
    @StateObject private var flight = TrashFlightController()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "doc.on.doc", title: L("大文件"),
                           subtitle: L("按个头排好队，大的在上面"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在翻你的文件夹…"), progress: model.progress)
                    } else {
                        Text(LF("共扫到 %@", cnt(model.count, "个文件")))
                    }
                    if let note = model.scopeNote {
                        // 这里原先钉着一颗「返回空间总览」——深挖那条链上没人记「上一页」，
                        // 删空之后这一屏就成了死胡同，只能把退路写死在工具条最左。
                        // 现在退路归窗口顶上那颗全局「返回」管，它按的是同一本历史、
                        // 落在哪儿就写哪儿，所以这里不再单摆一颗：两个返回入口会打架。
                        ThemeBadge(text: LF("只看 %@", note), tone: .tint, symbol: "scope")
                        ThemeButton(kind: .compact, title: L("不限这个目录")) {
                            model.scan(scope: store.scope)
                        }
                    } else {
                        ThemeBadge(text: LF("范围：%@", model.scope.uiName),
                                   tone: .neutral, symbol: "scope")
                    }
                } trailing: {
                    // 筛选控件放工具条右侧，不放页头：页头那一条要留给标题和副标题，
                    // 英文副标题一长就被控件挤到换行，控件自己也会顶出窗口边。
                    ThemeSwitch(label: L("跳过开发目录"), isOn: $model.skipDev) {
                        model.rescan(scope: store.scope)
                    }
                    ThemeStepper(label: L("前"), value: $model.limit, range: 10...200, step: 10) {
                        model.applyLimit()
                    }
                    ScanControl(scanning: model.scanning,
                                rescan: { model.rescan(scope: store.scope) },
                                stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.rows.isEmpty {
                ScanChecklist(progress: model.progress, scope: model.scope.uiName)
            } else if !model.scanning && model.rows.isEmpty {
                EmptyState(symbol: "doc", title: L("还没扫到大文件"),
                           hint: L("点右上角重新扫描，或回总览换个目录深挖"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: model.rows.count, note: ledgerNote)
                List($model.rows) { $r in
                    ItemRow(selected: $r.selected,
                            icon: .path(r.url),
                            name: r.name,
                            sub: displayPath(r.url.deletingLastPathComponent()) + " · " + r.dateStr,
                            // 第三行只给知识库认得的那几行：徽章只说代价的名字，这一行说代价是什么。
                            // 命不中的一行为空——一屏几十行里绝大多数本来就不在库里，那不是信息。
                            hint: verdictHint(for: r.url.path),
                            sizeText: shown[r.id] ?? human(r.size),
                            fraction: Double(r.size) / Double(maxSize),
                            badge: r.deletable ? nil : ItemBadge(text: L("本工具不碰"), tone: .neutral),
                            // 第二枚徽章走**另一条轴**：上面那枚说本工具动不动这一行，这枚说甩掉它
                            // 要付什么代价。这两页原先只有前一枚，于是恰好漏掉
                            // 最该提醒的那一类——**本工具能清、但删了会丢数据**的（模拟器数据、
                            // 模型权重）：勾选框大方地开着，一个字都不提醒，勾下去就没了。
                            badge2: verdictBadge(VerdictIndex.shared.verdict(for: r.url.path).tier),
                            selectable: r.deletable,
                            lit: r.deletable,
                            showRule: model.rows.first?.id != r.id,
                            lockedHint: r.deletable ? nil : outsideScopeHint) {
                        VStack(alignment: .leading, spacing: 7) {
                            PathLine(path: r.url.path)
                            // 「这个文件到底在哪个文件夹」是这一页最常被追问的一句。
                            // 摊开这一行顺手给个入口，省得自己去访达里一层层翻。
                            ThemeButton(kind: .compact, symbol: "folder",
                                        title: L("查看所在文件夹")) {
                                store.drill(into: r.url.deletingLastPathComponent().path)
                            }
                        }
                    }
                    // 只有勾上的行才报起点：这一列几十行，全挂 GeometryReader 是白量。
                    .heroAnchorGlobal(TrashFlightController.rowAnchor(r.id.uuidString),
                                      enabled: r.selected)
                }
                .ledgerCard()
                // 这一列的知识库覆盖总账。徽章只在认得时挂，于是「没徽章」里混着
                // 「认得且没影响」和「压根不认识」两种可能——不把这一层说破，
                // 用户会把整列读成「都没问题」，而那正是这一页最不能给错的一句话。
                if let vn = verdictNote { ListNote(text: vn) }
            }

            Spacer(minLength: 0)   // 清理条钉在窗口下沿，见 `CleanBar`

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: listedTotal),
                     errorText: err, selection: model.selectAll, flightTarget: true) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onChange(of: flight.anchors) { _ in fireSnapshotFlightIfAsked() }
        // 页刚进来时 `anchors` 只出现过一次（那时还没扫出行来），光靠它这一次钩子会早退；
        // 行数从 0 变成 N 是「扫完了」的信号，补在这里，钩子才有第二次机会。
        .onChange(of: model.rows.count) { _ in fireSnapshotFlightIfAsked() }
        .onAppear {
            // 总览跳过来的定向扫描只消费一次
            if let dir = store.bigScanDir {
                store.bigScanDir = nil
                model.scan(scope: store.scope, dirs: [dir], note: dir.lastPathComponent)
            } else if !model.started {
                model.scan(scope: store.scope)
            }
        }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "个文件"),
                               human(model.selectedBytes, inRulerOf: listedTotal))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.rows.map(\.size).max() ?? 1) }

    /// 这一列合起来多少字节——对账句和底部那串数都以它为准，两处用同一把尺。
    private var listedTotal: Int64 { model.rows.reduce(Int64(0)) { $0 + $1.size } }

    /// 整列统一到 `listedTotal` 那个单位再分摊，所以这几行**印出来**能加成对账句里那个合计。
    private var shown: [UUID: String] {
        sizeColumn(model.rows.map { (key: $0.id, bytes: $0.size) })
    }

    /// 这一页两笔账：本工具不碰的位置只摆上列表不入账，所以分「本工具能清 / 本工具不碰」两档。
    private var tiers: [LedgerTier] {
        let sp = listedSplitOf(model.rows, bytes: { $0.size }, lit: { $0.deletable })
        return [LedgerTier(label: L("本工具能清"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("本工具不碰"), bytes: sp.viewOnly, tone: .cold)]
    }

    /// 「共扫到 152 个」和这一列加起来是两回事：这一屏只画了前 30 个。
    /// 不写这句，用户会把 30 行的和去对页头那句话，对不上就以为数字是编的。
    private var ledgerNote: String? {
        model.count > model.rows.count
            ? LF("扫到的 %1$@ 个里只列最大的 %2$d 个，剩下的比这一列最小那行还小。",
                 String(model.count), model.rows.count)
            : nil
    }

    private var verdictNote: String? { fileVerdictNote(model.rows, ruler: listedTotal) }

    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时把这一页的飞行钉住拍一张（见 `TrashFlightController`）。
    /// 候选行只取清得动的前两条——钩子不写真账，但起点得是真会飞的那几行。
    private func fireSnapshotFlightIfAsked() {
        let open = Array(model.rows.filter(\.deletable).prefix(2))
        guard let first = open.first else { return }
        flight.fireSnapshotIfAsked(candidates: open.map { (key: $0.id.uuidString, bytes: $0.size) },
                                   selected: first.selected) {
            for id in open.map(\.id) {
                if let i = model.rows.firstIndex(where: { $0.id == id }) { model.rows[i].selected = true }
            }
        }
    }

    private func doClean() {
        err = nil
        let targets = model.selected
        // 起点终点都在清选区**之前**取：行一不勾就不再报锚点，按钮一禁用落点也跟着变。
        flight.launch(rows: targets.map { (key: $0.id.uuidString, bytes: $0.size) },
                      animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion))
        var ok = 0
        var errs: [String] = []
        for r in targets {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
            if let i = model.rows.firstIndex(where: { $0.id == r.id }) {
                model.rows[i].selected = false
            }
        }
        // 行会被剔掉，筹码已经在 `launch` 那一下量好了起点，从它原来的位置上起飞。
        model.pruneMissing()
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个文件", failed: errs.count)
    }
}

// ── 很久没动 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class OldFilesModel: ObservableObject {
    @Published var rows: [FileRow] = []
    @Published var scanning = false
    @Published var days = 90
    @Published var skipDev = true
    /// 本轮实际用的范围，页头贴标签用；范围变了没重扫时不能顶着旧标签说真话
    @Published private(set) var scope: ScanScope = .user
    @Published private(set) var started = false
    /// 现场读数：「很久没动」换到整盘范围要重走每一棵树，等几分钟得说清在等什么。
    private(set) var progress = ScanProgress()
    private var task: Task<Void, Never>? = nil
    /// 满足条件的文件总数（`rows` 只是它最大的那 300 个）；删掉几条就跟着减几条
    @Published private(set) var count = 0

    var selected: [FileRow] { rows.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.size } }

    /// 列表被就地删短之后，「扫到多少个」这个总数得跟着减，否则对账句会一直
    /// 说「只列了前 300 个」——而那时候屏幕上可能只剩 40 行，全都列出来了。
    func lose(_ n: Int) { count = max(rows.count, count - n) }

    var selectAll: SelectAll? {
        let open = rows.filter(\.deletable)
        guard !open.isEmpty else { return nil }
        return SelectAll(allSelected: open.allSatisfy(\.selected),
                         unselectable: rows.count - open.count) { on in
            for i in self.rows.indices where self.rows[i].deletable {
                self.rows[i].selected = on
            }
        }
    }

    func scan(scope: ScanScope) {
        task?.cancel()
        scanning = true
        started = true
        rows = []
        self.scope = scope
        progress = ScanProgress()
        let d = days
        let skip: Set<String> = skipDev ? ["node_modules", ".git", "Caches"] : []
        let targets = defaultScanDirs(scope: scope)
        task = Task {
            let cutoff = Date().addingTimeInterval(Double(-d) * 86400)
            let r = await walkFiles(dirs: targets, olderThan: cutoff, top: 300, skipNames: skip,
                                      progress: self.progress)
            if !Task.isCancelled {
                self.count = r.matched
                self.rows = r.rows
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

struct OldFilesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: OldFilesModel
    @State private var confirm = false
    @State private var err: String? = nil
    /// 删除飞行：起点（勾中的行）与落点（CleanBar 那颗按钮）都在这里面收着。
    @StateObject private var flight = TrashFlightController()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                // 筛选控件挂在页头右端，跟标题并列。这一条窄语言放得下（中文 692 pt / 内容区 774 pt），
                // 长译文由 `wrapsControls` 那一档把控件退到第二行右对齐——所以它不会顶出窗口边，
                // 也不会把副标题挤断。控件离开控制条之后，下面那行只剩读数自己。
                PageHeader(symbol: "clock", title: L("很久没动"),
                           subtitle: L("扫过的地方里，好久没碰的东西"),
                           variant: .display,
                           wrapsControls: true) {
                    ThemeBadge(text: LF("范围：%@", model.scope.uiName),
                               tone: .neutral, symbol: "scope")
                    ThemeSwitch(label: L("跳过开发目录"), isOn: $model.skipDev) {
                        model.scan(scope: store.scope)
                    }
                    ThemeStepper(label: L("超过"), unit: L("天"),
                                 value: $model.days, range: 30...365, step: 30) {
                        model.scan(scope: store.scope)
                    }
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan(scope: store.scope) },
                                stop: { model.stop() })
                }
                // 页头已经把控件收走了，这一行只剩读数自己 —— 撑满它，
                // 右缘才跟上面的页头、下面的账卡落在同一条竖线上。
                Group {
                    if model.scanning {
                        LoadingRow(text: L("正在看哪些文件落灰…"), progress: model.progress,
                                   fillsRow: true)
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(model.rows.count, "个文件"),
                                human(model.totalBytes)))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.rows.isEmpty {
                ScanChecklist(progress: model.progress, scope: model.scope.uiName)
            } else if !model.scanning && model.rows.isEmpty {
                EmptyState(symbol: "sparkle", title: L("没有落灰的文件"),
                           hint: L("扫过的地方很干净，保持住"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: model.rows.count, note: ledgerNote)
                List($model.rows) { $r in
                    ItemRow(selected: $r.selected,
                            icon: .path(r.url),
                            name: r.name,
                            sub: displayPath(r.url.deletingLastPathComponent()) + " · " + r.dateStr,
                            // 第三行只给知识库认得的那几行：徽章只说代价的名字，这一行说代价是什么。
                            // 命不中的一行为空——一屏几十行里绝大多数本来就不在库里，那不是信息。
                            hint: verdictHint(for: r.url.path),
                            sizeText: shown[r.id] ?? human(r.size),
                            fraction: Double(r.size) / Double(maxSize),
                            badge: r.deletable ? nil : ItemBadge(text: L("本工具不碰"), tone: .neutral),
                            // 第二枚徽章走**另一条轴**：上面那枚说本工具动不动这一行，这枚说甩掉它
                            // 要付什么代价。这两页原先只有前一枚，于是恰好漏掉
                            // 最该提醒的那一类——**本工具能清、但删了会丢数据**的（模拟器数据、
                            // 模型权重）：勾选框大方地开着，一个字都不提醒，勾下去就没了。
                            badge2: verdictBadge(VerdictIndex.shared.verdict(for: r.url.path).tier),
                            selectable: r.deletable,
                            lit: r.deletable,
                            showRule: model.rows.first?.id != r.id,
                            lockedHint: r.deletable ? nil : outsideScopeHint) {
                        VStack(alignment: .leading, spacing: 7) {
                            PathLine(path: r.url.path)
                            // 「这个文件到底在哪个文件夹」是这一页最常被追问的一句。
                            // 摊开这一行顺手给个入口，省得自己去访达里一层层翻。
                            ThemeButton(kind: .compact, symbol: "folder",
                                        title: L("查看所在文件夹")) {
                                store.drill(into: r.url.deletingLastPathComponent().path)
                            }
                        }
                    }
                    // 只有勾上的行才报起点：这一列几十行，全挂 GeometryReader 是白量。
                    .heroAnchorGlobal(TrashFlightController.rowAnchor(r.id.uuidString),
                                      enabled: r.selected)
                }
                .ledgerCard()
                // 这一列的知识库覆盖总账。徽章只在认得时挂，于是「没徽章」里混着
                // 「认得且没影响」和「压根不认识」两种可能——不把这一层说破，
                // 用户会把整列读成「都没问题」，而那正是这一页最不能给错的一句话。
                if let vn = verdictNote { ListNote(text: vn) }
            }

            Spacer(minLength: 0)   // 清理条钉在窗口下沿，见 `CleanBar`

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: model.totalBytes),
                     errorText: err, selection: model.selectAll, flightTarget: true) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onChange(of: flight.anchors) { _ in fireSnapshotFlightIfAsked() }
        // 页刚进来时 `anchors` 只出现过一次（那时还没扫出行来），光靠它这一次钩子会早退；
        // 行数从 0 变成 N 是「扫完了」的信号，补在这里，钩子才有第二次机会。
        .onChange(of: model.rows.count) { _ in fireSnapshotFlightIfAsked() }
        .onAppear { if !model.started { model.scan(scope: store.scope) } }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "个文件"),
                               human(model.selectedBytes, inRulerOf: model.totalBytes))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.rows.map(\.size).max() ?? 1) }

    /// 整列统一到页头那个总数的单位再分摊：这几行**印出来**加起来就是页头那句。
    private var shown: [UUID: String] {
        sizeColumn(model.rows.map { (key: $0.id, bytes: $0.size) })
    }

    private var tiers: [LedgerTier] {
        let sp = listedSplitOf(model.rows, bytes: { $0.size }, lit: { $0.deletable })
        return [LedgerTier(label: L("本工具能清"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("本工具不碰"), bytes: sp.viewOnly, tone: .cold)]
    }

    private var ledgerNote: String? {
        if model.count > model.rows.count {
            return LF("扫到的 %1$@ 个里只列最大的 %2$d 个，剩下的比这一列最小那行还小。",
                      String(model.count), model.rows.count)
        }
        return L("这一页的行全在屏幕上，当场就能把这一列加到页头那句。")
    }

    private var verdictNote: String? { fileVerdictNote(model.rows, ruler: model.totalBytes) }

    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时把这一页的飞行钉住拍一张（见 `TrashFlightController`）。
    /// 候选行只取清得动的前两条——钩子不写真账，但起点得是真会飞的那几行。
    private func fireSnapshotFlightIfAsked() {
        let open = Array(model.rows.filter(\.deletable).prefix(2))
        guard let first = open.first else { return }
        flight.fireSnapshotIfAsked(candidates: open.map { (key: $0.id.uuidString, bytes: $0.size) },
                                   selected: first.selected) {
            for id in open.map(\.id) {
                if let i = model.rows.firstIndex(where: { $0.id == id }) { model.rows[i].selected = true }
            }
        }
    }

    private func doClean() {
        err = nil
        let targets = model.selected
        // 起点终点都在清选区**之前**取：行一不勾就不再报锚点，按钮一禁用落点也跟着变。
        flight.launch(rows: targets.map { (key: $0.id.uuidString, bytes: $0.size) },
                      animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion))
        var ok = 0
        var errs: [String] = []
        for r in targets {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
        }
        // 行会被剔掉，筹码已经在 `launch` 那一下量好了起点，从它原来的位置上起飞。
        let before = model.rows.count
        model.rows.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        model.lose(before - model.rows.count)
        for i in model.rows.indices { model.rows[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个文件", failed: errs.count)
    }
}
