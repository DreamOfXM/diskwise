import SwiftUI
import DiskCleanerCore
import AppKit

// ── 空间总览：磁盘用量 + 主目录一级热点 ──
// 这一屏是磁盘清理类产品的门面，所以给了环形仪表：
// 一眼看清"整块盘被谁吃了"，比一根进度条有力得多。

@MainActor
final class OverviewModel: ObservableObject {
    @Published var usage: VolumeUsage? = nil
    @Published var hotspots: [(name: String, path: String, size: Int64?)] = []
    @Published var scanning = false
    private var task: Task<Void, Never>? = nil

    func refresh() {
        task?.cancel()
        usage = volumeUsage()
        scanning = true
        hotspots = []
        task = Task {
            let home = homePath()
            let appsPath = applicationsDir()
            var targets: [(String, String)] = []
            if let kids = try? FileManager.default.contentsOfDirectory(atPath: home) {
                for k in kids where !k.hasPrefix(".") {
                    let p = (home as NSString).appendingPathComponent(k)
                    if p == appsPath { continue }   // 单独一行，标签写 /Applications
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                        targets.append(("~/\(k)", p))
                    }
                }
            }
            targets.append(("/Applications", appsPath))
            var rows: [(String, String, Int64?)] = targets.map { ($0.0, $0.1, nil) }
            self.hotspots = rows
            await withTaskGroup(of: (Int, Int64).self) { group in
                for (i, t) in targets.enumerated() {
                    group.addTask { (i, await dirSize(URL(fileURLWithPath: t.1))) }
                }
                for await (i, sz) in group {
                    if Task.isCancelled { break }
                    rows[i].2 = sz
                    self.hotspots = rows.sorted { ($0.2 ?? -1) > ($1.2 ?? -1) }
                }
            }
            if !Task.isCancelled {
                self.hotspots = rows
                    .filter { ($0.2 ?? 0) > 100 * 1024 * 1024 }
                    .sorted { ($0.2 ?? -1) > ($1.2 ?? -1) }
                self.scanning = false
            }
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @StateObject private var model = OverviewModel()

    var body: some View {
        // 整页只有一个滚动容器：macOS 13 的 ScrollView 会把内容的完整高度
        // 当成自己的理想尺寸报上去，套两层就会把 detail 列顶成一千六百多点
        ScrollView {
            VStack(alignment: .leading, spacing: theme.metric.sectionGap) {
                PageHeader(symbol: "internaldrive", title: L("空间都去哪了"),
                           subtitle: L("先看清，再下手——下面每块地方都能一键深挖"),
                           variant: .display) {
                    if model.scanning {
                        ThemeButton(kind: .secondary, symbol: "stop.fill",
                                    title: L("停止")) { model.stop() }
                    } else {
                        ThemeButton(kind: .primary, symbol: "arrow.clockwise",
                                    title: L("重新扫描")) { model.refresh() }
                    }
                }
                .pagePadding()

                if let u = model.usage {
                    heroCard(u)
                        .pagePadding()
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(text: L("最占地方的文件夹"),
                                 detail: model.scanning ? L("统计中…") : cnt(model.hotspots.count, "项"))
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
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L("空间总览"))
        .onAppear { if model.hotspots.isEmpty { model.refresh() } }
        .onDisappear { model.stop() }
    }

    // MARK: 环形仪表 + 三个数

    private func heroCard(_ u: VolumeUsage) -> some View {
        ThemedCard {
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
        }
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

    /// 环形分段 = 前 4 大热点 + 其他已用 + 可用，加起来正好等于整块盘
    private func gaugeSegments(_ u: VolumeUsage) -> [GaugeSegment] {
        let top = Array(model.hotspots.prefix(4))
        let shown = top.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        var out: [GaugeSegment] = []
        for (i, h) in top.enumerated() {
            out.append(GaugeSegment(label: h.name, value: h.size ?? 0,
                                    color: theme.palette.chart[i % theme.palette.chart.count]))
        }
        let other = max(0, u.used - shown)
        if other > 0 {
            out.append(GaugeSegment(label: L("其他已用"), value: other,
                                    color: theme.palette.chart[min(4, theme.palette.chart.count - 1)]))
        }
        out.append(GaugeSegment(label: L("可用"), value: u.free, color: theme.palette.separator))
        return out
    }

    // MARK: 热点列表

    private var maxHotspotSize: Int64 {
        max(1, model.hotspots.compactMap { $0.size }.max() ?? 1)
    }

    private var hotspotList: some View {
        LazyVStack(spacing: 8) {
            ForEach(model.hotspots, id: \.path) { row in
                HotspotRow(name: row.name, path: row.path, size: row.size,
                           fraction: Double(row.size ?? 0) / Double(maxHotspotSize))
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
    var size: Int64?
    var fraction: Double

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: glyph, side: 26,
                     fill: theme.tileColor(index: tileIndex, dark: isDark),
                     foreground: isDark && theme.tileStrategy == .spectrum
                        ? theme.palette.paper : .white)
            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProportionBar(fraction: fraction, height: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(size.map { human($0) } ?? L("统计中…"))
                .font(theme.numeric(.callout))
                .monospacedDigit()
                .foregroundStyle(size == nil ? theme.palette.inkTertiary : theme.palette.ink)
                .fixedSize()

            HStack(spacing: 6) {
                if hovering || size == nil {
                    ThemeButton(kind: .compact, title: L("访达显示")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
                ThemeButton(kind: .compact, title: L("深挖")) {
                    store.bigScanDir = URL(fileURLWithPath: path)
                    store.jumpTo = .big
                }
                .accessibilityLabel(LF("去大文件页只扫%@", name))
            }
            .opacity(hovering ? 1 : 0.99)
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

    /// 常用目录给固定色，其余按路径哈希取色——同一台机器上每次打开位置不变
    private var tileIndex: Int {
        switch name {
        case "/Applications": return 3
        case "~/Downloads": return 6
        case "~/Desktop": return 2
        case "~/Library": return 8
        default: return abs(path.hashValue) % 10
        }
    }

    private var glyph: String {
        switch name {
        case "/Applications": return "app"
        case "~/Downloads": return "arrow.down.circle"
        case "~/Desktop": return "menubar.dock.rectangle"
        case "~/Library": return "books.vertical"
        default: return "folder"
        }
    }
}
