import DiskCleanerCore
import SwiftUI

// 诊断与转储：崩溃转储 / 系统诊断报告 / 观察区三页，共用一个数据源（DiagnosticsHub）。
// 设计出处：plans/design-ui-and-interfaces-2026-10-27.md 屏①②⑦（PR-1 范围）。
// 流速徽标（PR-2）、归属抽屉（PR-3）、保留策略（PR-4）都在这份骨架上往上叠。

// MARK: - 数据源

/// 一次类别发现的三页数据 + 选择状态，由 `ScanStore` 持有。
/// 扫描结果必须是 App 级状态：侧栏切分支、页面视图随导航销毁，模型跟着视图走就会
/// 每切一次重跑一遍定向遍历（`DiskCleanerApp` 对全部八页的同一条教训）。
@MainActor
final class DiagnosticsHub: ObservableObject {
    @Published private(set) var hits: [CategoryHit] = []
    @Published private(set) var reports: [ReportFile] = []
    @Published private(set) var observation: [ObservationItem] = []
    @Published private(set) var scanning = false
    @Published private(set) var started = false
    /// 流速徽标按 entryKey 挂在行上；异常粘滞到增长回落（评审 §2.1c）。
    @Published private(set) var velocity: [String: VelocityReport] = [:]
    /// 本轮没有任何可比的基线：首扫或历史全在 10 分钟内，页头提一句「下次起可对比」。
    @Published private(set) var baselinePending = false
    @Published var hitSelection = Set<String>()
    @Published var reportSelection = Set<String>()
    private var task: Task<Void, Never>? = nil
    /// 快照库。库坏了静默降级——快照是增益不是地基， velocities 为空即没有流速可看。
    private lazy var snapshots: SnapshotStore = SnapshotStore(path: SnapshotStore.defaultPath())

    /// 侧栏「诊断与转储」分组出现的判据：两页都空就不占位（设计稿屏①：无命中整组不出现）。
    var hasFindings: Bool { !hits.isEmpty || !reports.isEmpty }

    var totalBytes: Int64 { hits.reduce(0) { $0 + $1.bytes } }
    var selectedHits: [CategoryHit] { hits.filter { hitSelection.contains($0.id) } }
    var selectedBytes: Int64 { selectedHits.reduce(0) { $0 + $1.bytes } }

    var reportBytes: Int64 { reports.reduce(0) { $0 + $1.size } }
    var selectedReports: [ReportFile] { reports.filter { reportSelection.contains($0.id) } }
    var selectedReportBytes: Int64 { selectedReports.reduce(0) { $0 + $1.size } }

    var hitSelectAll: SelectAll? {
        guard !hits.isEmpty else { return nil }
        return SelectAll(allSelected: hits.allSatisfy { hitSelection.contains($0.id) },
                         unselectable: 0) { on in
            if on { self.hitSelection = Set(self.hits.map(\.id)) } else { self.hitSelection = [] }
        }
    }

    var reportSelectAll: SelectAll? {
        guard !reports.isEmpty else { return nil }
        return SelectAll(allSelected: reports.allSatisfy { reportSelection.contains($0.id) },
                         unselectable: 0) { on in
            if on { self.reportSelection = Set(self.reports.map(\.id)) } else { self.reportSelection = [] }
        }
    }

    /// 定向遍历。`force` 供页内那颗重扫用；启动后首次调用由 `ContentView` 触发——
    /// 类别发现挂的是启动节奏，不是哪一页的懒扫描（评审 §2.2：侧栏计数不能鸡生蛋）。
    func discover(force: Bool = false) {
        guard force || !started else { return }
        task?.cancel()
        scanning = true
        started = true
        let home = homeDir()
        task = Task {
            let report = await discoverDiagnosticCategories(home: home)
            guard !Task.isCancelled else { return }
            hits = report.hits
            reports = report.userReports
            observation = report.observation
            hitSelection.formIntersection(Set(hits.map(\.id)))
            reportSelection.formIntersection(Set(reports.map(\.id)))
            self.applyVelocity(for: report.hits)
            scanning = false
        }
    }

    func stop() {
        task?.cancel()
        guard scanning else { return }
        scanning = false
    }

    /// 本轮扫描的流速结算：算两档徽标、写快照。
    /// 基线是距今 ≥10 分钟的上一次扫描——连扫两次不换基线；Δ≤0 才撤徽标（粘滞）。
    private func applyVelocity(for hits: [CategoryHit]) {
        let scanID = UUID().uuidString
        let now = Date()
        let snaps = hits.map {
            ScanSnapshot(entryKey: $0.path, scanID: scanID, wallTime: now,
                         bytes: $0.bytes, fileCount: $0.files, newestMtime: $0.newest)
        }
        var next: [String: VelocityReport] = [:]
        var usedBaseline = false
        for s in snaps {
            if let base = snapshots.baseline(entryKey: s.entryKey, now: now, currentScanID: scanID) {
                usedBaseline = true
                let r = VelocityReport.compute(current: s, baseline: base)
                if r.tier != nil {
                    next[s.entryKey] = r
                } else if let prev = velocity[s.entryKey], r.deltaFiles > 0 || r.deltaBytes > 0 {
                    // 仍在涨但够不着阈值：保留上一轮的异常；回落（Δ≤0）自然落空
                    next[s.entryKey] = prev
                }
            }
        }
        snapshots.record(scanID: scanID, wallTime: now, snapshots: snaps)
        velocity = next
        baselinePending = !snaps.isEmpty && !usedBaseline
    }

    /// 清理后收行。行是先转淡再收的账本语义：搬走的立刻从这页消失。
    func removeHits(_ ids: Set<String>) {
        hits.removeAll { ids.contains($0.id) }
        hitSelection.subtract(ids)
    }

    func removeReports(_ ids: Set<String>) {
        reports.removeAll { ids.contains($0.id) }
        reportSelection.subtract(ids)
    }
}

// MARK: - 崩溃转储

struct CrashDumpsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var hub: DiagnosticsHub
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "ladybug", title: L("崩溃转储"),
                           subtitle: L("崩溃时留下的现场记录，攒多了就是事故"),
                           variant: .display)
                ControlStrip {
                    if hub.scanning {
                        LoadingRow(text: L("正在系统目录里找崩溃转储…"))
                    } else if hub.baselinePending {
                        Text(L("基线已建立，下次扫描起可对比"))
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(hub.hits.count, "个应用"), human(hub.totalBytes)))
                    }
                } trailing: {
                    ScanControl(scanning: hub.scanning,
                                rescan: { hub.discover(force: true) },
                                stop: { hub.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if hub.scanning && hub.hits.isEmpty {
                EmptyState(symbol: "ladybug",
                           title: L("正在系统目录里找崩溃转储"),
                           hint: L("只翻应用数据那几层，量到多大会顺手数清"))
                    .frame(maxHeight: .infinity)
            } else if !hub.scanning && hub.hits.isEmpty {
                EmptyState(symbol: "ladybug",
                           title: L("没有发现崩溃转储"),
                           hint: L("这台机器上没有 Crashpad 结构"))
                    .frame(maxHeight: .infinity)
            } else {
                List(hub.hits) { hit in
                    ItemRow(selected: hitBinding(hit),
                            icon: .path(URL(fileURLWithPath: hit.path)),
                            name: hit.host.map { "\($0) \(L("崩溃转储"))" } ?? L("崩溃转储"),
                            sub: hitSub(hit),
                            sizeText: shown[hit.id] ?? human(hit.bytes),
                            fraction: Double(hit.bytes) / Double(maxBytes),
                            badge: velocityBadge(hit)) {
                        ExplainLine(key: L("这是什么"), value: L("崩溃时留下的现场记录"))
                        ExplainLine(key: L("删了会怎样"), value: L("删了不影响使用；再崩溃还会再生成"))
                        ExplainLine(key: L("怎么恢复"), value: L("现场记录删了就没了，也不需要恢复"))
                        PathLine(path: hit.path)
                    }
                }
                .ledgerCard()
            }

            Spacer(minLength: 0)

            CleanBar(count: hub.selectedHits.count,
                     bytes: hub.selectedBytes,
                     bytesText: human(hub.selectedBytes, inRulerOf: hub.totalBytes),
                     errorText: err,
                     selection: hub.hitSelectAll,
                     busyHint: hub.scanning ? L("这一轮还在扫；扫完或按停才动手，避免边扫边删") : nil) {
                confirm = true
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { hub.discover() }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(hub.selectedHits.count, "个应用"),
                               human(hub.selectedBytes, inRulerOf: hub.totalBytes))) {
            doClean()
        }
    }

    private var maxBytes: Int64 { max(1, hub.hits.map(\.bytes).max() ?? 1) }

    /// 整列统一到页头那个总数的单位再分摊：印出来的行加起来就是页头那句。
    private var shown: [String: String] {
        sizeColumn(hub.hits.map { (key: $0.id, bytes: $0.bytes) })
    }

    private func hitBinding(_ hit: CategoryHit) -> Binding<Bool> {
        Binding(get: { hub.hitSelection.contains(hit.id) },
                set: { on in
                    if on { hub.hitSelection.insert(hit.id) } else { hub.hitSelection.remove(hit.id) }
                })
    }

    private func hitSub(_ hit: CategoryHit) -> String {
        var parts = [displayPath(URL(fileURLWithPath: hit.path))]
        parts.append(cnt(hit.files, "个文件"))
        if let v = hub.velocity[hit.id], v.tier != nil {
            parts.append(LF("较上次 %1$@ · %2$@", "+" + cnt(v.deltaFiles, "个文件"),
                            velocityInterval(v.intervalSeconds)))
        }
        return parts.joined(separator: " · ")
    }

    /// 两档徽标：速率命中红「流速异常」、仅绝对量命中黄「显著增长」（评审 §2.1）。
    private func velocityBadge(_ hit: CategoryHit) -> ItemBadge? {
        guard let v = hub.velocity[hit.id], let tier = v.tier else { return nil }
        switch tier {
        case .red: return ItemBadge(text: L("流速异常"), tone: .danger)
        case .yellow: return ItemBadge(text: L("显著增长"), tone: .warn)
        }
    }

    private func velocityInterval(_ seconds: Double) -> String {
        let minutes = max(1, Int(seconds / 60))
        if minutes >= 1440 { return cnt(minutes / 1440, "天") }
        return cnt(minutes, "分钟")
    }

    /// 移的是可清理面（四个子目录整目录），settings.dat 与目录骨架不动。
    /// 子目录作单位是性能约束：16 万个 dump 逐个进废纸篓就是 16 万次回收登记，
    /// 四笔才落在预算内。撤销粒度随之是「一个子目录一次」，整批撤销进 PR-4 的修剪流。
    private func doClean() {
        err = nil
        let targets = hub.selectedHits
        let spec = CategoryRule.crashDumps.safeDeleteSpec
        Task { @MainActor in
            var errs: [String] = []
            var cleaned: Set<String> = []
            for hit in targets {
                guard let spec else { continue }
                let root = URL(fileURLWithPath: hit.path)
                var moved = 0
                for dir in spec.cleanTargets(under: root) {
                    guard FileManager.default.fileExists(atPath: dir.path) else { continue }
                    do {
                        let size = await dirSize(dir)
                        let dst = try trashItem(dir)
                        store.record(TrashRecord(original: dir, inTrash: dst, size: size,
                                                 displayName: "\(hit.host ?? dir.path)/Crashpad/\(dir.lastPathComponent)"))
                        moved += 1
                    } catch {
                        errs.append(failLine(dir.lastPathComponent, error))
                    }
                }
                if moved > 0 { cleaned.insert(hit.id) }
            }
            hub.removeHits(cleaned)
            if errs.isEmpty {
                store.notice = trashedNotice(cleaned.count, "个应用", failed: 0)
            } else {
                err = errList(errs)
            }
        }
    }
}

// MARK: - 系统诊断报告

struct DiagReportsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var hub: DiagnosticsHub
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "stethoscope", title: L("系统诊断报告"),
                           subtitle: L("系统排查故障用的日志，攒着是为了定位问题"),
                           variant: .display)
                ControlStrip {
                    if hub.scanning {
                        LoadingRow(text: L("正在读诊断报告目录…"))
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(hub.reports.count, "个文件"), human(hub.reportBytes)))
                    }
                } trailing: {
                    ScanControl(scanning: hub.scanning,
                                rescan: { hub.discover(force: true) },
                                stop: { hub.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if hub.scanning && hub.reports.isEmpty {
                EmptyState(symbol: "stethoscope",
                           title: L("正在读诊断报告目录"),
                           hint: L("只看 .ips、.hang、.panic 三种后缀"))
                    .frame(maxHeight: .infinity)
            } else if !hub.scanning && hub.reports.isEmpty {
                EmptyState(symbol: "stethoscope",
                           title: L("没有诊断报告"),
                           hint: L("最近没有攒下报告"))
                    .frame(maxHeight: .infinity)
            } else {
                List(hub.reports) { file in
                    ItemRow(selected: fileBinding(file),
                            icon: .path(file.url),
                            name: file.process ?? file.url.lastPathComponent,
                            sub: fileSub(file),
                            sizeText: shown[file.id] ?? human(file.size),
                            fraction: Double(file.size) / Double(maxBytes)) {
                        ExplainLine(key: L("这是什么"), value: L("系统排查故障用的日志文件"))
                        ExplainLine(key: L("删了会怎样"), value: L("删了不影响系统；排查问题时就没有依据了"))
                        PathLine(path: file.url.path)
                    }
                }
                .ledgerCard()
            }

            Spacer(minLength: 0)

            CleanBar(count: hub.selectedReports.count,
                     bytes: hub.selectedReportBytes,
                     bytesText: human(hub.selectedReportBytes, inRulerOf: hub.reportBytes),
                     errorText: err,
                     selection: hub.reportSelectAll,
                     busyHint: hub.scanning ? L("这一轮还在扫；扫完或按停才动手，避免边扫边删") : nil) {
                confirm = true
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { hub.discover() }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(hub.selectedReports.count, "个文件"),
                               human(hub.selectedReportBytes, inRulerOf: hub.reportBytes))) {
            doClean()
        }
    }

    private var maxBytes: Int64 { max(1, hub.reports.map(\.size).max() ?? 1) }

    private var shown: [String: String] {
        sizeColumn(hub.reports.map { (key: $0.id, bytes: $0.size) })
    }

    private func fileBinding(_ file: ReportFile) -> Binding<Bool> {
        Binding(get: { hub.reportSelection.contains(file.id) },
                set: { on in
                    if on { hub.reportSelection.insert(file.id) } else { hub.reportSelection.remove(file.id) }
                })
    }

    private func fileSub(_ file: ReportFile) -> String {
        displayPath(file.url.deletingLastPathComponent())
    }

    /// 报告是散文件：逐个进废纸篓，量小（几十到几百份），每份一条可撤销记录。
    private func doClean() {
        err = nil
        let targets = hub.selectedReports
        var errs: [String] = []
        for file in targets {
            do {
                let dst = try trashItem(file.url)
                store.record(TrashRecord(original: file.url, inTrash: dst, size: file.size,
                                         displayName: file.url.lastPathComponent))
            } catch {
                errs.append(failLine(file.url.lastPathComponent, error))
            }
        }
        hub.removeReports(Set(targets.map(\.id)))
        if errs.isEmpty {
            store.notice = trashedNotice(targets.count, "个文件", failed: 0)
        } else {
            err = errList(errs)
        }
    }
}

// MARK: - 观察区

/// 只读清单：能看见、动不了的东西。没有勾选框、没有清理条（设计稿屏⑦的交互红线）。
/// 原因码与 agent 通道的拒绝词同源，同一件事在两个入口叫同一个名字。
struct ObservationView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var hub: DiagnosticsHub
    @State private var asking: ObservationItem? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "eye", title: L("观察"),
                           subtitle: L("只能看、不能删的位置都在这里"),
                           variant: .display)
                ControlStrip {
                    if hub.scanning {
                        LoadingRow(text: L("正在系统目录里找崩溃转储…"))
                    } else {
                        Text(LF("共 %@", cnt(hub.observation.count, "项")))
                    }
                } trailing: {
                    ScanControl(scanning: hub.scanning,
                                rescan: { hub.discover(force: true) },
                                stop: { hub.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            List(hub.observation) { item in
                ItemRow(selected: .constant(false),
                        icon: .path(URL(fileURLWithPath: item.path)),
                        name: name(of: item),
                        sub: sub(of: item),
                        sizeText: item.bytes.map { human($0) } ?? "—",
                        fraction: 0,
                        badge: ItemBadge(text: reasonLabel(item.reason), tone: .neutral),
                        selectable: false,
                        lit: false) {
                    ExplainLine(key: L("为什么不能删"), value: reasonExplain(item.reason))
                    PathLine(path: item.path)
                }
                .contextMenu {
                    Button {
                        asking = item
                    } label: {
                        Label(L("为什么不能删"), systemImage: "questionmark.circle")
                    }
                }
            }
            .ledgerCard()

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .onAppear { hub.discover() }
        .alert(L("为什么不能删"),
               isPresented: Binding(get: { asking != nil },
                                    set: { if !$0 { asking = nil } })) {
            Button(L("知道了"), role: .cancel) {}
        } message: {
            Text(reasonExplain(asking?.reason ?? .unknownClass))
        }
    }

    private func name(of item: ObservationItem) -> String {
        let url = URL(fileURLWithPath: item.path)
        return url.lastPathComponent.isEmpty ? item.path : url.lastPathComponent
    }

    private func sub(of item: ObservationItem) -> String {
        var parts = [displayPath(URL(fileURLWithPath: item.path))]
        if let files = item.files { parts.append(cnt(files, "个文件")) }
        return parts.joined(separator: " · ")
    }
}

/// 原因码 → 短标签（行内那枚徽章）
func reasonLabel(_ reason: ObservationReason) -> String {
    switch reason {
    case .outsideAllowed: return L("在允许清理的范围之外")
    case .blacklistedSystemDir: return L("系统黑名单目录")
    case .unknownClass: return L("结构不完整，认不准")
    case .appDataUnattributed: return L("没能归属到应用的数据")
    }
}

/// 原因码 → 整句解释（右键「为什么不能删」与行内明细共用一份，两个入口一个说法）
func reasonExplain(_ reason: ObservationReason) -> String {
    switch reason {
    case .outsideAllowed:
        return L("家目录与「应用程序」之外的位置，本工具不搬动；要处理请在访达里自己动手。")
    case .blacklistedSystemDir:
        return L("系统目录在保护名单里，只有系统自己能动。")
    case .unknownClass:
        return L("名字像崩溃转储，但结构不完整；认不准就不动它。")
    case .appDataUnattributed:
        return L("还没认出这份数据属于哪个应用，先只看着。")
    }
}
