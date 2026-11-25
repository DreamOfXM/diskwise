import SwiftUI
import DiskCleanerCore

// ── 「该清了」：把散在各页的「你可能不要了」收成一页，并且给结论 ──
//
// 别的页问的是「哪一类东西大」（大文件 / 缓存 / 残留），进来时人已经知道自己要找什么。
// 这一页问的是另一句：**我这儿有什么是已经不需要了的**。
//
// 所以它不按目录分栏，按「删了会怎样」分四档，而且每一档都带一句为什么这么判：
//   · 删了不丢东西 —— 缓存、装完没删的安装包、同一工具的旧版本。勾了就搬。
//   · 先看一眼再删 —— 旧备份、旧会话、很久没打开的应用。存着数据，得人自己过目。
//   · 动不了       —— 只读卷、系统保护、别的软件依赖它。行不可勾，写明人该怎么办。
//   · 还在用       —— 只进账，不列成行；列出来只会让人以为「这一屏还能再腾」。
//
// 判词与结论全部来自 Core 的 `AdviceScanner`，界面这一层不再判一次：
// 同一件事两处判，迟早会出现「命令行说能动、界面说动不了」，而人只会信那个更悲观的。
//
// 时间依据必须跟在天数后面念出来（`stale_basis`）：备份按内部文件算会把昨天刚备份的
// 记忆说成两年前的，而按容器日期算才是对的。只写「96 天」是在给一个不知道自己在量什么
// 的数字背书。

/// 这一类东西是什么。kind 是 Core 的固定词表，界面只负责翻译。
func adviceKindLabel(_ kind: String) -> String {
    switch kind {
    case "unused_app":        return L("很久没打开的应用")
    case "session_history":   return L("旧会话记录")
    case "backup_snapshot":   return L("旧备份与快照")
    case "duplicate_version": return L("同一工具的旧版本")
    case "installer_image":   return L("装完没删的安装包")
    case "orphan_app_data":   return L("卸载后留下的数据")
    case "orphan_project":    return L("没人管的旧项目")
    case "large_file":        return L("大文件")
    case "trash":             return L("废纸篓")
    case "system_index":      return L("系统缓存")
    case "version_history":   return L("文档版本历史")
    default:                  return kind
    }
}

/// 行首那一格：认得出是什么，比认得出叫什么更重要。
private func adviceSymbol(_ kind: String) -> String {
    switch kind {
    case "unused_app":        return "app.dashed"
    case "session_history":   return "bubble.left.and.bubble.right"
    case "backup_snapshot":   return "clock.arrow.circlepath"
    case "duplicate_version": return "square.stack.3d.up"
    case "installer_image":   return "shippingbox"
    case "orphan_app_data":   return "app.badge"
    case "orphan_project":    return "folder"
    case "large_file":        return "doc"
    case "trash":             return "trash"
    case "system_index":      return "magnifyingglass"
    case "version_history":   return "clock.arrow.circlepath"
    default:                  return "questionmark.folder"
    }
}

/// 「多久没动」是按什么算出来的。这句必须跟着天数走，不能省。
func adviceBasisLabel(_ basis: String) -> String {
    switch basis {
    case "file_mtime":     return L("按内部最新文件算")
    case "container_date": return L("按它自己的日期算")
    case "last_used_date": return L("按上次打开算")
    default:               return L("时间不明")
    }
}

/// 动不了的原因。四种处置方式完全不同，所以不能合成一句「权限不够」。
func adviceBlockLabel(_ reason: String) -> String {
    switch reason {
    case "needs_fda":              return L("缺完全磁盘访问权限")
    case "needs_admin":            return L("要管理员密码")
    case "sip":                    return L("受系统保护")
    case "readonly_volume":        return L("在只读卷上")
    case "in_use":                 return L("正在用")
    case "functional_dependency":  return L("别的软件依赖它")
    default:                       return reason
    }
}

/// 一行 = 一条建议 + 它此刻勾没勾。
///
/// 单独包一层而不是直接改 `UnusedItem`：那个结构是给命令行和 agent 的，字段一旦
/// 混进界面状态，JSON 里就会多出一个 `selected`——那是界面的事，不是盘上的事实。
struct AdvisedRow: Identifiable {
    let item: UnusedItem
    var selected: Bool
    /// 以路径为身份：同一个路径在一趟扫描里只出现一次，而显示的 name 可能重名。
    var id: String { item.path }
}

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁。
@MainActor
final class AdviceModel: ObservableObject {
    @Published var rows: [AdvisedRow] = []
    @Published var scanning = false
    @Published private(set) var started = false
    /// 四档合计。来自 Core 的 `totals`，跟列表里的行同一趟算出来。
    @Published private(set) var totals: [String: Int64] = [:]
    @Published private(set) var topActions: [String] = []
    private var task: Task<Void, Never>? = nil

    /// 这一页多久算「没用上」，跟命里那 90 天同一口径。
    /// 不放在界面上给开关：多一个旋钮就多一个「我调了它为什么没变」的问题。
    let staleDays = 90

    var selected: [AdvisedRow] { rows.filter { $0.selected } }

    /// 勾中的这些**实际**能腾多少：路径互相套着的只数最外面那层。
    /// 按各自体积相加会虚高——废纸篓里可能正躺着刚清掉的那几项。
    var selectedBytes: Int64 {
        contentsUnionSize(selected.map { (path: $0.item.path, bytes: $0.item.physicalBytes) })
    }

    /// 全选只碰「删了不丢东西」那一档。另两档要么存着数据（得人自己过目），
    /// 要么根本动不了，一键带走等于替用户拍了不该替人拍的板。
    private var openRows: [AdvisedRow] { rows.filter { canPick($0.item) && $0.item.recommend == "safe" } }

    var selectAll: SelectAll? {
        let open = openRows
        guard !open.isEmpty else { return nil }
        return SelectAll(allSelected: open.allSatisfy(\.selected),
                         unselectable: rows.count - open.count) { on in
            let ids = Set(open.map(\.id))
            for i in self.rows.indices where ids.contains(self.rows[i].id) {
                self.rows[i].selected = on
            }
        }
    }

    func load(force: Bool = false) {
        if started && !force { return }
        task?.cancel()
        started = true
        scanning = true
        task = Task {
            let report = await AdviceScanner.scan(staleDays: staleDays)
            if Task.isCancelled { return }
            // 排序就是这一页的主张：能直接删的排最前，动不了的排在最后。
            // 每档内部按体积降序——同一档里先看大的。
            let order = ["safe": 0, "review": 1, "blocked": 2, "keep": 3]
            let sorted = report.items.sorted {
                let a = order[$0.recommend] ?? 9, b = order[$1.recommend] ?? 9
                if a != b { return a < b }
                if $0.physicalBytes != $1.physicalBytes { return $0.physicalBytes > $1.physicalBytes }
                // 体积相同的按路径定序：几条 0 字节的系统缓存谁先谁后本来没有意义，
                // 但两次扫描顺序不同，人就会以为「刚才是这条」。
                return $0.path < $1.path
            }
            self.rows = sorted.map { AdvisedRow(item: $0, selected: false) }
            self.totals = report.totals
            self.topActions = report.topActions
            self.scanning = false
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
    }
}

/// 这一条能不能勾。
///
/// `blocked` 不行：勾了也没法搬，画一个勾选框等于许诺一件做不到的事。
/// `keep` 也不列成行，见下面的 `listed`。
func canPick(_ item: UnusedItem) -> Bool {
    item.recommend == "safe" || item.recommend == "review"
}

struct AdviceView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: AdviceModel
    @State private var confirmClean = false
    @State private var errorText: String? = nil
    @StateObject private var flight = TrashFlightController()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "checklist",
                           title: L("该清了"),
                           subtitle: L("很久没打开的应用、旧备份、旧会话、装了没用过的版本、装完就忘的安装包。每条都写明为什么这么判，动不了的那些卡在哪。"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在翻应用、备份、会话目录，逐个量体积…"),
                                   progress: ScanProgress())
                    } else {
                        Text(LF("%d 项可查", listed.count))
                    }
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.load(force: true) }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && listed.isEmpty {
                ScanSkeleton()
            } else if !model.scanning && listed.isEmpty {
                EmptyState(symbol: "checklist",
                           title: L("没有发现你已经不要的东西"),
                           hint: L("应用都在用、备份是新的、会话也还在写。过一阵子再来看看。"))
                    .frame(maxHeight: .infinity)
            } else {
                PageLedger(tiers: tiers, rows: listed.count, note: ledgerNote)
                List($model.rows) { $row in
                    ItemRow(selected: $row.selected,
                                icon: rowIcon(URL(fileURLWithPath: row.item.path),
                                              adviceSymbol(row.item.kind)),
                                name: rowName(row.item),
                                sub: rowSub(row.item),
                                sizeText: sizeText(row.item),
                                fraction: Double(row.item.physicalBytes) / Double(maxSize),
                                badge: verdictBadgeOf(row.item),
                                badge2: blockBadge(row.item),
                                selectable: canPick(row.item),
                                lit: row.item.recommend == "safe",
                                showRule: listed.first?.id != row.id,
                                // 截图链路：`DISKWISE_EXPAND=1` 摊开第一行，或点名某一行。
                                // 展开态只有点箭头才出现，而批量拍图这一路没有键鼠。
                                preopen: (SnapshotMode.expandFirstRow && listed.first?.id == row.id)
                                    || SnapshotMode.expandsRow(row.item.name,
                                                               rowName(row.item))) {
                            if let content = contentsLine(row.item.files, nil) {
                                ExplainLine(key: L("内容"), value: content)
                            }
                            ExplainLine(key: L("删了怎么恢复"), value: recoverNote(row.item))
                            if row.item.recommend == "blocked" {
                                ExplainLine(key: L("怎么才能删"), value: unblockNote(row.item))
                            }
                            if row.item.logicalBytes > row.item.physicalBytes * 2 {
                                // 稀疏文件：按文件大小报会比实际大一个量级。不写这句，
                                // 用户清完发现只腾出一小截，只会认为数是我们编的。
                                ExplainLine(key: L("体积"),
                                            value: LF("文件大小写着 %1$@，实际只占 %2$@（稀疏文件）。",
                                                      human(row.item.logicalBytes),
                                                      human(row.item.physicalBytes)))
                            }
                            PathLine(path: row.item.path)
                        }
                    .heroAnchorGlobal(TrashFlightController.rowAnchor(row.id), enabled: row.selected)
                }
                .ledgerCard()
            }

            Spacer(minLength: 0)

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     bytesText: human(model.selectedBytes, inRulerOf: listedTotal),
                     errorText: errorText, hint: barHint,
                     selection: model.selectAll, flightTarget: true) { confirmClean = true }
        }
        .frame(maxWidth: .infinity)
        .flightField(flights: $flight.flights, anchors: $flight.anchors)
        .onAppear { model.load() }
        .confirmTrash(isPresented: $confirmClean,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "项"),
                               human(model.selectedBytes, inRulerOf: listedTotal))) {
            clean()
        }
    }

    /// 四档全部列成行，`keep` 排最后。
    ///
    /// 曾经把 `keep` 滤掉（「还在用的东西列它干什么」），实拍一看账上写着「还在用 39.5 GB」，
    /// 列表里一行都没有——那 39.5 GB 就成了一个点不进去、也核对不了的数。账上的每一档
    /// 都得能在下面找到对应的行，否则这一页的合计就只是四个我自己相信的数字。
    /// 它们不可勾（`canPick` 已经排除），徽章写着「还在用」，就是让人自己看一眼再决定。
    private var listed: [AdvisedRow] { model.rows }

    private var maxSize: Int64 { max(1, listed.map(\.item.physicalBytes).max() ?? 1) }

    private var listedTotal: Int64 {
        listed.reduce(Int64(0)) { $0 + $1.item.physicalBytes }
    }

    /// 四档账。`keep` 也算进来：不算的话，这一页的合计会跟 `diskwise unused`
    /// 报的 `total_bytes` 对不上，而两个数说的是同一趟扫描。
    private var tiers: [LedgerTier] {
        let t = model.totals
        return [LedgerTier(label: L("删了不丢东西"), bytes: t["safe_now_bytes"] ?? 0, tone: .hot),
                LedgerTier(label: L("先看一眼再删"), bytes: t["review_bytes"] ?? 0, tone: .warn),
                LedgerTier(label: L("动不了"), bytes: t["blocked_bytes"] ?? 0, tone: .risk),
                // 「先不动」而不是「还在用」：这一档里躺着 63 天没打开的微信、QQ，
            // 它们只是没到 90 天那条线，不是「你在用」。说在用是编的。
            LedgerTier(label: L("先不动"), bytes: t["keep_bytes"] ?? 0, tone: .cold)]
    }

    /// 顶上那句对账话。只在真有「动不了」的时候说：
    /// 不说清，用户会以为合计里那截是我漏掉的。
    private var ledgerNote: String? {
        guard (model.totals["blocked_bytes"] ?? 0) > 0 else { return nil }
        // 不复述那个数：上面账本里的数是按合计单位对齐过的，这里再 human() 一次
        // 会得到 4.2 与 4.1 并排——同一笔账两个写法，人只会先怀疑我们编数。
        return L("「动不了」那一档不是我们的疏漏：有的是只读卷上的，有的是系统或别的软件正依赖着。展开行看具体是哪种，以及人该怎么办。")
    }

    private var barHint: String? {
        L("合计按各自真占的空间算，路径套着的只数最外层")
    }

    /// 体积那一格。
    ///
    /// 读不到体积的项（`.Spotlight-V100` 这类归 root 所有的）在 Core 里就是 0 字节，
    /// 直接印「0 B」等于告诉人「这是个空目录」——而它可能是整台机器上最大的一块。
    /// 量不到就说量不到，旁边那枚徽章会写清是缺哪种权限。
    /// 行名。绝大多数项的名字就是路径尾段（iMovie、openclaw-private-backup），原样用；
    /// 只有 Data 卷根下那几个系统缓存例外——它们在 Core 里的名字是写死的英文，
    /// 直接显示会让这一列一半中文一半英文。
    private func rowName(_ item: UnusedItem) -> String {
        switch item.kind {
        case "system_index":
            return item.path.hasSuffix(".fseventsd") ? L("文件系统事件记录") : L("Spotlight 索引")
        case "version_history":
            return L("文档版本历史")
        default:
            return item.name
        }
    }

    private func sizeText(_ item: UnusedItem) -> String {
        item.physicalBytes == 0 && !canPick(item) ? L("量不到") : human(item.physicalBytes)
    }

    /// 副标题只放两件事：这是什么、多久没动（以及这个「多久」是按什么算的）。
    ///
    /// 文件数原来也在这行，英文一长就从中间被压掉一段——实拍时正好把「63 days」
    /// 吞成 `Untouched_...`，而天数恰恰是这一行最该被看见的数字。它挪进展开行。
    /// 删了以后怎么拿回来。
    ///
    /// 这一句**不复述 Core 的 `restore`**：那是给 agent 和命令行看的英文，
    /// 直接摆到中文界面上就是一半中文一半英文（实拍过）。界面只说人关心的那件事：
    /// 它是能自己长回来的，还是真没了。
    private func recoverNote(_ item: UnusedItem) -> String {
        // 系统缓存的重建方式跟别的不一样：不是「重新下载」，是系统自己重新扫一遍。
        // 一句「重新下载就会回来」摆在搜索索引旁边，等于没说清它会怎么长回来。
        switch item.kind {
        case "system_index", "version_history":
            return L("系统会自己重建这份缓存，重建期间搜索和浏览会慢一些。")
        default:
            break
        }
        return item.regenerable
            ? L("这些都能自己长回来：重新下载、重装或重新编译就会回来。")
            : L("删了就没了。在废纸篓里还能捞回来，清空之后就真没了。")
    }

    /// 动不了的那一条，人到底该怎么办。
    ///
    /// 同样不转述 Core 的 `user_action`（英文长句）。六种原因各给一句中文办法，
    /// 只有「要管理员密码」这一种真的需要一条命令——那条命令按路径现拼，
    /// 引号里的双引号与反斜杠要先转义，否则路径一带空格就执行到别处去了。
    private func unblockNote(_ item: UnusedItem) -> String {
        switch item.blockedReason {
        case "needs_admin":
            return L("在终端里执行下面这条。") + "\n" + sudoCommand(item.path)
        case "needs_fda":
            return L("去系统设置里给它「完全磁盘访问权限」，退出这个 App 再打开，权限才会生效。")
        case "readonly_volume":
            return L("它所在的卷是只读的，得在管着它的那个 App 里卸（比如在 Xcode 里删掉这个运行时）。")
        case "sip", "functional_dependency":
            return L("系统或别的软件正依赖它，删了会坏，留着。")
        case "in_use":
            return L("先退出这个 App，再回来删。")
        default:
            return adviceBlockLabel(item.blockedReason)
        }
    }

    private func sudoCommand(_ path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "sudo rm -rf \"\(escaped)\""
    }

    private func rowSub(_ item: UnusedItem) -> String {
        var parts: [String] = []
        // 行名跟类别同名时（系统缓存那三条就是）不再重复一遍：
        // 「文档版本历史 / 文档版本历史 · 时间不明」看着像我们词穷。
        if adviceKindLabel(item.kind) != rowName(item) {
            parts.append(adviceKindLabel(item.kind))
        }
        if item.staleDays >= 0 {
            parts.append(LF("%1$d 天没动（%2$@）", item.staleDays, adviceBasisLabel(item.staleBasis)))
        } else {
            parts.append(adviceBasisLabel(item.staleBasis))
        }
        return parts.joined(separator: " · ")
    }

    /// 这一行属于哪一档。用徽章说，而不是只靠排序——排序只在一屏之内看得见。
    private func verdictBadgeOf(_ item: UnusedItem) -> ItemBadge? {
        switch item.recommend {
        case "safe":    return ItemBadge(text: L("删了不丢东西"), tone: .safe)
        case "review":  return ItemBadge(text: L("先看一眼再删"), tone: .warn)
        case "blocked": return ItemBadge(text: L("动不了"), tone: .danger)
        case "keep":    return ItemBadge(text: L("先不动"), tone: .neutral)
        default:        return nil
        }
    }

    /// 第二枚徽章：动不了的到底是哪一种。只说「动不了」等于什么都没说，
    /// 而这六种处置方式差得很远——一种输个密码就行，一种只能去 Xcode 里卸。
    private func blockBadge(_ item: UnusedItem) -> ItemBadge? {
        // 只认真正被挡住的那一档。`keep` 也勾不动，但它不是「被挡住」，
        // 而它的 `blocked_reason` 是枚举里的 `none`——照 `!canPick` 判，
        // 每一行「先不动」旁边都会多挂一枚写着 none 的灰徽章（实拍过）。
        guard item.recommend == "blocked" else { return nil }
        return ItemBadge(text: adviceBlockLabel(item.blockedReason), tone: .neutral)
    }

    private func clean() {
        errorText = nil
        let targets = model.selected
        flight.launch(rows: targets.map { (key: $0.id, bytes: $0.item.physicalBytes) },
                      animate: TrashFlightController.canAnimate(reduceMotion: reduceMotion))
        var ok = 0
        var errs: [String] = []
        for row in targets {
            let p = row.item.path
            do {
                let t = try trashItem(URL(fileURLWithPath: p))
                store.record(TrashRecord(original: URL(fileURLWithPath: p), inTrash: t,
                                         size: row.item.physicalBytes,
                                         displayName: row.item.name))
                ok += 1
            } catch {
                errs.append(failLine(row.item.name, error))
            }
            if let i = model.rows.firstIndex(where: { $0.id == row.id }) {
                model.rows[i].selected = false
                // 搬走了就回不来（除非去废纸篓捞），从这一页摘掉：
                // 留着一条已经不存在的路径，点进去是空的，展开是错的。
                model.rows.remove(at: i)
            }
        }
        if !errs.isEmpty { errorText = errList(errs) }
        store.notice = trashedNotice(ok, "项", failed: errs.count)
    }
}
