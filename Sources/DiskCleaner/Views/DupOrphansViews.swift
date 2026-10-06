import SwiftUI
import DiskCleanerCore

// ── 重复文件：每组保留日期最新的一个，其余可删 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class DupModel: ObservableObject {
    @Published var groups: [DupGroup] = []
    /// 被受管环境摘走的副本，按组归堆。页顶那句「不参与比对」点开的就是这份名单：
    /// 整组撤下的那些不列进主列表，但必须看得见，否则像偷偷藏东西。
    @Published private(set) var envGroups: [EnvDupGroup] = []
    @Published var scanning = false
    @Published var phase = ""
    /// 现场读数：这一页先遍历再哈希，遍历那几分钟里唯一能证明「在动」的就是它。
    private(set) var progress = ScanProgress()
    @Published var minMB = 20
    @Published var selection: Set<String> = []   // 选中待删的文件 path
    /// 本轮实际用的范围，页头贴标签用
    @Published private(set) var scope: ScanScope = .user
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    var waste: Int64 { groups.reduce(0) { $0 + $1.waste } }
    var envBytes: Int64 { envGroups.reduce(0) { $0 + $1.bytes } }
    var selectedCount: Int { selection.count }

    func scan(scope: ScanScope) {
        task?.cancel()
        scanning = true
        started = true
        self.scope = scope
        groups = []
        envGroups = []
        selection = []
        let minB = Int64(minMB) * MB
        let targets = defaultScanDirs(scope: scope)
        task = Task {
            self.phase = L("遍历文件…")
            self.progress = ScanProgress()
            // 只留下我们删得动的：整盘扫描会走进 /Library、/opt 这些 root 地盘，
            // 那些重复归包管理器管，列出来只会让用户去点一个注定失败的勾选框。
            let files = await walkFiles(dirs: targets, minSize: minB,
                                        skipNames: ["node_modules", ".git", "Caches"],
                                        progress: self.progress)
                .rows.filter(\.deletable)
            if Task.isCancelled { return }
            self.phase = LF("比对内容（%@ 个候选）…", String(files.count))
            // 哈希是同步重活，扔后台线程做
            let r = await Task.detached { findDupGroups(files) }.value
            if !Task.isCancelled {
                self.groups = r.groups
                self.envGroups = r.excluded
                self.scanning = false
                self.phase = ""
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }

    /// 「全选」只管多余的那几份，每组保留的那一份算在「不在全选范围内」里：
    /// 它列在同一个组里却永远勾不动，不报这个数用户只会以为漏勾了一份。
    /// 反向也必须能按——这一页动辄几百项，一次勾错没有一键撤回路可走不通。
    var selectAll: SelectAll? {
        let extras = groups.flatMap { $0.files.dropFirst() }
        guard !extras.isEmpty else { return nil }
        return SelectAll(allSelected: extras.allSatisfy { selection.contains($0.path) },
                         unselectable: groups.count) { on in
            self.selection = on ? Set(extras.map(\.path)) : []
        }
    }
}

struct DupView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: DupModel
    @State private var confirm = false
    @State private var err: String? = nil
    @State private var envList = false
    /// 删除飞行：起点（勾中的组）与落点（CleanBar 那颗按钮）都在这里面收着。
    @StateObject private var flight = TrashFlightController()

    var selectedBytes: Int64 {
        var sizeByPath: [String: Int64] = [:]
        for g in model.groups {
            for u in g.files { sizeByPath[u.path] = g.size }
        }
        return model.selection.reduce(0) { $0 + (sizeByPath[$1] ?? 0) }
    }

    /// 全页最狠一组的浪费量，给组间比例条当分母
    private var maxWaste: Int64 { max(1, model.groups.map(\.waste).max() ?? 1) }

    /// 整列统一到页头「可收回约 X」那个单位再分摊：那一列印出来加得起。
    private var shown: [UUID: String] {
        sizeColumn(model.groups.map { (key: $0.id, bytes: $0.waste) })
    }

    /// 这一页只有一档：列出来的每一份都是多出来的副本，本工具都能清。
    /// 每组保留的那份压根没进这一列，所以条子上也不会出现「本工具不碰」那一段。
    private var tiers: [LedgerTier] {
        [LedgerTier(label: L("本工具能清"), bytes: model.waste, tone: .hot)]
    }

    /// 每组保留的那一份也列在组里（第一行、带锁、勾不动），所以这句话要说的是
    /// 「它在哪儿、为什么按不动」，不是「它不在这一列里」。
    private var ledgerNote: String? { L("每组日期最新的那份列在组里第一行，带锁、不给勾。") }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "square.on.square", title: L("重复文件"),
                           subtitle: L("每组日期最新的那份永远保留，动其余的"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: model.phase.isEmpty ? L("正在比对…") : model.phase,
                                       progress: model.progress)
                    } else {
                        Text(LF("发现 %1$@，可收回约 %2$@",
                                cnt(model.groups.count, "组重复"), human(model.waste)))
                    }
                    ThemeBadge(text: LF("范围：%@", model.scope.uiName),
                               tone: .neutral, symbol: "scope")
                    if !model.envGroups.isEmpty {
                        EnvCopiesClause(count: model.envGroups.count) { envList = true }
                    }
                } trailing: {
                    ThemeStepper(label: "≥", unit: "MB", value: $model.minMB,
                                 range: 5...500, step: 5) { model.scan(scope: store.scope) }
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan(scope: store.scope) }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.groups.isEmpty {
                ScanChecklist(progress: model.progress, scope: model.scope.uiName)
            } else if !model.scanning && model.groups.isEmpty {
                EmptyState(symbol: "checklist", title: L("没有重复文件"),
                           hint: LF("%1$@以上的都查过了，调低还能再找些小的，但更慢",
                                    "\(model.minMB) MB"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: model.groups.count, note: ledgerNote)
                List(model.groups) { g in
                    dupRow(g)
                        // 只有整组勾上的行才报起点：这一页几十组，全挂 GeometryReader 是白量。
                        .heroAnchorGlobal(TrashFlightController.rowAnchor(g.id.uuidString),
                                          enabled: groupSelected(g))
                }
                .ledgerCard()
            }

            Spacer(minLength: 0)   // 清理条钉在窗口下沿，见 `CleanBar`

            CleanBar(count: model.selectedCount, bytes: selectedBytes,
                     bytesText: human(selectedBytes, inRulerOf: model.waste),
                     errorText: err, hint: L("每组保留日期最新的那份，勾不上"),
                     selection: model.selectAll, flightTarget: true) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onChange(of: flight.anchors) { _ in fireSnapshotFlightIfAsked() }
        // 页刚进来时 `anchors` 只出现过一次（那时还没比出组来），光靠它这一次钩子会早退；
        // 组数从 0 变成 N 是「比完了」的信号，补在这里，钩子才有第二次机会。
        .onChange(of: model.groups.count) { _ in fireSnapshotFlightIfAsked() }
        .onAppear { if !model.started { model.scan(scope: store.scope) } }
        // 那句只在有副本被摘出去时才在页上，所以这一按也只在它在的时候有效——
        // 拍不出空名单，也就拍不出一张骗人的名单。
        .onChange(of: store.envListPulse) { _ in envList = !model.envGroups.isEmpty }
        .sheet(isPresented: $envList) {
            EnvCopiesSheet(groups: model.envGroups, bytes: model.envBytes)
                .themed(theme)   // 名单跟随当前皮肤，别在弹出来那一刻跳色
        }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@移入废纸篓（每组日期最新的一份永远保留）。",
                               cnt(model.selectedCount, "个多余副本"))) {
            doClean()
        }
    }

    /// 一组重复 = 账本里的一行：整组勾上/取消，展示级那个数是这组能收回多少。
    ///
    /// 原来这一行的展示级数字是一颗「可收回 X」徽章，右侧那一列反倒没有数——
    /// 别的页都在右边报数，只有这一页报在徽章里，一整列比不出大小。
    /// 一组里除保留那份之外**全都**勾上了才算这一行勾上——行上的勾选框和行锚点用的是同一个判据。
    private func groupSelected(_ g: DupGroup) -> Bool {
        let extras = g.files.dropFirst()
        return !extras.isEmpty && extras.allSatisfy { model.selection.contains($0.path) }
    }

    private func dupRow(_ g: DupGroup) -> some View {
        let extras = Array(g.files.dropFirst())
        return ItemRow(
            selected: Binding(
                get: { groupSelected(g) },
                set: { on in
                    let paths = extras.map(\.path)
                    if on { model.selection.formUnion(paths) }
                    else { model.selection.subtract(paths) }
                }),
            icon: rowIcon(g.files.first, "doc.on.doc"),
            name: LF("%1$@ 等 %2$@",
                     g.files.first?.lastPathComponent ?? L("重复组"),
                     cnt(g.files.count, "份")),
            sub: LF("每份 %@", human(g.size)),
            sizeText: shown[g.id] ?? human(g.waste),
            fraction: Double(g.waste) / Double(maxWaste),
            badge: nil,
            lit: true,
            showRule: model.groups.first?.id != g.id,
            preopen: SnapshotMode.expandFirstRow && model.groups.first?.id == g.id) {
            ForEach(Array(g.files.enumerated()), id: \.element.path) { idx, url in
                DupFileRow(url: url, isKept: idx == 0, selection: $model.selection)
            }
        }
    }
    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时把这一页的飞行钉住拍一张（见 `TrashFlightController`）。
    /// 候选组取有多余副本的前两组，勾的是那几份多余副本（保留那份从来不给勾）。
    private func fireSnapshotFlightIfAsked() {
        let open = Array(model.groups.filter { $0.files.count > 1 }.prefix(2))
        guard let first = open.first else { return }
        flight.fireSnapshotIfAsked(candidates: open.map { (key: $0.id.uuidString, bytes: $0.waste) },
                                   selected: groupSelected(first)) {
            for g in open { model.selection.formUnion(g.files.dropFirst().map(\.path)) }
        }
    }

    private func doClean() {
        err = nil
        // 一组一行：起点是那一组此刻在屏幕上的位置，体积是这一组要带走的那几份之和。
        var perGroup: [(key: String, bytes: Int64)] = []
        for g in model.groups {
            let n = g.files.dropFirst().reduce(Int64(0)) {
                $0 + (model.selection.contains($1.path) ? g.size : 0)
            }
            if n > 0 { perGroup.append((key: g.id.uuidString, bytes: n)) }
        }
        // 起点终点都在清选区**之前**取：行一不勾就不再报锚点，按钮一禁用落点也跟着变。
        flight.launch(rows: perGroup,
                      animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion))
        var ok = 0
        var errs: [String] = []
        for path in model.selection {
            let u = URL(fileURLWithPath: path)
            let sz = fileSize(u)
            do {
                let t = try trashItem(u)
                store.record(TrashRecord(original: u, inTrash: t, size: sz, displayName: u.lastPathComponent))
                ok += 1
            } catch { errs.append(failLine(u.lastPathComponent, error)) }
        }
        model.selection = []
        // 副本删完的组就地消失；要新结果点重新扫描，不必每次删除都重扫整库
        model.groups.removeAll { $0.files.dropFirst().allSatisfy { u in
            !FileManager.default.fileExists(atPath: u.path)
        } }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个副本", failed: errs.count)
    }
}

// MARK: - 重复组里的一份文件

/// 组内明细行，坐在 `ItemRow` 展开区里（左边距由那一层给，这里不再叠）。
///
/// 保留那份**没有勾选框**：位置留着、框不画，别的行才能对齐成一条竖线。
private struct DupFileRow: View {
    @Environment(\.theme) private var theme
    var url: URL
    var isKept: Bool
    @Binding var selection: Set<String>

    var body: some View {
        HStack(spacing: 10) {
            if isKept {
                ThemeBadge(text: L("保留"), tone: .safe, symbol: "lock.fill")
                    .frame(minWidth: 62, alignment: .leading)
                    .help(L("每组留下日期最新的那一份：备份、导出这类目录是按日期递增的，留最旧的等于把最新那份删了"))
            } else {
                Toggle("", isOn: Binding(
                    get: { selection.contains(url.path) },
                    set: { on in
                        if on { selection.insert(url.path) } else { selection.remove(url.path) }
                    }
                ))
                .toggleStyle(ThemeCheckStyle(side: 16))
                .labelsHidden()
                .frame(minWidth: 62, alignment: .leading)
            }
            Text(displayPath(url))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(isKept ? theme.palette.inkTertiary : theme.palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            // 日期摆出来，「留的是哪一份」才看得见：这一页原先一个日期都没有，
            // 保留规则只能靠猜，用户看到留了最旧那份时以为我们挑错了。
            Text(shortDate(fileDate(url)))
                .font(theme.numeric(.caption2))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

// ── 各环境自己的副本：不进比对，但必须看得见 ──

/// 页顶那句「另有 N 组…不参与比对」。整组撤下的副本要在这一页留一个入口，
/// 不然用户看到的是一次凭空少掉的组数，像我们偷偷不算。
private struct EnvCopiesClause: View {
    @Environment(\.theme) private var theme
    var count: Int
    var action: () -> Void

    @State private var hovering = false
    @State private var hand = false

    private var fg: Color {
        hovering ? SweepRing.lamp(theme.palette.tint) : theme.palette.inkTertiary
    }

    var body: some View {
        Button(action: action) {
            Text(LF("另有 %1$@ 是各环境自己的副本，不参与比对", cnt(count, "组")))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(fg)
                .underline(hovering, color: fg)
                .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(.plain)
        .onHover {
            hovering = $0
            guard hand != $0 else { return }
            hand = $0
            ($0 ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .accessibilityAddTraits(.isLink)
    }
}

/// 「不参与比对的组」名单。只讲三件事：哪一组、住在几个环境里、想回收该动谁。
///
/// 这里不画勾选框：这一屏一个字节都轮不到这一页来删，摆个勾不上的框只会制造挫败。
/// 每份的路径仍给 `PathLine`，要点到访达里看清楚随时能去。
private struct EnvCopiesSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var groups: [EnvDupGroup]
    var bytes: Int64

    private var maxBytes: Int64 { max(1, groups.map(\.bytes).max() ?? 1) }

    private var shown: [UUID: String] {
        sizeColumn(groups.map { (key: $0.id, bytes: $0.bytes) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(L("不参与比对的组"))
                    .font(theme.display(.title3))
                    .tracking(theme.titleTracking)
                    .foregroundStyle(theme.palette.ink)
                Text(LF("%1$@ · 共 %2$@", cnt(groups.count, "组"), human(bytes)))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .monospacedDigit()
                Spacer(minLength: 12)
                ThemeButton(kind: .ghost, title: L("关闭")) { dismiss() }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            List(groups) { g in
                ItemRow(selected: .constant(false),
                        icon: .path(g.files.first ?? URL(fileURLWithPath: "/")),
                        name: rowName(g),
                        sub: LF("每份 %1$@ · 住在 %2$@",
                                human(g.size), cnt(g.envs.count, "个环境")),
                        sizeText: shown[g.id] ?? human(g.bytes),
                        fraction: Double(g.bytes) / Double(maxBytes),
                        selectable: false,
                        lit: false,
                        showRule: groups.first?.id != g.id,
                        preopen: SnapshotMode.expandFirstRow && groups.first?.id == g.id) {
                            ExplainLine(key: L("住在哪个环境"),
                                        value: g.envs.map { displayPath(URL(fileURLWithPath: $0)) }
                                            .joined(separator: " · "))
                            ForEach(g.files, id: \.path) { u in
                                PathLine(path: u.path)
                            }
                        }
            }
            .ledgerCard()

            ListNote(text: L("这些副本各自住在某个环境里。删一份，那个环境就缺一块；卸掉那个环境，整块一起回收。"))
        }
        .frame(width: 780, height: 520)
        .background(theme.palette.paper)
    }

    /// 只有一份被摘出去时不说「等 1 份」：那个「等」字承诺了后面还有，而这里没有。
    private func rowName(_ g: EnvDupGroup) -> String {
        let first = g.files.first?.lastPathComponent ?? L("重复组")
        return g.files.count > 1 ? LF("%1$@ 等 %2$@", first, cnt(g.files.count, "份")) : first
    }
}

// ── 卸载残留：App 没了、数据还在 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class OrphansModel: ObservableObject {
    @Published var items: [OrphanItem] = []
    @Published var scanning = false
    @Published var appCount = 0
    @Published private(set) var started = false
    /// 现场读数：这页慢在「逐个残留目录量体积」那一步，几分钟里没别的可看。
    private(set) var progress = ScanProgress()
    private var task: Task<Void, Never>? = nil

    var selected: [OrphanItem] { items.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalBytes: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }

    /// 全选只扫「删了没影响」那批：这页的立脚点是宁可漏报不可误删，标「删了会丢数据」的意思是
    /// 「得你自己判」，一键把它带走等于把这页存在的理由按掉了。
    var selectAll: SelectAll? {
        let open = items.filter { $0.level != "warn" }
        guard !open.isEmpty else { return nil }
        return SelectAll(allSelected: open.allSatisfy(\.selected),
                         unselectable: items.count - open.count) { on in
            for i in self.items.indices where self.items[i].level != "warn" {
                self.items[i].selected = on
            }
        }
    }

    func scan() {
        task?.cancel()
        scanning = true
        started = true
        items = []
        progress = ScanProgress()
        task = Task {
            let (list, apps) = await scanOrphans(progress: self.progress)
            if !Task.isCancelled {
                self.items = list
                self.appCount = apps
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

/// 残留条目：Core 只给「哪个应用、留在哪、稳不稳」，句子在这拼
private func orphanWhat(_ it: OrphanItem) -> String {
    LF("已卸载应用「%1$@」留在 %2$@ 里的数据", L(it.guess), it.loc)
}

private func orphanRisk(_ it: OrphanItem) -> String {
    it.level == "warn"
        ? L("重装这个应用时不会带回到这些配置；其他应用不受影响")
        : L("基本没影响：应用下次需要时会自己重建")
}

struct OrphansView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: OrphansModel
    @State private var confirm = false
    @State private var err: String? = nil
    /// 删除飞行：起点（勾中的行）与落点（CleanBar 那颗按钮）都在这里面收着。
    @StateObject private var flight = TrashFlightController()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "app.badge", title: L("卸载残留"),
                           subtitle: L("App 卸载了，数据没带走——按已装应用逐一对过"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在盘点已装应用、对孤儿…"),
                                   progress: model.progress)
                    } else {
                        Text(LF("对过 %1$@，%2$@，共 %3$@",
                                cnt(model.appCount, "个应用"),
                                cnt(model.items.count, "处可疑"),
                                human(model.totalBytes)))
                    }
                    ThemeBadge(text: L("宁可漏报，不可误删"), tone: .neutral)
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
                EmptyState(symbol: "app.badge.checkmark", title: L("没有卸载残留"),
                           hint: L("每个犄角旮旯都对得上号，挺干净"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: model.items.count, note: ledgerNote)
                List($model.items) { $it in
                    ItemRow(selected: $it.selected,
                            icon: .path(it.path),
                            name: it.name,
                            sub: it.loc,
                            sizeText: shown[it.id] ?? human(it.size ?? 0),
                            fraction: Double(it.size ?? 0) / Double(maxSize),
                            badge: verdictBadge(it.level == "warn" ? .risky : .safe),
                            lit: it.level != "warn",
                            showRule: model.items.first?.id != it.id,
                            preopen: SnapshotMode.expandFirstRow
                                && model.items.first?.id == it.id) {
                        ExplainLine(key: L("这是什么"), value: orphanWhat(it))
                        ExplainLine(key: L("删了会怎样"), value: orphanRisk(it))
                        ExplainLine(key: L("怎么恢复"), value: L("从废纸篓还原，或重装该应用"))
                        if let what = contentsLine(it.files, it.newest) {
                            ExplainLine(key: L("内容"), value: what)
                        }
                        PathLine(path: it.path.path)
                    }
                    // 只有勾上的行才报起点：这一页几十处，全挂 GeometryReader 是白量。
                    .heroAnchorGlobal(TrashFlightController.rowAnchor(it.path.path),
                                      enabled: it.selected)
                }
                .ledgerCard()
            }

            Spacer(minLength: 0)   // 清理条钉在窗口下沿，见 `CleanBar`

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: listedTotal),
                     errorText: err, hint: L("删了会丢数据的那几项本来就不给全选"),
                     selection: model.selectAll, flightTarget: true) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onChange(of: flight.anchors) { _ in fireSnapshotFlightIfAsked() }
        // 页刚进来时 `anchors` 只出现过一次（那时还没扫出残留来），光靠它这一次钩子会早退；
        // 行数从 0 变成 N 是「盘完了」的信号，补在这里，钩子才有第二次机会。
        .onChange(of: model.items.count) { _ in fireSnapshotFlightIfAsked() }
        .onAppear { if !model.started { model.scan() } }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "处残留"),
                               human(model.selectedBytes, inRulerOf: listedTotal))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.items.compactMap(\.size).max() ?? 1) }

    /// 这一页的账：页头那个「共 X」与整列同一个单位，印出来的行相加就是它。
    private var listedTotal: Int64 { model.items.reduce(0) { $0 + ($1.size ?? 0) } }

    private var shown: [UUID: String] {
        sizeColumn(model.items.map { (key: $0.id, bytes: $0.size ?? 0) })
    }

    /// 「删了会丢数据」那档照样能手动勾着删，所以按「本工具全都清得动」记账；它的不同只体现在
    /// 「不给全选」和那一行的灯色上，不是一堆删不掉的字节。
    private var tiers: [LedgerTier] {
        [LedgerTier(label: L("本工具能清"), bytes: listedTotal, tone: .hot)]
    }

    private var ledgerNote: String? { L("删了会丢数据的那几项不在全选范围内，得逐条自己判。") }

    /// 截图钩子：`DISKWISE_FLIGHT=<0~1>` 时把这一页的飞行钉住拍一张（见 `TrashFlightController`）。
    /// 候选行取「删了没影响」那档的前两处——钩子不写真账，但起点得是真会飞的那几行。
    private func fireSnapshotFlightIfAsked() {
        let open = Array(model.items.filter { $0.level != "warn" }.prefix(2))
        guard let first = open.first else { return }
        flight.fireSnapshotIfAsked(candidates: open.map { (key: $0.path.path, bytes: $0.size ?? 0) },
                                   selected: first.selected) {
            for path in open.map(\.path.path) {
                if let i = model.items.firstIndex(where: { $0.path.path == path }) {
                    model.items[i].selected = true
                }
            }
        }
    }

    private func doClean() {
        err = nil
        let targets = model.selected
        // 起点终点都在清选区**之前**取：行一不勾就不再报锚点，按钮一禁用落点也跟着变。
        flight.launch(rows: targets.map { (key: $0.path.path, bytes: $0.size ?? 0) },
                      animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion))
        var ok = 0
        var errs: [String] = []
        for it in targets {
            do {
                let t = try trashItem(it.path)
                store.record(TrashRecord(original: it.path, inTrash: t, size: it.size ?? 0, displayName: it.name))
                ok += 1
            } catch { errs.append(failLine(it.name, error)) }
        }
        // 行会被剔掉，筹码已经在 `launch` 那一下量好了起点，从它原来的位置上起飞。
        model.items.removeAll { !FileManager.default.fileExists(atPath: $0.path.path) }
        for i in model.items.indices { model.items[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "处残留", failed: errs.count)
    }
}
