import Foundation
import CryptoKit

// ── 六个移植视图的后端：大文件 / 旧文件 / 重复 / 卸载残留 / node_modules / Docker ──
// 口径与 Python 版一致；UI 只负责展示 + 勾选 + 走 trashItem。

// ══ 通用文件行 ══

public struct FileRow: Identifiable {
    public let id = UUID()
    public var url: URL
    public var size: Int64
    public var mtime: Date
    public var selected = false

    public var name: String { url.lastPathComponent }
    /// 这一项我们删得动吗。整盘扫描会把系统区也摆上列表：账要算全，手不能伸。
    public var deletable: Bool { isDeletable(url) }
    public var dateStr: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: mtime)
    }
}

/// 一次遍历的结果。`rows` 可能被 `top` 截断，`matched` 永远是命中总数。
public struct WalkResult {
    public var rows: [FileRow]
    public var matched: Int
}

/// 深度优先遍历。
/// - `olderThan`：日期过滤下推进遍历，别让整棵树的行先落进数组再筛。
/// - `top`：只留最大的前 N 条，攒到 4N 就收缩一次。不封顶的话一个 Documents 目录
///   就能往内存里塞几十万个 FileRow。
public func walkFiles(dirs: [URL], minSize: Int64 = 0, olderThan: Date? = nil,
                      top: Int = 0, skipNames: Set<String> = [],
                      progress: ScanProgress? = nil) async -> WalkResult {
    var out: [FileRow] = []
    var matched = 0
    let cutoff = olderThan.map { $0.timeIntervalSince1970 }
    // 每个根记住自己的卷号：跨卷守卫要按根比，不能拿第一个根的号去卡所有根。
    //
    // 还要记住「哪些别的根就在我底下」，走到就跳过，让那块以自己的根身份去扫。
    // 不挡的话同一份文件会被走两遍：列表按 path 作 ForEach 的 id，第二条只占行高不画字；
    // 重复文件页会把同一份内容算成两组。演示树里整盘根全落在假家目录底下，正是这种嵌套。
    let rootPaths = dirs.map { $0.standardizedFileURL.path }
    func nestedRoots(under root: String) -> Set<String> {
        Set(rootPaths.filter { $0 != root && $0.hasPrefix(root + "/") })
    }
    var stack: [(String, dev_t?, Set<String>)] = rootPaths.map {
        ($0, deviceOf(URL(fileURLWithPath: $0)), nestedRoots(under: $0))
    }
    var n = 0
    while let (dir, rootDev, skip) = stack.popLast() {
        if Task.isCancelled { break }
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
        var dFiles = 0
        var dBytes: Int64 = 0
        for name in items {
            if name == ".Trash" || skipNames.contains(name) { continue }
            let p = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            if lstat(p, &st) != 0 { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { continue }
            if mode == S_IFDIR {
                if skip.contains(URL(fileURLWithPath: p).standardizedFileURL.path) { continue }
                if let d = rootDev, st.st_dev != d { continue }
                stack.append((p, rootDev, skip))
                continue
            }
            n += 1
            if n % 20000 == 0 && Task.isCancelled { break }
            let sz = Int64(st.st_blocks) * 512
            let mt = Double(st.st_mtimespec.tv_sec)
            // 读数记的是「检查过」，不是「命中」：过滤条件挡掉的那些同样真的被看过，
            // 只报命中的话，一个装满小文件的目录会显示成什么都没发生。
            dFiles += 1
            dBytes += sz
            guard sz >= minSize, cutoff == nil || mt < cutoff! else { continue }
            matched += 1
            out.append(FileRow(url: URL(fileURLWithPath: p), size: sz,
                               mtime: Date(timeIntervalSince1970: mt)))
            if top > 0 && out.count >= top * 4 {
                out.sort { $0.size > $1.size }
                out = Array(out.prefix(top))
            }
        }
        progress?.walk(files: dFiles, bytes: dBytes, in: dir)
    }
    out.sort { $0.size > $1.size }
    if top > 0 { out = Array(out.prefix(top)) }
    return WalkResult(rows: out, matched: matched)
}

/// 各扫描页的默认根。
///
/// 这里以前写死六个家目录子夹（Downloads / Desktop / Documents / Movies / Pictures / Music），
/// 在一台 434 GB 的盘上只覆盖约 20 GB——「大文件」页因此名不副实：照着它的列表清完，盘还是满的。
/// 范围必须和总览页同源，且明写在页头上。
public func defaultScanDirs(scope: ScanScope) -> [URL] {
    scanRoots(scope: scope)
}

// ══ 重复文件：大小 → 首尾1MB → 全量哈希 ══

public struct DupGroup: Identifiable {
    public let id = UUID()
    public var size: Int64
    public var files: [URL]   // 第一个保留（日期最新那份），其余可删
    public var waste: Int64 { size * Int64(max(0, files.count - 1)) }
}

/// 一组内容相同、其中至少一份住在受管环境里的副本。
///
/// `files` 只有被摘出去的那几份：同组剩下的自由副本照旧进 `DupGroup`，
/// 两边加起来才是这一组的全部内容，哪一份都不会只在一处出现、另一处凭空消失。
public struct EnvDupGroup: Identifiable {
    public let id = UUID()
    public var size: Int64
    public var files: [URL]
    /// 这些副本所在的环境根，去重后按路径排：名单要说「住在几个环境里」
    public var envs: [String]
    public var bytes: Int64 { size * Int64(files.count) }
}

public struct DupScanResult {
    public var groups: [DupGroup]
    public var excluded: [EnvDupGroup]
}

/// 这份文件住在哪个受管环境里，取不到返回 nil。
///
/// 判据只看路径，不碰文件系统：Python 虚拟环境、pipx、node_modules、Xcode 构建区
/// 里的每一份副本都是那个环境自己装的、自己要用的，删一份那个环境就缺一块。
/// 它跟「同一份内容在两个项目目录里各存了一份」不是一回事，所以整批摘出去，
/// 不进重复比对。要回收那块地，得卸掉整个环境。
public func managedEnv(of url: URL) -> String? {
    let comps = url.pathComponents
    guard comps.first == "/", comps.count > 2 else { return nil }
    let last = comps.count - 1        // 最后一颗是文件名，不当标记
    // 环境根 = 标记那颗（或它的名字那颗）为止的前缀
    func root(_ end: Int) -> String {
        let upto = min(max(end, 1), last)
        let body = comps[1..<upto]
        return body.isEmpty ? "/" : "/" + body.joined(separator: "/")
    }
    var i = 1
    while i < last {
        switch comps[i] {
        case "node_modules", "venv", ".venv":
            return root(i + 1)
        case "DerivedData":
            // 构建区按工程分格子，环境根要连那一格一起吃下去
            return root(i + 2)
        case "venvs" where i >= 2 && comps[i - 1] == "pipx":
            return root(i + 2)
        case "site-packages":
            // .../lib/python3.x/site-packages/…：环境根在 lib 的上一层
            if i >= 3, comps[i - 1].hasPrefix("python"), comps[i - 2] == "lib" {
                return root(i - 2)
            }
            return root(i)
        default:
            i += 1
        }
    }
    return nil
}

private func md5Hex(_ data: Data) -> String {
    Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func partialHash(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    guard let head = try? h.read(upToCount: 1 << 20), !head.isEmpty else { return nil }
    var d = Data(head)
    if let end = try? h.seekToEnd(), end > (2 << 20) {
        try? h.seek(toOffset: end - UInt64(1 << 20))
        if let tail = try? h.read(upToCount: 1 << 20) {
            d.append(tail)
        }
    }
    return md5Hex(d)
}

private func fullHash(_ url: URL) -> String? {
    guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? h.close() }
    var digest = Insecure.MD5()
    while true {
        guard let chunk = try? h.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
        digest.update(data: chunk)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

/// 留哪一份看这个日期：修改时间，读不到退回创建时间，再读不到算最旧。
/// 单独露出来是因为行上标的日期必须跟排序用的是同一个数——否则界面说「留最新」，
/// 行的日期却对不上，那一屏就成了自证矛盾的现场。
public func fileDate(_ url: URL) -> Date {
    let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
    return v?.contentModificationDate ?? v?.creationDate ?? .distantPast
}

/// `yyyy-MM-dd HH:mm`：同一天里连拍几份备份很常见，只到「日」就分不出留哪个
public func shortDate(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

public func findDupGroups(_ rows: [FileRow]) -> DupScanResult {
    var bySize: [Int64: [URL]] = [:]
    for r in rows { bySize[r.size, default: []].append(r.url) }
    var groups: [DupGroup] = []
    var excluded: [EnvDupGroup] = []
    for (sz, urls) in bySize where urls.count > 1 {
        var byPart: [String: [URL]] = [:]
        for u in urls {
            if Task.isCancelled { break }
            if let h = partialHash(u) { byPart[h, default: []].append(u) }
        }
        for (_, cand) in byPart where cand.count > 1 {
            var byFull: [String: [URL]] = [:]
            for u in cand {
                if Task.isCancelled { break }
                if let h = fullHash(u) { byFull[h, default: []].append(u) }
            }
            for (_, same) in byFull where same.count > 1 {
                // 降序：files[0] 是保留的那一份，留最新。备份、导出这类目录按日期递增，
                // 留最旧等于把最新那份送进废纸篓、留下一堆过期档。
                // 日期相同（整棵树同一秒拷出来的演示盘、批量复制）必须有第二把尺：
                // 只按日期排的话同秒之间谁在前取决于字典遍历顺序，同一台机器重扫一次
                // 就能把「保留」挪到另一份上，这一列就不可信了。
                let ordered = same.sorted {
                    fileDate($0) != fileDate($1)
                        ? fileDate($0) > fileDate($1)
                        : $0.path < $1.path
                }
                // 环境自带的那些先摘出去：它们不是「多出来的一份」，是某个环境的
                // 一块零件。摘完之后不够两份的，这一组就没有可回收的副本了。
                var free: [URL] = []
                var owned: [URL] = []
                for u in ordered {
                    if managedEnv(of: u) == nil { free.append(u) } else { owned.append(u) }
                }
                if free.count > 1 { groups.append(DupGroup(size: sz, files: free)) }
                if !owned.isEmpty {
                    let envs = Set(owned.compactMap { managedEnv(of: $0) }).sorted()
                    excluded.append(EnvDupGroup(size: sz, files: owned, envs: envs))
                }
            }
        }
    }
    return DupScanResult(groups: groups.sorted { $0.waste > $1.waste },
                         excluded: excluded.sorted { $0.bytes > $1.bytes })
}

// ══ 卸载残留：以已安装 App 为基准，找 App 没了、数据还在的孤儿 ══

public struct OrphanItem: Identifiable {
    public let id = UUID()
    public var name: String
    /// macOS 里的真实目录名（Application Support 等），本身就是英文，不进词表
    public var loc: String
    public var path: URL
    public var size: Int64?
    public var level: String   // safe | warn
    /// 从包名猜出来的应用名，可能为空；是品牌名，界面查词表
    public var guess: String
    /// 残留目录里的文件个数与最近一次改动，展开行用。一个 2 GB 的残留里躺着 3 个文件
    /// 还是 40 万个，决定用户敢不敢勾——只有字节数时这两种看起来是一回事。
    public var files: Int = 0
    public var newest: Date? = nil
    public var selected = false
}

private let orphanLocations: [(label: String, subpath: String, kind: String, level: String)] = [
    ("Application Support", "Library/Application Support", "dir", "warn"),
    ("Group Containers", "Library/Group Containers", "dir", "warn"),
    ("Preferences", "Library/Preferences", "plist", "warn"),
    ("Containers", "Library/Containers", "dir", "safe"),
    ("Caches", "Library/Caches", "dir", "safe"),
    ("Saved Application State", "Library/Saved Application State", "state", "safe"),
    ("HTTPStorages", "Library/HTTPStorages", "file", "safe"),
    ("WebKit", "Library/WebKit", "dir", "safe"),
    ("Logs", "Library/Logs", "dir", "safe"),
    ("Application Scripts", "Library/Application Scripts", "dir", "safe"),
]

private let orphanDenylist: Set<String> = [
    "addressbook", "automator", "callhistory", "callhistorydb", "callhistorytransactions",
    "clouddocs", "dock", "knowledge", "syncservices", "tcc", "icloud", "familycircle",
    "crashreporter", "coresimulator", "mobilemeaccounts", "syncdefaults",
    "com.microsoft.autoupdate2", "com.google.keystone", "com.google.keystone.agent",
    "com.google.keystone.daemon", "com.adobe.ccxprocess",
]

private let orphanGuess: [(kw: String, label: String)] = [
    ("xinwechat", "微信"), ("weixin", "微信"), ("wechat", "微信"),
    ("wework", "企业微信"), ("wxwork", "企业微信"),
    ("dingtalk", "钉钉"), ("qq", "QQ"), ("tencent", "腾讯系应用"),
]

private func stripTeamID(_ s: String) -> String {
    if s.count > 11, s[s.index(s.startIndex, offsetBy: 10)] == ".",
       s.prefix(10).allSatisfy({ $0.isLetter || $0.isNumber }) {
        return String(s.dropFirst(11))
    }
    return s
}

private func splitTokens(_ s: String) -> [String] {
    s.lowercased().split { ". -_".contains($0) }.map(String.init).filter { $0.count >= 4 }
}

public func scanOrphans(progress: ScanProgress? = nil) async -> (items: [OrphanItem], appCount: Int) {
    // 1. 盘点已安装 App
    var ids = Set<String>(), toks = Set<String>(), names = Set<String>()
    let home = homePath()
    for root in [applicationsDir(), "/System/Applications", home + "/Applications"] {
        guard let apps = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for a in apps where a.hasSuffix(".app") {
            let stem = String(a.dropLast(4)).trimmingCharacters(in: .whitespaces).lowercased()
            names.insert(stem)
            toks.insert(stem.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: ""))
            toks.formUnion(splitTokens(stem))
            let info = (root as NSString).appendingPathComponent(a + "/Contents/Info.plist")
            if let data = try? Data(contentsOf: URL(fileURLWithPath: info)),
               let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let bid = (pl["CFBundleIdentifier"] as? String)?.lowercased(), !bid.isEmpty {
                ids.insert(bid)
                toks.insert(bid)
                toks.formUnion(splitTokens(bid))
            }
            if Task.isCancelled { return ([], names.count) }
        }
    }
    func related(_ stem: String) -> Bool {
        let cl = stripTeamID(stem).lowercased().trimmingCharacters(in: .whitespaces)
        if ids.contains(cl) || names.contains(cl) || orphanDenylist.contains(cl) { return true }
        if toks.contains(where: { $0.count >= 5 && (cl.contains($0) || $0.contains(cl)) }) { return true }
        var segs = cl.split { ". -_".contains($0) }.map(String.init)
        if segs.first == "group" || segs.first == "team" { segs = Array(segs.dropFirst()) }
        return segs.contains { $0.count >= 4 && (toks.contains($0) || ids.contains($0)) }
    }
    func guess(_ stem: String) -> String {
        let cl = stripTeamID(stem).lowercased()
        for (kw, label) in orphanGuess where cl.contains(kw) { return label }
        let segs = cl.split { ". -_".contains($0) }.map(String.init)
        return (segs.count > 1 ? segs[1] : segs.first ?? "").capitalized
    }
    // 2. 找孤儿
    var cands: [(label: String, level: String, path: String, stem: String)] = []
    for loc in orphanLocations {
        let root = (home as NSString).appendingPathComponent(loc.subpath)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
        for n in entries {
            if n.hasPrefix(".") { continue }
            let p = (root as NSString).appendingPathComponent(n)
            var stem: String
            switch loc.kind {
            case "plist":
                guard n.lowercased().hasSuffix(".plist") else { continue }
                stem = String(n.dropLast(6))
            case "state":
                guard n.hasSuffix(".savedState") else { continue }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                stem = String(n.dropLast(11))
            case "file":
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
                stem = n
            default:
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
                stem = n
            }
            if loc.label == "Caches" || loc.label == "HTTPStorages" || loc.label == "Containers"
                || loc.label == "Saved Application State" {
                if !stem.contains(".") { continue }  // 只认 id 形态，避免误报 pip 之类
            }
            if related(stem) { continue }
            cands.append((loc.label, loc.level, p, stem))
        }
        if Task.isCancelled { break }
    }
    // 3. 并行统计大小
    var items: [OrphanItem] = []
    await withTaskGroup(of: OrphanItem?.self) { group in
        for c in cands {
            group.addTask {
                if Task.isCancelled { return nil }
                let u = URL(fileURLWithPath: c.path)
                let st = await pathStat(u, progress: progress)
                guard st.bytes > 0 else { return nil }
                let g = guess(c.stem)
                return OrphanItem(
                    name: c.stem, loc: c.label, path: u, size: st.bytes, level: c.level,
                    guess: g, files: st.files, newest: st.newest)
            }
        }
        for await r in group {
            if let r = r { items.append(r) }
        }
    }
    items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
    return (items, names.count)
}

// ══ node_modules：全盘找，聚合到项目级 ══

public struct NMProject: Identifiable {
    public let id = UUID()
    public var project: String
    public var size: Int64
    public var nmCount: Int
    public var date: String
    public var partial: Bool
    /// 这份依赖是谁装的（`npm` / `pnpm` / `yarn` / `bun`）。认不出来就是 nil，界面挂通用图。
    public var manager: String?
    public var selected = false
}

/// 这一份 `node_modules` 是谁装出来的。先认目录里的内部标记，认不出才看项目根的锁文件。
///
/// 内部标记优先是有理由的：锁文件会说谎——项目改投 pnpm 之后 `package-lock.json`
/// 常常还躺在仓库里，而 `node_modules/.pnpm` 是真把依赖写进盘的那个管理器留下的痕迹。
/// 这一行报的是「这些字节是谁落下来的」，不是「这个项目现在声称用谁」。
/// 本机实测（2026-09-27）八处 `node_modules`：`.pnpm` 两处、`.package-lock.json` 六处，
/// 与各自的 `pnpm-lock.yaml` / `package-lock.json` 一一对上。
private func nodePackageManager(nmDir: String, projectDir: String) -> String? {
    func has(_ dir: String, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name))
    }
    if has(nmDir, ".pnpm") || has(nmDir, ".modules.yaml") { return "pnpm" }
    if has(nmDir, ".package-lock.json") { return "npm" }
    if has(nmDir, ".yarn-integrity") || has(nmDir, ".yarn-state.yml") { return "yarn" }
    if has(projectDir, "pnpm-lock.yaml") { return "pnpm" }
    if has(projectDir, "yarn.lock") { return "yarn" }
    if has(projectDir, "bun.lockb") || has(projectDir, "bun.lock") { return "bun" }
    if has(projectDir, "package-lock.json") { return "npm" }
    return nil
}

/// node_modules 只在用户区找，不跟着「整盘」开关走。
///
/// 这不是漏扫，是算过的：依赖目录只会长在项目里，而项目在家目录。系统区里唯一像样的
/// 一处是包管理器自己的全局目录（`/opt/homebrew/lib/node_modules` 那类），删它等于拆掉
/// 命令行工具，而且 brew 有自己的清理方式。为了这一处把整棵 /Library 走一遍，
/// 换来的是几分钟空转 + 一个勾不得的条目。
public func findNodeModules(progress: ScanProgress? = nil) async -> [NMProject] {
    let home = homePath()
    let roots = [URL(fileURLWithPath: home), URL(fileURLWithPath: applicationsDir())]
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    // 第一段：翻目录找 node_modules（命中即不再下钻）
    var nmDirs: [String] = []
    // 每个根记自己的卷号：跨卷守卫要按根比
    var stack = roots.map { ($0.path, deviceOf($0)) }
    while let (d, rootDev) = stack.popLast() {
        if Task.isCancelled { break }
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
        for k in kids {
            if k == ".Trash" || k == ".git" { continue }
            let p = (d as NSString).appendingPathComponent(k)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            var st = stat()
            if lstat(p, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK { continue }
            if k == "node_modules" { nmDirs.append(p); continue }
            if let dev = rootDev, st.st_dev != dev { continue }
            stack.append((p, rootDev))
        }
        // 这一趟数的是目录项而不是文件：整棵家目录翻下来一个 node_modules 都可能没撞上，
        // 但「正在看 ~/Projects/foo/src」这句话是真的在往前走的证据。
        progress?.walk(files: kids.count, bytes: 0, in: d)
    }
    // 第二段：并行统计，聚合到项目级
    var projects: [String: (size: Int64, nms: Int, mtime: Date, partial: Bool, mgr: String?)] = [:]
    await withTaskGroup(of: (proj: String, size: Int64, mt: Date, partial: Bool, mgr: String?)?.self) { group in
        for nm in nmDirs {
            group.addTask {
                if Task.isCancelled { return nil }
                let u = URL(fileURLWithPath: nm)
                // 项目根：向上找 package.json
                var proj = u.deletingLastPathComponent().path
                var cur = proj
                while true {
                    if FileManager.default.fileExists(atPath: (cur as NSString).appendingPathComponent("package.json")) {
                        proj = cur
                        break
                    }
                    let parent = (cur as NSString).deletingLastPathComponent
                    if parent == cur || !(parent == home || parent.hasPrefix(home + "/")) { break }
                    cur = parent
                }
                let sz = await dirSize(u)
                let mt = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return (proj, sz, mt, false, nodePackageManager(nmDir: nm, projectDir: proj))
            }
        }
        for await r in group {
            guard let r = r else { continue }
            var e = projects[r.proj] ?? (0, 0, .distantPast, false, nil)
            e.size += r.size
            e.nms += 1
            e.mtime = max(e.mtime, r.mt)
            if r.partial { e.partial = true }
            // 一个项目里可能有多处 node_modules（monorepo）：第一个认出来的管理器就够
            if e.mgr == nil { e.mgr = r.mgr }
            projects[r.proj] = e
        }
    }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return projects.map { (proj, e) in
        NMProject(project: proj, size: e.size, nmCount: e.nms,
                  date: f.string(from: e.mtime), partial: e.partial, manager: e.mgr)
    }.sorted { $0.size > $1.size }
}

// ══ iOS 模拟器：一台一行（设备名 / 系统 / 最后启动 / 占盘）══

/// 一台模拟器的账。
public struct SimDevice: Identifiable {
    /// UDID，也就是那台设备在 `Devices/` 下的目录名
    public let id: String
    /// 设备自己报的名字（`iPhone 17`），不是我们编的
    public var name: String
    /// 系统版本（`iOS 26.5`）；`device.plist` 读不出来时给空串，界面就不印这一格
    public var os: String
    /// 最后一次启动。从没启动过的台子这一格是 nil——那种最该先动。
    public var lastBooted: Date?
    public var size: Int64
    public var path: String
}

/// 逐台量模拟器。只在用户摊开「Xcode 模拟器设备」那一行时跑，不进常规扫描。
///
/// 为什么这一行非要逐台：本机实测（2026-09-27）26 台里近 7 天动过的 17 台占了 16.9 GB，
/// 而 7 天没动的那 8 台加起来只有 139 MB。别处那条「留着新的、删旧的」的默认规则
/// 在这里几乎省不出空间，只能把每台摆出来让人自己挑。
public func scanSimulators(under dir: URL) async -> [SimDevice] {
    let fm = FileManager.default
    guard let kids = try? fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    else { return [] }
    // 一台模拟器 = 一个装着 `device.plist` 的目录。认这个而不是认 UUID 形状：
    // 同一层还散着 `Caches`、`.simdeviceinfo` 之类的东西，按形状认会把不是台子的算进来。
    let devices = kids.filter {
        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            && fm.fileExists(atPath: $0.appendingPathComponent("device.plist").path)
    }
    var out: [SimDevice] = []
    await withTaskGroup(of: SimDevice?.self) { group in
        for d in devices {
            group.addTask {
                if Task.isCancelled { return nil }
                let sz = await dirSize(d)
                let info = NSDictionary(contentsOf: d.appendingPathComponent("device.plist"))
                let udid = d.lastPathComponent
                return SimDevice(
                    id: udid,
                    name: info?["name"] as? String ?? udid,
                    os: simRuntimeName(info?["runtime"] as? String),
                    lastBooted: info?["lastBootedAt"] as? Date,
                    size: sz, path: d.path)
            }
        }
        for await r in group { if let r = r { out.append(r) } }
    }
    return out.sorted { $0.size > $1.size }
}

/// `com.apple.CoreSimulator.SimRuntime.iOS-26-5` → `iOS 26.5`。
/// 认不出来（新写法、读不到）就原样给空串，不硬凑一个版本号出来。
private func simRuntimeName(_ raw: String?) -> String {
    guard let tail = raw?.split(separator: ".").last else { return "" }
    let parts = tail.split(separator: "-")
    guard parts.count >= 2, let head = parts.first else { return "" }
    return "\(head) \(parts.dropFirst().joined(separator: "."))"
}

// ══ Docker 占用：一行一个运行时（磁盘实占），引擎答得上来就附它自己的账本；不代删，只指路 ══

/// 装在这台机器上的容器运行时。Core 只认「是哪家、数据落在哪个目录、.app 的包名」，
/// 名字与措辞归界面。
///
/// 为什么不能只找 Docker：OrbStack 也提供 `docker` 命令、也实现同一个引擎接口。
/// 这台机器实测（2026-09-27）`/usr/local/bin/docker` 是软链进 `/Applications/OrbStack.app` 的，
/// 机器上根本没装 Docker Desktop，而 OrbStack 那块虚拟机磁盘实占 22.8 GB。
/// 只认 Docker 的话，这一页在这里既报不出这 22.8 GB，又会把清理指路写到一款没装的 App 上。
public enum DockerRuntime: String, CaseIterable {
    case dockerDesktop, orbstack, podman, colima

    /// 这一家把数据落在哪。目录不存在就返回 nil——没装就不该有这一行。
    public var dataDir: URL? {
        let rel: String
        switch self {
        case .dockerDesktop: rel = "Library/Containers/com.docker.docker"
        case .orbstack:      rel = "Library/Group Containers/HUAQ24HBR6.dev.orbstack"
        case .podman:        rel = ".local/share/containers/storage"
        case .colima:        rel = ".colima"
        }
        let url = homeDir().appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// .app 的包名，行首那一格靠它挂真图标。
    ///
    /// OrbStack 非得自己报：它的组容器目录叫 `HUAQ24HBR6.dev.orbstack`，
    /// 顺着路径找包名会找到那串 team 前缀，查到的是不存在的东西（它真实包名是 `dev.kdrag0n.MacVirt`）。
    /// Podman / colima 通常只是命令行，没有必装的 .app，留 nil 让界面往下走通用兜底。
    public var bundleID: String? {
        switch self {
        case .dockerDesktop: return "com.docker.docker"
        case .orbstack:      return "dev.kdrag0n.MacVirt"
        case .podman, .colima: return nil
        }
    }
}

/// 条目的种类——措辞归界面，这里只给分类和数字
public enum DockerKind: String {
    /// 一行一个运行时：那块虚拟机磁盘在这台机器上实际占掉的量
    case runtime
    case dfImages, dfContainers, dfVolumes, dfCache
    case image, danglingImage
    case other

    /// 这一类的字节**计不计进页头那个总数**。
    ///
    /// 页头那个数答的是「容器这一类吃掉这块盘多少」，那只有真躺在盘上的字节算数：
    /// `docker system df` 报的是引擎自己的账，镜像按逻辑大小列、共享层被各镜像重复计入。
    /// 这台机器实测（2026-09-27）四个段相加 38.4 GB，而 OrbStack 那块磁盘实占 22.8 GB——
    /// 两副面孔同桌相加就是把同一段字节数两遍。段和镜像明细照样列（那是唯一能报出镜像名的地方），
    /// 但它们是账本里的批注，不是磁盘上多出来的第五第六笔。
    public var countsInTotal: Bool { self == .runtime }
}

public struct DockerItem: Identifiable {
    public let id = UUID()
    public var kind: DockerKind
    /// 这一行属于哪家运行时。引擎答得上来才有归属；认不出那家（比如自己编的 CLI）就 nil，
    /// 界面给一句通用指路，不谎称是 Docker Desktop。
    public var runtime: DockerRuntime? = nil
    /// 镜像的 仓库:tag、悬空镜像的 ID、运行时的标识——真实数据，不翻译
    public var title: String
    public var size: Int64
    public var total: String?
    public var active: String?
    /// Docker 自己报的「这一类里还能清掉多少」，已经换算成字节。
    /// 界面不能直接印 Docker 给的那串字：它写的是 `13.04GB`（1024 进制、单位粘在数字上），
    /// 和这一页其余各行的十进制两档数字同桌就是两种口径。
    public var reclaimable: Int64?
    /// 同一格里的占比（`54%`），Docker 算的，原样带过来不重算
    public var reclaimableShare: String?
    /// 运行时那一行的数据目录。有它，行首才挂得出那家 App 的真图标；
    /// `docker system df` 那几段背后没有路径可对——虚拟盘里没有一个文件给图标服务读。
    public var path: URL? = nil

    public var countsInTotal: Bool { kind.countsInTotal }
}

private func runCmd(_ exe: String, _ args: [String], timeout: TimeInterval = 20) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if p.isRunning { p.terminate(); return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

/// Docker 那一串尺寸是 go-units 的 `HumanSize` 印出来的：底数 1000，缩写 B/kB/MB/GB
/// （本机实测 `577.5kB`、`401.4MB`、`23.91GB`）。按 1024 读会把 Docker 的 23.91GB
/// 显示成 25.7 GB——比它自己报的数大 7.4%，用户对着 `docker system df` 核不上。
/// 带 i 的 KiB/MiB/GiB 才是 1024（`BytesSize` 那一档，别的 CLI 可能这么印），两种都认。
public func parseDockerSize(_ s: String) -> Int64 {
    let mult: [(suffix: String, m: Double)] = [("PiB", Double(1 << 50)), ("TiB", Double(1 << 40)),
                                               ("GiB", Double(1 << 30)), ("MiB", Double(1 << 20)), ("KiB", 1024),
                                               ("PB", 1_000_000_000_000_000), ("TB", 1_000_000_000_000),
                                               ("GB", 1_000_000_000), ("MB", 1_000_000),
                                               ("kB", 1_000), ("KB", 1_000), ("B", 1)]
    let t = s.trimmingCharacters(in: .whitespaces)
    for (suf, m) in mult where t.hasSuffix(suf) {
        if let v = Double(t.dropLast(suf.count)) { return Int64(v * m) }
    }
    return 0
}

/// `docker system df` 的 Reclaimable 一格写成 `13.04GB (54%)`，也可能只写 `5.651GB`。
/// 字节段并进本工具的口径，占比原样留着——自己按 13.04/23.91 重算一遍，
/// 会和 Docker 屏幕上那个数对不上，而这一页唯一能引的数就是 Docker 报的那几个。
public func parseDockerReclaimable(_ s: String) -> (bytes: Int64, share: String?) {
    let t = s.trimmingCharacters(in: .whitespaces)
    let head = String(t.prefix { $0 != "(" && !$0.isWhitespace })
    let tail = t.dropFirst(head.count).trimmingCharacters(in: .whitespaces)
    guard tail.hasPrefix("("), tail.hasSuffix(")") else {
        return (parseDockerSize(head), tail.isEmpty ? nil : tail)
    }
    return (parseDockerSize(head), String(tail.dropFirst().dropLast()))
}

private func dockerCLI() -> String? {
    if let p = runCmd("/bin/sh", ["-c", "command -v docker"])?.trimmingCharacters(in: .whitespacesAndNewlines),
       !p.isEmpty {
        return p
    }
    for cand in ["/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                 "/Applications/Docker.app/Contents/Resources/bin/docker"] {
        if FileManager.default.fileExists(atPath: cand) { return cand }
    }
    return nil
}

/// 现在这个 `docker` 命令背后是哪家。看的是软链真身，不是命令名——
/// OrbStack 把 `/usr/local/bin/docker` 直接链进自己的 .app（本机实测落到
/// `/Applications/OrbStack.app/Contents/MacOS/xbin/docker`），两家用的命令名一模一样。
/// 这一格认错，页面上「去 Docker Desktop 里清」那句指路就把人往一款没装的 App 支使。
private func engineOwnerRuntime() -> DockerRuntime? {
    guard let cli = dockerCLI() else { return nil }
    let real = URL(fileURLWithPath: cli).resolvingSymlinksInPath().path.lowercased()
    if real.contains("orbstack") { return .orbstack }
    if real.contains("docker.app") { return .dockerDesktop }
    return nil
}

/// 一行一个运行时，量的是各家数据目录在这块盘上的实占。
///
/// 走 `dirSize` 而不是文件大小：它按 `st_blocks × 512` 累加，取到的正是稀疏文件
/// 真占住的那部分。OrbStack 那块 `data.img.raw` 逻辑大小 494 GB、实占 22.8 GB
/// （本机实测 2026-09-27），它自家 README 就写着「看到 8 TB 别慌，那不是它占的空间」——
/// 印逻辑大小等于替人撒谎。
private func runtimeDiskRows() async -> [DockerItem] {
    let installed = DockerRuntime.allCases.compactMap { r in r.dataDir.map { (r, $0) } }
    var out: [(Int, DockerItem)] = []
    await withTaskGroup(of: (Int, DockerItem)?.self) { group in
        for (i, pair) in installed.enumerated() {
            group.addTask {
                if Task.isCancelled { return nil }
                let sz = await dirSize(pair.1)
                guard sz > 0 else { return nil }
                return (i, DockerItem(kind: .runtime, runtime: pair.0,
                                      title: pair.0.rawValue, size: sz, path: pair.1))
            }
        }
        for await r in group { if let r = r { out.append(r) } }
    }
    return out.sorted { $0.0 < $1.0 }.map(\.1)
}

public func scanDocker() async -> [DockerItem] {
    var detail: [DockerItem] = []
    let engine: DockerRuntime? = HomeAccess.runsSandboxed ? nil : engineOwnerRuntime()
    // ① 引擎自己的账本：CLI 在且守护进程答得上来。沙盒版不走这条路——起外部可执行文件
    // 在沙盒里本就不确定，而这一页要答的「占了这块盘多少」按磁盘实占同样答得出。
    if !HomeAccess.runsSandboxed,
       let cli = dockerCLI(),
       let info = runCmd(cli, ["info", "--format", "{{.ServerVersion}}"], timeout: 4),
       !info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let df = runCmd(cli, ["system", "df", "--format", "{{json .}}"]) ?? ""
        for line in df.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = row["Type"] as? String else { continue }
            let kind: DockerKind = ["Images": .dfImages, "Containers": .dfContainers,
                                    "Local Volumes": .dfVolumes, "Build Cache": .dfCache][t] ?? .other
            let rec = (row["Reclaimable"] as? String).map(parseDockerReclaimable)
            detail.append(DockerItem(
                kind: kind, runtime: engine, title: t,
                size: parseDockerSize(row["Size"] as? String ?? ""),
                total: row["TotalCount"] as? String,
                active: row["Active"] as? String,
                reclaimable: rec?.bytes,
                reclaimableShare: rec?.share))
        }
        let imgs = runCmd(cli, ["image", "ls", "--format", "{{json .}}"]) ?? ""
        var imgItems: [DockerItem] = []
        for line in imgs.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let repo = row["Repository"] as? String ?? ""
            let sz = parseDockerSize(row["Size"] as? String ?? "")
            if repo.isEmpty || repo == "<none>" {
                imgItems.append(DockerItem(kind: .danglingImage, runtime: engine,
                                           title: row["ID"] as? String ?? "", size: sz))
            } else {
                imgItems.append(DockerItem(kind: .image, runtime: engine,
                                           title: "\(repo):\(row["Tag"] as? String ?? "")", size: sz))
            }
        }
        detail += imgItems.sorted { $0.size > $1.size }.prefix(60)
    }
    // ② 磁盘的账：运行时那一行排在最前面，页头那个「共 X」就是它们相加
    let disks = await runtimeDiskRows()
    guard disks.isEmpty else { return disks + detail }
    // 引擎答了、机器上却找不到任何一家的数据目录（DOCKER_HOST 指向远端之类）。
    // 这时候没有磁盘实占那一行可以落账，就把段相加顶上去——页头写 0 是更坏的谎。
    guard !detail.isEmpty else { return [] }
    let sections = detail.filter { $0.kind != .image && $0.kind != .danglingImage }
    return [DockerItem(kind: .runtime, runtime: engine, title: engine?.rawValue ?? "",
                       size: sections.reduce(Int64(0)) { $0 + $1.size })] + detail
}
