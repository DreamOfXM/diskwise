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
    @Published var scanning = false
    /// 已经量完的目录数。环形要等全部量完才谈得上「未扫描」，所以这个数得露出来。
    @Published private(set) var done = 0
    @Published private(set) var pending = 0
    /// 扫过的目录合计占多少。环形的「未扫描」= 已用 − 这个数，整张图的口径全靠它。
    @Published private(set) var covered: Int64 = 0
    @Published private(set) var started = false
    /// 本轮扫描用的范围。显示的是「扫的时候是什么范围」，不是当前选择——
    /// 切了范围但还没重扫时，界面得说真话。
    @Published private(set) var scope: ScanScope = .user
    private var task: Task<Void, Never>? = nil

    /// 小于这个数不进列表：家目录一级有上百个点目录，绝大多数是几 KB 的配置夹。
    static let sizeFloor: Int64 = 100 * 1024 * 1024
    /// 列表封顶。再长就没人逐行扫了，多出来的体积并进环形的「其他已统计」。
    static let listCap = 20

    /// 只刷磁盘余量——可用空间随时在变，进页面就该是新的；
    /// 热点体积要遍历整棵家目录，不能跟着一起重跑。
    func refreshUsage() { usage = volumeUsage() }

    func refresh(scope: ScanScope) {
        task?.cancel()
        usage = volumeUsage()
        scanning = true
        started = true
        self.scope = scope
        hotspots = []
        covered = 0
        done = 0
        task = Task {
            let targets = hotspotTargets(scope)
            pending = targets.count
            var sized: [(name: String, path: String, size: Int64)] = []
            var total: Int64 = 0
            await withTaskGroup(of: (Int, Int64).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask { (i, await dirSize(URL(fileURLWithPath: t.path))) }
                }
                // 组按完成顺序回，不是提交顺序——所以子任务必须把下标带回来。
                for await (i, sz) in group {
                    if Task.isCancelled { break }
                    let t = targets[i]
                    pending -= 1
                    done += 1
                    total += sz
                    covered = total
                    if sz > Self.sizeFloor {
                        sized.append((t.name, t.path, sz))
                        sized.sort { $0.size > $1.size }
                        hotspots = Array(sized.prefix(Self.listCap))
                    }
                }
            }
            if !Task.isCancelled { scanning = false }
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
    }

    /// 扫描对象 = 范围内的系统根 + 家目录一级（点目录算在内）。
    ///
    /// 点目录必须算：开发机上最能吃盘的往往就是 ~/.omlx、~/.ollama 这类模型仓库，
    /// 只扫可见目录等于把整机最大的一块藏起来——实测一台机器上因此少报了 42GB，
    /// 而当时列表第一名只有 39.7GB。
    ///
    /// 系统根先进 `seen`、家目录一级后进，是为了去重：演示树把 /Applications 挂在
    /// 假家目录底下，同一个 path 进两遍不是重复一行那么简单——列表以 path 作
    /// ForEach 的 id，第二条会占住行高却什么都不画，环形还会把它算两遍。
    private func hotspotTargets(_ scope: ScanScope) -> [(name: String, path: String)] {
        var out: [(name: String, path: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ path: String) {
            guard seen.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted
            else { return }
            out.append((name, path))
        }
        add("/Applications", applicationsDir())
        if scope == .disk {
            for r in systemScanRoots() where r.lastPathComponent != "Applications" {
                add(systemRootName(r), r.path)
            }
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
    @ObservedObject var model: OverviewModel

    var body: some View {
        // 页头钉在滚动区外面：它是这一屏的标题，滚走了就没人知道自己在哪页。
        // 下面仍然只有一个 ScrollView——macOS 13 的 ScrollView 会把内容的完整高度
        // 当成自己的理想尺寸报上去，套两层就会把 detail 列顶成一千六百多点。
        VStack(spacing: 0) {
            PageHeader(symbol: "internaldrive", title: L("空间总览"),
                       subtitle: L("先看清，再下手——下面每块地方都能一键深挖"),
                       variant: .display) {
                HStack(spacing: 12) {
                    SegmentedStrip(symbols: ["house", "internaldrive"],
                                   labels: ScanScope.allCases.map(\.uiName),
                                   isOn: { store.scope == ScanScope.allCases[$0] },
                                   select: { i in store.setScope(ScanScope.allCases[i]) },
                                   a11yPrefix: L("扫描范围"))
                    ScanControl(scanning: model.scanning, kind: .primary,
                                rescan: { model.refresh(scope: store.scope) },
                                stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: theme.metric.sectionGap) {
                    if let u = model.usage {
                        heroCard(u)
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
                        }
                    }
                    .pagePadding()
                }
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.started ? model.refreshUsage() : model.refresh(scope: store.scope) }
        .onChange(of: store.scanEpoch) { _ in model.refresh(scope: store.scope) }
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
                              legendWidth: 258)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 3) {
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
                            metric(L("可用"), human(u.free))
                        }
                        if u.free < 20 * 1024 * 1024 * 1024 {
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
            }
        }
    }

    private var scopeNote: String {
        if HomeAccess.runsSandboxed {
            return L("覆盖范围：你授权过的目录。系统区在沙盒里读不到，所以单列为「未覆盖」。")
        }
        return model.scope == .disk
            ? L("覆盖范围：整块盘上普通用户可读的位置。剩下的「未覆盖」是系统卷和只有管理员能读的目录，不在清理范围内。")
            : L("覆盖范围：家目录（含隐藏项）与 /Applications。剩下的「未覆盖」在系统区，切到「整盘」能多覆盖一块。")
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

    /// 环形分段 = 前 3 大热点 + 其余已量完的 + 没扫到的 + 可用，四段加起来正好等于整块盘。
    ///
    /// 「没扫到的」必须单列。以前把「排在列表 5-20 名」和「压根没扫」揉成一块灰色
    /// 「其他已用」，实测一台机器上那块占 70%，于是用户自然要问「怎么才列出这么点」——
    /// 因为图上根本分不清是没扫到，还是扫了觉得不值一提。
    private func gaugeSegments(_ u: VolumeUsage) -> [GaugeSegment] {
        let top = Array(model.hotspots.prefix(3))
        let topSum = top.reduce(Int64(0)) { $0 + $1.size }
        var out: [GaugeSegment] = []
        for (i, h) in top.enumerated() {
            out.append(GaugeSegment(label: h.name, value: h.size,
                                    color: theme.palette.chart[i % theme.palette.chart.count]))
        }
        let restScanned = max(0, model.covered - topSum)
        if restScanned > 0 {
            // 下标 4 是每套配色里最弱的一支（见 ARCHITECTURE §4.2）：这一段可能很大，
            // 给它强色会把前三名的柱子糊掉。
            out.append(GaugeSegment(label: L("其他已统计"), value: restScanned,
                                    color: theme.palette.chart[min(4, theme.palette.chart.count - 1)]))
        }
        let untouched = max(0, u.used - model.covered)
        if untouched > 0 {
            out.append(GaugeSegment(label: L("未覆盖区域"), value: untouched,
                                    color: theme.palette.inkTertiary.opacity(0.45)))
        }
        out.append(GaugeSegment(label: L("可用"), value: u.free, color: theme.palette.separator))
        return out
    }

    // MARK: 热点列表

    private var maxHotspotSize: Int64 {
        max(1, model.hotspots.map { $0.size }.max() ?? 1)
    }

    private var hotspotList: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.hotspots, id: \.path) { row in
                HotspotRow(name: row.name, path: row.path, size: row.size,
                           fraction: Double(row.size) / Double(maxHotspotSize))
            }
        }
    }
}

// MARK: - 热点行

private struct HotspotRow: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var name: String
    var path: String
    var size: Int64
    var fraction: Double

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: glyph, side: 26,
                     fill: theme.tileColor(index: tileIndex, dark: isDark),
                     muted: true)
            VStack(alignment: .leading, spacing: 7) {
                Text(name)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProportionBar(fraction: fraction)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(human(size))
                .font(theme.numeric(.callout))
                .monospacedDigit()
                .foregroundStyle(theme.palette.ink)
                .fixedSize()

            // 「访达显示」常驻占位、只在悬停时显形：它一插进来就会把右边的数值从
            // 自己那一列顶走，而数值列是这张表唯一的对齐轴。
            HStack(spacing: 6) {
                ThemeButton(kind: .compact, title: L("访达显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)

                ThemeButton(kind: .compact, title: L("深挖")) {
                    store.bigScanDir = URL(fileURLWithPath: path)
                    store.jumpTo = .big
                }
                .accessibilityLabel(LF("去大文件页只扫%@", name))
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
