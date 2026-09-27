import SwiftUI
import DiskCleanerCore

// ── 缓存两页（应用缓存 / 开发缓存）：知识库驱动，每项解释 + 勾选 + 只进废纸篓 ──
//
// 知识库条目之间路径互相套着（`~/Library/Caches` 底下就躺着 `Caches/Homebrew`），
// 所以任何「合起来多少」都必须走 `contentsUnionSize`，不能按条目自己的 size 相加。
//
// safety_db.json 里的 name/what/whatif/rec 是中文原文，也就是本地化 key——
// 英文译文全在 en.lproj 那张表里，构建时用 l10n_tool 逐条核对覆盖率。

/// 知识库位置：打包版在 Contents/Resources，`swift run` 时在包根目录的源码树里。
/// 刻意不用 Bundle.module——它的生成代码找不到 .bundle 就 fatalError，
/// 且回退路径是构建机的绝对路径，等于只有开发者自己的机器能打开这一页。
private func safetyDBURL() -> URL? {
    if let u = Bundle.main.url(forResource: "safety_db", withExtension: "json") { return u }
    let dev = "Sources/DiskCleaner/Resources/safety_db.json"
    return FileManager.default.fileExists(atPath: dev) ? URL(fileURLWithPath: dev) : nil
}

/// 分组标识 → 显示名。排序认 key，界面才查词表。
func cacheGroupLabel(_ key: String) -> String {
    switch key {
    case "general": return L("常规缓存")
    case "cn_app":  return L("国产 App")
    case "dev":     return L("开发工具")
    default:        return key
    }
}

/// 同一套版面跑两个入口：应用缓存（日常 App 留下的）与开发缓存（开发工具留下的）。
///
/// 差别只有三处——读知识库的哪几组、页头那三样文案、副标题还要不要再标一次分组。
/// 版面、勾选、账本、删除全共用一份，所以两页的行为不会各跑各的口径。
enum CachesPage {
    case app, dev

    /// 这一台只管知识库里的哪几组。分开两台各扫各的：页头那句「本机 N 处」
    /// 说的就得是自己这一组，不能拿整本知识库的数顶上去。
    var groupKeys: Set<String> { self == .dev ? ["dev"] : ["general", "cn_app"] }
    var symbol: String { self == .dev ? "hammer" : "sparkles" }
    var titleKey: String { self == .dev ? "开发缓存" : "应用缓存" }
    var subtitleKey: String {
        self == .dev ? "装过的工具才出现在这一页，删了下次用到会自己重新下载"
                     : "每项都写明来历，勾你认得的，不认识的别碰"
    }
    /// 空态在两页说的是两件事：应用页空 = 知识库没读出来（故障）；
    /// 开发页空 = 这台机器压根没装过开发工具（正常），不能拿报错的口吻说它。
    var emptyTitleKey: String {
        self == .dev ? "没有检测到开发工具的缓存" : "知识库没加载出来"
    }
    var emptyHintKey: String {
        self == .dev ? "装过 Xcode、npm、Gradle、Ollama 之后回到这里重新扫描"
                     : "点右上角重新扫描，还不行就提个 Issue"
    }
    /// 只有应用页需要把「国产 App」标在行里：开发页整页都是开发工具，再标一遍等于没说。
    var showsGroupLabel: Bool { self == .app }
}

/// 行内副标题。原来写分组名，可知识库 27 条里 25 条的 grp 都是 general，
/// 于是每行都是「常规缓存」——一行字重复 25 遍就等于没有信息。
/// 认一条缓存靠的是路径尾段，所以副标题给真实路径；展开行里仍是全路径。
private func cacheRowSub(_ item: CacheItem, showsGroup: Bool) -> String? {
    guard let first = item.resolvedPaths.first else { return nil }
    var parts: [String] = []
    if showsGroup && item.groupKey != "general" { parts.append(cacheGroupLabel(item.groupKey)) }
    parts.append(displayPath(first))
    if item.resolvedPaths.count > 1 {
        parts.append(LF("%d 处", item.resolvedPaths.count))
    }
    return parts.joined(separator: " · ")
}

/// 这一行亮不亮「动得了」那一档。体积还没量出来的不亮（那是「还不知道」，
/// 不是「能删」）；标「留意」的也不亮——全选不碰它，就不该给批量带走的暗示。
private func cacheLit(_ it: CacheItem) -> Bool {
    (it.size ?? 0) > 0 && it.entry.level != "warn"
}

/// 一组条目名下所有解析路径各自的字节（父目录那个数本来就含着它下面的子目录）。
private func pathSizes(of items: [CacheItem]) -> [(path: String, bytes: Int64)] {
    items.flatMap { $0.pathSizes.map { (path: $0.key, bytes: $0.value) } }
}

/// 「Xcode 模拟器设备」那一行背后那摞台子在哪；不是这一条就返回 nil。
///
/// 整页只有这一条要逐台摊开：它的字节集中在**哪几台**上，而别处一条缓存目录摊开
/// 只会看到几百个不相干的文件名——那一列不承载任何决定。
private func simulatorDevicesDir(_ item: CacheItem) -> URL? {
    item.resolvedPaths.first { $0.lastPathComponent == "Devices" && $0.path.contains("CoreSimulator") }
}

/// 摊开那一行时逐台列模拟器：设备名 · 系统 · 占盘 · 上次启动。
///
/// 只在行真被摊开时才量（`.task` 跟着视图生死，收起行就掐掉这一趟）：26 台各走一遍
/// 子树是这一页最慢的一件事，不该为「也许有人会点开」在页面进来时先付掉。
///
/// 这一格只列不删：整条「模拟器设备」本来就在「留意」档，勾选框在行首那一级，
/// 台子级的一键删除要另加一套选中状态，等有人真要按台清时再做。
struct SimDeviceRows: View {
    @Environment(\.theme) private var theme
    var dir: URL
    @State private var rows: [SimDevice]? = nil

    var body: some View {
        Group {
            if rows == nil {
                ExplainLine(key: L("逐台看"), value: L("正在一台一台量，稍等…"))
            } else {
                ForEach(rows ?? []) { d in row(d) }
            }
        }
        .task { rows = await scanSimulators(under: dir) }
    }

    /// 一台一行，三格定宽。这里不能套 `ExplainLine`：它的键列按内容走宽，
    /// 26 台摊开就是 26 个不同的落点，那堆体积数字对不齐，也就比不出大小。
    private func row(_ d: SimDevice) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(d.os.isEmpty ? d.name : "\(d.name) · \(d.os)")
                .font(theme.bodyFont(.caption).weight(.semibold))
                .foregroundStyle(theme.palette.inkTertiary)
                .lineLimit(1)
                .frame(width: 236, alignment: .leading)
            Text(human(d.size))
                .font(theme.bodyFont(.caption).monospacedDigit())
                .foregroundStyle(theme.palette.inkSecondary)
                .frame(width: 74, alignment: .trailing)
            Text(booted(d))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private func booted(_ d: SimDevice) -> String {
        guard let when = d.lastBooted else { return L("从没启动过") }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return LF("上次启动 %@", f.string(from: when))
    }
}

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class CachesModel: ObservableObject {
    /// 这台只管知识库里的那几组（见 `CachesPage`）。
    let groupKeys: Set<String>
    init(groupKeys: Set<String> = ["general", "cn_app"]) { self.groupKeys = groupKeys }

    @Published var items: [CacheItem] = []
    @Published var scanning = false
    @Published private(set) var started = false
    /// 现场读数：这一页慢在逐个缓存目录量体积，27 条能走一两分钟。
    private(set) var progress = ScanProgress()
    private var task: Task<Void, Never>? = nil

    var selected: [CacheItem] { items.filter { $0.selected && $0.size != nil } }

    /// 勾了的这些条目**实际**占多少：路径互相套着的只数最外面那层。
    ///
    /// 按条目各自的 `size` 相加会虚高 —— 演示树上全选打印过 38.6 GB，
    /// 而真实能腾出的是 33.1 GB，差的 5.5 GB 全是同一份字节被数了两遍。
    var selectedBytes: Int64 { contentsUnionSize(pathSizes(of: selected)) }

    /// 「全选」这一按到底能带走多少，给卡下面那句对账话用。
    var selectableBytes: Int64 { contentsUnionSize(pathSizes(of: openItems)) }

    /// 全选只管「勾得动又不催你自己判」的那批：标「留意」的要用户自己过目，
    /// 一键把它带走等于替用户拍了他该拍的板。体积没量出来的也不能选——
    /// 选了也不知道能腾出多少，确认框里会写成一个假数。
    private var openItems: [CacheItem] { items.filter(cacheLit) }

    var selectAll: SelectAll? {
        let open = openItems
        guard !open.isEmpty else { return nil }
        return SelectAll(allSelected: open.allSatisfy(\.selected),
                         unselectable: items.count - open.count) { on in
            let ids = Set(open.map(\.id))
            for i in self.items.indices where ids.contains(self.items[i].id) {
                self.items[i].selected = on
            }
        }
    }

    /// 有几条目的路径正套在别的条目底下。0 就不说，非 0 必须说：
    /// 那一列相加比底部那个数大，用户第一个怀疑的就是数字是编的。
    var overlapCount: Int {
        let kept = Set(dropNested(pathSizes(of: items).map(\.path)))
        return items.filter { !$0.pathSizes.keys.allSatisfy(kept.contains) }.count
    }

    func load(force: Bool = false) {
        if started && !force { return }
        task?.cancel()
        started = true
        scanning = true
        progress = ScanProgress()
        task = Task {
            let entries = loadSafetyEntries(from: safetyDBURL())
                .filter { groupKeys.contains($0.grp ?? "general") }
            var list: [CacheItem] = []
            for e in entries {
                if Task.isCancelled { break }
                let paths = globExpand(e.path.isEmpty ? "~/.nonexistent-\(UUID().uuidString)" : e.path)
                if paths.isEmpty { continue }   // 没装的 App 不显示
                list.append(CacheItem(entry: e, resolvedPaths: paths))
            }
            // 常规缓存排前面
            list.sort { ($0.groupKey != "general" ? 1 : 0, $0.entry.name) < ($1.groupKey != "general" ? 1 : 0, $1.entry.name) }
            self.items = list
            // 并行统计大小。逐路径记账而不只留一个和：总览那条环形要把同一条目的
            // 几处缓存拆到不同的弧上去归账，只有一个总数就拆不开。
            await withTaskGroup(of: (UUID, [String: DirScan]).self) { group in
                for it in list {
                    group.addTask {
                        var per: [String: DirScan] = [:]
                        for p in it.resolvedPaths {
                            if Task.isCancelled { break }
                            per[p.path] = await pathStat(p, progress: self.progress)
                        }
                        return (it.id, per)
                    }
                }
                for await (id, per) in group {
                    if Task.isCancelled { break }
                    if let i = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[i].pathSizes = per.mapValues(\.bytes)
                        self.items[i].size = per.values.reduce(Int64(0)) { $0 + $1.bytes }
                        self.items[i].files = per.values.reduce(0) { $0 + $1.files }
                        self.items[i].newest = per.values.compactMap(\.newest).max()
                    }
                }
            }
            // 有体积的排前面
            self.items.sort {
                let a = $0.size ?? -1, b = $1.size ?? -1
                if a != b { return a > b }
                return $0.groupKey < $1.groupKey
            }
            if !Task.isCancelled { self.scanning = false }
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
    }
}

struct CachesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: CachesModel
    var page: CachesPage = .app
    @State private var confirmClean = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: page.symbol, title: L(page.titleKey),
                           subtitle: L(page.subtitleKey), variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在翻你的缓存目录，稍等…"), progress: model.progress)
                    } else {
                        Text(LF("%d 项可查", model.items.count))
                    }
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.load(force: true) }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.items.isEmpty {
                ScanSkeleton()
            } else if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: page.symbol, title: L(page.emptyTitleKey),
                           hint: L(page.emptyHintKey))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: measured.count, note: ledgerNote)
                List($model.items) { $item in
                    ItemRow(selected: $item.selected,
                            icon: rowIcon(item.resolvedPaths, "sparkles"),
                            appID: item.entry.app,
                            brand: item.entry.icon,
                            name: L(item.entry.name),
                            sub: cacheRowSub(item, showsGroup: page.showsGroupLabel),
                            sizeText: item.size == nil ? L("统计中…") : (shown[item.id] ?? human(item.size ?? 0)),
                            fraction: Double(item.size ?? 0) / Double(maxSize),
                            badge: ItemBadge(text: item.entry.level == "warn" ? L("留意") : L("安全"),
                                             tone: item.entry.level == "warn" ? .warn : .safe),
                            selectable: (item.size ?? 0) > 0,
                            lit: cacheLit(item),
                            showRule: model.items.first?.id != item.id,
                            preopen: SnapshotMode.expandFirstRow
                                && model.items.first?.id == item.id) {
                        ExplainLine(key: L("这是什么"), value: L(item.entry.what))
                        ExplainLine(key: L("删了会怎样"), value: L(item.entry.whatif))
                        ExplainLine(key: L("怎么恢复"), value: L(item.entry.rec))
                        if let what = contentsLine(item.files, item.newest) {
                            ExplainLine(key: L("内容"), value: what)
                        }
                        if let devDir = simulatorDevicesDir(item) {
                            SimDeviceRows(dir: devDir)
                        }
                        ForEach(item.resolvedPaths, id: \.self) { p in
                            PathLine(path: p.path)
                        }
                    }
                }
                .ledgerCard()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: listedTotal),
                     errorText: errorText, hint: barHint,
                     selection: model.selectAll) { confirmClean = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { model.load() }
        .confirmTrash(isPresented: $confirmClean,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "项"),
                               human(model.selectedBytes, inRulerOf: listedTotal))) {
            clean()
        }
    }

    private var maxSize: Int64 { max(1, model.items.compactMap(\.size).max() ?? 1) }

    /// 量出体积的那些行——「合计」和「这一列」说的是同一批行，没量出来的不算进去。
    /// 算进去会怎样：那一格印的是「统计中…」，加不出数，合计却把它当成 0。
    private var measured: [(id: UUID, bytes: Int64, lit: Bool)] {
        model.items.compactMap { it in
            guard let sz = it.size, sz > 0 else { return nil }
            return (id: it.id, bytes: sz, lit: cacheLit(it))
        }
    }

    private var listedTotal: Int64 { measured.reduce(Int64(0)) { $0 + $1.bytes } }

    private var shown: [UUID: String] {
        sizeColumn(measured.map { (key: $0.id, bytes: $0.bytes) })
    }

    /// 两档：亮着的（动得了）和标「留意」的。`listedSplitOf` 里那堆"不亮"的在这一页
    /// 全是「留意」——体积没量出来的行根本进不了 `measured`，所以不会有第三档。
    private var tiers: [LedgerTier] {
        let sp = listedSplitOf(measured, bytes: { $0.bytes }, lit: { $0.lit })
        return [LedgerTier(label: L("动得了"), bytes: sp.reclaimable, tone: .hot),
                LedgerTier(label: L("留意"), bytes: sp.viewOnly, tone: .warn)]
    }

    private var ledgerNote: String? {
        // 那一列相加会比底部那个数大，而两个数同屏——不说清是哪几条套着，
        // 用户只会认定其中一个在编。
        model.overlapCount > 0
            ? LF("%1$d 条的路径就套在别的条目底下，所以「全选」实际能带走 %2$@，不是这一列相加出来的那个数。",
                 model.overlapCount, human(model.selectableBytes))
            : nil
    }

    private var barHint: String? {
        model.overlapCount > 0
            ? LF("%1$d 条路径套在别的条目底下，合计只数最外面那层", model.overlapCount)
            : L("合计按条目各自的大小相加")
    }

    private func clean() {
        errorText = nil
        var ok = 0
        var errs: [String] = []
        for it in model.selected {
            for p in it.resolvedPaths {
                do {
                    let sz = it.resolvedPaths.count == 1 ? (it.size ?? 0) : fileSize(p)
                    let t = try trashItem(p)
                    store.record(TrashRecord(original: p, inTrash: t,
                                             size: it.resolvedPaths.count == 1 ? (it.size ?? sz) : sz,
                                             displayName: p.lastPathComponent))
                    ok += 1
                } catch {
                    errs.append(failLine(p.lastPathComponent, error))
                }
            }
            if let i = model.items.firstIndex(where: { $0.id == it.id }) {
                model.items[i].selected = false
                // 删完通常就没了：重新解析，消失的标 0
                let left = it.resolvedPaths.filter { FileManager.default.fileExists(atPath: $0.path) }
                model.items[i].resolvedPaths = left
                model.items[i].size = left.isEmpty ? 0 : nil
            }
        }
        if !errs.isEmpty { errorText = errList(errs) }
        store.notice = trashedNotice(ok, "项", failed: errs.count)
    }
}
