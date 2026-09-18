import SwiftUI
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
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowToolbarStyle(.unified)
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
    let caches = CachesModel()
    let orphans = OrphansModel()
}

// 全 App 共享：废纸篓历史（撤销用）+ 顶部提示条 + 跨页跳转
@MainActor
final class AppStore: ObservableObject {
    @Published var trashHistory: [TrashRecord] = []
    @Published var notice: String? = nil
    @Published var jumpTo: AppPanel? = nil
    @Published var bigScanDir: URL? = nil   // 总览跳过来的定向扫描目录
    /// 用户选的界面语言。改它 = 让整棵树重画，所以切语言不用重启（商店版也不能自己重启）。
    @Published private(set) var languageChoice: AppLanguage = L10n.choice

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
    case overview, big, old, dup, nodemodules, docker, caches, orphans, trash, appearance, feedback

    var symbol: String {
        switch self {
        case .overview: return "internaldrive"
        case .big: return "doc.on.doc"
        case .old: return "clock"
        case .dup: return "square.on.square"
        case .nodemodules: return "shippingbox"
        case .docker: return "cube"
        case .caches: return "sparkles"
        case .orphans: return "app.badge"
        case .trash: return "trash"
        case .appearance: return "paintpalette"
        case .feedback: return "text.bubble"
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
        case .caches: return "缓存清理"
        case .orphans: return "卸载残留"
        case .trash: return "废纸篓"
        case .appearance: return "外观皮肤"
        case .feedback: return "问题反馈"
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
    @State private var selection: AppPanel? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 216, ideal: 232, max: 280)
        } detail: {
            detail
        }
        .onChange(of: store.jumpTo) { target in
            guard let target else { return }
            withAnimation(theme.animation) { selection = target }
            store.jumpTo = nil
        }
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sideSection(L("看清空间"), [.overview, .big, .old, .dup])
                sideSection(L("开发机专项"), [.nodemodules, .docker])
                sideSection(L("清理"), [.caches, .orphans, .trash])
                sideSection(L("个性化"), [.appearance])
                sideSection(L("支持"), [.feedback])
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 这一列的初始位置本来就在标题栏下面（安全区已经把 unified 标题栏那 52pt 让出来了），
        // 但 ScrollView 会把内容一路画到窗口顶：滚一下，段标题就钻进红绿灯里。
        // 夹在布局边界上，滚过头也只是在标题栏那条线处消失。
        .clipped()
        .background(SidebarMaterial().ignoresSafeArea())
        .disabled(grant.needsGrant)
        .opacity(grant.needsGrant ? 0.4 : 1)
        .safeAreaInset(edge: .bottom, spacing: 0) { sidebarFooter }
    }

    private func sideSection(_ title: String, _ panels: [AppPanel]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            sideHeader(title).padding(.bottom, 2)
            ForEach(panels, id: \.self) { panel in
                SidebarRow(panel: panel, isSelected: selection == panel) {
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
        ZStack(alignment: .top) {
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
            NoticeBar()
        }
        .animation(theme.animation, value: store.notice)
        .background(ThemedBackdrop())
        .navigationTitle(grant.needsGrant ? L("访问授权") : (selection?.title ?? L("空间总览")))
        .navigationSubtitle(subtitleForSelection)
    }

    @ViewBuilder private var page: some View {
        switch selection ?? .overview {
        case .overview: OverviewView(model: scans.overview)
        case .big: BigFilesView(model: scans.big)
        case .old: OldFilesView(model: scans.old)
        case .dup: DupView(model: scans.dup)
        case .nodemodules: NMView(model: scans.nodemodules)
        case .docker: DockerView(model: scans.docker)
        case .caches: CachesView(model: scans.caches)
        case .orphans: OrphansView(model: scans.orphans)
        case .trash: TrashView()
        case .appearance: AppearanceView()
        case .feedback: FeedbackView()
        }
    }

    private var subtitleForSelection: String {
        if grant.needsGrant { return L("授权完成后这里就能看到空间去哪了") }
        guard selection == .appearance else { return "" }
        if Channel.showsPricing {
            guard theme.tier == .free else { return "" }
            return LF("免费 %1$d 套 · 付费 %2$d 套",
                      Theme.all.filter { $0.tier == .free }.count,
                      Theme.all.filter { $0.tier == .premium }.count)
        }
        return LF("共 %d 套皮肤", Theme.all.count)
    }
}

// MARK: - 侧边栏行

private struct SidebarRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var panel: AppPanel
    var isSelected: Bool
    var tap: () -> Void

    @State private var hovering = false

    private var isDark: Bool {
        (theme.scheme ?? colorScheme) == .dark
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                IconTile(symbol: panel.symbol, side: 24,
                         fill: theme.tileColor(index: panel.tileIndex, dark: isDark),
                         foreground: isDark && theme.tileStrategy == .spectrum
                            ? theme.palette.paper : .white)
                Text(panel.title)
                    .font(theme.bodyFont(.callout).weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
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
