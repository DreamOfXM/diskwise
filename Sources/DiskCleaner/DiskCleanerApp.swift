import SwiftUI
import DiskCleanerCore

@main
struct DiskCleanerApp: App {
    @StateObject private var store = AppStore()
    @StateObject private var themeManager = ThemeManager.shared

    init() {
        // 截图模式自己 exit，不会回到这里往下走
        if let outDir = SnapshotMode.requestedDir { SnapshotMode.run(outDir: outDir) }
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

// 全 App 共享：废纸篓历史（撤销用）+ 顶部提示条 + 跨页跳转
@MainActor
final class AppStore: ObservableObject {
    @Published var trashHistory: [TrashRecord] = []
    @Published var notice: String? = nil
    @Published var jumpTo: AppPanel? = nil
    @Published var bigScanDir: URL? = nil   // 总览跳过来的定向扫描目录

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
    case overview, big, old, dup, nodemodules, docker, caches, orphans, trash, appearance

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
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(SidebarMaterial())
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
            .foregroundStyle(theme.palette.inkTertiary)
            .padding(.leading, 8)
            .padding(.top, 10)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 4) {
            Divider().overlay(theme.palette.separator).padding(.horizontal, 12)
            Text("\(Product.name) \(versionString)")
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)
        }
        .background(SidebarMaterial())
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(v)"
    }

    // MARK: 详情

    @ViewBuilder private var detail: some View {
        ZStack(alignment: .top) {
            Group {
                switch selection ?? .overview {
                case .overview: OverviewView()
                case .big: BigFilesView()
                case .old: OldFilesView()
                case .dup: DupView()
                case .nodemodules: NMView()
                case .docker: DockerView()
                case .caches: CachesView()
                case .orphans: OrphansView()
                case .trash: TrashView()
                case .appearance: AppearanceView()
                }
            }
            NoticeBar()
        }
        .animation(theme.animation, value: store.notice)
        .background(ThemedBackdrop())
        .navigationTitle(selection?.title ?? L("空间总览"))
        .navigationSubtitle(subtitleForSelection)
    }

    private var subtitleForSelection: String {
        if selection == .appearance && theme.tier == .free {
            return LF("免费 %1$d 套 · 付费 %2$d 套",
                      Theme.all.filter { $0.tier == .free }.count,
                      Theme.all.filter { $0.tier == .premium }.count)
        }
        return ""
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
private struct SidebarMaterial: View {
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            ThemedBackdrop()
            if theme.elevation == .glass {
                Rectangle().fill(.thinMaterial)
                theme.palette.paper.opacity(0.28)
            } else {
                theme.palette.paper.opacity(0.55)
            }
        }
    }
}
