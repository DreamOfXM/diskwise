import SwiftUI
import DiskCleanerCore

// ── node_modules：按项目聚合，删了重装回来就行 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class NMModel: ObservableObject {
    @Published var items: [NMProject] = []
    @Published var scanning = false
    @Published private(set) var started = false
    /// 现场读数。这一趟数的是**目录项**不是文件：整棵家目录翻下来一个 node_modules
    /// 都可能没撞上，但「正在看 ~/Projects/foo/src」那句是真的在往前走的证据。
    private(set) var progress = ScanProgress(counted: .entries)
    private var task: Task<Void, Never>? = nil

    var selected: [NMProject] { items.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    var selectAll: SelectAll? {
        guard !items.isEmpty else { return nil }
        return SelectAll(allSelected: items.allSatisfy(\.selected), unselectable: 0) { on in
            for i in self.items.indices { self.items[i].selected = on }
        }
    }

    func scan() {
        task?.cancel()
        scanning = true
        started = true
        items = []
        progress = ScanProgress(counted: .entries)
        task = Task {
            let list = await findNodeModules(progress: self.progress)
            if !Task.isCancelled {
                self.items = list
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

struct NMView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: NMModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "shippingbox", title: L("node_modules"),
                           subtitle: L("依赖能重装，空间先拿回"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在翻项目目录找 node_modules…"), progress: model.progress)
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(model.items.count, "个项目"), human(model.totalBytes)))
                    }
                    // 这页不吃「整盘」开关（理由见 findNodeModules），那就把范围写在脸上，
                    // 别让「全盘找 node_modules」这句提示冒充整盘覆盖。
                    ThemeBadge(text: LF("范围：%@", ScanScope.user.uiName),
                               tone: .neutral, symbol: "scope")
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.items.isEmpty {
                ScanSkeleton()
            } else if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "shippingbox", title: L("没找到 node_modules"),
                           hint: L("这台机器大概不写前端"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: model.items.count, note: ledgerNote)
                List($model.items) { $it in
                    ItemRow(selected: $it.selected,
                            icon: .path(URL(fileURLWithPath: it.project)),
                            name: URL(fileURLWithPath: it.project).lastPathComponent,
                            sub: nmSub(it),
                            sizeText: shown[it.id] ?? human(it.size),
                            fraction: Double(it.size) / Double(maxSize),
                            badge: it.partial ? ItemBadge(text: L("部分"), tone: .warn) : nil,
                            showRule: model.items.first?.id != it.id) {
                        ExplainLine(key: L("这是什么"), value: L("Node.js 项目的依赖文件夹，只在开发这个项目时用到"))
                        ExplainLine(key: L("删了会怎样"), value: L("这个项目暂时跑不起来；不影响源码与 package.json"))
                        ExplainLine(key: L("怎么恢复"), value: L("在项目目录执行 npm install（或 pnpm/yarn），按 package.json 原样装回"))
                        PathLine(path: it.project)
                    }
                }
                .ledgerCard()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: model.totalBytes),
                     errorText: err, selection: model.selectAll) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !model.started { model.scan() } }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@的依赖（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "个项目"),
                               human(model.selectedBytes, inRulerOf: model.totalBytes))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.items.map(\.size).max() ?? 1) }

    /// 整列统一到页头那个总数的单位再分摊：这几行**印出来**加起来就是页头那句。
    private var shown: [UUID: String] {
        sizeColumn(model.items.map { (key: $0.id, bytes: $0.size) })
    }

    /// 这一页只有一档：列出来的每个 `node_modules` 都能重装回来，全动得了。
    private var tiers: [LedgerTier] {
        [LedgerTier(label: L("动得了"), bytes: model.totalBytes, tone: .hot)]
    }

    private var ledgerNote: String? {
        LF("页头那句「共 %@」跟这一列是同一个数——这一页的行全在屏幕上。", human(model.totalBytes))
    }

    private func nmSub(_ it: NMProject) -> String {
        [cnt(it.nmCount, "个包"), it.date, it.partial ? L("部分统计") : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        // 删项目下的 node_modules（可能多个）
        for it in model.selected {
            let projName = URL(fileURLWithPath: it.project).lastPathComponent
            let nmURL = URL(fileURLWithPath: it.project).appendingPathComponent("node_modules")
            let targets = (try? FileManager.default.contentsOfDirectory(atPath: it.project)
                .filter { $0 == "node_modules" }
                .map { URL(fileURLWithPath: it.project).appendingPathComponent($0) }) ?? [nmURL]
            for t in targets {
                guard FileManager.default.fileExists(atPath: t.path) else { continue }
                do {
                    let dst = try trashItem(t)
                    store.record(TrashRecord(original: t, inTrash: dst, size: it.size,
                                             displayName: "\(projName)/node_modules"))
                    ok += 1
                } catch { errs.append(failLine(it.project, error)) }
            }
        }
        // 就地收尾：整个依赖目录都没了的项目从列表里消失，不必重扫全盘
        model.items.removeAll { !FileManager.default.fileExists(
            atPath: ($0.project as NSString).appendingPathComponent("node_modules")) }
        for i in model.items.indices { model.items[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个 node_modules", failed: errs.count)
    }
}

// ── Docker：只读明细，不代删，只指路 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class DockerModel: ObservableObject {
    @Published var items: [DockerItem] = []
    @Published var scanning = false
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    /// 页头那个「共 X」：只加**段**，不加段下面的明细。
    ///
    /// 原来这里是 `items.reduce`，而 `items` 里既装着 `docker system df` 的四段合计、
    /// 又装着它们各自的镜像明细（`ScanJobs.swift` 把 `imgItems` 追加进了同一个数组），
    /// 于是同一份字节数了两遍，实拍拍出过「共 56.5 GB」而真实占用是 41.3 GB。
    /// 明细照样列出来（那是这一页唯一能报出名字的东西），只是不进加法。
    var totalBytes: Int64 { items.filter(\.countsInTotal).reduce(0) { $0 + $1.size } }
    var detailCount: Int { items.filter { !$0.countsInTotal }.count }

    func scan() {
        task?.cancel()
        scanning = true
        started = true
        items = []
        task = Task {
            let list = await Task.detached { await scanDocker() }.value
            if !Task.isCancelled {
                self.items = list
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

/// Core 只给分类标识，措辞全在这里
private func dockerHead(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages:      return L("镜像 · 合计")
    case .dfContainers:  return L("容器 · 合计")
    case .dfVolumes:     return L("卷 · 合计")
    case .dfCache:       return L("构建缓存 · 合计")
    case .image:         return it.title
    case .danglingImage: return LF("悬空镜像（%@）", it.title)
    case .rawDir:        return LF("Docker 数据 · %@", it.title)
    case .other:         return LF("%@ · 合计", it.title)
    }
}

private func dockerNote(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        return L("这一段是 Docker 自己报的总量，明细列在它下面")
    case .image, .danglingImage:
        return L("镜像存在 Docker 的虚拟盘里")
    case .rawDir:
        return L("Docker 未运行，只能按子目录粗分")
    }
}

/// 行内副标题：段报它的组成，明细就地标明它不进展式——
/// 一屏列得下四段却列不下几十行镜像，对账那句在卡底下，滚到中间就看不到了。
private func dockerSub(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        // 「可回收」这三个字在本工具里专指「我们替你搬得走的」，而这一页一项都动不了，
        // 所以 Docker 报的那个数必须带上它自己的主语。
        var s = LF("共 %1$@ 个，活跃 %2$@ 个", it.total ?? "?", it.active ?? "?")
        guard let can = it.reclaimable, can > 0 else { return s }
        if let share = it.reclaimableShare {
            s += LF("，Docker Desktop 里还能清 %1$@（%2$@）",
                    human(can, inRulerOf: it.size), share)
        } else {
            s += LF("，Docker Desktop 里还能清 %@", human(can, inRulerOf: it.size))
        }
        return s
    case .image, .danglingImage:
        return L("镜像明细 · 已经算在上面那一段「镜像 · 合计」里")
    case .rawDir:
        return L("按子目录粗分")
    }
}

/// 明细行摊开后要说的一句：它的字节不进展式。计算属性，语言切换后才跟着换。
///
/// 只在明细行上出现——段自己就是被加的那一项，跟它说「不重复相加」是废话。
private var dockerDetailNote: String {
    L("这一行已经算在上面那一段「镜像 · 合计」里，不重复相加")
}

/// 行首那一格。回退模式（Docker 没在跑）量的是真目录，挂访达里那个文件夹的图标；
/// `docker system df` 那几段背后没有路径可对——虚拟盘里没有一个文件给图标服务读——
/// 所以只能按类别挂符号，那是诚实的写法，不是偷懒的兜底。
private func dockerIcon(_ it: DockerItem) -> RowIcon {
    if let p = it.path { return .path(p) }
    let symbol: String
    switch it.kind {
    case .dfContainers:                symbol = "play.rectangle"
    case .dfVolumes:                   symbol = "externaldrive"
    case .dfCache:                     symbol = "bolt.horizontal"
    case .dfImages, .image, .danglingImage: symbol = "shippingbox"
    case .other:                       symbol = "circle.grid.cross"
    case .rawDir:                      symbol = "folder"
    }
    return .symbol(symbol)
}

private func dockerHowTo(_ it: DockerItem) -> String {
    switch it.kind {
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        return L("打开 Docker Desktop 对应页面删除；本工具不代删（虚拟盘内无独立路径）")
    case .image, .danglingImage:
        return L("Docker Desktop → Images 里删除")
    case .rawDir:
        return L("更稳妥：在 Docker Desktop 里清理；这里删等于清空该子目录")
    }
}

struct DockerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: DockerModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "cube", title: L("Docker 占用"),
                           subtitle: L("只看不删——照指路去 Docker Desktop 里动手"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在问 Docker 都吃了啥…"))
                    } else {
                        Text(LF("共 %@", human(model.totalBytes)))
                    }
                    ThemeBadge(text: L("本页不设删除键"), tone: .neutral)
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.items.isEmpty {
                ScanSkeleton()
            } else if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "cube", title: L("没发现 Docker 数据"),
                           hint: L("没装 Docker Desktop 就不会有"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers,
                           rows: model.items.filter(\.countsInTotal).count,
                           note: ledgerNote)
                List(model.items) { it in
                    ItemRow(selected: .constant(false),
                            icon: dockerIcon(it),
                            name: dockerHead(it),
                            sub: dockerSub(it),
                            sizeText: shown[it.id] ?? human(it.size),
                            fraction: Double(it.size) / Double(maxSize),
                            selectable: false,
                            showRule: model.items.first?.id != it.id) {
                        ExplainLine(key: L("这是什么"), value: dockerNote(it))
                        if !it.countsInTotal {
                            ExplainLine(key: L("这一行的账"), value: dockerDetailNote)
                        }
                        ExplainLine(key: L("怎么清"), value: dockerHowTo(it))
                    }
                }
                .ledgerCard()
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !model.started { model.scan() } }
    }

    private var maxSize: Int64 { max(1, model.items.map(\.size).max() ?? 1) }

    /// 段那几行**当场要加得起来**：页头那个数就是它们四个的和，各自四舍五入会飘出
    /// 41.3 而页头写着 41.2（2026-09-26 实拍）。明细行不进加式，只跟着同一把尺，
    /// 保证能和段横向比大小。
    private var shown: [UUID: String] {
        var out: [UUID: String] = [:]
        let sections = model.items.filter(\.countsInTotal)
        for (it, s) in zip(sections, addableHumanColumn(sections.map(\.size),
                                                        total: model.totalBytes)) {
            out[it.id] = s
        }
        for it in model.items where !it.countsInTotal {
            out[it.id] = human(it.size, inRulerOf: model.totalBytes)
        }
        return out
    }

    /// 这一页一个字节的决定都不替用户做，所以只有「只能看」这一档，整块条子是灰的。
    private var tiers: [LedgerTier] {
        [LedgerTier(label: L("只能看"), bytes: model.totalBytes, tone: .cold)]
    }

    /// 原来这句还要重述一遍「N 段相加 X 就是页头那个数」——那是 `ListNote` 唯一的活，
    /// 现在这件事由上面那块账替它说，同屏留两遍同样的两个数就是两本账。
    private var ledgerNote: String? {
        var s = L("这一页动不了，所以整列一个灯色都不上。")
        if model.detailCount > 0 {
            s += LF("下面 %d 行是明细，已经躺在上面那几段里面，不单独加一次。", model.detailCount)
        }
        return s
    }
}

