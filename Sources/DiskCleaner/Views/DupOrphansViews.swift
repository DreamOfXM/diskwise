import SwiftUI
import DiskCleanerCore

// ── 重复文件：每组保留最早的一个，其余可删 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class DupModel: ObservableObject {
    @Published var groups: [DupGroup] = []
    @Published var scanning = false
    @Published var progress = ""
    @Published var minMB = 20
    @Published var selection: Set<String> = []   // 选中待删的文件 path
    /// 本轮实际用的范围，页头贴标签用
    @Published private(set) var scope: ScanScope = .user
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    var waste: Int64 { groups.reduce(0) { $0 + $1.waste } }
    var selectedCount: Int { selection.count }

    func scan(scope: ScanScope) {
        task?.cancel()
        scanning = true
        started = true
        self.scope = scope
        groups = []
        selection = []
        let minB = Int64(minMB) * MB
        let targets = defaultScanDirs(scope: scope)
        task = Task {
            self.progress = L("遍历文件…")
            // 只留下我们删得动的：整盘扫描会走进 /Library、/opt 这些 root 地盘，
            // 那些重复归包管理器管，列出来只会让用户去点一个注定失败的勾选框。
            let files = await walkFiles(dirs: targets, minSize: minB,
                                        skipNames: ["node_modules", ".git", "Caches"])
                .rows.filter(\.deletable)
            if Task.isCancelled { return }
            self.progress = LF("比对内容（%@ 个候选）…", String(files.count))
            // 哈希是同步重活，扔后台线程做
            let gs = await Task.detached { findDupGroups(files) }.value
            if !Task.isCancelled {
                self.groups = gs
                self.scanning = false
                self.progress = ""
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }

    func selectAllButFirst() {
        for g in groups {
            for u in g.files.dropFirst() { selection.insert(u.path) }
        }
    }
}

struct DupView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: DupModel
    @State private var confirm = false
    @State private var err: String? = nil

    var selectedBytes: Int64 {
        var sizeByPath: [String: Int64] = [:]
        for g in model.groups {
            for u in g.files { sizeByPath[u.path] = g.size }
        }
        return model.selection.reduce(0) { $0 + (sizeByPath[$1] ?? 0) }
    }

    /// 全页最狠一组的浪费量，给组间比例条当分母
    private var maxWaste: Int64 { max(1, model.groups.map(\.waste).max() ?? 1) }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "square.on.square", title: L("重复文件"),
                           subtitle: L("每组最早的那份永远保留，动其余的"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: model.progress.isEmpty ? L("正在比对…") : model.progress)
                    } else {
                        Text(LF("发现 %1$@，可收回约 %2$@",
                                cnt(model.groups.count, "组重复"), human(model.waste)))
                    }
                    ThemeBadge(text: LF("范围：%@", model.scope.uiName),
                               tone: .neutral, symbol: "scope")
                } trailing: {
                    ThemeStepper(label: "≥", unit: "MB", value: $model.minMB,
                                 range: 5...500, step: 5) { model.scan(scope: store.scope) }
                    ThemeButton(kind: .secondary, symbol: "checkmark.rectangle.stack",
                                title: L("全选多余"),
                                isDisabled: model.groups.isEmpty) { model.selectAllButFirst() }
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan(scope: store.scope) }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.groups.isEmpty {
                scanningState(scope: model.scope)
            } else if !model.scanning && model.groups.isEmpty {
                EmptyState(symbol: "checklist", title: L("没有重复文件"),
                           hint: LF("%1$@以上的都查过了，调低还能再找些小的，但更慢",
                                    "\(model.minMB) MB"))
                    .frame(maxHeight: .infinity)
            } else {
                List(model.groups) { g in
                    DupGroupRow(group: g, selection: $model.selection, maxWaste: maxWaste)
                        .themedRow()
                }
                .themedList()
            }

            CleanBar(count: model.selectedCount, bytes: selectedBytes,
                     errorText: err) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !model.started { model.scan(scope: store.scope) } }
        .onChange(of: store.scanEpoch) { _ in model.scan(scope: store.scope) }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@移入废纸篓（每组最早的一份永远保留）。",
                               cnt(model.selectedCount, "个多余副本"))) {
            doClean()
        }
    }

    private func doClean() {
        err = nil
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

// MARK: - 重复组

private struct DupGroupRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var group: DupGroup
    @Binding var selection: Set<String>
    var maxWaste: Int64

    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(reduceMotion ? nil : theme.animation) { expanded.toggle() }
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: expanded ? "chevron-down" : "chevron-right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .frame(width: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(LF("%1$@ 等 %2$@",
                                group.files.first?.lastPathComponent ?? L("重复组"),
                                cnt(group.files.count, "份")))
                            .font(theme.bodyFont(.callout))
                            .foregroundStyle(theme.palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(LF("每份 %@", human(group.size)))
                            .font(theme.bodyFont(.caption2))
                            .foregroundStyle(theme.palette.inkTertiary)
                    }
                    Spacer(minLength: 10)
                    ThemeBadge(text: LF("可收回 %@", human(group.waste)), tone: .tint)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ProportionBar(fraction: fraction, color: theme.palette.chart[3])
                .padding(.leading, 21)

            if expanded {
                VStack(spacing: 2) {
                    ForEach(Array(group.files.enumerated()), id: \.element.path) { idx, url in
                        fileRow(url, isKept: idx == 0)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            theme.cardShape().fill(hovering ? theme.palette.surfaceAlt.opacity(0.5)
                                           : theme.palette.surface)
        )
        .overlay(theme.cardShape().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
        .onHover { hovering = $0 }
    }

    /// 组内浪费占全页最狠一组的比例——一眼看出哪组最值得动
    private var fraction: Double {
        Double(group.waste) / Double(max(1, maxWaste))
    }

    private func fileRow(_ url: URL, isKept: Bool) -> some View {
        HStack(spacing: 10) {
            if isKept {
                ThemeBadge(text: L("保留"), tone: .safe, symbol: "lock.fill")
                    .frame(minWidth: 62, alignment: .leading)
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
            Text(url.path)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(isKept ? theme.palette.inkTertiary : theme.palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.leading, 21)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
    private var task: Task<Void, Never>? = nil

    var selected: [OrphanItem] { items.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + ($1.size ?? 0) } }
    var totalBytes: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }

    /// 全选只扫「安全」那批：这页的立脚点是宁可漏报不可误删，标「留意」的意思是
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
        task = Task {
            let (list, apps) = await scanOrphans()
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
    @ObservedObject var model: OrphansModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "app.badge", title: L("卸载残留"),
                           subtitle: L("App 卸载了，数据没带走——按已装应用逐一对过"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在盘点已装应用、对孤儿…"))
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

            if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "app.badge.checkmark", title: L("没有卸载残留"),
                           hint: L("每个犄角旮旯都对得上号，挺干净"))
                    .frame(maxHeight: .infinity)
            } else {
                List($model.items) { $it in
                    ItemRow(selected: $it.selected,
                            name: it.name,
                            sub: it.loc,
                            sizeText: human(it.size ?? 0),
                            fraction: Double(it.size ?? 0) / Double(maxSize),
                            badge: ItemBadge(text: it.level == "warn" ? L("留意") : L("安全"),
                                             tone: it.level == "warn" ? .warn : .safe)) {
                        ExplainLine(key: L("这是什么"), value: orphanWhat(it))
                        ExplainLine(key: L("删了会怎样"), value: orphanRisk(it))
                        ExplainLine(key: L("怎么恢复"), value: L("从废纸篓还原，或重装该应用"))
                        PathLine(path: it.path.path)
                    }
                    .themedRow()
                }
                .themedList()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     errorText: err, selection: model.selectAll) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !model.started { model.scan() } }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "处残留"),
                               human(model.selectedBytes))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.items.compactMap(\.size).max() ?? 1) }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        for it in model.selected {
            do {
                let t = try trashItem(it.path)
                store.record(TrashRecord(original: it.path, inTrash: t, size: it.size ?? 0, displayName: it.name))
                ok += 1
            } catch { errs.append(failLine(it.name, error)) }
        }
        model.items.removeAll { !FileManager.default.fileExists(atPath: $0.path.path) }
        for i in model.items.indices { model.items[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "处残留", failed: errs.count)
    }
}
