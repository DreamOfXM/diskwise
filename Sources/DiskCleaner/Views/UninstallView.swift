import SwiftUI
import DiskCleanerCore

// ── 卸载 App：挑一个，把它和它留下的数据一起搬走 ──
//
// 两栏：左边是「这台机器上装着什么」，右边是选中那个 App 名下的东西。
// 左边只列**搬得动**的（`InstalledApp.canUninstall`）——系统目录里的、以及只以链接
// 形式出现的那几份，列出来却搬不动比不列更糟；它们照样参与右边的归属判断，
// 因为「这处数据同时属于另一个已装 App」这件事不因为对方搬不动就消失。
//
// 移动顺序只有一种：先本体，后数据。本体搬不动就**一处数据也不动**——
// 那会把 App 留在盘上却没有数据，是比「没卸成」坏得多的一种结果。
// 所有路径都进废纸篓，跟别的页共用同一条撤销账（`TrashRecord`）。

// MARK: - 模型

@MainActor
final class UninstallModel: ObservableObject {
    /// 可卸载的那几份，按名字排好。系统目录里的与链接形态的不在这里。
    @Published private(set) var apps: [InstalledApp] = []
    /// 盘点到几份（含搬不动的），页头那句「对过 N 个应用」用它
    @Published private(set) var scanned = 0
    @Published private(set) var scanning = false
    @Published private(set) var started = false
    @Published var query = ""

    /// 右边这一栏此刻说的是谁
    @Published private(set) var current: InstalledApp? = nil
    @Published var items: [AppDataItem] = []
    @Published private(set) var bundleBytes: Int64? = nil
    /// 两个以上 App 都认领、因此谁都不删的那几处（只用来解释「为什么这一处没算给你」）
    @Published private(set) var sharedPaths: [URL] = []
    @Published private(set) var planning = false

    /// 全量盘点。**匹配用它，不只用 `apps`**：共用目录的另一位主人可能是个系统 App。
    private(set) var inventory: AppInventory? = nil
    private(set) var progress = ScanProgress()
    private(set) var planProgress = ScanProgress()

    private var scanTask: Task<Void, Never>? = nil
    private var planTask: Task<Void, Never>? = nil

    var shown: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return apps }
        return apps.filter { $0.name.lowercased().contains(q) || $0.bundleID.contains(q) }
    }

    var selectedBytes: Int64 { items.reduce(0) { $0 + ($1.selected ? ($1.size ?? 0) : 0) } }
    /// 这一趟要搬走多少：本体 + 勾上的数据
    var totalBytes: Int64 { (bundleBytes ?? 0) + selectedBytes }
    var moveCount: Int { 1 + items.filter(\.selected).count }

    /// 本工具自己那几份：包名跟正在跑的这份一致就是自己，不论装在哪、是哪一版。
    /// 商店版在 /Applications、手上跑的是开发版，两个包路径不同但同一个身份。
    /// 包名不同的副本（旧 key 签的、复制的另一版）是另一件事，照常可卸。
    static var ownBundleID: String { (Bundle.main.bundleIdentifier ?? "").lowercased() }

    func isSelf(_ app: InstalledApp) -> Bool {
        !Self.ownBundleID.isEmpty && app.bundleID.lowercased() == Self.ownBundleID
    }

    /// 这一页真正动得了的份数。页头那句「其中 N 个可以卸载」用它——
    /// 自己那一行还列着（置灰），但不该算进「可以卸载」。
    var uninstallableCount: Int { apps.filter { !isSelf($0) }.count }

    func scan() {
        scanTask?.cancel()
        planTask?.cancel()
        scanning = true
        started = true
        apps = []
        scanned = 0
        inventory = nil
        clearPlan()
        progress = ScanProgress()
        let p = progress
        scanTask = Task {
            let inv = await inventoryApps(progress: p)
            if Task.isCancelled { return }
            self.inventory = inv
            self.scanned = inv.appCount
            // 自己那一份留在列表里、置灰，不删掉这一行：列表少一行没人说得清是为什么，
            // 而「这一行动不了」本身就是要说清楚的事。判据是包名——商店版装在 /Applications、
            // 手上跑的是开发版，两个包不同路径但同一个身份，都算「自己」。
            // 包名不同的副本（旧 key 签的、复制的另一版）是另一件事，照常可卸。
            self.apps = inv.apps.filter(\.canUninstall)
            self.scanning = false
        }
    }

    func stop() {
        scanTask?.cancel()
        planTask?.cancel()
        scanning = false
        planning = false
    }

    /// 点了左边某一行：量它的本体，再逐处认领它的数据。
    ///
    /// 一次只量一个 App——Xcode 那种本体上百万个文件，列表里若为显示体积先全量一遍，
    /// 点开这一页要先等几分钟。
    func choose(_ app: InstalledApp?) {
        planTask?.cancel()
        guard let app, !isSelf(app), let inv = inventory else { clearPlan(); return }
        current = app
        items = []
        bundleBytes = nil
        sharedPaths = []
        planning = true
        planProgress = ScanProgress()
        let p = planProgress
        planTask = Task {
            let plan = await scanUninstall(app, inventory: inv, progress: p)
            if Task.isCancelled { return }
            self.items = plan.items
            self.bundleBytes = plan.bundleBytes
            self.sharedPaths = plan.sharedPaths
            self.planning = false
        }
    }

    /// 卸完一份：它从列表里消失，右边回到「选一个」那一屏。
    func drop(_ app: InstalledApp) {
        apps.removeAll { $0.id == app.id }
        if current?.id == app.id { clearPlan() }
    }

    private func clearPlan() {
        current = nil
        items = []
        bundleBytes = nil
        sharedPaths = []
        planning = false
    }
}

// MARK: - 这一页

struct UninstallView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: UninstallModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: AppPanel.uninstall.symbol, title: L("卸载 App"),
                           subtitle: L("应用和它留下的数据一起搬走——只动你的家目录"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在盘点已装应用…"), progress: model.progress)
                    } else {
                        Text(LF("盘点了 %1$@，其中 %2$@ 可以卸载",
                                cnt(model.scanned, "个应用"),
                                cnt(model.uninstallableCount, "个应用")))
                    }
                    ThemeBadge(text: L("只动家目录"), tone: .neutral)
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if model.scanning && model.apps.isEmpty {
                ScanChecklist(progress: model.progress)
            } else if !model.scanning && model.apps.isEmpty {
                EmptyState(symbol: "trash.slash", title: L("没有可卸载的应用"),
                           hint: L("系统目录里的 App 和以链接形式出现的 App 不列出来——它们要么搬不动，要么搬走的只是一个链接"))
                    .frame(maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    picker
                        .frame(width: 300)
                    detail
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .pagePadding()
                .frame(maxHeight: .infinity, alignment: .top)
            }

            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if !model.started { model.scan() }
            if let q = SnapshotMode.requestedQuery { model.query = q }
            pickSnapshotAppIfAsked()
        }
        // 盘完那一瞬才有人可选：进来时 `apps` 还是空的，光靠 `onAppear` 会早退。
        .onChange(of: model.apps.count) { _ in pickSnapshotAppIfAsked() }
        .alert(LF("确认卸载「%@」？", model.current?.name ?? ""), isPresented: $confirm) {
            Button(L("取消"), role: .cancel) {}
            Button(L("卸载并移进废纸篓"), role: .destructive) { run() }
        } message: {
            Text(confirmText)
        }
    }

    /// 截图钩子：`DISKWISE_APP=<名字或包名片段>` 时自己挑中那一行（见 `SnapshotMode.requestedApp`）。
    /// 挑的是左边那颗按钮按下去调的同一个 `choose`，量体积、认领数据、勾安全档全走真路。
    private func pickSnapshotAppIfAsked() {
        guard let want = SnapshotMode.requestedApp, model.current == nil,
              let app = model.shown.first(where: {
                  $0.name.lowercased().contains(want) || $0.bundleID.lowercased().contains(want)
              }) else { return }
        model.choose(app)
    }

    // MARK: 左边：装着哪些 App
    private var picker: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.inkTertiary)
                TextField(L("搜索应用"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                if !model.query.isEmpty {
                    Button {
                        model.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.palette.inkTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("清空搜索"))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(theme.controlShape().fill(theme.palette.surfaceAlt))
            .padding(10)

            Rectangle().fill(theme.palette.separator).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(model.shown) { app in
                        appRow(app)
                    }
                    if model.shown.isEmpty && !model.scanning {
                        Text(L("没有匹配的应用"))
                            .font(theme.bodyFont(.caption))
                            .foregroundStyle(theme.palette.inkTertiary)
                            .padding(.top, 18)
                    }
                }
                .padding(6)
            }
        }
        .panelCard()
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func appRow(_ app: InstalledApp) -> some View {
        let selfRow = model.isSelf(app)
        let on = !selfRow && model.current?.id == app.id
        return Button {
            model.choose(app)
        } label: {
            HStack(spacing: 9) {
                RowIconView(icon: .path(app.path), side: 26)
                    .opacity(selfRow ? 0.45 : 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(selfRow ? theme.palette.inkTertiary : theme.palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 置灰那一行不留包名，改说「为什么点不动」——灰着不解释，
                    // 读起来像是这一行坏了。
                    Text(selfRow
                         ? L("就是本工具自己 · 要卸载请在访达里拖进废纸篓")
                         : (app.bundleID.isEmpty ? app.path.path : app.bundleID))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if app.isAppStore && !selfRow {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .help(L("从 App Store 安装"))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? theme.palette.tintSoft : Color.clear,
                        in: theme.controlShape())
            .contentShape(theme.controlShape())
        }
        .buttonStyle(.plain)
        // 置灰不是「淡一点的可点」：禁用之后连悬停高亮都不该有，否则手伸过去才发现按不动。
        .disabled(selfRow)
        .help(selfRow ? L("就是本工具自己 · 要卸载请在访达里拖进废纸篓") : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: 右边：这个 App 名下有什么

    @ViewBuilder private var detail: some View {
        if let app = model.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    appCard(app)
                    if model.planning {
                        LoadingRow(text: LF("正在量「%@」的本体和数据…", app.name),
                                   progress: model.planProgress, fillsRow: true)
                            .panelCard()
                    } else {
                        dataCard(app)
                        notes(app)
                    }
                }
                .padding(.bottom, 8)
            }
        } else {
            EmptyState(symbol: "square.split.2x1", title: L("选左边一个应用"),
                       hint: L("它名下的本体和数据会列在这里，勾哪几处就搬哪几处"))
                .frame(maxHeight: .infinity)
        }
    }

    private func appCard(_ app: InstalledApp) -> some View {
        HStack(alignment: .top, spacing: 14) {
            RowIconView(icon: .path(app.path), side: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(theme.display(.title3))
                    .foregroundStyle(theme.palette.ink)
                HStack(spacing: 8) {
                    Text(app.bundleID.isEmpty ? L("没有包名") : app.bundleID)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                        .lineLimit(1)
                    if app.isAppStore {
                        ThemeBadge(text: L("App Store"), tone: .tint, symbol: "arrow.down.circle")
                    }
                }
                Text(displayPath(app.path))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 10)
            VStack(alignment: .trailing, spacing: 2) {
                Text(L("本体加勾选的数据"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                SizeNumber(shown: human(model.totalBytes), size: 26)
            }
        }
        .padding(16)
        .panelCard()
    }

    private func dataCard(_ app: InstalledApp) -> some View {
        VStack(spacing: 0) {
            // 本体不是可勾选项：没有「卸了 App 但不搬本体」这种东西。
            // 勾选框那一格留空（`selectable: false`），名字和数字仍在同一列上。
            ItemRow(selected: .constant(false),
                    icon: .path(app.path),
                    name: app.name,
                    sub: L("应用本体 · 一定会搬走"),
                    sizeText: human(model.bundleBytes ?? 0),
                    fraction: fraction(model.bundleBytes ?? 0),
                    selectable: false,
                    lit: true,
                    showRule: false) {
                ExplainLine(key: L("这是什么"), value: L("这个 App 的程序本体（.app 那个包）"))
                ExplainLine(key: L("删了会怎样"), value: L("App 从「应用程序」里消失；从废纸篓拖回来就装回去了"))
            }
            .themedRow()

            ForEach($model.items) { $it in
                ItemRow(selected: $it.selected,
                        icon: .path(it.path),
                        name: it.name,
                        sub: it.loc,
                        sizeText: human(it.size ?? 0),
                        fraction: fraction(it.size ?? 0),
                        badge: verdictBadge(it.level == "warn" ? .risky : .safe),
                        lit: it.level != "warn") {
                    ExplainLine(key: L("这是什么"), value: LF("%1$@ 留在 %2$@ 里的数据", app.name, it.loc))
                    ExplainLine(key: L("删了会怎样"), value: riskLine(it))
                    ExplainLine(key: L("怎么恢复"), value: L("从废纸篓还原，或重装该应用"))
                    if let what = contentsLine(it.files, it.newest) {
                        ExplainLine(key: L("内容"), value: what)
                    }
                    PathLine(path: it.path.path)
                }
                .themedRow()
            }
        }
        .panelCard()
    }

    @ViewBuilder private func notes(_ app: InstalledApp) -> some View {
        if !model.sharedPaths.isEmpty {
            ListNote(text: LF("另有 %1$@（%2$@）同时属于另一个已装应用，不列在这里，也不删。",
                              cnt(model.sharedPaths.count, "处"),
                              model.sharedPaths.prefix(3).map(\.lastPathComponent)
                                  .joined(separator: "、")))
        }
        if let b = model.bundleBytes, b > 0, model.items.isEmpty, !model.planning {
            ListNote(text: L("它名下没找到别的数据，这一趟只搬走本体。"))
        }
        if app.isAppStore {
            ListNote(text: L("这是 App Store 装的应用：删了之后，需要时可以在 App Store 免费装回来。"))
        }
    }

    // MARK: 底下那条：这一趟要搬多少、动手的那颗钮

    private var footer: some View {
        VStack(spacing: 0) {
            if let e = err {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.warnFG)
                    Text(e)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.warnFG)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.controlShape().fill(theme.palette.warnBG))
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }
            HStack(spacing: 13) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.current == nil ? L("还没挑应用") : LF("要搬走 %@",
                                                                  cnt(model.moveCount, "项")))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                    SizeNumber(shown: human(model.totalBytes), size: 21)
                }
                Spacer(minLength: 10)
                Text(L("只进废纸篓，可撤销"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                ThemeButton(kind: .primary, symbol: "trash",
                            title: L("卸载并移进废纸篓"),
                            isDisabled: model.current == nil || model.planning) {
                    confirm = true
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 13)
            .frame(maxWidth: .infinity)
            .background(theme.palette.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.palette.separator).frame(height: 1)
            }
        }
    }

    // MARK: 措辞与动作

    private var confirmText: String {
        let name = model.current?.name ?? ""
        let base = LF("「%1$@」的本体和勾选的 %2$@（共 %3$@）会一起进废纸篓，随时可撤销。",
                      name, cnt(model.items.filter(\.selected).count, "处"), human(model.totalBytes))
        return base + L("它要是正在运行，先退出再卸载，否则可能删不干净。")
    }

    /// 量过的最大值。本体可能比所有数据加起来都大，条子按两者里最大的那个归一。
    private func fraction(_ bytes: Int64) -> Double {
        let top = max(model.bundleBytes ?? 0, model.items.compactMap(\.size).max() ?? 1)
        return Double(bytes) / Double(max(1, top))
    }

    private func riskLine(_ it: AppDataItem) -> String {
        if it.loc == "Preferences" {
            return L("不勾：设置和登录状态留着；勾上：下次启动回到初始状态，可能要重新登录或重新输入许可。")
        }
        return it.level == "warn"
            ? L("重装这个应用时不会带回到这些配置；其他应用不受影响")
            : L("应用下次需要时会自己重建")
    }

    private func run() {
        err = nil
        guard let app = model.current else { return }
        var ok = 0
        var errs: [String] = []

        // 本体先走。它没搬动就**不走数据那一步**：把 App 留在盘上却把它的配置删了，
        // 是「卸了一半」里最难收场的一种。
        do {
            let t = try trashItem(app.path)
            store.record(TrashRecord(original: app.path, inTrash: t,
                                     size: model.bundleBytes ?? 0, displayName: app.name))
            ok += 1
        } catch {
            errs.append(failLine(app.name, error))
            err = errList(errs)
            return
        }

        // 量不动的条目（尺寸为 nil）不进列表，所以这里勾着的都有数。
        let data = model.items.filter(\.selected)
        for it in data {
            do {
                let t = try trashItem(it.path)
                store.record(TrashRecord(original: it.path, inTrash: t,
                                         size: it.size ?? 0, displayName: it.name))
                ok += 1
            } catch {
                errs.append(failLine(it.name, error))
            }
        }
        model.drop(app)
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "项", failed: errs.count)
    }
}

// MARK: - 小零件

/// 这一页两栏各是一张卡：不加外边距（外面已经有一层 `pagePadding`）。
private struct PanelCard: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = theme.cardShape()
        content
            .background(shape.fill(theme.palette.surface))
            .clipShape(shape)
            .overlay(shape.stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
    }
}

private extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}
