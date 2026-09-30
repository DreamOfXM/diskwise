import SwiftUI
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

    /// 侧栏一行的容量：这一类**已经量出来**的那笔账，与各页顶上那块账同源。
    ///
    /// 没扫过返回 nil，画面上留空。写 0 是谎报「这一类是空的」，写「未知」
    /// 是给一个还没发生的事占一格——两者都不如什么都不写。
    func amount(_ panel: AppPanel) -> Int64? {
        switch panel {
        case .big:         return big.started ? big.rows.reduce(0) { $0 + $1.size } : nil
        case .old:         return old.started ? old.totalBytes : nil
        case .dup:         return dup.started ? dup.waste : nil
        case .nodemodules: return nodemodules.started ? nodemodules.totalBytes : nil
        case .docker:      return docker.started ? docker.totalBytes : nil
        // 缓存页只量得出体积的那些行才算：没量出来的那格印的是「统计中…」，加不进任何账。
        case .caches, .devcache: return cacheAmount(panel == .devcache ? devcache : caches)
        case .orphans:     return orphans.started ? orphans.totalBytes : nil
        // 下钻页的那笔账是「当前这一层」，跟侧栏那一列（各页总量）不是一个口径，
        // 报上去只会让同一格数字随用户点进点出地跳。
        case .overview, .trash, .appearance, .feedback, .folderDrill: return nil
        }
    }

    private func cacheAmount(_ model: CachesModel) -> Int64? {
        model.started ? model.items.reduce(Int64(0)) { $0 + max(0, $1.size ?? 0) } : nil
    }
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
    /// 跟 `jumpTo` 分工：这个只说「看哪儿」，切页由 `drill(into:)` 一起做。
    /// 分开是因为从总览、大文件、下钻页三处都能发起下钻，而「跳页」这件事只有一处该管。
    @Published var folderDrillPath: String? = nil
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

    /// 进某个文件夹往下看。三个入口（总览的账目行与明细行、大文件页的行、下钻页的面包屑）
    /// 都收在这一条上：先写落点、再切页，顺序反了会先看见上一处的残留内容再跳。
    func drill(into path: String) {
        guard !path.isEmpty else { return }
        folderDrillPath = path
        jumpTo = .folderDrill
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

    func clearHistory() {
        trashHistory.removeAll()
    }
}

enum AppPanel: Hashable, CaseIterable {
    // `folderDrill` 追加在最后：`tileIndex` 拿 `allCases` 的下标当取色序号，
    // 插在中间会把后面每一页的图标配色整体挪一格（那是一条看不见的回归）。
    // 它也不进侧栏——下钻页是「从某一行进去」的，不是一栏常驻的目的地。
    case overview, big, old, dup, nodemodules, docker, devcache, caches, orphans, trash, appearance, feedback, folderDrill

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
        }
    }

    var title: String { L(titleKey) }

    /// 与 Theme.spectrum 的取色顺序严格对应
    var tileIndex: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

struct ContentView: View {
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var grant = HomeGrant.shared
    @StateObject private var scans = ScanStore()
    @State private var selection: AppPanel? = SnapshotMode.requestedPanel ?? .overview

    var body: some View {
        NavigationSplitView {
            // 侧栏的 `max` 钉在 `ideal` 上：`max` 一旦高于 `ideal`，这一列实际就停在
            // `max`（AX 实测 `max: 280` 时侧栏宽 288），而侧栏里最长的那行
            // （图标 22 + 「开发缓存」+ 行尾金额）内容宽只有 ~208，多出来的全是空的。
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
            ToolbarItem(placement: .primaryAction) { VolumeChip() }
        }
        .onChange(of: store.jumpTo) { target in
            guard let target else { return }
            withAnimation(theme.animation) { selection = target }
            store.jumpTo = nil
        }
        .background(WindowContentUnderTitleBar())
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sideSection(L("看清空间"), [.overview, .big, .old, .dup])
                sideSection(L("开发机专项"), [.nodemodules, .docker, .devcache])
                sideSection(L("清理"), [.caches, .orphans, .trash])
                sideSection(L("关于"), [.appearance, .feedback])
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
                SidebarRow(panel: panel, amount: scans.amount(panel),
                           isSelected: selection == panel) {
                    withAnimation(theme.animation) { selection = panel }
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

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(v)"
    }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        // GeometryReader 是「要多少给多少」，不是「内容多大我要多大」——
        // macOS 13 的 ScrollView/List 会把内容的完整高度报成自己的理想尺寸，
        // 于是整列被撑到九百多点，窗口装不下时不是滚动而是上下各切一截：
        // 页头被顶出窗口顶、内容从红绿灯底下穿出去。这里把高度钉死在列上，
        // 内容才真的在自己框里滚。
        GeometryReader { proxy in
            VStack(spacing: 0) {
                // 提示条原来浮在页头上（ZStack + 顶部内边距），一有撤销提示就把标题糊住。
                // 现在它是版面的一行：出现时把内容顶下去，谁也不盖谁。
                NoticeBar()
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
        }
    }
}

// MARK: - 侧边栏行

private struct SidebarRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var panel: AppPanel
    /// 这一类量出来的容量；nil = 这一页还没扫过，那一格什么都不写。
    var amount: Int64? = nil
    var isSelected: Bool
    var tap: () -> Void

    @State private var hovering = false

    private var isDark: Bool {
        (theme.scheme ?? colorScheme) == .dark
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                // 导航图标一律浅底同色：十一个实心彩块排下来就是启动器，
                // 而且实心主色块在我们这套形状语言里=「推进/花钱」的主按钮。
                IconTile(symbol: panel.symbol, side: 22,
                         fill: theme.tileColor(index: panel.tileIndex, dark: isDark),
                         muted: true)
                Text(panel.title)
                    .font(theme.bodyFont(.callout).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                // 各页那笔账不同源（缓存那格套在别的条目里、重复那格只数多出来的副本），
                // 加不到一起，所以这一列不强行统一单位：统一成 GB 会把 300 MB 那类
                // 印成 0.3 GB，反而看不清谁大谁小。
                if let amount, amount > 0 {
                    Text(human(amount))
                        .font(theme.bodyFont(.caption2))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? theme.palette.inkSecondary
                                                    : theme.palette.inkTertiary)
                        .fixedSize()
                }
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
                .overlay(alignment: .leading) {
                    Capsule().fill(theme.palette.tint)
                        .frame(width: 3)
                        .padding(.vertical, 5)
                        .offset(x: -1)
                }
        } else if hovering {
            shape.fill(theme.palette.surfaceAlt.opacity(0.8))
        }
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
