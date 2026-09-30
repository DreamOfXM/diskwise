import SwiftUI
import DiskCleanerCore

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

    /// 「全选」只管勾得动的那几行：系统区的行选上也删不掉，全选后按清理只会换一屏报错。
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
    @ObservedObject var model: BigFilesModel
    @State private var confirm = false
    @State private var err: String? = nil

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
                        // 深挖是从总览的热点行跳进来的，但这条链上没人记「上一页」，
                        // 删空之后这一屏就成了死胡同——所以返回入口固定摆在工具条最左，
                        // 空列表时页头还在，它就一直按得回去。
                        ThemeButton(kind: .compact, title: L("返回空间总览")) {
                            store.jumpTo = .overview
                        }
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
                ScanSkeleton(scope: model.scope.uiName)
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
                            sizeText: shown[r.id] ?? human(r.size),
                            fraction: Double(r.size) / Double(maxSize),
                            badge: r.deletable ? nil : ItemBadge(text: L("系统区"), tone: .neutral),
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
                }
                .ledgerCard()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: listedTotal),
                     errorText: err, selection: model.selectAll) { confirm = true }
        }
        .frame(maxWidth: .infinity)
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

    /// 这一页两笔账：系统区里的东西本工具不动手，所以分「动得了 / 只能看」两档。
    private var tiers: [LedgerTier] {
        let sp = listedSplitOf(model.rows, bytes: { $0.size }, lit: { $0.deletable })
        return [LedgerTier(label: L("动得了"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("只能看"), bytes: sp.viewOnly, tone: .cold)]
    }

    /// 「共扫到 152 个」和这一列加起来是两回事：这一屏只画了前 30 个。
    /// 不写这句，用户会把 30 行的和去对页头那句话，对不上就以为数字是编的。
    private var ledgerNote: String? {
        model.count > model.rows.count
            ? LF("扫到的 %1$@ 个里只列最大的 %2$d 个，剩下的比这一列最小那行还小。",
                 String(model.count), model.rows.count)
            : nil
    }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        for r in model.selected {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
            if let i = model.rows.firstIndex(where: { $0.id == r.id }) {
                model.rows[i].selected = false
            }
        }
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
    @ObservedObject var model: OldFilesModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "clock", title: L("很久没动"),
                           subtitle: L("扫过的地方里，好久没碰的东西"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在看哪些文件落灰…"), progress: model.progress)
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(model.rows.count, "个文件"), human(model.totalBytes)))
                    }
                    ThemeBadge(text: LF("范围：%@", model.scope.uiName),
                               tone: .neutral, symbol: "scope")
                } trailing: {
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
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.rows.isEmpty {
                ScanSkeleton(scope: model.scope.uiName)
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
                            sizeText: shown[r.id] ?? human(r.size),
                            fraction: Double(r.size) / Double(maxSize),
                            badge: r.deletable ? nil : ItemBadge(text: L("系统区"), tone: .neutral),
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
                }
                .ledgerCard()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: model.totalBytes),
                     errorText: err, selection: model.selectAll) { confirm = true }
        }
        .frame(maxWidth: .infinity)
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
        return [LedgerTier(label: L("动得了"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("只能看"), bytes: sp.viewOnly, tone: .cold)]
    }

    private var ledgerNote: String? {
        if model.count > model.rows.count {
            return LF("扫到的 %1$@ 个里只列最大的 %2$d 个，剩下的比这一列最小那行还小。",
                      String(model.count), model.rows.count)
        }
        return L("这一页的行全在屏幕上，当场就能把这一列加到页头那句。")
    }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        for r in model.selected {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
        }
        let before = model.rows.count
        model.rows.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        model.lose(before - model.rows.count)
        for i in model.rows.indices { model.rows[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个文件", failed: errs.count)
    }
}
