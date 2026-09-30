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
//   1. 可删性一律走 `isDeletable`（同大文件页），不另立规矩。系统区照样只能看——
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
    /// 面包屑：**盘顶 → 当前**，一路都能点。最后一条就是 `path`。
    @Published private(set) var crumbs: [String] = []
    @Published private(set) var level: DirLevel? = nil
    @Published private(set) var busy = false
    /// 这一轮量的是谁。「正在量」那几秒里如果不说是哪儿，读起来跟「点坏了」一样。
    @Published private(set) var pendingPath: String = ""
    @Published var selected: Set<String> = []

    /// 每层一次，最多列这么多行。`/Applications` 那种一级几百个，
    /// 全列出来没人逐行扫，多出来的并进尾巴那句。
    static let cap = 40

    private var cache: [String: DirLevel] = [:]
    private var task: Task<Void, Never>? = nil
    /// 只给截图链路用（`DISKWISE_DRILL_INTO=1`）：第一层量完自动钻一次，
    /// 好把「面包屑 ＋ 深一层」这一屏拍进图里。走的是同一颗箭头调的那个 `into`。
    private var autoDescended = false

    var rows: [ChildEntry] { level?.entries ?? [] }
    var selectedEntries: [ChildEntry] { rows.filter { selected.contains($0.path) } }
    var selectedBytes: Int64 { selectedEntries.reduce(Int64(0)) { $0 + $1.size } }

    /// 还能不能往上退一层。盘顶那一层没有上一级。
    var canGoUp: Bool {
        !path.isEmpty && (path as NSString).deletingLastPathComponent != path
    }

    /// 退到上一层。面包屑之外还得有一颗常驻的：深到十几层时，「往上退一层」是
    /// 这一页里唯一一个不用先看清自己在哪儿就能按的动作。
    func upOneLevel() {
        guard canGoUp else { return }
        open((path as NSString).deletingLastPathComponent)
    }

    /// 进一个目录。同一处再点一次不重量（缓存直接回填）。
    func open(_ target: String) {
        guard !target.isEmpty else { return }
        if target == path, level != nil, !busy { return }
        path = target
        rebuildCrumbs()
        selected.removeAll()
        load(target)
    }

    /// 面包屑点第 `index` 格回退。
    func up(to index: Int) {
        guard crumbs.indices.contains(index) else { return }
        open(crumbs[index])
    }

    /// 点行：目录才往里走，文件不动（文件在这一页只能勾选）。双保险——行上那颗
    /// 「进入」本来就不给文件画，但键盘/无障碍那一路仍可能调到这里。
    func into(_ child: ChildEntry) {
        guard child.isDir else { return }
        open(child.path)
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
        busy = true
        pendingPath = target
        let limit = Self.cap
        task = Task { [weak self] in
            let lv = await dirLevel(URL(fileURLWithPath: target), includeFiles: true, limit: limit)
            guard !Task.isCancelled, let self, self.path == target else { return }
            self.cache[target] = lv
            self.level = lv
            self.busy = false
            if SnapshotMode.drillAutoDescend, !self.autoDescended,
               let first = lv.entries.first(where: { $0.isDir }) {
                self.autoDescended = true
                self.open(first.path)
            }
        }
    }

    /// 面包屑从**盘顶**长下来（规则见 `crumbChain`），不从上一条扫描根长——
    /// 以扫描根为起点的话，`/Library`、`/Applications` 这类本身就是根的地方只剩
    /// 孤零零一格，上面全不见，而人恰恰是在「进太深了、想退出去」时看这一条。
    private func rebuildCrumbs() {
        crumbs = path.isEmpty ? [] : crumbChain(for: path)
    }
}

struct FolderDrillView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: FolderDrillModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "folder", title: L("文件夹详情"),
                           subtitle: L("一层层往里走，看清每个文件夹和文件占了多少"),
                           variant: .display) {
                    ThemeButton(kind: .compact, symbol: "arrow.up",
                                title: L("上一级"),
                                isDisabled: !model.canGoUp) {
                        model.upOneLevel()
                    }
                    .help(L("退到上一层文件夹"))
                }
                crumbsBar
                ControlStrip {
                    if model.busy {
                        LoadingRow(text: LF("正在量「%@」", shortLabel(model.pendingPath)))
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

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: model.level?.total ?? 0),
                     errorText: err, selection: selectAll) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { start() }
        .onChange(of: store.folderDrillPath) { _ in start() }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "项"),
                               human(model.selectedBytes, inRulerOf: model.level?.total ?? 0))) {
            doClean()
        }
    }

    // MARK: 主体

    @ViewBuilder private var content: some View {
        if model.path.isEmpty {
            EmptyState(symbol: "folder", title: L("还没选文件夹"),
                       hint: L("回空间总览，点一行文件夹的名字进来；也可以从大文件那页点「查看所在文件夹」。"))
                .frame(maxHeight: .infinity)
        } else if model.busy && model.rows.isEmpty {
            ScanSkeleton()
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
                        sizeText: shown[r.id] ?? human(r.size),
                        fraction: Double(r.size) / Double(maxSize),
                        badge: isDeletable(r.url) ? nil : ItemBadge(text: L("只能看"), tone: .neutral),
                        selectable: isDeletable(r.url),
                        lit: isDeletable(r.url),
                        lockedHint: isDeletable(r.url) ? nil : outsideScopeHint,
                        onOpen: r.isDir ? { model.into(r) } : nil,
                        onReveal: { reveal(r.path) }) {
                    PathLine(path: r.path)
                }
            }
            .ledgerCard()
            ListNote(text: tailNote)
        }
    }

    private var crumbsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                crumb(L("空间总览"), active: false) { store.jumpTo = .overview }
                ForEach(Array(model.crumbs.enumerated()), id: \.element) { i, p in
                    Text("›")
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                    crumb(shortLabel(p), active: i == model.crumbs.count - 1) {
                        model.up(to: i)
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

    /// 这一层的账：分「动得了 / 只能看」两堆，跟大文件页同一口径。
    private var tiers: [LedgerTier] {
        let sp = listedSplitOf(model.rows, bytes: { $0.size }, lit: { isDeletable($0.url) })
        return [LedgerTier(label: L("动得了"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("只能看"), bytes: sp.viewOnly, tone: .cold)]
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

    /// 尾巴那句：没逐行列出来的那些。**不能省**——省了用户就会把这一列去加页头那个数，
    /// 加不上就以为数字是编的。
    private var tailNote: String {
        guard let lv = model.level else { return "" }
        var parts = [LF("这一层量到 %@", human(lv.total))]
        if lv.unlistedCount > 0 {
            parts.append(LF("另有 %1$@（%2$@）没逐行列出",
                            cnt(lv.unlistedCount, "项"), human(lv.unlistedBytes)))
        }
        return parts.joined(separator: " · ") + "。"
    }

    /// 行内副标题：目录报「多少个文件 + 最近改动」，文件报「最近改动」。
    /// 光有字节数的话，10 GB 的一堆碎缓存和 10 GB 的单个镜像长得一样，
    /// 而前者能一条条判、后者不能。
    private func subLine(_ r: ChildEntry) -> String? {
        if r.isDir { return contentsLine(r.files, r.newest) }
        guard let n = r.newest else { return nil }
        return LF("最近改动 %@", shortDate(n))
    }

    private func selection(_ r: ChildEntry) -> Binding<Bool> {
        Binding(get: { model.selected.contains(r.path) },
                set: { on in
                    if on { model.selected.insert(r.path) } else { model.selected.remove(r.path) }
                })
    }

    /// 「全选」只管勾得动的那几行：系统区的行选上也删不掉，全选后按清理只会换一屏报错。
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
        model.open(p)
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        for r in model.selectedEntries {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
        }
        model.selected.removeAll()
        model.reload()
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "项", failed: errs.count)
    }
}

/// 面包屑/状态行里那一小截名字：盘顶换成宗卷名（跟访达路径栏同一个词），
/// 家目录缩成 `~`，其余取尾段。
private func shortLabel(_ path: String) -> String {
    if path.isEmpty { return "" }
    if path == "/" {
        let name = FileManager.default.displayName(atPath: "/")
        return name.isEmpty ? "/" : name
    }
    if path == homePath() { return "~" }
    let last = (path as NSString).lastPathComponent
    return last.isEmpty ? path : last
}
