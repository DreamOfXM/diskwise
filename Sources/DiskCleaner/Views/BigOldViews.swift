import SwiftUI
import DiskCleanerCore

// ── 大文件 TOP ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class BigFilesModel: ObservableObject {
    @Published var rows: [FileRow] = []
    @Published var scanning = false
    @Published var count = 0
    @Published var limit = 30
    @Published var skipDev = true
    @Published var scopeNote: String? = nil
    /// 本次会话里扫过没有——区分「还没扫」和「扫了但没有」
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil
    /// 遍历有界保留的候选集（最多 200 条）；rows 只是它的前 limit 条
    private var all: [FileRow] = []
    private var customDirs: [URL]? = nil

    var selected: [FileRow] { rows.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }

    /// 总览跳过来的定向扫描；dirs == nil 回到默认范围
    func scan(dirs: [URL]? = nil, note: String? = nil) {
        task?.cancel()
        scanning = true
        started = true
        rows = []
        all = []
        customDirs = dirs
        scopeNote = note
        let skip: Set<String> = skipDev ? ["node_modules", ".git", "Caches"] : []
        let targets = dirs ?? defaultScanDirs()
        task = Task {
            let r = await walkFiles(dirs: targets, top: 200, skipNames: skip)
            if !Task.isCancelled {
                self.count = r.matched
                self.all = r.rows
                self.applyLimit()
                self.scanning = false
            }
        }
    }

    func rescan() { scan(dirs: customDirs, note: scopeNote) }

    func stop() { task?.cancel(); scanning = false }

    /// 改「前 N」不重扫：勾选同步回候选集，再切一刀
    func applyLimit() {
        syncBack()
        rows = Array(all.prefix(limit))
    }

    /// 删完就地把没了的条目剔掉，不值得为此重走一遍全盘
    func pruneMissing() {
        syncBack()
        all.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        rows = Array(all.prefix(limit))
    }

    /// rows 永远是 all 的前缀，按下标对齐写回
    private func syncBack() {
        for i in rows.indices where i < all.count { all[i] = rows[i] }
    }
}

struct BigFilesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: BigFilesModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "doc.on.doc", title: L("大文件"),
                           subtitle: L("按个头排好队，大的先杀"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在翻你的文件夹…"))
                    } else {
                        Text(LF("共扫到 %@", cnt(model.count, "个文件")))
                    }
                    if let note = model.scopeNote {
                        ThemeBadge(text: LF("只看 %@", note), tone: .tint, symbol: "scope")
                        ThemeButton(kind: .compact, title: L("恢复默认")) { model.scan() }
                    }
                } trailing: {
                    // 筛选控件放工具条右侧，不放页头：页头那一条要留给标题和副标题，
                    // 英文副标题一长就被控件挤到换行，控件自己也会顶出窗口边。
                    ThemeSwitch(label: L("跳过开发目录"), isOn: $model.skipDev) { model.rescan() }
                    ThemeStepper(label: L("前"), value: $model.limit, range: 10...200, step: 10) {
                        model.applyLimit()
                    }
                    ScanControl(scanning: model.scanning,
                                rescan: { model.rescan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if !model.scanning && model.rows.isEmpty {
                EmptyState(symbol: "doc", title: L("还没扫到大文件"),
                           hint: L("点右上角重新扫描，或回总览换个目录深挖"))
                    .frame(maxHeight: .infinity)
            } else {
                List($model.rows) { $r in
                    ItemRow(selected: $r.selected,
                            name: r.name,
                            sub: displayPath(r.url.deletingLastPathComponent()) + " · " + r.dateStr,
                            sizeText: human(r.size),
                            fraction: Double(r.size) / Double(maxSize)) {
                        PathLine(path: r.url.path)
                    }
                    .themedRow()
                }
                .themedList()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     errorText: err) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // 总览跳过来的定向扫描只消费一次
            if let dir = store.bigScanDir {
                store.bigScanDir = nil
                model.scan(dirs: [dir], note: dir.lastPathComponent)
            } else if !model.started {
                model.scan()
            }
        }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "个文件"),
                               human(model.selectedBytes))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.rows.map(\.size).max() ?? 1) }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        for r in model.selected {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
            if let i = model.rows.firstIndex(where: { $0.id == r.id }) {
                model.rows[i].selected = false
            }
        }
        model.pruneMissing()
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个文件", failed: errs.count)
    }
}

// ── 很久没动 ──

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class OldFilesModel: ObservableObject {
    @Published var rows: [FileRow] = []
    @Published var scanning = false
    @Published var days = 90
    @Published var skipDev = true
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    var selected: [FileRow] { rows.filter { $0.selected } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }
    var totalBytes: Int64 { rows.reduce(0) { $0 + $1.size } }

    func scan() {
        task?.cancel()
        scanning = true
        started = true
        rows = []
        let d = days
        let skip: Set<String> = skipDev ? ["node_modules", ".git", "Caches"] : []
        task = Task {
            let home = homePath()
            let dirs = ["Downloads", "Desktop"].compactMap { n -> URL? in
                let u = URL(fileURLWithPath: home).appendingPathComponent(n)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return u
            }
            let cutoff = Date().addingTimeInterval(Double(-d) * 86400)
            let r = await walkFiles(dirs: dirs, olderThan: cutoff, top: 300, skipNames: skip)
            if !Task.isCancelled {
                self.rows = r.rows
                self.scanning = false
            }
        }
    }

    func stop() { task?.cancel(); scanning = false }
}

struct OldFilesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: OldFilesModel
    @State private var confirm = false
    @State private var err: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "clock", title: L("很久没动"),
                           subtitle: L("下载和桌面里，好久没碰的东西"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在看哪些文件落灰…"))
                    } else {
                        Text(LF("%1$@，共 %2$@", cnt(model.rows.count, "个文件"), human(model.totalBytes)))
                    }
                } trailing: {
                    ThemeSwitch(label: L("跳过开发目录"), isOn: $model.skipDev) { model.scan() }
                    ThemeStepper(label: L("超过"), unit: L("天"),
                                 value: $model.days, range: 30...365, step: 30) {
                        model.scan()
                    }
                    ScanControl(scanning: model.scanning,
                                rescan: { model.scan() }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if !model.scanning && model.rows.isEmpty {
                EmptyState(symbol: "sparkle", title: L("没有落灰的文件"),
                           hint: L("下载和桌面很干净，保持住"))
                    .frame(maxHeight: .infinity)
            } else {
                List($model.rows) { $r in
                    ItemRow(selected: $r.selected,
                            name: r.name,
                            sub: displayPath(r.url.deletingLastPathComponent()) + " · " + r.dateStr,
                            sizeText: human(r.size),
                            fraction: Double(r.size) / Double(maxSize)) {
                        PathLine(path: r.url.path)
                    }
                    .themedRow()
                }
                .themedList()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     errorText: err) { confirm = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { if !model.started { model.scan() } }
        .confirmTrash(isPresented: $confirm,
                      text: LF("将 %1$@（%2$@）移入废纸篓。",
                               cnt(model.selected.count, "个文件"),
                               human(model.selectedBytes))) {
            doClean()
        }
    }

    private var maxSize: Int64 { max(1, model.rows.map(\.size).max() ?? 1) }

    private func doClean() {
        err = nil
        var ok = 0
        var errs: [String] = []
        for r in model.selected {
            do {
                let t = try trashItem(r.url)
                store.record(TrashRecord(original: r.url, inTrash: t, size: r.size, displayName: r.name))
                ok += 1
            } catch { errs.append(failLine(r.name, error)) }
        }
        model.rows.removeAll { !FileManager.default.fileExists(atPath: $0.url.path) }
        for i in model.rows.indices { model.rows[i].selected = false }
        if !errs.isEmpty { err = errList(errs) }
        store.notice = trashedNotice(ok, "个文件", failed: errs.count)
    }
}
