import SwiftUI
import AppKit
import Combine
import DiskCleanerCore

@main
struct DiskCleanerApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        // 截图模式自己 exit，不会回到这里往下走
        if let outDir = SnapshotMode.requestedDir { SnapshotMode.run(outDir: outDir) }
        // 沙盒版：先把上次的家目录授权续上，晚一步就会有页面拿容器路径去扫描
        HomeAccess.restore()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(themeManager)
                // 皮肤走 Environment：换肤只改色，不重建子树、不重跑扫描
                .themed(themeManager.effective)
                .preferredColorScheme(themeManager.effectiveScheme)
                .tint(themeManager.effective.palette.tint)
                // 初始尺寸要写死在这里：macOS 13 的窗口拿内容的「理想尺寸」当初始尺寸，
                // 而 ScrollView/List 把整列内容的完整高度报成理想尺寸——不钉这一行的话，
                // 打开总览是 1040×979，点进 Docker 变成 900×620，每切一页窗口跳一次。
                //
                // `minWidth` 900 → 1000：这一屏报上来的理想宽比 1000 还小，于是开窗宽整个
                // 塌在 `minWidth` 那一档上，**默认打开的就是最小窗**（2026-09-28 实拍：
                // 清空存档后 fresh launch 仍是 900x700）。900 那一档英雄区只剩 avail 628，
                // 环被右边那本账挤到 248，掉在弧上标签与盘心两行口径的闸门（260，
                // `Components.swift` 的 `arcLabel`）以下——招牌屏一打开就是一个没数的小饼。
                // 1000 这档环 348，标签和盘心都在。最小窗仍是 1000：1280 宽的屏放得下。
                .frame(minWidth: 1000, idealWidth: 1080, minHeight: 560, idealHeight: 700)
        }
        // 系统那条 unified 标题栏我们一个字都不用：它会把窗口标题再画一遍，
        // 而每一页页头本来就有标题——两行同义反复叠在一起就是重影。
        // 隐藏标题栏后内容顶到窗口边，红绿灯那一条改由我们自己让（见 ChromeStrip）。
        .windowStyle(.hiddenTitleBar)
        // ⌘, 是 macOS 用户找设置的落点，稿子①的判据就是「按 ⌘, 真能打开这一屏」。
        // 不换窗口、不开第二个壳：这一屏本来就在侧栏里，按了就把它带到那一行。
        // 一个窗口都没有时先把 App 激活，落点存着不丢，下一扇窗开起来时接住
        // （见 `ContentView.onAppear` 那条 drain）。
        //
        // 样稿那张 ⌘K 命令面板**不搬**（2026-10-22 判定，理由留在这儿免得下次重推）：
        // 面板列的九条里六条已经有直达键、且就在当前这一屏——⌘? 清理说明、⌘, 设置、
        // ⌘R 重新扫描（`SharedViews` 那颗钮带着 `shortcut`）、⌘↵ 移进废纸篓、空格预演、
        // Esc 退出。「切菜单取色 ⌘M」和 G-F/G-N/G-T 跳页是样稿讲环时的演示，产品里侧栏
        // 常驻，不该再拿一个面板当目录。唯一确实没接的是撤销：它属于刚清完那一屏和废纸篓
        // 页那一行，给一个只在"有上一步可回"时才成立的动作挂全局键，等于在其余时间里
        // 留一颗按下去只会响一声的键。
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(L("设置")) {
                    // 和点侧栏同一条：换目的地，顺手把导航历史压成只有这一站。
                    store.resetNav(to: .menuLaunch)
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // 稿子②那句「? 打开清理说明」。系统那条「DiskWise 帮助」是死路：这个包里没有
            // help book，按下去只会响一声。所以把「帮助」这一整组换成我们自己那一屏——
            // 用户按 ⌘? 或打开「帮助」菜单，落点都是「这一版哪几处和上一版不一样」。
            // 键写在菜单上而不是裸 `?`：裸 `?` 会先进菜单键等价这一层，把反馈邮箱里那个
            // 问号吃掉（稿子的 `?` 是无修饰键，网页里不会跟输入框抢，原生窗口里会）。
            CommandGroup(replacing: .help) {
                Button(L("清理说明")) {
                    Prefs.shared.reopenGuide()
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }
}

// 扫描结果是 App 级状态：页面视图随导航销毁，模型不能跟着一起销毁，
// 否则每切一次 tab 就重走一遍全盘——切来切去卡的就是这个。
@MainActor
final class ScanStore: ObservableObject {
    let overview = OverviewModel()
    let big = BigFilesModel()
    let old = OldFilesModel()
    let dup = DupModel()
    let nodemodules = NMModel()
    let docker = DockerModel()
    let caches = CachesModel(groupKeys: ["general", "cn_app"])
    let devcache = CachesModel(groupKeys: ["dev"])
    let orphans = OrphansModel()
    /// 文件夹下钻。由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁——
    /// 从某个文件夹跳去总览看一眼再回来，不该把刚量好的那一层白扔。
    let folderDrill = FolderDrillModel()

    init() {
        // 总览那个「还能腾出多少」要报真数，而真数的来源是缓存知识库量出来的那些处。
        // 两个模型都由这里持有，所以接线放在这一层，不让 OverviewModel 去摸 store。
        overview.bind(caches: [caches, devcache])
        // 侧栏那几格容量要跟着各页变，而各页的模型是 8 个独立的 ObservableObject：
        // 把它们的 willChange 转发上来，持有 ScanStore 的那一层才重画。
        forward(overview); forward(big); forward(old); forward(dup)
        forward(nodemodules); forward(docker); forward(caches); forward(orphans)
        forward(devcache)
        forward(folderDrill)
    }

    private var bag = Set<AnyCancellable>()

    private func forward<T: ObservableObject>(_ model: T) {
        model.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &bag)
    }
}

/// 历史里的一站。
///
/// 两截：去了哪一页，以及**页内落在哪一层**。下钻页里往里进一层也是一次跳转，
/// 只记页名的话退回来会落在这棵树的入口，而不是刚才站着的那一层。
struct NavStop: Equatable {
    var panel: AppPanel
    var drillPath: String? = nil
}

// 全 App 共享：废纸篓历史（撤销用）+ 顶部提示条 + 跨页跳转
@MainActor
final class AppStore: ObservableObject {
    @Published var trashHistory: [TrashRecord] = []
    @Published var notice: String? = nil
    @Published var jumpTo: AppPanel? = nil
    @Published var bigScanDir: URL? = nil   // 总览跳过来的定向扫描目录
    /// 「进这个文件夹往下看」——文件夹下钻页要落到哪一层。
    ///
    /// 跟 `jumpTo` 分工：这个只说「看哪儿」，切页由 `arrive(_:)` / `resetNav(to:)` 一起做。
    /// 分开是因为从总览、大文件、下钻页三处都能发起下钻，而「跳页」这件事只有一处该管。
    @Published var folderDrillPath: String? = nil
    /// 走到过的地方。**栈顶就是此刻这一屏**，这是「返回」的全部依据。
    ///
    /// `jumpTo` 是消费一次就清空的命令，答不了「我从哪儿来」，所以来源得单独记一本。
    /// 两种入口分得很清楚：侧栏点页与面包屑首格是「根」入口，走 `resetNav(to:)`
    /// 把历史压成只有那一站；内容里每一次跳转（深挖、点文件夹名、下钻页里进/退）
    /// 都走 `arrive(_:)`。这条界线就是「返回」的边界——重新挑目的地，
    /// 不该还能倒着走回去。
    ///
    /// 去重和截断的规则在 `NavStack` 里，由自检钉住；这里只管把它接到界面上。
    private var nav = NavStack<NavStop>(first: NavStop(panel: .overview))
    /// 第一站只认第一次 `seedNav`：窗重新出现时不能把走过的历史清掉。
    private var navSeeded = false
    /// 每走一步 +1。下钻页据此重新对账自己在哪一层。
    ///
    /// 光听 `folderDrillPath` 不够：后退时落点可能和来处**恰好是同一个值**
    /// （比如从 A 进到 A/B 再退回来，中间那一段被截掉了），
    /// 值没变 onChange 就不响，界面会停在子目录上不动。
    @Published private(set) var navPulse = 0
    /// 让总览页就地摊开某个名字的那一行，读完即清空。
    /// 现在只有截图链路会写它（`DISKWISE_DRILL`）：摊开出来的下级要点下去才看得见，
    /// 而批量拍图这一路没有键鼠。走的仍是行上那颗箭头调的同一个方法，不是另画的假界面。
    @Published var overviewDrill: String? = nil
    /// 让总览页把某一格就地摊开：`rest` = 「其他已统计」那一格（`restnote` 是它的旧名，两者同指此处），
    /// `gap` = 「没量到」那一格，其余值当作某个目录的完整路径，摊开它的下一级。
    /// 同样只有截图链路会写（`DISKWISE_JUMP`），走的仍是行首那颗 `▸` 调的同一个方法（`openDrill`），
    /// 所以拍出来的那一张连带是下钻态：环收成参照盘。
    @Published var overviewJump: String? = nil
    /// 让画面上那一页按一次底部清理条的「全选 / 取消全选」：每 +1 就按一次。
    /// 只有截图链路会写（`DISKWISE_PICK`），因为批量拍图这一路没有键鼠，
    /// 而「勾上 170 项之后撤得回来」这件事只有真按一次才照得出来。
    /// 按下的就是那颗按钮自己的 action，不是另画的假界面。
    @Published var selectAllPulse = 0
    /// 让画面上那一页把「不参与比对的组」那份名单弹出来：每 +1 就点一次页顶那句。
    /// 同样只有截图链路会写（`DISKWISE_SHEET`）。名单只在点开后才存在，而这一路没有键鼠，
    /// 按的仍是那句 `EnvCopiesClause` 自己的 action。
    @Published var envListPulse = 0
    /// 「整盘重扫了一轮」的脉冲：每 +1 表示总览那颗按钮刚被按下。
    ///
    /// 总览自己会就地作废它摊开出来的下一级（`dropChildren`），但**别的页**手里那些
    /// 「进过的层」还挂着上一轮的数——文件夹详情就是一个，它进过的每一层都存在自己
    /// 那个 `cache` 里。盘的账已经变了，隔着一轮扫描还拿旧数当今天的账看，
    /// 正是「手动重扫」这个动作要消灭的东西。各页自己监听这个数去作废各自的缓存，
    /// 谁也不必认识谁。
    @Published var rescanPulse = 0
    /// 把总览那一屏当前摊开的明细收回去。行首那颗 `▸` 的收起路径就是再点一次同一行，
    /// 截图这一路点不到它，所以每 +1 让视图自己走一遍同一颗 `setDrill(nil)`。
    @Published var overviewCollapsePulse = 0
    /// 让总览页对环上某一条弧**真点一下**：`arm` = 挑一条动得了的弧（上膛或搬走，
    /// 取决于它此刻是否已经上膛），`refuse` = 挑一条动不了的弧看它怎么解释自己。
    /// 只有截图链路会写（`DISKWISE_RING`），走的仍是弧上 `onTapGesture` 那个
    /// `tapArc`——两段式确认、3.2 秒自动解除、真 `trashItem` 全都在链路上，
    /// 不是另画一张「看起来像上膛了」的假界面。
    /// 值 `rescan` 是另一个用途：重跑一趟扫描，好拍「扫描途中」那一帧（光束钉在
    /// 量到的边界上这件事，只有那一帧能证明）。
    @Published var overviewRing: String? = nil
    /// 首次清理流程的截图口令：`open` / `confirm` / `run` / `undo` / `close`。
    /// 只有截图链路会写（`DISKWISE_CLEAN`），走的仍是页面上那几颗按钮自己的方法，
    /// 不另画一条「看起来像确认页」的假路。
    @Published var overviewClean: String? = nil
    /// 扫描范围。界面上没有开关：两档的账画在同一屏，人就会拿用户区的环形去对整盘的列表，
    /// 对不上就直接不信这屏的数（实测过）。所以永远走这一版能扫到的最大范围，
    /// 沙盒版给 `.disk` 只会扫一堆读不到的路径，那才是真的扫不动。
    var scope: ScanScope { ScanScope.effective }
    /// 用户选的界面语言。改它 = 让整棵树重画，所以切语言不用重启（商店版也不能自己重启）。
    /// 初值要把 `DISKWISE_LANG` 那次覆盖折进来，否则截图模式下词表被环境变量换掉了、
    /// 选择器还指着存盘那一格，图里就是「界面英文、选中中文」。跟随系统的 Auto 不参与这条覆盖。
    @Published private(set) var languageChoice: AppLanguage = SnapshotMode.requestedLang ?? L10n.choice

    func setLanguage(_ lang: AppLanguage) {
        guard lang != languageChoice else { return }
        L10n.apply(lang)          // 先换词表，再让视图重画
        L10n.setChoice(lang)      // 记住选择，下次启动系统级也对得上
        languageChoice = lang
    }

    var trashedBytes: Int64 { trashHistory.reduce(0) { $0 + $1.size } }

    func record(_ r: TrashRecord) {
        trashHistory.append(r)
    }

    var canGoBack: Bool { nav.canGoBack }

    /// 后退一步。栈空时什么都不做——那颗按钮本来就只在有上一站时才画出来。
    func goBack() {
        guard let top = nav.pop() else { return }
        folderDrillPath = top.drillPath
        jumpTo = top.panel
        navPulse += 1
    }

    /// 内容里的一次跳转：落到 `stop`，并记进历史。
    /// 去重与截断的规则在 `NavStack.arrive`，这里只管把它接上界面。
    func arrive(_ stop: NavStop) {
        nav.arrive(stop)
        folderDrillPath = stop.drillPath
        jumpTo = stop.panel
        navPulse += 1
    }

    /// 「根」入口：侧栏点页、面包屑首格。历史压成只有这一站，返回按钮随即消失。
    /// 点侧栏是在重新挑目的地，不是往下走一步——把这一幕也记进历史的话，
    /// 人会在缓存页按返回跳到大文件页，谁都不想要这个。
    func resetNav(to panel: AppPanel) {
        if panel != .folderDrill { folderDrillPath = nil }
        nav.reset(to: NavStop(panel: panel, drillPath: folderDrillPath))
        jumpTo = panel
        navPulse += 1
    }

    /// 开机时把第一站放进历史，不导航——窗已经开在那一页上了。
    /// 少了这一步，第一跳之后栈底是空的，会退到一个没有页面的地方。
    func seedNav(_ panel: AppPanel) {
        guard !navSeeded else { return }
        navSeeded = true
        nav.reset(to: NavStop(panel: panel, drillPath: folderDrillPath))
    }

    /// 进某个文件夹往下看。四个入口（总览的账目行与明细行、大文件页的行、
    /// 下钻页的面包屑与「上一级」）都收在这一条上：先写落点、再切页，
    /// 顺序反了会先看见上一处的残留内容再跳。
    func drill(into path: String) {
        guard !path.isEmpty else { return }
        arrive(NavStop(panel: .folderDrill, drillPath: path))
    }

    /// 深挖：去大文件页，只扫这一棵。总览的账目行与明细行两处共用。
    /// 落点在切页之前写好，大文件页的 `onAppear` 才能一次就消费到。
    func deepDive(into path: String) {
        guard !path.isEmpty else { return }
        bigScanDir = URL(fileURLWithPath: path)
        arrive(NavStop(panel: .big))
    }

    /// 下钻页的「上一级」。顶层目录（`/Applications`、`/Library` 这类）再往上是
    /// **空间总览**：盘顶 `/` 不算一站，理由见 `drillParent`。它跟面包屑第一格
    /// 走的是同一条路，所以两边必须由同一条规则算落点——分开写迟早会一处分折、一处不折。
    func goUpFromDrill() {
        guard let p = folderDrillPath, !p.isEmpty else { return }
        if let up = drillParent(of: p) {
            drill(into: up)
        } else {
            resetNav(to: .overview)
        }
    }

    /// 返回按钮那行说明里要写的名字：上一站是个目录就写目录名，否则写页名。
    var backTargetLabel: String {
        guard let top = nav.previous else { return "" }
        if top.panel == .folderDrill, let p = top.drillPath {
            return (p as NSString).lastPathComponent
        }
        return top.panel.title
    }

    func undoLast() -> String {
        guard let last = trashHistory.popLast() else { return L("没有可撤销的操作") }
        do {
            try untrash(last)
            return LF("已放回：%@", last.displayName)
        } catch {
            trashHistory.append(last)
            return LF("撤销失败：%@", error.localizedDescription)
        }
    }

    /// 一次撤销一整批（首次清理那一步）。
    ///
    /// 倒序放回：这一批是同一屏上勾出来、按列表顺序搬走的，倒着退才能让「后搬进去的
    /// 先回到原位」——同名的两处不会在放回途中互相占位。放回失败的**留在历史里**：
    /// 那条记录还是真的，撤掉就等于对废纸篓页撒谎。返回真放回的那几条，
    /// 调用方拿它把选择恢复成「还没清的样子」。
    @discardableResult
    func undoBatch(_ records: [TrashRecord]) -> (restored: [TrashRecord], failed: Int, firstError: String?) {
        var restored: [TrashRecord] = []
        var failed = 0
        var firstError: String? = nil
        for r in records.reversed() {
            do {
                try untrash(r)
                restored.append(r)
                trashHistory.removeAll { $0.inTrash.path == r.inTrash.path }
            } catch {
                failed += 1
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        return (restored, failed, firstError)
    }

    func clearHistory() {
        trashHistory.removeAll()
    }
}

enum AppPanel: Hashable, CaseIterable {
    // 顺序不再决定图标颜色：2026-10-19 起侧栏按分组取色（见 `sidebarGroup`），
    // 加页或挪页不会再让别的行换色。`folderDrill` 不进侧栏——下钻页是「从某一行进去」的，
    // 不是一栏常驻的目的地；`menuLaunch` 与 `agent` 是后来追加的两页。
    case overview, big, old, dup, nodemodules, docker, devcache, caches, orphans, trash, appearance, feedback, folderDrill, menuLaunch, agent

    var symbol: String {
        switch self {
        case .overview: return "internaldrive"
        case .big: return "doc.on.doc"
        case .old: return "clock"
        case .dup: return "square.on.square"
        case .nodemodules: return "shippingbox"
        case .docker: return "cube"
        case .devcache: return "hammer"
        case .caches: return "sparkles"
        case .orphans: return "app.badge"
        case .trash: return "trash"
        case .appearance: return "paintpalette"
        case .feedback: return "text.bubble"
        case .folderDrill: return "folder"
        case .menuLaunch: return "gearshape.2"
        case .agent: return "cpu"
        }
    }

    /// 侧边栏标题：这里给源文案（key），显示前才查词表
    var titleKey: String {
        switch self {
        case .overview: return "空间总览"
        case .big: return "大文件"
        case .old: return "很久没动"
        case .dup: return "重复文件"
        case .nodemodules: return "node_modules"
        case .docker: return "Docker 占用"
        case .devcache: return "开发缓存"
        case .caches: return "应用缓存"
        case .orphans: return "卸载残留"
        case .trash: return "废纸篓"
        case .appearance: return "外观皮肤"
        case .feedback: return "问题反馈"
        case .folderDrill: return "文件夹详情"
        case .menuLaunch: return "菜单栏与启动"
        case .agent: return "AI Agent"
        }
    }

    var title: String { L(titleKey) }

    /// 侧栏分组序号，对应 `Theme.groupHuesLight/Dark` 的下标。
    /// 组内所有行共用一个色相：认的是「这一栏在管哪类事」，不是「这一页叫什么」。
    var sidebarGroup: Int {
        switch self {
        case .overview, .big, .old, .dup, .folderDrill: return 0
        case .nodemodules, .docker, .devcache: return 1
        case .caches, .orphans, .trash: return 2
        case .agent: return 3
        case .appearance, .feedback, .menuLaunch: return 4
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var grant = HomeGrant.shared
    @ObservedObject private var prefs = Prefs.shared
    @StateObject private var scans = ScanStore()
    @State private var selection: AppPanel? = SnapshotMode.requestedPanel ?? .overview

    /// 标题带附件里是**另一棵** SwiftUI 树（`TitlebarAccessory`），根上那几样 Environment
    /// 传不进去，逐条补一遍：`AppStore`、`ThemeManager`、皮肤、tint。
    /// 漏皮肤是最贵的一条——`\.theme` 的保命默认值是 `builtIn`（`Theme.swift:280`），
    /// 不注入的话顶栏会穿着另一套色，还只在附件那一格。
    @ViewBuilder private func inTitlebar<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .environmentObject(store)
            .environmentObject(themeManager)
            .themed(themeManager.effective)
            .tint(themeManager.effective.palette.tint)
    }

    var body: some View {
        NavigationSplitView {
            // 侧栏的 `max` 钉在 `ideal` 上：`max` 一旦高于 `ideal`，这一列实际就停在
            // `max`（AX 实测 `max: 280` 时侧栏宽 288），而侧栏里最长的那行
            // （图标 22 + 「开发缓存」）内容宽只有 ~160——行尾那一格金额 2026-10-23
            // 撤了之后更空。232 这一档不是内容撑出来的，是留给「设置」这类组标题和
            // 英文译文的余量，多出来的空白由行背景的圆角块自己收。
            // `min` 留 216 只是给这一列 16 pt 的可拖区间。**开窗宽不由这一列决定**：
            // 它跟着下面那行 `.frame(minWidth:)` 走——两档都实拍过：这一列三档钉成
            // 同一个数、minWidth 还是 900 时开 900x700；把 minWidth 提到 1000 后开 1000x700。
            sidebar
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 232)
        } detail: {
            detail
        }
        // 系统那条 52pt 的标题带原本是空的（我们只把红绿灯和侧栏切换按钮让了出来）。
        // 容量读数挂在它上面：不占版面、切到哪页都在，清完一轮涨的就是这里那个数。
        .toolbar {
            // 全局后退：只在历史里还有上一站时才画出来，栈空即消失。
            //
            // 摆在窗口上而不是每页各摆一颗——退路本来就与「哪一页」无关，
            // 分页去摆迟早会长出两种按法：大文件页原先那颗写死的「返回空间总览」
            // 就是这么来的，而文件夹详情页那边压根不走同一条路。
            ToolbarItem(placement: .navigation) { BackButton() }
            // 卷名和容量条排在红绿灯之后（稿子 `.vol{margin-right:auto}`：顶栏读起的
            // 第一句是「哪块盘、还剩多少」）。
            //
            // 它**不能**走标题带附件：`.leading` 那一格实测落在 x=88，正是系统侧栏切换
            // 按钮的位置，两组叠在一格里，系统只能把那颗按钮挤成工具条溢出——
            // 2026-10-25 他那张实拍：右边多出 ▢⋯，「量完」「重新扫描」整段被裁没，
            // 「?」被推出窗口右沿。留在 toolbar 里则和那颗按钮同一条流，谁也不压谁。
            if !prefs.showsFirstRun {
                ToolbarItem(placement: .navigation) {
                    // 总览把「可用」交给环心的大数，顶栏这一句让位；子页留着。
                    VolumeChip(showsFree: (selection ?? .overview) != .overview)
                        .background(ToolbarItemUnbordered())
                }
            }
        }
        // 稿子 `.titlebar` 是两段：`.vol{margin-right:auto}` 把盘符那一组钉在左，
        // `.tb-right` 因此落到窗口右沿。真机原来不是这样——1700 pt 窗里整条工具条从
        // 内容区左沿一路排到底，右边空着九百多 pt（2026-10-24 他圈的就是这一条）。
        // 贴右这件事系统工具条给不了（三条理由记在 `TitlebarAccessory` 的头注里），
        // 所以右组走 `.trailing` 附件那一格，自己画、不套胶囊。
        .background(TitlebarAccessory(attribute: .trailing) {
            // 引导页盖着的时候，窗口顶上那一格读数也收起来。
            // 这一屏要讲的是「一整圈就是这块盘」，而它底下站的正是盘上真实的可用量——
            // 一个还没被解释过的数挂在自我介绍上面，等于让读者先看见答案再看题。
            if !prefs.showsFirstRun {
                inTitlebar {
                    HStack(spacing: 14) {
                        // 右边这一组按样稿 `.tb-right` 的顺序：落款 → 扫描 → 声音 → 「?」。
                        // （稿子中间那颗「菜单」是原型切 1.8 / 1.9 侧栏配色的演示开关，
                        // 产品里没有对应功能，不搬——`DiskCleanerApp.swift:51` 记着这条。）
                        // 声音排在落款右边、问号左边：它管的是「这一下有没有声」，
                        // 和新鲜度一样是整扇窗的事，所以挂在标题带上、不塞进任何一页的页头。
                        // 「?」挂在最右、读数之外：它回答的是「这一版怎么动手」，
                        // 需要它的时刻是人正卡在主画面上，而不是已经退进设置里翻。
                        GaugeFreshness()
                        // 总览的重扫从页头搬到了这里（稿子 `.tb-right` 中间那颗）。
                        // 它扫的仍是总览那一趟：顶栏是整扇窗的 chrome，不可能跟着八页
                        // 各扫各的；别的页页内那颗照旧扫本页。⌘R 只在总览这一页绑给它，
                        // 见 `ScanControl.showsShortcut`。
                        ScanControl(scanning: scans.overview.scanning,
                                    kind: .compact,
                                    showsShortcut: (selection ?? .overview) == .overview,
                                    rescan: {
                                        // 发脉冲在前：`refresh` 会当场把 `scanning` 置真，
                                        // 别的页要在这同一轮里把各自的旧账作废掉。
                                        store.rescanPulse += 1
                                        scans.overview.refresh(scope: store.scope)
                                    },
                                    stop: { scans.overview.stop() })
                        SoundToggle()
                        GuideButton()
                    }
                    // 稿子 `.titlebar{padding:0 16px}`：贴右沿不是贴到像素上，右边还留
                    // 16 pt。这一格归我们自己排，AppKit 只把附件推到窗口的直角处——
                    // 不补这道留白，「?」那枚圆钮会压在窗口右上的圆角上（2026-10-24 实拍）。
                    .padding(.trailing, 16)
                    // 这一组**不许被压**：附件那格的宽是宿主按 SwiftUI 报上来的尺寸排的，
                    // 而被压过的布局报上来的就是压后的宽——量出来扫描期整格停在 174 pt，
                    // 比「停止+声音+?」的理想宽少十几 pt，少的全从「停止」两个字里扣，
                    // 扣成一颗只有方块和省略号的钮（2026-10-25 他圈的那颗）。钉死理想宽，
                    // 宿主才量得到真值，这一格才跟着内容长。
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        })
        // 首次运行那一屏：盖在两列之上，侧栏和页面都摸不到，看完才收。
        // 用 overlay 而不是 sheet——sheet 是另一扇子窗，截图链路拍不到（见 `FirstRunView` 头注）。
        .overlay {
            if prefs.showsFirstRun {
                FirstRunView()
                    .transition(.opacity)
            }
        }
        .animation(theme.animation, value: prefs.showsFirstRun)
        // 「清理说明」那四页排在引导屏**之后**：两扇模态叠着挡道没有意义，
        // 而这一套讲的「点两下」「进篓≠腾出」必须有数可对才能讲——引导屏那会儿
        // 沙盒版连盘都还没量到。所以判据是「引导屏已经收了 且 这一版还没看过」。
        // 同一个 overlay 槽位，靠 `showsFirstRun` 让位，不用 z-index 抢。
        .overlay {
            if !prefs.showsFirstRun && prefs.showsGuide {
                CleanupGuide(startPage: SnapshotMode.guidePage) {
                    Prefs.shared.finishGuide()
                }
                .transition(.opacity)
            }
        }
        .animation(theme.animation, value: prefs.showsGuide)
        .onChange(of: store.jumpTo) { target in
            guard let target else { return }
            withAnimation(theme.animation) { selection = target }
            store.jumpTo = nil
        }
        .onAppear {
            // 一个窗口都没有时按 ⌘,，落点只能先存着：这一扇窗（或下一扇）起来时在这儿接住。
            if let target = store.jumpTo {
                selection = target
                store.jumpTo = nil
            }
            // 历史里先站一站：少了它，第一跳之后栈底是空的，返回会退到没有页面的地方。
            store.seedNav(selection ?? .overview)
            MenuBar.readout.apply(shows: prefs.menuBarEnabled)
            // 性能探针：只有设了 `DISKWISE_PERF` 才有任何动作，见 `PerfProbe` 头注。
            // 总览模型单独递给它：悬停那一发要按手指走的那条路，`AppStore` 上没有直达口子。
            PerfProbe.shared.start(store: store, overview: scans.overview, on: selection ?? .overview)
            // 四类代价账的验收读数：只有设了 `DISKWISE_COST` 才有任何动作。
            PerfProbe.watchCostLedger(scans.overview)
            // 声音：合成在后台算，算完之前谁也不等它。截图那一趟整套静音
            // （`Sound.prepare` 自己看 `SnapshotMode.active`）。
            Sound.shared.prepare(enabled: prefs.soundEnabled)
        }
        .background(WindowContentUnderTitleBar())
        // Esc 撤下膛——总览那两下确认对外承诺的三条退路之一（见 `EscapeTap`）。
        // 挂在窗口这一层而不是总览那一页里：`disarm()` 自己带「没上膛就不发变更」的
        // 闸门（`OverviewModel.disarm`），所以在别的页按 Esc 是一次空转，不重画任何东西；
        // 反过来若跟着页面销毁，切走之后再按就彻底没人接了。
        .background(EscapeTap { scans.overview.disarm() })
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sideSection(L("看清空间"), [.overview, .big, .old, .dup])
                sideSection(L("开发机专项"), [.nodemodules, .docker, .devcache])
                sideSection(L("清理"), [.caches, .orphans, .trash])
                // 「AI」这一组只有直装渠道才有：这一页讲的是把随包附带的 `diskwise`
                // 命令行挂进 AI 工具，而商店版压根不带那个文件（见 AgentCLILocation），
                // 挂上去只会画出一屏「本包不含 CLI」的死路。
                // 这是「渠道差异」的正当例外：不是功能开关，是沙盒物理做不到。
                if !Channel.isAppStore {
                    sideSection(L("AI"), [.agent])
                }
                // 第四组从「关于」改叫「设置」：皮肤和反馈挂在「关于」下是同一处错位——
                // macOS 用户按 ⌘, 找的就是这一组（稿子①，2026-09-30 拍板）。
                sideSection(L("设置"), [.appearance, .feedback, .menuLaunch])
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SidebarMaterial().ignoresSafeArea())
        .disabled(grant.needsGrant)
        .opacity(grant.needsGrant ? 0.4 : 1)
        // 红绿灯那一条用 safeAreaInset 而不是 VStack 兄弟节点：后者在 macOS 13 会把
        // 整列撑到内容的理想高度，窗口不够高时上下各切一截（页头直接消失）。
        // 让出来的这条铺上侧边栏材质，滚过头的内容从它底下穿过去，就是系统的滚动边缘效果。
        .safeAreaInset(edge: .top, spacing: 0) {
            ChromeStrip(leading: Chrome.trafficLightInset).background(SidebarMaterial())
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private func sideSection(_ title: String, _ panels: [AppPanel]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sideHeader(title).padding(.bottom, 2)
            ForEach(panels, id: \.self) { panel in
                // 行尾不报各页的数（样稿 `renderSidebar` 那张表：每一行都是 `amt:null`）。
                // 这一列是导航，不是账本：各页那笔账不同源（缓存那格套在别的条目里、
                // 重复那格只数多出来的副本），加不到一起，排成一列就是一张加不起来的假账，
                // 而它看起来又像在排名。要数，进那一页看页头。
                SidebarRow(panel: panel,
                           showsNew: panel == .agent && prefs.agentPageIsNew,
                           isSelected: selection == panel) {
                    // 走 store 而不是直接改 selection：点侧栏是「重新挑目的地」，
                    // 得顺手把导航历史压成只有这一站，返回按钮随之消失。
                    store.resetNav(to: panel)
                }
            }
        }
        .padding(.top, 8)
    }

    private func sideHeader(_ text: String) -> some View {
        Text(text)
            .font(theme.bodyFont(.caption2).weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(theme.palette.inkSecondary)
            .padding(.leading, 8)
            .padding(.top, 10)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            Divider().overlay(theme.palette.separator).padding(.horizontal, 12)
            Text("\(Product.name) \(versionString)")
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        .background(SidebarMaterial().ignoresSafeArea())
    }

    /// 左下角那格「v1.9 · 10-24 17:44」。**在进程起来那一刻取一次，钉住不重算。**
    ///
    /// 原来它是个每次渲染都现读二进制 mtime 的计算属性，于是这一格跟着**磁盘**走而不是
    /// 跟着**进程**走：换构建时磁盘上的 mtime 往前走，还开着的老窗口跑的仍是老代码，
    /// 那一格就报出一个比屏幕上这份代码更新的时间。2026-10-24 实拍命中：一个 12:33 起来的
    /// 进程左下角写着 17:44，于是「我看的是不是最新版」这个问题被这一格答成了「是」，
    /// 而那一版里本轮的动效修复根本还没有。这一格存在的理由就是回答「我看到的这份是什么
    /// 时候编的」，那它必须说进程的事，不能说文件的事。
    static let launchedBuildStamp: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        guard let exe = Bundle.main.executableURL,
              let date = (try? exe.resourceValues(forKeys: [.contentModificationDateKey]))?
                  .contentModificationDate else { return "v\(v)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM-dd HH:mm"
        return "v\(v) · \(f.string(from: date))"
    }()

    private var versionString: String { Self.launchedBuildStamp }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        // GeometryReader 是「要多少给多少」，不是「内容多大我要多大」——
        // macOS 13 的 ScrollView/List 会把内容的完整高度报成自己的理想尺寸，
        // 于是整列被撑到九百多点，窗口装不下时不是滚动而是上下各切一截：
        // 页头被顶出窗口顶、内容从红绿灯底下穿出去。这里把高度钉死在列上，
        // 内容才真的在自己框里滚。
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Group {
                    // 没授权就一屏数字都不给：拿容器路径扫出来的「几乎没东西」比报错坏得多
                    if grant.needsGrant {
                        HomeGrantView()
                    } else {
                        page
                    }
                }
                // 切语言 = 重建这一页。词表是全局读的，SwiftUI 不知道哪些视图该重画，
                // 于是站着的那一屏会留着旧文案（标题、页头、分段控件全在内）。
                // 扫描结果在 ScanStore 里，重建不会重跑扫描。
                .id(store.languageChoice)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            // 提示条**浮在内容区底沿**，不占版面一行——这是设计稿自己的做法：
            // `.dbar{position:absolute;left:252px;right:20px;bottom:14px;z-index:50}`、
            // `.pgtip{position:absolute;left:50%;bottom:16px;z-index:70}`，稿子里两处提示
            // 都是浮的。之前把它排成 VStack 的一行，理由是「浮在页头上会把标题糊住」——那条
            // 成立，但稿子的解法是浮到**底沿**：既不糊标题，也不用把整页顶下去。
            // 「顶下去」这一动作本身有代价：环居中的那一片按滚动视口高算
            // （`OverviewView` 的 `ringBox(viewportH, ring)`），视口一矮，环就在**自己卡片的
            // 局部坐标里**挪了位；而双击回收那一趟吃的是按下时量到的矩形，于是环在动效底下
            // 走掉，水珠留在这头——不同心。它不占版面，这一路就不会发生。
            .overlay(alignment: .bottom) {
                NoticeBar()
            }
        }
        .animation(theme.animation, value: store.notice)
        // 红绿灯那一条：只让位、不撑高（同侧边栏）
        .safeAreaInset(edge: .top, spacing: 0) { ChromeStrip() }
        .background(ThemedBackdrop())
        // 只留这一处标题：给「窗口」菜单和旁白用，标题栏本身已经不再显示文字。
        // 页面里那十处 navigationTitle 全删了——同一个名字在屏幕上出现两遍，
        // 一遍还是系统字号，看起来就像另一层没对齐的界面。
        .navigationTitle(grant.needsGrant ? L("访问授权") : (selection?.title ?? L("空间总览")))
    }

    @ViewBuilder private var page: some View {
        switch selection ?? .overview {
        case .overview: OverviewView(model: scans.overview)
        case .big: BigFilesView(model: scans.big)
        case .old: OldFilesView(model: scans.old)
        case .dup: DupView(model: scans.dup)
        case .nodemodules: NMView(model: scans.nodemodules)
        case .docker: DockerView(model: scans.docker)
        case .devcache: CachesView(model: scans.devcache, page: .dev)
        case .caches: CachesView(model: scans.caches)
        case .orphans: OrphansView(model: scans.orphans)
        case .trash: TrashView()
        case .appearance: AppearanceView()
        case .feedback: FeedbackView()
        case .folderDrill: FolderDrillView(model: scans.folderDrill)
        case .menuLaunch: MenuBarLaunchView()
        case .agent: AgentPageView()
        }
    }
}

// MARK: - 后退

/// 窗口顶上那颗「退一步」。历史里没有上一站时什么都不画。
///
/// 按的是 `AppStore.navHistory`：每一站都记着「哪一页 ＋ 页内哪一层」，
/// 所以从下钻页退出来落回刚才那一层目录，而不是这一页的入口。
private struct BackButton: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        if store.canGoBack {
            Button {
                store.goBack()
            } label: {
                Label(L("返回"), systemImage: "chevron.backward")
            }
            .labelStyle(.titleAndIcon)
            .help(LF("回到「%@」", store.backTargetLabel))
        }
    }
}

// MARK: - 侧边栏行

private struct SidebarRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var panel: AppPanel
    /// 这一页有没有「新」角标：只在真·新功能第一次亮相时画，进去一次就永久收起。
    var showsNew: Bool = false
    var isSelected: Bool
    var tap: () -> Void

    @State private var hovering = false

    private var isDark: Bool {
        (theme.scheme ?? colorScheme) == .dark
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                // 导航图标按组取色（5 组 5 色）：一组里所有页同色，深色皮上也只有
                // 环形那支金弧是高饱和/发光的东西。仍然浅底同色——实心彩块是主按钮的形。
                IconTile(symbol: panel.symbol, side: 22,
                         fill: theme.groupTileColor(group: panel.sidebarGroup, dark: isDark),
                         muted: true)
                // 选中不再加粗：填充已经说明了「你在这一页」，再加一档字重就有两个信号
                // 在喊同一句话。竞品 14 家里 10 家只做填充（G′，2026-10-19）。
                Text(panel.title)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // 「新」挂在行尾：这一格原来站的是各页的容量读数，2026-10-23 跟着
                // 样稿那张 `amt:null` 的表一起撤了（见 `sideSection`），于是它空着。
                if showsNew { NewBadge() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(rowBackground)
            .contentShape(theme.controlShape())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var rowBackground: some View {
        let shape = theme.controlShape()
        if isSelected {
            shape.fill(theme.palette.tintSoft)
        } else if hovering {
            shape.fill(theme.palette.surfaceAlt.opacity(0.8))
        }
    }
}

// MARK: - 「新」角标

/// 侧栏上那枚「新」：**描边**小胶囊，不填主色。
///
/// 实心主色块在这套皮肤里是「推进 / 花钱」那颗主按钮（`SidebarRow` 上面写着同一条）。
/// 这一颗说的话轻得多——「这里多了个页面，你还没看过」——它必须比行里的标题更安静，
/// 不然侧栏会先被一个角标按住。底色取 `surface` 而不是侧栏那层半透明材质：
/// 材质由窗口服务器采窗口**后面**的东西（见 `SidebarMaterial`），
/// 描边胶囊压在透背景上会跟着极光糊成一片。
private struct NewBadge: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Text(L("新"))
            .font(theme.bodyFont(.caption2).weight(.semibold))
            .foregroundStyle(theme.palette.tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(theme.palette.surface))
            .overlay(Capsule().stroke(theme.palette.tint.opacity(0.5), lineWidth: theme.metric.stroke))
            .fixedSize()
    }
}

// MARK: - 侧边栏材质
/// 侧边栏半透明，让 aurora / fiber 背景透出来
///
/// 这里不能用 .thinMaterial：材质由窗口服务器合成，采的是**窗口后面**的东西，
/// 不是本 App 自己画的那层背景。极光那套实测被采成一块灰泥（rgb 154,166,178），
/// 段标题对比度掉到 1.35:1。透背景用色块透明度就够，且完全可预测。
private struct SidebarMaterial: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            ThemedBackdrop()
            theme.palette.paper.opacity(theme.elevation == .glass ? 0.62 : 0.55)
        }
    }
}
