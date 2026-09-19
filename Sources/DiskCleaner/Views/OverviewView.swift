import SwiftUI
import DiskCleanerCore
import AppKit

// ── 空间总览：磁盘用量 + 主目录一级热点 ──
// 这一屏是磁盘清理类产品的门面，所以给了环形仪表：
// 一眼看清"整块盘被谁吃了"，比一根进度条有力得多。

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
    /// 这个进程实测有没有「完全磁盘访问权限」。授权是在系统设置里点的，macOS 要 App
    /// 退出重开才落到进程上，所以「扫描里报了几处 EPERM」不能当授权状态用——
    /// 那样会对着已经勾过的人说「点这个按钮去开」。每轮扫描开始时重测一次。
    @Published private(set) var hasFDA = false
    /// 整块盘按 APFS 卷拆开的账。nil = 这台机器拆不出（演示树、非 APFS），
    /// 那时「没量到的地方」只能整体归成一块，不硬编明细。
    @Published private(set) var split: VolumeSplit? = nil
    @Published private(set) var started = false
    /// 行内摊开的下一级，按父路径缓存。行视图会随滚动和导航重建，不缓存的话
    /// 每次滚回来都要重走一遍几十 G 的子树——那看着就像 App 卡死了。
    @Published private(set) var childRows: [String: [(name: String, path: String, size: Int64)]] = [:]
    @Published private(set) var childBusy: Set<String> = []
    /// 哪几行正摊着。状态放模型上而不是行的 @State 上：重扫时旧的下级账必须一起作废，
    /// 行自己记着「我展开着」就会剩下一片空档。
    @Published private(set) var expandedChildren: Set<String> = []
    private var childTasks: [String: Task<Void, Never>] = [:]
    private var task: Task<Void, Never>? = nil

    /// 小于这个数不进列表：家目录一级有上百个点目录，绝大多数是几 KB 的配置夹。
    static let sizeFloor: Int64 = 100 * MB
    /// 列表封顶。再长就没人逐行扫了，多出来的体积并进环形的「其他已统计」。
    static let listCap = 20
    /// 单行摊开后最多列几格下级。再往下就没人在读了，剩下的报一个合并数。
    static let childCap = 12

    /// 列表里这些格子按「这个工具动得了动不了」分两堆。判据是路径（`isDeletable`），
    /// 不是名字查表：整盘多扫进来的那几处只能看，家目录与 /Applications 里的都能动手。
    /// 这一行是「其他已统计」那块弧的正面回答——占大空间的到底能不能删，得当场说死。
    var listedSplit: (reclaimable: Int64, viewOnly: Int64) {
        var r: Int64 = 0, v: Int64 = 0
        for h in hotspots + restHotspots {
            if isDeletable(URL(fileURLWithPath: h.path)) { r += h.size } else { v += h.size }
        }
        return (r, v)
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
        dropChildren()
        readVolume()
        scanning = true
        started = true
        hasFDA = fullDiskAccessGranted()
        hotspots = []
        restHotspots = []
        unlistedCount = 0
        unlistedBytes = 0
        covered = 0
        done = 0
        measuring = []
        needFDA = []
        needAdmin = []
        task = Task {
            let targets = hotspotTargets(scope)
            pending = targets.count
            var sized: [(name: String, path: String, size: Int64)] = []
            var total: Int64 = 0
            var blame = DirScan()
            await withTaskGroup(of: (Int, DirScan).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask {
                        await self.enterMeasuring(t.name)
                        let r = await dirSizeReport(URL(fileURLWithPath: t.path))
                        await self.exitMeasuring(t.name)
                        return (i, r)
                    }
                }
                // 组按完成顺序回，不是提交顺序——所以子任务必须把下标带回来。
                for await (i, r) in group {
                    if Task.isCancelled { break }
                    let t = targets[i]
                    pending -= 1
                    done += 1
                    total += r.bytes
                    covered = total
                    blame.merge(r)
                    // 不设上限：这两串只被数个数拿去报「多少处读不动」。
                    // 掐到 60 条就等于对着 187 处说「有 60 处」，是个假数。
                    needFDA = blame.needFullDiskAccess
                    needAdmin = blame.needAdmin
                    if r.bytes > Self.sizeFloor {
                        sized.append((t.name, t.path, r.bytes))
                        sized.sort { $0.size > $1.size }
                        hotspots = Array(sized.prefix(Self.listCap))
                        restHotspots = Array(sized.dropFirst(Self.listCap))
                    }
                }
            }
            guard !Task.isCancelled else { return }
            scanning = false
            measuring = []
            // 环形加起来等于整块盘，列表这一头也必须能对上：摊到几行、剩下多少，
            // 当场说清。不然「其他已统计」那块弧里就有一截是谁都没报过的数。
            unlistedBytes = max(0, total - sized.reduce(Int64(0)) { $0 + $1.size })
            unlistedCount = max(0, targets.count - sized.count)
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
        measuring = []
    }

    func enterMeasuring(_ name: String) {
        guard !measuring.contains(name) else { return }
        measuring.append(name)
    }

    func exitMeasuring(_ name: String) {
        measuring.removeAll { $0 == name }
    }

    // MARK: 行内摊开下一级

    func toggleChildren(of path: String) {
        if expandedChildren.contains(path) {
            expandedChildren.remove(path)
            return
        }
        expandedChildren.insert(path)
        measureChildren(of: path)
    }

    /// 量某一行的下一级。量过就直接回缓存，反复点不会重走子树。
    func measureChildren(of path: String) {
        guard childRows[path] == nil, childBusy.insert(path).inserted else { return }
        childTasks[path] = Task { [weak self] in
            let rows = await childDirSizes(URL(fileURLWithPath: path),
                                           limit: OverviewModel.childCap)
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
        expandedChildren = []
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

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: OverviewModel

    /// 默认摊开：这块是「那几百 G 到底是谁」的正面回答，收起来等于把答案藏起来。
    @State private var gapExpanded = true
    /// 列表封顶之后的那些格子。默认收起，但一行点开就全在——
    /// 环形里那块「其他已统计」不能只有一坨数，得能一路摊到名字。
    @State private var showAllHotspots = false
    /// 环形图例点出来的跳转目标（值就是列表里那一行的 id）。跳完就清空，
    /// 否则同一格点第二次不会触发 onChange。
    @State private var ringTarget: String? = nil

    /// 「展开其余 N 处」那颗按钮的 id：没有分界线时（前三之后就没了）弧指到这儿。
    private static let restAnchor = "overview.restHotspots"
    /// 列表尾巴那几行总账的 id，「其他已统计」在没有「展开其余」时的落点。
    private static let restNoteAnchor = "overview.restNote"
    /// 「没量到的地方」那一段的 id：环形上那块灰（扫的时候叫「这一轮还没量到的」）指到这儿。
    private static let gapAnchor = "overview.gapSection"
    /// 前三行与其余行之间那条分界线的 id。真机上它是 200.1 GB 的入口，
    /// 「其他已统计」那块弧就该落在这道线上，而不是落到线底下很远的对账句上。
    private static let restGroupAnchor = "overview.restGroup"
    /// 分界线以下、还在封顶列表里的那些行（第 4 到第 20 行）。
    private var restGroupRows: [(name: String, path: String, size: Int64)] {
        Array(model.hotspots.dropFirst(3))
    }
    /// 「其他已统计」那条弧的落点：有分界线就落到分界线上（那组大头就在它下面），
    /// 没有分界线就落到「展开其余」，一行都没被封顶切掉时落到列表尾巴那句对账。
    /// 真机上这条曾经指错：弧上有 221.9 GB，点下去只看得见 21.2 GB，
    /// 剩下 200 GB 停在屏幕上方没人框它，用户当场结论是「大头你一直找不到」。
    private var restJumpTarget: String {
        if !restGroupRows.isEmpty, restArcValue != nil { return Self.restGroupAnchor }
        return model.restHotspots.isEmpty ? Self.restNoteAnchor : Self.restAnchor
    }
    /// 环上「其他已统计」那块弧的数，用列表这一头的段复述时要用同一个数。
    /// nil = 还没量完或分段算术不成立，那时不画分界线也不写对账。
    private var restArcValue: Int64? {
        guard let u = model.usage else { return nil }
        let topSum = model.hotspots.prefix(3).reduce(Int64(0)) { $0 + $1.size }
        guard let s = ringSplit(covered: model.covered, used: u.used, topSum: topSum),
              s.restMeasured > 0 else { return nil }
        return s.restMeasured
    }
    /// 「其他已统计」那块弧的颜色：跟图例同一支，分界线靠它跟弧挂上钩。
    private var restArcColor: Color {
        theme.palette.chart[min(4, theme.palette.chart.count - 1)]
    }

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric.sectionGap) {
                if let u = model.usage {
                    heroCard(u)
                        .pagePadding()
                }

                // 紧跟环形：上面刚说「没量到 17%」，下面就得说出这一坨是谁、
                // 能不能要回来。放到页面底部等于让用户自己往下找答案。
                if model.started && model.done > 0, let u = model.usage {
                    gapSection(u)
                        .id(Self.gapAnchor)
                        .pagePadding()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: L("最占地方的文件夹"),
                                 detail: model.scanning
                                     ? LF("已量完 %1$d / %2$d", model.done,
                                          model.done + model.pending)
                                     : cnt(model.hotspots.count, "项"))
                    if model.hotspots.isEmpty && !model.scanning {
                        EmptyState(symbol: "magnifyingglass", title: L("还没扫出来"),
                                   hint: L("点右上角重新扫描"))
                            .frame(minHeight: 220)
                    } else {
                        hotspotList
                        // 环形上「其他已统计」那块弧的账，在这一头收口：
                        // 列出来的分两堆（能删的 / 只能看的），没列出来的报数。
                        VStack(alignment: .leading, spacing: 6) {
                            if !model.scanning && !model.hotspots.isEmpty {
                                Text(listedSplitNote(model.listedSplit,
                                                     rows: model.hotspots.count + model.restHotspots.count))
                                    .font(theme.bodyFont(.caption))
                                    .foregroundStyle(theme.palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            // 环形那块「其他已统计」不能停在一条弧上：下面这几段相加就是它，
                            // 当场写出来，人才信这一百多 G 不是一坨编出来的数。
                            if !model.scanning, let note = restArcNote() {
                                Text(note)
                                    .font(theme.bodyFont(.caption))
                                    .foregroundStyle(theme.palette.inkTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .id(Self.restNoteAnchor)
                    }
                }
                .pagePadding()
            }
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        // 页头钉在滚动区外面：它是这一屏的标题，滚走了就没人知道自己在哪页。
        // 下面仍然只有一个 ScrollView——macOS 13 的 ScrollView 会把内容的完整高度
        // 当成自己的理想尺寸报上去，套两层就会把 detail 列顶成一千六百多点。
        VStack(spacing: 0) {
            PageHeader(symbol: "internaldrive", title: L("空间总览"),
                       subtitle: L("先看清，再下手——下面每块地方都能一键深挖"),
                       variant: .display) {
                ScanControl(scanning: model.scanning, kind: .primary,
                            rescan: { model.refresh(scope: store.scope) },
                            stop: { model.stop() })
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 2)

            // 演示树必须占满一条视线，不能只靠覆盖率那行末尾的小字：假家目录配真盘
            // 容量、或者配一块 96 GB 的假盘，缩略图里跟真机一模一样，挑图的人（包括
            // 我自己）就会拿一张假账去说「这才几十 G」。
            if homeIsDemo {
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

            // 环形图例点哪一块，下面就把那一行送到眼前。光有一条弧加一个数，
            // 回答不了「这是谁、在哪、我动得了吗」——而这三问正是这块弧存在的全部理由。
            ScrollViewReader { proxy in
                scrollContent
                    .onChange(of: ringTarget) { target in
                        guard let target else { return }
                        // 跳过去之前先把那一块摊开：落到一段收起来的明细上等于没回答。
                        if target == Self.restAnchor || target == Self.restNoteAnchor
                            || target == Self.restGroupAnchor {
                            showAllHotspots = true
                        }
                        if target == Self.gapAnchor { gapExpanded = true }
                        withAnimation(reduceMotion ? nil : theme.animation) {
                            proxy.scrollTo(target, anchor: .top)
                        }
                        ringTarget = nil
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.started ? model.refreshUsage() : model.refresh(scope: store.scope) }
        .onChange(of: store.overviewDrill) { name in
            guard let name else { return }
            store.overviewDrill = nil
            guard let hit = (model.hotspots + model.restHotspots).first(where: { $0.name == name })
            else { return }
            model.toggleChildren(of: hit.path)
        }
        .onChange(of: store.overviewJump) { token in
            guard let token else { return }
            store.overviewJump = nil
            // 走的是图例那一格完全相同的路径（含「先摊开再滚」），截图验的就是这条真链路。
            switch token {
            case "rest": ringTarget = restJumpTarget
            // 列表尾巴那句对账单独给一个口令：真机上「展开其余」摊开有几十行，
            // 落到那颗按钮上看不见这句，而它才是「其他已统计这块弧到底怎么凑的」的答案。
            case "restnote": ringTarget = Self.restNoteAnchor
            case "gap": ringTarget = Self.gapAnchor
            default: ringTarget = token
            }
        }
    }

    // MARK: 环形仪表 + 三个数

    private func heroCard(_ u: VolumeUsage) -> some View {
        ThemedCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 22) {
                    RingGauge(segments: gaugeSegments(u),
                              centerValue: "\(Int((Double(u.used) / Double(max(1, u.total)) * 100).rounded()))%",
                              centerLabel: L("已使用"),
                              diameter: 148,
                              legendWidth: 258,
                              select: { ringTarget = $0 })

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
                            // 「已用」是整块数据卷的账，切哪一档都一样，所以范围标不挂在这里
                            // ——挂在它旁边会让人以为 376.5 会随范围变。标挂在下面那行
                            // 真正随范围变的「量到」上。
                            Text(L("已用"))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkSecondary)
                            Text(human(u.used))
                                .font(theme.numeric(.largeTitle))
                                .monospacedDigit()
                                .foregroundStyle(theme.palette.ink)
                        }
                        Divider().overlay(theme.palette.separator)
                        HStack(alignment: .top, spacing: 30) {
                            metric(L("总容量"), human(u.total))
                            metric(L("可用"), human(u.available))
                        }
                        // 「可用」跟系统设置那个数对齐了，就得当场说清它为什么比
                        // 物理空闲大：不然环形上多出来的那条弧没人知道是谁。
                        if u.purgeable > 0 {
                            Text(LF("其中 %1$@ 是系统随时能腾出的可清除空间（快照、缓存那一类），此刻还占着盘。",
                                    human(u.purgeable)))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if u.available < 20 * GB {
                            callout(text: L("可用不足 20GB，该动手了。先从下面最大的几块下手。"))
                        } else {
                            Text(L("空间还算宽裕，看看下面谁最占地方。"))
                                .font(theme.bodyFont(.callout))
                                .foregroundStyle(theme.palette.inkSecondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

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
        }
    }

    /// 列表这一头收口：列出来的按「这个工具动得了动不了」分两堆报数。
    /// 但空的那一堆不写：用户区扫出来的行全在家目录里，照抄模板就会拍出
    /// 「只能看不能删 0 B」——那是在演示一个不存在的东西（跟可清除那格同一条规矩）。
    private func listedSplitNote(_ sp: (reclaimable: Int64, viewOnly: Int64), rows: Int) -> String {
        if sp.viewOnly == 0 {
            return LF("列出的 %1$d 项全都能进废纸篓，合计 %2$@。", rows, human(sp.reclaimable))
        }
        if sp.reclaimable == 0 {
            return LF("列出的 %1$d 项合计 %2$@，这个工具一项都动不了——只能看。", rows, human(sp.viewOnly))
        }
        return LF("列出的 %1$d 项里：能进废纸篓 %2$@，只能看不能删 %3$@。",
                  rows, human(sp.reclaimable), human(sp.viewOnly))
    }

    /// 环形上「其他已统计」那块弧在列表这一头的对账单：它由哪几段相加、各多少，
    /// 当场列出来。只有一条弧加一个数时，人会真去把下面那 20 行加起来对——实测
    /// 有人对着 134.7 GB 加了三遍加不出来（那时有两本账同屏），从此不信这屏的任何数。
    /// 空的段不写，理由跟「可清除 0 B」那条一样：不演示不存在的东西。
    private func restArcNote() -> String? {
        guard let total = restArcValue else { return nil }
        let tail = model.hotspots.dropFirst(3)
        let listed = tail.reduce(Int64(0)) { $0 + $1.size }
        let extra = model.restHotspots.reduce(Int64(0)) { $0 + $1.size }
        var parts: [String] = []
        if !tail.isEmpty {
            parts.append(LF("上面那 %1$d 行 %2$@", tail.count, human(listed)))
        }
        if !model.restHotspots.isEmpty {
            parts.append(LF("「展开其余」里那 %1$d 处 %2$@", model.restHotspots.count, human(extra)))
        }
        if model.unlistedBytes > 0 {
            parts.append(LF("%1$d 处不到 %2$@ 的小目录 %3$@", model.unlistedCount,
                            human(OverviewModel.sizeFloor), human(model.unlistedBytes)))
        }
        guard !parts.isEmpty else { return nil }
        return LF("环形里「其他已统计」%1$@ 就是这几段相加：%2$@。",
                  human(total), parts.joined(separator: " ＋ "))
    }

    /// 这一行要把整块盘的账一路减到底：494 = 可用 128 + 已用 366，已用 = 量到 320 + 量不到 46。
    /// 只报「已量到 320.6，占已用 85%」不够——人手里记的是「我这盘 500 G」，
    /// 看到 320 就以为我们说整块盘只有 320，那一瞬间工具就变成在骗人。
    /// 可用必须写成「空闲 + 可清除」两段：只报那个跟系统对齐的大数，等于把
    /// 10 GB 还占着盘的东西说成空的。差额去哪了不在这里逐块说，下面「没量到的地方」点名。
    /// 可清除是 0 时不再写这一项：环形上本来就不画 0 字节的弧（见 `gaugeSegments`），
    /// 句子却照抄模板就会拍出一张「系统可清除 0 B」的图——那是在演示一个不存在的东西。
    private func coverageLine(_ u: VolumeUsage) -> some View {
        let pct = Int((Double(model.covered) / Double(max(1, u.used)) * 100).rounded())
        let tail = LF("已用 %1$@。已用里这一轮量到 %2$@（%3$d%%），剩下的 %4$@ 在下面逐块点名。",
                      human(u.used), human(model.covered), pct,
                      human(max(0, u.used - model.covered)))
        let text: String
        if u.purgeable > 0 {
            text = LF("整块盘 %1$@：可用 %2$@（空闲 %3$@ ＋ 系统可清除 %4$@），",
                      human(u.total), human(u.available), human(u.free), human(u.purgeable)) + tail
        } else {
            text = LF("整块盘 %1$@：可用 %2$@（全是空闲），",
                      human(u.total), human(u.available)) + tail
        }
        return Text(text)
            .font(theme.bodyFont(.caption))
            .foregroundStyle(theme.palette.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 没量到的地方

    /// 一行差额：名字、多大、为什么是这么个去向、这个工具动得了动不了。
    private struct GapRow {
        let title: String
        let tag: String
        var reason: String
        let bytes: Int64
        /// 这一块有没有能要回来的部分——决定画不画那颗「去授权」。
        let actionable: Bool
    }

    /// 这一格能不能靠「去授权」要回来——决定画不画那颗按钮。
    ///
    /// 判据是实测探针（`model.hasFDA`），不是扫描里报了几处 EPERM：系统设置里勾完，
    /// macOS 要 App 退出重开才把授权落到进程上，而这趟扫描往往正是重开之前跑的。
    /// 只数 EPERM 就会对着已经勾过的人说「点下面的按钮去开」，那是把人往回踢。
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
                           actionable: canGrantFDA || HomeAccess.runsSandboxed)
        var rows = [first]
        if let s = model.split {
            rows.append(GapRow(
                title: L("macOS 系统卷"), tag: L("删不动"),
                reason: L("只读、签名封存，由 SIP 看着。任何清理工具都动不了它，真要瘦只能等系统更新自己整理。"),
                bytes: s.sealedSystem, actionable: false))
            rows.append(GapRow(
                title: L("虚拟内存与休眠镜像"), tag: L("系统自己收回"),
                reason: L("内存吃紧时 macOS 借硬盘喘息，深度休眠前还会把整份内存写下来。关掉占内存的应用就会缩，不该由工具去删。"),
                bytes: s.virtualMemory, actionable: false))
            rows.append(GapRow(
                title: L("启动与恢复分区"), tag: L("删不动"),
                reason: L("开不了机时才用得上，属于固件的地盘。恢复卷平时不挂载，也一起算在这一行。"),
                bytes: s.bootAndRecovery, actionable: false))
            rows.append(GapRow(
                title: L("卷之间的未归属占用"), tag: L("对不到目录"),
                reason: L("APFS 容器自己的元数据，加上各卷共享的那点取整差。这一坨对不到具体文件夹，只能整体看着。"),
                bytes: s.unattributed, actionable: false))
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
            text = homeIsDemo
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
                    ? LF("其中 %1$d 处缺「完全磁盘访问权限」：点下面的按钮去开，勾完要退出这个 App 再打开才生效，然后重扫一轮。",
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

    private func gapSection(_ u: VolumeUsage) -> some View {
        let rows = gapRows(u)
        let total = rows.reduce(Int64(0)) { $0 + $1.bytes }
        // 收起时「去授权」不能跟着明细一起藏：它是这条路径上唯一的入口，
        // 而想把这块要回来的念头恰恰出现在「先收起来」的那一刻。
        let grantFDA = !gapExpanded && canGrantFDA
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : theme.animation) { gapExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        ThemeChevron(expanded: gapExpanded)
                        Text(L("没量到的地方"))
                            .font(theme.display(.subheadline))
                            .tracking(theme.titleTracking + 0.2)
                            .foregroundStyle(theme.palette.ink)
                        if homeIsDemo {
                            Text(L("（演示数据）"))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkTertiary)
                        }
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(gapExpanded ? L("收起这一块") : L("展开这一块"))

                // 合上也要留总数：这一屏要回答的就是「那几百 G 是谁」，
                // 只剩一个标题等于把答案藏了；摊开时这行还是逐块相加的核对值。
                Text(LF("共 %@", human(total)))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .monospacedDigit()
                    .fixedSize()

                if grantFDA {
                    ThemeButton(kind: .compact, symbol: "lock.open",
                                title: L("去授权")) {
                        openFullDiskAccessPane()
                    }
                    .help(L("打开「系统设置 › 隐私与安全性 › 完全磁盘访问权限」；勾上后要重启 DiskWise 才生效"))
                }
            }

            if gapExpanded {
                ThemedCard {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 {
                                Divider().overlay(theme.palette.separator)
                                    .padding(.vertical, 12)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.title)
                                        .font(theme.bodyFont(.callout))
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
                                        .font(theme.numeric(.callout))
                                        .monospacedDigit()
                                        .foregroundStyle(theme.palette.ink)
                                        .fixedSize()
                                }
                                Text(row.reason)
                                    .font(theme.bodyFont(.caption))
                                    .foregroundStyle(theme.palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if row.actionable && canGrantFDA {
                                    ThemeButton(kind: .compact, symbol: "lock.open",
                                                title: L("去授权")) {
                                        openFullDiskAccessPane()
                                    }
                                    .help(L("打开「系统设置 › 隐私与安全性 › 完全磁盘访问权限」；勾上后要重启 DiskWise 才生效"))
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
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

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
            Text(value)
                .font(theme.numeric(.title3))
                .monospacedDigit()
                .foregroundStyle(theme.palette.ink)
        }
    }

    private func callout(text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.warnFG)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.warnFG)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.controlShape().fill(theme.palette.warnBG))
    }

    /// 环形分段 = 前 3 大热点 + 其余量到的 + 这一轮没量到的 + 可清除 + 空闲，加起来正好等于整块盘。
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
    /// 除了「空闲」和「系统可清除」，每一块弧都带一个跳转目标：图例点下去要么落到
    /// 列表里那一行，要么落到「没量到的地方」那一段。环形上凭空出现一块说不清是谁的弧，
    /// 就是这一屏最不该留下的缺口。
    private func gaugeSegments(_ u: VolumeUsage) -> [GaugeSegment] {
        let top = Array(model.hotspots.prefix(3))
        let topSum = top.reduce(Int64(0)) { $0 + $1.size }
        var out: [GaugeSegment] = []
        for (i, h) in top.enumerated() {
            out.append(GaugeSegment(label: h.name, value: h.size,
                                    color: theme.palette.chart[i % theme.palette.chart.count],
                                    jumpTo: h.path))
        }
        // 下标 4 是每套配色里最弱的一支（见 ARCHITECTURE §4.2）：这一段可能很大，
        // 给它强色会把前三名的柱子糊掉。列表里那条分界线用同一支，弧跟线才对得上。
        let weakChart = restArcColor

        // 分段算术由 Core 的纯函数把关（自检钉的是「三块加起来等于已用」）；
        // 不成立就两块都不画，宁可留一块大的「没量到」也不画一张对不上的图。
        if let s = ringSplit(covered: model.covered, used: u.used, topSum: topSum) {
            if s.restMeasured > 0 {
                out.append(GaugeSegment(label: L("其他已统计"), value: s.restMeasured,
                                        color: weakChart, jumpTo: restJumpTarget))
            }
            if s.untouched > 0 {
                // 正在扫的时候这块不是结论，是进度：叫成「没量到的地方」会让人以为
                // 这一坨永远清不动，而它下一秒就会缩。
                // 图例这一列只有 ~90pt 给标签（值占 72、百分比 34、箭头 11），英文整句会被
                // 拦腰截成「Where…pace is」，所以这里用短词，长句留给下面那张卡的标题。
                out.append(GaugeSegment(label: model.scanning ? L("这一轮还没量到的") : L("没量到"),
                                        value: s.untouched,
                                        color: theme.palette.inkTertiary.opacity(0.45),
                                        jumpTo: Self.gapAnchor))
            }
        }
        // 系统记作可用、此刻却还占着盘的那一块（快照、缓存）。必须单列：
        // 「可用」跟系统设置对齐之后，环形里就得有一块弧代表它，
        // 否则前 3 ＋ 其他 ＋ 整盘 ＋ 量不到 ＋ 可用加起来不等于整块盘，图又成了装饰。
        if u.purgeable > 0 {
            out.append(GaugeSegment(label: L("系统可清除"), value: u.purgeable,
                                    color: theme.palette.chart[5 % theme.palette.chart.count]))
        }
        // 这条弧叫「空闲」不叫「可用」：上面那个「可用」是系统口径（含可清除），
        // 两条弧一个代表空闲、一个代表可清除，加起来才等于那个可用。
        out.append(GaugeSegment(label: L("空闲"), value: u.free, color: theme.palette.separator))
        return out
    }

    // MARK: 热点列表

    private var maxHotspotSize: Int64 {
        max(1, model.hotspots.map { $0.size }.max() ?? 1)
    }

    private var hotspotList: some View {
        LazyVStack(spacing: 8) {
            // 前三名各自是一条弧，第四名往后合起来是一条弧，分界线就画在它们中间。
            // 它必须是 LazyVStack 的直接子节点：先前写在 ForEach 的内容里，
            // 扫到第 4 行时算出的旧值被 SwiftUI 一路留着不刷新，摊开的数就成了假账。
            ForEach(model.hotspots.prefix(3), id: \.path) { row in
                HotspotRow(model: model, name: row.name, path: row.path, size: row.size,
                           fraction: Double(row.size) / Double(maxHotspotSize))
                    .id(row.path)     // 环形图例要点着这一行跳，光靠 ForEach 的身份不够
            }
            if !restGroupRows.isEmpty, let total = restArcValue {
                restGroupDivider(total)
            }
            ForEach(model.hotspots.dropFirst(3), id: \.path) { row in
                HotspotRow(model: model, name: row.name, path: row.path, size: row.size,
                           fraction: Double(row.size) / Double(maxHotspotSize))
                    .id(row.path)
            }
            // 一行都没量完时，把正在量的那几处摆出来。不然切完范围就是几分钟的
            // 空白列表，看着像点了没反应——路径要「陆续加载」，人才知道它在干活。
            ForEach(model.measuring.prefix(6), id: \.self) { name in
                MeasuringRow(name: name)
            }
            // 封顶之外的那些：默认收起，但点开就全在。环形上那块「其他已统计」
            // 由此能一路摊到名字，而不是停在一坨数上。
            if !model.restHotspots.isEmpty {
                Button {
                    withAnimation(reduceMotion ? nil : theme.animation) {
                        showAllHotspots.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        ThemeChevron(expanded: showAllHotspots)
                        Text(showAllHotspots
                             ? L("收起其余的")
                             : LF("展开其余 %1$d 处（合计 %2$@）", model.restHotspots.count,
                                  human(model.restHotspots.reduce(Int64(0)) { $0 + $1.size })))
                            .font(theme.bodyFont(.callout))
                            .foregroundStyle(theme.palette.inkSecondary)
                        Spacer(minLength: 8)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("展开其余没列出来的目录"))
                .id(Self.restAnchor)
                if showAllHotspots {
                    ForEach(model.restHotspots, id: \.path) { row in
                        HotspotRow(model: model, name: row.name, path: row.path, size: row.size,
                                   fraction: Double(row.size) / Double(maxHotspotSize))
                    }
                }
            }
        }
    }

    /// 前三行与其余行之间的分界线：把「其他已统计」那条弧在列表里的落点画出来，
    /// 并当场报这一组的小计。占大头的 200 GB 一直就在这十几行里，缺的只是有人
    /// 把它们框成「这一组就是那条弧」——没有这条线，点弧只会跳到底下的对账句上，
    /// 屏幕上只剩 21.2 GB，用户读到的是「221.9 GB 里的大头找不到」。
    private func restGroupDivider(_ total: Int64) -> some View {
        let groupBytes = restGroupRows.reduce(Int64(0)) { $0 + $1.size }
        return HStack(spacing: 6) {
            Circle().fill(restArcColor).frame(width: 7, height: 7)
            Text(LF("环形「其他已统计」%1$@ 的大头在下面这 %2$d 行里，合计 %3$@。",
                    human(total), restGroupRows.count, human(groupBytes)))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 13)
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.palette.separator).frame(height: 1)
        }
        .id(Self.restGroupAnchor)
    }
}

// MARK: - 热点行

private struct HotspotRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: OverviewModel
    @State private var hovering = false

    var name: String
    var path: String
    var size: Int64
    var fraction: Double

    /// 这一格这个工具动得了动不了。判据是真实路径，不是显示名：
    /// 整盘档摊进来的 /Library、/private 只能看，家目录里的能进废纸篓。
    private var deletable: Bool { isDeletable(URL(fileURLWithPath: path)) }
    private var expanded: Bool { model.expandedChildren.contains(path) }
    private var children: [(name: String, path: String, size: Int64)] { model.childRows[path] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row
            if expanded {
                childPanel
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            theme.cardShape().fill(hovering ? theme.palette.surfaceAlt.opacity(0.5)
                                           : theme.palette.surface)
        )
        .overlay(theme.cardShape().stroke(theme.palette.separator,
                                         lineWidth: theme.metric.stroke))
        .onHover { hovering = $0 }
        .animation(theme.animation, value: hovering)
        .animation(reduceMotion ? nil : theme.animation, value: expanded)
    }

    private var row: some View {
        HStack(spacing: 12) {
            // 箭头常驻：光看一行名字没人知道它还能不能再往下摊，
            // 而「往下摊」正是「其他已统计」那 130 多 G 唯一的入口。
            Button {
                withAnimation(reduceMotion ? nil : theme.animation) {
                    model.toggleChildren(of: path)
                }
            } label: {
                ThemeChevron(expanded: expanded, color: theme.palette.inkSecondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LF("展开或收起 %@ 的下一级", name))

            IconTile(symbol: glyph, side: 26,
                     fill: theme.tileColor(index: tileIndex, dark: isDark),
                     muted: true)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ActionBadge(deletable: deletable)
                }
                ProportionBar(fraction: fraction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(human(size))
                .font(theme.numeric(.callout))
                .monospacedDigit()
                .foregroundStyle(theme.palette.ink)
                .fixedSize()

            // 两颗按钮常驻可见。「访达显示」只在悬停时显形过一次，代价就是
            // 占大空间又删不了的那几行永远没人知道它在哪——看不见位置等于没交代。
            HStack(spacing: 6) {
                ThemeButton(kind: .compact, title: L("访达显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .help(LF("在访达里打开 %@", path))

                ThemeButton(kind: .compact, title: L("深挖")) {
                    store.bigScanDir = URL(fileURLWithPath: path)
                    store.jumpTo = .big
                }
                .accessibilityLabel(LF("去大文件页只扫%@", name))
            }
        }
    }

    /// 摊开的下一级。父行那一格是整棵子树的账，只列前几名必定差一截，
    /// 所以差多少当场报出来——不然环形对得上、列表对不上，又是一笔糊涂账。
    private var childPanel: some View {
        let busy = model.childBusy.contains(path)
        let listed = children.reduce(Int64(0)) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 5) {
            if busy && children.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Text(LF("正在量 %@ 的下一级", name))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Spacer(minLength: 8)
                }
                .padding(.vertical, 3)
            }
            ForEach(children, id: \.path) { c in
                HotspotChildRow(name: c.name, path: c.path, size: c.size,
                                fraction: Double(c.size) / Double(max(1, children.first?.size ?? 1)))
            }
            if !busy {
                let rest = max(0, size - listed)
                if children.isEmpty {
                    Text(rest > MB
                         ? L("这一层的空间全在它自己的文件里，没有读得出的子目录。用上面的「访达显示」去看。")
                         : L("这一层没有读得出的子目录。"))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if rest > MB {
                    Text(LF("这一层自己的文件、加上排在 %1$d 名之后的子目录，合计 %2$@，没逐行列出。",
                            OverviewModel.childCap, human(rest)))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, 24)   // 箭头 12 + 间距 12：子行正好缩进一级
    }

    private var isDark: Bool { (theme.scheme ?? colorScheme) == .dark }

    /// 认路径的最后一节，不认显示名。
    ///
    /// 显示名会随语言、用户名、以及整盘范围下的 /Library vs ~/Library 变；
    /// 图标要答的是「这是哪一类地方」，那只能从真实路径读。
    private var dirKey: String {
        URL(fileURLWithPath: path).standardizedFileURL.lastPathComponent.lowercased()
    }

    private var insideHome: Bool {
        // 显示名前缀就是这一行的归属标签：~/ 开头的是家目录，其余是盘顶的系统区
        name.hasPrefix("~/")
    }

    /// 常用目录给固定色，其余按路径取稳定哈希——同一目录每次启动都在同一个色上。
    /// 这里不能用 String.hashValue：Swift 的哈希每个进程重新播种，用它等于每次打开换一套配色。
    private var tileIndex: Int {
        switch dirKey {
        case "applications": return 3
        case "downloads": return 6
        case "desktop": return 2
        case "library": return 8
        default: return stableTileHash(path) % Theme.spectrumLight.count
        }
    }

    private var glyph: String {
        switch dirKey {
        case "applications": return "app"
        case "downloads": return "arrow.down.circle"
        case "desktop": return "menubar.dock.rectangle"
        case "library": return insideHome ? "books.vertical" : "gearshape.2"
        case "documents": return "doc.text"
        case "movies": return "film"
        case "music": return "music.note"
        case "pictures": return "photo"
        case "shared": return "person.2"
        case "local", "opt": return "terminal"
        case "private": return "lock.circle"
        default: return "folder"
        }
    }
}

private func stableTileHash(_ s: String) -> Int {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01b3
    }
    return Int(h % 1000)
}

// MARK: - 能不能动手的标签

/// 一行位置旁边那颗「能删 / 只能看」。
///
/// 环形上随便哪一块，用户要问的都是同一句：这块我要不还得回来。大文件那页有勾选框，
/// 框锁住再加上「系统区」标就等于说了；这一页没有勾选框，以前两堆都不写——
/// 一屏上看不出哪几行动得了手。所以标常驻在这一列上，两堆各写各的。
private struct ActionBadge: View {
    var deletable: Bool

    var body: some View {
        ThemeBadge(text: deletable ? L("能删") : L("只能看"),
                   tone: deletable ? .safe : .neutral,
                   symbol: deletable ? "trash" : "eye")
            .help(deletable ? L("这一项能移进废纸篓")
                            : L("这个位置不在本工具的操作范围内，只能在访达里看"))
    }
}

// MARK: - 摊开后的下一级行

private struct HotspotChildRow: View {
    @Environment(\.theme) private var theme
    @State private var hovering = false

    var name: String
    var path: String
    var size: Int64
    var fraction: Double

    private var deletable: Bool { isDeletable(URL(fileURLWithPath: path)) }

    var body: some View {
        HStack(spacing: 8) {
            ProportionBar(fraction: fraction,
                          color: deletable ? theme.palette.tint : theme.palette.inkTertiary.opacity(0.5),
                          height: 3, trackWidth: 40)
            Text(name)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            ActionBadge(deletable: deletable)
            Spacer(minLength: 8)
            Text(human(size))
                .font(theme.numeric(.caption))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize()
            ThemeButton(kind: .ghost, title: L("访达显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .help(LF("在访达里打开 %@", path))
        }
        .opacity(hovering ? 1 : 0.86)
        .animation(theme.animation, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - 正在量的占位行

/// 还没量完的目录先占一行，路径立刻出现在列表里。
///
/// 体积要等整棵树走完才报得出来，一趟整盘扫描里最慢的那几处能跑几分钟。
/// 没有占位行的话，切完范围就是几分钟的空白列表——那看着跟「点了没反应」
/// 一模一样，而这一屏的全部卖点恰恰是「它在老老实实扫」。
private struct MeasuringRow: View {
    @Environment(\.theme) private var theme
    var name: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.inkTertiary)
                .frame(width: 26, height: 26)
            Text(name)
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(L("正在量"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(theme.cardShape().fill(theme.palette.surface.opacity(0.55)))
        .overlay(theme.cardShape().stroke(theme.palette.separator,
                                         lineWidth: theme.metric.stroke))
    }
}
