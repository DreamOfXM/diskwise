import SwiftUI
import DiskCleanerCore

// ── node_modules：按项目聚合，删了重装回来就行 ──

/// 行首那一格挂的是「这份依赖是谁装的」：npm / pnpm / yarn / bun 各挂自家官方标，
/// 认不出管理器才挂 Node.js——`node_modules` 这个名字本身就足够支持这句话，
/// 所以那一格不会空着，也不会退化成整列一样的通用文件夹。
///
/// 归属 App 那一档在这里天然取不到（项目目录不是任何 App 的沙盒），所以品牌标就是首选，
/// 不是兜底。

/// 恢复这一句跟着真正的管理器走：知道是 pnpm 就别再让他敲 npm install。
private func restoreHint(_ manager: String?) -> String {
    guard let m = manager else {
        return L("在项目目录执行 npm install（或 pnpm/yarn），按 package.json 原样装回")
    }
    return LF("在项目目录执行 %@，按 package.json 原样装回", "\(m) install")
}

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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: NMModel
    @State private var confirm = false
    @State private var err: String? = nil
    /// 删除飞行：起点（勾中的行）与落点（CleanBar 那颗按钮）都在这里面收着。
    @StateObject private var flight = TrashFlightController()

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
                    // 这一页**不挂范围徽章**。别处那几枚（大文件/很久没动/重复）都是跟着用户
                    // 手上那个「整盘 ↔ 用户区」开关走的，徽章说的是**这一刻选了什么**；
                    // 这一页的范围是写死的 `ScanScope.user`（理由见 `findNodeModules`），
                    // 一枚永远只会说同一句话的徽章不是信息，是装饰——而且这一屏就它一个人挂，
                    // 读起来像「这一页另有一个可以调的档却找不到」。
                    // 「这页只看用户区」这件事由别处说：加载那行写的是「翻**项目目录**找
                    // node_modules」，而项目只长在家目录里。
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.items.isEmpty {
                ScanChecklist(progress: model.progress)
            } else if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "shippingbox", title: L("没找到 node_modules"),
                           hint: L("这台机器大概不写前端"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: model.items.count, note: ledgerNote)
                List($model.items) { $it in
                    ItemRow(selected: $it.selected,
                            icon: .path(URL(fileURLWithPath: it.project)),
                            brand: it.manager ?? "nodedotjs",
                            name: URL(fileURLWithPath: it.project).lastPathComponent,
                            sub: nmSub(it),
                            sizeText: shown[it.id] ?? human(it.size),
                            fraction: Double(it.size) / Double(maxSize),
                            badge: it.partial ? ItemBadge(text: L("部分"), tone: .warn) : nil,
                            showRule: model.items.first?.id != it.id) {
                        ExplainLine(key: L("这是什么"), value: L("Node.js 项目的依赖文件夹，只在开发这个项目时用到"))
                        ExplainLine(key: L("删了会怎样"), value: L("这个项目暂时跑不起来；不影响源码与 package.json"))
                        ExplainLine(key: L("怎么恢复"), value: restoreHint(it.manager))
                        PathLine(path: it.project)
                    }
                    // 只有勾上的行才报起点：这一页上百行，全挂 GeometryReader 是白量。
                    .heroAnchorGlobal(TrashFlightController.rowAnchor(it.project),
                                      enabled: it.selected)
                }
                .ledgerCard()
            }

            Spacer(minLength: 0)   // 清理条钉在窗口下沿，见 `CleanBar`

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: model.totalBytes),
                     errorText: err, selection: model.selectAll, flightTarget: true) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onChange(of: flight.anchors) { _ in fireSnapshotFlightIfAsked() }
        // 页刚进来时 `anchors` 只出现过一次（那时还没扫出项目来），光靠它这一次钩子会早退；
        // 行数从 0 变成 N 是「扫完了」的信号，补在这里，钩子才有第二次机会。
        .onChange(of: model.items.count) { _ in fireSnapshotFlightIfAsked() }
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

    /// 这一页只有一档：列出来的每个 `node_modules` 都能重装回来，本工具全都清得动。
    private var tiers: [LedgerTier] {
        [LedgerTier(label: L("本工具能清"), bytes: model.totalBytes, tone: .hot)]
    }

    private var ledgerNote: String? {
        LF("页头那句「共 %@」跟这一列是同一个数——这一页的行全在屏幕上。", human(model.totalBytes))
    }

    /// 副标题只报**有信息量**的那几样。
    ///
    /// 原来每行都印「N 个包」，可那个数数的是项目里有几处 `node_modules`（monorepo 才会大于 1），
    /// 不是依赖包的数量——118 行里 117 行都是「1 个包」，一行重复到底就等于没有信息。
    /// 现在只在真有多处时才说，其余留日期。
    private func nmSub(_ it: NMProject) -> String {
        var parts: [String] = []
        if it.nmCount > 1 { parts.append(cnt(it.nmCount, "个 node_modules")) }
        parts.append(it.date)
        if it.partial { parts.append(L("部分统计")) }
        return parts.joined(separator: " · ")
    }

    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时把这一页的飞行钉住拍一张（见 `TrashFlightController`）。
    private func fireSnapshotFlightIfAsked() {
        let open = Array(model.items.prefix(2))
        guard let first = open.first else { return }
        flight.fireSnapshotIfAsked(candidates: open.map { (key: $0.project, bytes: $0.size) },
                                   selected: first.selected) {
            for p in open.map(\.project) {
                if let i = model.items.firstIndex(where: { $0.project == p }) {
                    model.items[i].selected = true
                }
            }
        }
    }

    private func doClean() {
        err = nil
        let targets = model.selected
        // 起点终点都在清选区**之前**取：行一不勾就不再报锚点，按钮一禁用落点也跟着变。
        flight.launch(rows: targets.map { (key: $0.project, bytes: $0.size) },
                      animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion))
        var ok = 0
        var errs: [String] = []
        // 删项目下的 node_modules（可能多个）
        for it in targets {
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
    /// 现场读数：这一趟要问引擎一把，再逐家量虚拟机磁盘的实占，几秒钟里得说清走到哪儿了。
    private(set) var progress = ScanProgress(counted: .entries)
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
        progress = ScanProgress(counted: .entries)
        let prog = progress
        // 短名在这儿取：Core 不认识 `.strings`，而这一格的短名得跟着界面语言走。
        // 它跟「一行一个运行时」那几格用的词不能撞——引擎那家自己也在运行时之列，
        // 两格都写 `orbstack` 的话，清单就答不出「现在走到的是哪一件活」。
        let engineLabel = L("引擎报的总量")
        task = Task {
            let list = await Task.detached {
                await scanDocker(engineLabel: engineLabel, progress: prog)
            }.value
            if !Task.isCancelled {
                self.items = list
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

/// Core 只给分类标识，措辞全在这里
///
/// 品牌名不翻译：这两家在两种语言里都叫这个名字。认不出是谁家（CLI 不是这两家之一、
/// 或商店版沙盒里问不到）才用那句通用说法。
private func runtimeName(_ r: DockerRuntime?) -> String {
    switch r {
    case .orbstack:      return "OrbStack"
    case .dockerDesktop: return "Docker Desktop"
    case .podman:        return "Podman"
    case .colima:        return "colima"
    case nil:            return L("容器引擎")
    }
}

private func dockerHead(_ it: DockerItem) -> String {
    switch it.kind {
    case .runtime:       return LF("%@ 数据", runtimeName(it.runtime))
    case .dfImages:      return L("镜像 · 合计")
    case .dfContainers:  return L("容器 · 合计")
    case .dfVolumes:     return L("卷 · 合计")
    case .dfCache:       return L("构建缓存 · 合计")
    case .image:         return it.title
    case .danglingImage: return LF("悬空镜像（%@）", it.title)
    case .other:         return LF("%@ · 合计", it.title)
    }
}

private func dockerNote(_ it: DockerItem) -> String {
    let name = runtimeName(it.runtime)
    switch it.kind {
    case .runtime:
        // 磁盘那一行是本页唯一进展式的数，所以它必须自己说清量的是什么。
        guard it.path != nil else {
            return L("这台机器上找不到这一家的数据目录，这一行是引擎报的几段相加")
        }
        return LF("%@ 的镜像、容器、卷都存在一块虚拟机磁盘里；这一行是那块磁盘在这台机器上实际占掉的量", name)
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        return LF("这一段是 %@ 自己报的账，量的是引擎内部的逻辑大小，不是这块盘上另外的字节", name)
    case .image, .danglingImage:
        return LF("%@ 的镜像都躺在那块虚拟机磁盘里", name)
    }
}

/// 行内副标题：运行时那行说自己量的是什么，段报它的组成，明细就地标明它不进展式——
/// 一屏列得下四段却列不下几十行镜像，对账那句在卡底下，滚到中间就看不到了。
private func dockerSub(_ it: DockerItem) -> String {
    switch it.kind {
    case .runtime:
        return it.path != nil ? L("磁盘实占") : L("引擎报的总量")
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        // 「可回收」这三个字在本工具里专指「我们替你搬得走的」，而这一页一项都动不了，
        // 所以引擎报的那个数必须带上它自己的主语——而且主语得是真在跑的那一家。
        var s = LF("共 %1$@ 个，活跃 %2$@ 个", it.total ?? "?", it.active ?? "?")
        guard let can = it.reclaimable, can > 0 else { return s }
        let name = runtimeName(it.runtime)
        if let share = it.reclaimableShare {
            s += LF("，%1$@ 里还能清 %2$@（%3$@）", name,
                    human(can, inRulerOf: it.size), share)
        } else {
            s += LF("，%1$@ 里还能清 %2$@", name, human(can, inRulerOf: it.size))
        }
        return s
    case .image, .danglingImage:
        return L("镜像明细 · 已经算在上面那一段「镜像 · 合计」里")
    }
}

/// 明细行摊开后要说的一句：它的字节不进展式。计算属性，语言切换后才跟着换。
///
/// 不只镜像明细不进展式——`docker system df` 那四段同样不进，它们和磁盘实占那行
/// 说的是同一批字节的两种算法（本机实测：四段相加 38.4 GB，那块磁盘实占 22.8 GB）。
private var dockerDetailNote: String {
    L("这一行不进展式：它是引擎报的账，不是这块盘上另外的字节")
}

/// 行首那一格。运行时那一行挂着数据目录，所以挂得上那一家的真 App 图标；
/// `docker system df` 那几段背后没有路径可对——虚拟盘里没有一个文件给图标服务读——
/// 只能按类别挂符号，那是诚实的写法，不是偷懒的兜底。
private func dockerIcon(_ it: DockerItem) -> RowIcon {
    if let p = it.path { return .path(p) }
    let symbol: String
    switch it.kind {
    case .runtime:                   symbol = "cube"
    case .dfContainers:              symbol = "play.rectangle"
    case .dfVolumes:                 symbol = "externaldrive"
    case .dfCache:                   symbol = "bolt.horizontal"
    case .dfImages, .image, .danglingImage: symbol = "shippingbox"
    case .other:                     symbol = "circle.grid.cross"
    }
    return .symbol(symbol)
}

private func dockerHowTo(_ it: DockerItem) -> String {
    let name = runtimeName(it.runtime)
    switch it.kind {
    case .runtime:
        guard it.path != nil else { return L("本工具不代删；在跑起来的那一家里清") }
        switch it.runtime {
        // 「删完会自动收缩」不是安慰话，是 OrbStack 自家 README 里写的机制。
        case .orbstack: return L("在 OrbStack 里清：它的 docker 命令是通的（docker system prune -a 删不用的镜像与构建缓存），删完那块磁盘会自动收缩")
        case .colima:   return L("colima 的删法是删掉整个虚拟机（colima delete）；本工具不代删")
        case .podman:   return L("用 podman 自己的命令清（podman system prune）；本工具不代删")
        default:        return LF("打开 %@ 对应页面删除；本工具不代删（虚拟盘内无独立路径）", name)
        }
    case .image, .danglingImage:
        return LF("在 %@ 里删这个镜像（命令行是 docker rmi）", name)
    case .dfImages, .dfContainers, .dfVolumes, .dfCache, .other:
        return LF("打开 %@ 对应页面删除；本工具不代删（虚拟盘内无独立路径）", name)
    }
}


struct DockerView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var model: DockerModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "cube", title: L("Docker 占用"),
                           subtitle: L("只看不删——各家容器的删法不一样，展开那一行看指路"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在盘点 Docker 占用…"))
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
                ScanChecklist(progress: model.progress)
            } else if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "cube", title: L("没找到容器运行时"),
                           hint: L("这台机器上没有 Docker Desktop、OrbStack、Podman、colima 的数据目录"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers,
                           rows: model.items.filter(\.countsInTotal).count,
                           note: ledgerNote)
                List(model.items) { it in
                    ItemRow(selected: .constant(false),
                            icon: dockerIcon(it),
                            appID: it.runtime?.bundleID,
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
                        if let p = it.path { PathLine(path: p.path) }
                    }
                }
                .ledgerCard()
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !model.started { model.scan() } }
    }

    private var maxSize: Int64 { max(1, model.items.map(\.size).max() ?? 1) }

    /// 进加式的那几行（一行一个运行时）**当场要加得起来**：页头那个数就是它们的和，
    /// 各行独立四舍五入会飘出 41.3 而页头写着 41.2（2026-09-26 实拍）。引擎报的账和
    /// 镜像明细不进加式，只跟着同一把尺，保证能和上面那些行横向比大小。
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

    /// 这一页一个字节的决定都不替用户做，所以只有「本工具不碰」这一档，整块条子是灰的。
    private var tiers: [LedgerTier] {
        [LedgerTier(label: L("本工具不碰"), bytes: model.totalBytes, tone: .cold)]
    }

    /// 原来这句还要重述一遍「N 段相加 X 就是页头那个数」——那是 `ListNote` 唯一的活，
    /// 现在这件事由上面那块账替它说，同屏留两遍同样的两个数就是两本账。
    private var ledgerNote: String? {
        var s = L("这一页动不了，所以整列一个灯色都不上。")
        if model.detailCount > 0 {
            s += LF("下面 %d 行是引擎自己报的口径，和上面那一行量的是同一块磁盘，不单独加一次。",
                    model.detailCount)
        }
        return s
    }
}

