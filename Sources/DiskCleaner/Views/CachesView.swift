import SwiftUI
import DiskCleanerCore

// ── 缓存清理：知识库驱动，每项解释 + 勾选 + 只进废纸篓 ──
// 注意：知识库条目路径互相有重叠，未勾选项一律不做加总展示（UI 已守此规矩）。
//
// safety_db.json 里的 name/what/whatif/rec 是中文原文，也就是本地化 key——
// 英文译文全在 en.lproj 那张表里，构建时用 l10n_tool 逐条核对覆盖率。

/// 知识库位置：打包版在 Contents/Resources，`swift run` 时在包根目录的源码树里。
/// 刻意不用 Bundle.module——它的生成代码找不到 .bundle 就 fatalError，
/// 且回退路径是构建机的绝对路径，等于只有开发者自己的机器能打开这一页。
private func safetyDBURL() -> URL? {
    if let u = Bundle.main.url(forResource: "safety_db", withExtension: "json") { return u }
    let dev = "Sources/DiskCleaner/Resources/safety_db.json"
    return FileManager.default.fileExists(atPath: dev) ? URL(fileURLWithPath: dev) : nil
}

/// 分组标识 → 显示名。排序认 key，界面才查词表。
func cacheGroupLabel(_ key: String) -> String {
    switch key {
    case "general": return L("常规缓存")
    case "cn_app":  return L("国产 App")
    default:        return key
    }
}

/// 行内副标题。原来写分组名，可知识库 27 条里 25 条的 grp 都是 general，
/// 于是每行都是「常规缓存」——一行字重复 25 遍就等于没有信息。
/// 认一条缓存靠的是路径尾段，所以副标题给真实路径；展开行里仍是全路径。
private func cacheRowSub(_ item: CacheItem) -> String? {
    guard let first = item.resolvedPaths.first else { return nil }
    var parts: [String] = []
    if item.groupKey != "general" { parts.append(cacheGroupLabel(item.groupKey)) }
    parts.append(displayPath(first))
    if item.resolvedPaths.count > 1 {
        parts.append(LF("%d 处", item.resolvedPaths.count))
    }
    return parts.joined(separator: " · ")
}

/// 由 ScanStore 持有：视图随导航销毁，模型不能跟着一起销毁
@MainActor
final class CachesModel: ObservableObject {
    @Published var items: [CacheItem] = []
    @Published var scanning = false
    @Published private(set) var started = false
    private var task: Task<Void, Never>? = nil

    var selected: [CacheItem] { items.filter { $0.selected && $0.size != nil } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + ($1.size ?? 0) } }

    func load(force: Bool = false) {
        if started && !force { return }
        task?.cancel()
        started = true
        scanning = true
        task = Task {
            let entries = loadSafetyEntries(from: safetyDBURL())
            var list: [CacheItem] = []
            for e in entries {
                if Task.isCancelled { break }
                let paths = globExpand(e.path.isEmpty ? "~/.nonexistent-\(UUID().uuidString)" : e.path)
                if paths.isEmpty { continue }   // 没装的 App 不显示
                list.append(CacheItem(entry: e, resolvedPaths: paths))
            }
            // 常规缓存排前面
            list.sort { ($0.groupKey != "general" ? 1 : 0, $0.entry.name) < ($1.groupKey != "general" ? 1 : 0, $1.entry.name) }
            self.items = list
            // 并行统计大小
            await withTaskGroup(of: (UUID, Int64).self) { group in
                for it in list {
                    group.addTask {
                        var s: Int64 = 0
                        for p in it.resolvedPaths {
                            if Task.isCancelled { break }
                            var isDir: ObjCBool = false
                            if FileManager.default.fileExists(atPath: p.path, isDirectory: &isDir) {
                                s += isDir.boolValue ? await dirSize(p) : fileSize(p)
                            }
                        }
                        return (it.id, s)
                    }
                }
                for await (id, sz) in group {
                    if Task.isCancelled { break }
                    if let i = self.items.firstIndex(where: { $0.id == id }) {
                        self.items[i].size = sz
                    }
                }
            }
            // 有体积的排前面
            self.items.sort {
                let a = $0.size ?? -1, b = $1.size ?? -1
                if a != b { return a > b }
                return $0.groupKey < $1.groupKey
            }
            if !Task.isCancelled { self.scanning = false }
        }
    }

    func stop() {
        task?.cancel()
        scanning = false
    }
}

struct CachesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @ObservedObject var model: CachesModel
    @State private var confirmClean = false
    @State private var errorText: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                PageHeader(symbol: "sparkles", title: L("缓存清理"),
                           subtitle: L("每项都写明来历，勾你认得的，不认识的别碰"),
                           variant: .display)
                ControlStrip {
                    if model.scanning {
                        LoadingRow(text: L("正在翻你的缓存目录，稍等…"))
                    } else {
                        Text(LF("%d 项可查", model.items.count))
                    }
                    ThemeBadge(text: L("条目路径有重叠，未勾选不做加总"), tone: .neutral)
                } trailing: {
                    ScanControl(scanning: model.scanning,
                                rescan: { model.load(force: true) }, stop: { model.stop() })
                }
            }
            .pagePadding()
            .padding(.top, 14)
            .padding(.bottom, 12)

            if !model.scanning && model.items.isEmpty {
                EmptyState(symbol: "tray", title: L("知识库没加载出来"),
                           hint: L("点右上角重新扫描，还不行就提个 Issue"))
                    .frame(maxHeight: .infinity)
            } else {
                List($model.items) { $item in
                    ItemRow(selected: $item.selected,
                            name: L(item.entry.name),
                            sub: cacheRowSub(item),
                            sizeText: item.size.map { human($0) } ?? L("统计中…"),
                            fraction: Double(item.size ?? 0) / Double(maxSize),
                            badge: ItemBadge(text: item.entry.level == "warn" ? L("留意") : L("安全"),
                                             tone: item.entry.level == "warn" ? .warn : .safe),
                            selectable: item.size != nil && item.size != 0) {
                        ExplainLine(key: L("这是什么"), value: L(item.entry.what))
                        ExplainLine(key: L("删了会怎样"), value: L(item.entry.whatif))
                        ExplainLine(key: L("怎么恢复"), value: L(item.entry.rec))
                        ForEach(item.resolvedPaths, id: \.self) { p in
                            PathLine(path: p.path)
                        }
                    }
                    .themedRow()
                }
                .themedList()
            }

            CleanBar(count: model.selected.count, bytes: model.selectedBytes,
                     errorText: errorText) { confirmClean = true }
        }
        .frame(maxWidth: .infinity)
        .onAppear { model.load() }
        .alert(L("确认清理？"), isPresented: $confirmClean) {
            Button(L("取消"), role: .cancel) {}
            Button(L("移入废纸篓"), role: .destructive) { clean() }
        } message: {
            Text(LF("将 %1$@（%2$@）移入废纸篓，随时可撤销。真正释放空间需要之后清空废纸篓。",
                    cnt(model.selected.count, "项"), human(model.selectedBytes)))
        }
    }

    private var maxSize: Int64 { max(1, model.items.compactMap(\.size).max() ?? 1) }

    private func clean() {
        errorText = nil
        var ok = 0
        var errs: [String] = []
        for it in model.selected {
            for p in it.resolvedPaths {
                do {
                    let sz = it.resolvedPaths.count == 1 ? (it.size ?? 0) : fileSize(p)
                    let t = try trashItem(p)
                    store.record(TrashRecord(original: p, inTrash: t,
                                             size: it.resolvedPaths.count == 1 ? (it.size ?? sz) : sz,
                                             displayName: p.lastPathComponent))
                    ok += 1
                } catch {
                    errs.append(failLine(p.lastPathComponent, error))
                }
            }
            if let i = model.items.firstIndex(where: { $0.id == it.id }) {
                model.items[i].selected = false
                // 删完通常就没了：重新解析，消失的标 0
                let left = it.resolvedPaths.filter { FileManager.default.fileExists(atPath: $0.path) }
                model.items[i].resolvedPaths = left
                model.items[i].size = left.isEmpty ? 0 : nil
            }
        }
        if !errs.isEmpty { errorText = errList(errs) }
        store.notice = trashedNotice(ok, "项", failed: errs.count)
    }
}
