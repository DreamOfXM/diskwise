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
                      top: Int = 0, skipNames: Set<String> = []) async -> WalkResult {
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
            guard sz >= minSize, cutoff == nil || mt < cutoff! else { continue }
            matched += 1
            out.append(FileRow(url: URL(fileURLWithPath: p), size: sz,
                               mtime: Date(timeIntervalSince1970: mt)))
            if top > 0 && out.count >= top * 4 {
                out.sort { $0.size > $1.size }
                out = Array(out.prefix(top))
            }
        }
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
    public var files: [URL]   // 第一个保留，其余可删
    public var waste: Int64 { size * Int64(max(0, files.count - 1)) }
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

public func findDupGroups(_ rows: [FileRow]) -> [DupGroup] {
    var bySize: [Int64: [URL]] = [:]
    for r in rows { bySize[r.size, default: []].append(r.url) }
    var groups: [DupGroup] = []
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
                let ordered = same.sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                    < ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
                groups.append(DupGroup(size: sz, files: ordered))
            }
        }
    }
    return groups.sorted { $0.waste > $1.waste }
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

public func scanOrphans() async -> (items: [OrphanItem], appCount: Int) {
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
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: c.path, isDirectory: &isDir)
                let sz: Int64 = isDir.boolValue ? await dirSize(u) : fileSize(u)
                guard sz > 0 else { return nil }
                let g = guess(c.stem)
                return OrphanItem(
                    name: c.stem, loc: c.label, path: u, size: sz, level: c.level, guess: g)
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
    public var selected = false
}

/// node_modules 只在用户区找，不跟着「整盘」开关走。
///
/// 这不是漏扫，是算过的：依赖目录只会长在项目里，而项目在家目录。系统区里唯一像样的
/// 一处是包管理器自己的全局目录（`/opt/homebrew/lib/node_modules` 那类），删它等于拆掉
/// 命令行工具，而且 brew 有自己的清理方式。为了这一处把整棵 /Library 走一遍，
/// 换来的是几分钟空转 + 一个勾不得的条目。
public func findNodeModules() async -> [NMProject] {
    let home = homePath()
    let roots = [URL(fileURLWithPath: home), URL(fileURLWithPath: applicationsDir())]
        .filter { FileManager.default.fileExists(atPath: $0.path) }
    // 第一段：翻目录找 node_modules（命中即不再下钻）
    var nmDirs: [String] = []
    // 每个根记自己的卷号：跨卷守卫要按根比
    var stack = roots.map { ($0.path, deviceOf($0)) }
    var visited = 0
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
        visited += 1
    }
    // 第二段：并行统计，聚合到项目级
    var projects: [String: (size: Int64, nms: Int, mtime: Date, partial: Bool)] = [:]
    await withTaskGroup(of: (proj: String, size: Int64, mt: Date, partial: Bool)?.self) { group in
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
                return (proj, sz, mt, false)
            }
        }
        for await r in group {
            guard let r = r else { continue }
            var e = projects[r.proj] ?? (0, 0, .distantPast, false)
            e.size += r.size
            e.nms += 1
            e.mtime = max(e.mtime, r.mt)
            if r.partial { e.partial = true }
            projects[r.proj] = e
        }
    }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return projects.map { (proj, e) in
        NMProject(project: proj, size: e.size, nmCount: e.nms,
                  date: f.string(from: e.mtime), partial: e.partial)
    }.sorted { $0.size > $1.size }
}

// ══ Docker：只读命令明细（不代删，只指路）；没跑则回退粗粒度 ══

/// Docker 条目的种类——措辞归界面，这里只给分类和数字
public enum DockerKind: String {
    case dfImages, dfContainers, dfVolumes, dfCache
    case image, danglingImage
    case rawDir, other
}

public struct DockerItem: Identifiable {
    public let id = UUID()
    public var kind: DockerKind
    /// 镜像的 仓库:tag、悬空镜像的 ID、回退模式的子目录名——真实数据，不翻译
    public var title: String
    public var size: Int64
    public var total: String?
    public var active: String?
    public var reclaimable: String?
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

private func parseDockerSize(_ s: String) -> Int64 {
    let mult: [(suffix: String, m: Double)] = [("PB", Double(1 << 50)), ("TB", Double(1 << 40)), ("GB", Double(1 << 30)),
                                               ("MB", Double(1 << 20)), ("kB", 1024), ("KB", 1024), ("B", 1)]
    let t = s.trimmingCharacters(in: .whitespaces)
    for (suf, m) in mult where t.hasSuffix(suf) {
        if let v = Double(t.dropLast(suf.count)) { return Int64(v * m) }
    }
    return 0
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

public func scanDocker() async -> [DockerItem] {
    let base = homeDir().appendingPathComponent("Library/Containers/com.docker.docker")
    // CLI 在且守护进程在跑：分类明细。沙盒版不走这条路——起外部可执行文件在沙盒里本就不确定，
    // 而这一页要答的「Docker 占了多少」按目录统计同样答得出，只是粒度粗一点。
    if !HomeAccess.runsSandboxed,
       let cli = dockerCLI(),
       let info = runCmd(cli, ["info", "--format", "{{.ServerVersion}}"], timeout: 4),
       !info.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        var items: [DockerItem] = []
        let df = runCmd(cli, ["system", "df", "--format", "{{json .}}"]) ?? ""
        for line in df.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let t = row["Type"] as? String else { continue }
            let kind: DockerKind = ["Images": .dfImages, "Containers": .dfContainers,
                                    "Local Volumes": .dfVolumes, "Build Cache": .dfCache][t] ?? .other
            items.append(DockerItem(
                kind: kind, title: t,
                size: parseDockerSize(row["Size"] as? String ?? ""),
                total: row["TotalCount"] as? String,
                active: row["Active"] as? String,
                reclaimable: row["Reclaimable"] as? String))
        }
        let imgs = runCmd(cli, ["image", "ls", "--format", "{{json .}}"]) ?? ""
        var imgItems: [DockerItem] = []
        for line in imgs.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let row = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let repo = row["Repository"] as? String ?? ""
            let sz = parseDockerSize(row["Size"] as? String ?? "")
            if repo.isEmpty || repo == "<none>" {
                imgItems.append(DockerItem(kind: .danglingImage,
                                           title: row["ID"] as? String ?? "", size: sz))
            } else {
                imgItems.append(DockerItem(kind: .image,
                                           title: "\(repo):\(row["Tag"] as? String ?? "")", size: sz))
            }
        }
        items += imgItems.sorted { $0.size > $1.size }.prefix(60)
        return items
    }
    // 回退：按子目录粗分（真实路径，可走废纸篓但标粗粒度）
    guard let kids = try? FileManager.default.contentsOfDirectory(
        at: base, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return []
    }
    var items: [DockerItem] = []
    await withTaskGroup(of: DockerItem?.self) { group in
        for k in kids {
            group.addTask {
                if Task.isCancelled { return nil }
                let sz = await dirSize(k)
                guard sz > 0 else { return nil }
                return DockerItem(kind: .rawDir, title: k.lastPathComponent, size: sz)
            }
        }
        for await r in group { if let r = r { items.append(r) } }
    }
    return items.sorted { $0.size > $1.size }
}
