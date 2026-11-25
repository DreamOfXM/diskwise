import Foundation
import AppKit

#if canImport(Darwin)
import Darwin
#endif

// ── 建议层：把「盘上有什么」变成「哪些东西你大概不需要了」 ──
//
// 这一层和另外两层分工严格不同：
//   · 整盘账（overview）回答「空间去哪了」——按物理块算，闭合到每一字节；
//   · 清理白名单（scan_disk）回答「知识库认识哪些缓存」——只覆盖缓存这一类；
//   · 本层回答「哪些东西留着没用」，也就是前面两层的空白：很久没打开的应用、
//     旧会话、旧备份、同一工具的多个版本、下完就没管的安装包、半年没动的项目。
//
// 这里最常见、代价最大的错法只有一个：**把「旧」当成「没用」**。
// 目录的 mtime 会因为被访问而刷新，快照里的文件保留着原始旧时间，
// 所以「多久没动」这件事必须带出处（stale_basis），不能只给一个数字。
//
// 本层只读。它给的是建议（safe / review / keep / blocked），不是删除动作：
// 最终按不按下去由人决定。

/// 一条建议的分档。
///
/// - `safe`：删了不丢东西，也确实拿得回空间（旧版本、装完就没用的安装包）。
/// - `review`：大概率没用了，但删掉会失去某些东西（对话记录、旧项目、备份），
///   得人看一眼。
/// - `keep`：正在用 / 时间太新 / 是关键路径的依赖。
/// - `blocked`：想删也删不动，或者删了系统会坏。给出原因和用户能做的动作。
public enum AdviceVerdict: String, Codable {
    case safe
    case review
    case keep
    case blocked
}

/// `blocked` 的原因。必须是枚举：自由文本最后会退化成「权限不够」这一句，
/// 而这四种的处置方式完全不同——一个输密码就行，一个只能去 Xcode 里卸。
public enum AdviceBlock: String, Codable {
    case none
    /// 需要「完全磁盘访问权限」：系统设置里勾一下，重开进程就生效
    case needsFullDiskAccess = "needs_fda"
    /// 需要管理员/root：sudo 或访达里输密码
    case needsAdmin = "needs_admin"
    /// 系统完整性保护：路径本身不许改
    case sip
    /// 只读卷（密封系统卷、模拟器运行时镜像）
    case readonlyVolume = "readonly_volume"
    /// 有进程正在用，删了会当场出问题
    case inUse = "in_use"
    /// 别的软件依赖它（运行时、命令行工具、框架）
    case functionalDependency = "functional_dependency"
}

/// 「多久没动」是按什么算出来的。这一格比天数本身重要：
/// 同一个目录，按内部文件算「两年没动」、按容器算「昨天刚备份」，结论正好相反。
public enum StaleBasis: String, Codable {
    /// 里面最新那个文件的修改时间。最常用，也最容易被快照骗。
    case fileMtime = "file_mtime"
    /// 容器本身（目录名里的日期或目录 mtime）。备份/快照必须用这个。
    case containerDate = "container_date"
    /// 系统记的「上次打开时间」（启动服务数据库，应用专有）。
    case lastUsedDate = "last_used_date"
    /// 拿不到时间依据——不猜，`stale_days` 给 -1。
    case unknown
}

public struct UnusedItem: Encodable {
    public let path: String
    public let name: String
    /// unused_app | session_history | backup_snapshot | duplicate_version |
    /// installer_image | orphan_project | stale_download | runtime_cache
    public let kind: String
    /// 真占盘（st_blocks×512）。判断「能腾出多少」只认它。
    public let physicalBytes: Int64
    /// 文件大小相加。与 physical 差得远说明是稀疏文件，别按它算。
    public let logicalBytes: Int64
    public let files: Int
    /// 多久没动（天）。`stale_basis` 为 unknown 时是 -1。
    public let staleDays: Int
    public let staleBasis: String
    /// 最近活动的绝对日期（ISO，仅日期）。方便人核对「到底哪天」。
    public let lastActive: String?
    /// 删了能不能自己长回来（重下/重装/重新编译）。
    public let regenerable: Bool
    public let recommend: String
    public let blockedReason: String
    /// 人该做什么（英文，agent 会直接转述）。blocked 时是「怎么才能删」。
    public let userAction: String?
    /// 一句话结论：为什么这么判。这是给人看的核心理由。
    public let why: String
    /// 删了以后怎么恢复。
    public let restore: String?

    enum CodingKeys: String, CodingKey {
        case path, name, kind, files, recommend, why, restore
        case physicalBytes = "physical_bytes"
        case logicalBytes = "logical_bytes"
        case staleDays = "stale_days"
        case staleBasis = "stale_basis"
        case lastActive = "last_active"
        case regenerable
        case blockedReason = "blocked_reason"
        case userAction = "user_action"
    }
}

public struct UnusedReport: Encodable {
    public let scope: [String]
    public let items: [UnusedItem]
    /// 分档合计。加起来 == 所有条目的 physical_bytes 之和。
    public let totals: [String: Int64]
    /// 最该动手的三五件事，人话。
    public let topActions: [String]
    public let notes: [String]

    enum CodingKeys: String, CodingKey {
        case scope, items, totals, notes
        case topActions = "top_actions"
    }
}

public enum AdviceScanner {

    /// 一个候选：收集阶段只认路径和线索，体积留到测量阶段。
    struct Candidate {
        var path: String
        var name: String
        var kind: String
        var regenerable: Bool
        var restore: String?
        var whyHint: String
        /// 用容器日期而不是内部文件时间（备份/快照必须如此）
        var useContainerDate: Bool
        /// 应用专用：上次打开的日期
        var lastUsed: Date?
        /// 版本号比较用：同一工具里排序取最新
        var version: String?
        var groupKey: String?
        /// 以普通用户身份连读都读不了（root 或系统服务独占）。
        /// 这类项即使量出 0 字节也不能当「空的」丢掉——真实体积要靠 sudo 才看得见。
        var needsRoot: Bool = false
    }

    /// 目录名里带这些词的，按「备份/快照」处理：时间基准切到容器。
    private static let backupWords = ["backup", "backups", "snapshot", "snapshots",
                                      "archive", "archives", "old", "bak"]
    /// 会话历史类目录名。只收「明确是历史记录」的，不含通用 projects。
    private static let sessionWords = ["sessions", "session", "history", "transcripts",
                                       "conversations", "chats", "trajectories"]

    /// 安装包/镜像：装完就没用了，留着只是占地方。
    private static let installerExts: Set<String> = ["dmg", "pkg", "iso", "xip", "img"]

    /// 应用目录里这些不能算「可以删」：系统自带、Apple 工具链、正在运行。
    private static let protectedAppPrefixes = [
        "/Applications/Xcode.app", "/Applications/Utilities",
    ]

    /// SIP 保护区：给出正确原因，别让人白输密码。
    private static let sipPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/",
                                      "/Library/Apple/", "/private/var/db/"]

    /// 路径是不是真的被 SIP 护着。
    ///
    /// `/System/Volumes/Data` 是数据卷上的一层，只是路径长得像系统卷——它可写、
    /// 里面的东西能删。不排掉它，Data 卷根下所有东西（包括那个涨到 47 GB 的
    /// Spotlight 索引）都会被说成「SIP 保护，动不了」，而它们其实是整台机器上
    /// 最容易腾的一批。误判方向刚好相反：把能删的说成不能删，比漏报更误导。
    public static func isSIPProtected(_ path: String) -> Bool {
        if path == "/System/Volumes/Data" || path.hasPrefix("/System/Volumes/Data/") {
            return false
        }
        return sipPrefixes.contains { path.hasPrefix($0) }
    }

    // MARK: - 入口

    /// 扫一遍，给建议。只读。
    ///
    /// - Parameters:
    ///   - roots: 额外要看的目录（默认家目录顶层 + /Applications + 常见工具目录）
    ///   - minBytes: 单条最小体积，默认 200 MB —— 比这小的条目加起来也不值得占一屏
    ///   - staleDays: 「多久没动」的全局门槛，默认 90 天（约三个月：换季了还没碰过的东西）
    public static func scan(roots: [String]? = nil, minBytes: Int64 = 200_000_000,
                            staleDays: Int = 90) async -> UnusedReport {
        let home = homePath()
        let now = Date()
        var scope: [String] = []
        var cands: [Candidate] = []

        // 1. 应用：装了很多、常用的就那几个。判据是「上次打开」，不是文件时间。
        if roots == nil {
            for dir in ["/Applications", (home as NSString).appendingPathComponent("Applications")] {
                for app in apps(in: dir) {
                    cands.append(app)
                }
                scope.append(dir)
            }
        }

        // 2. 家目录顶层：备份、快照、会话、孤儿项目都在这一层露头。
        let homeRoots = roots ?? topLevelDirs(home)
        for dir in homeRoots {
            scope.append(dir)
            let name = (dir as NSString).lastPathComponent
            let lower = name.lowercased()
            if backupWords.contains(where: { lower.contains($0) }) {
                cands.append(Candidate(
                    path: dir, name: name, kind: "backup_snapshot", regenerable: false,
                    restore: nil,
                    whyHint: "Directory name says backup/snapshot. Judged by the container's own "
                        + "date, NOT by the files inside — snapshots keep original (old) file times.",
                    useContainerDate: true, lastUsed: nil, version: nil, groupKey: nil))
            } else if sessionWords.contains(where: { lower.contains($0) }) {
                cands.append(Candidate(
                    path: dir, name: name, kind: "session_history", regenerable: false,
                    restore: nil,
                    whyHint: "Looks like stored conversation/session history: deleting it loses the "
                        + "records themselves, not just a cache.",
                    useContainerDate: false, lastUsed: nil, version: nil, groupKey: nil))
            } else {
                cands.append(contentsOf: orphanProject(at: dir, name: name))
            }
        }

        // 3. 工具目录里的多版本：只有最新那个是「在用」的，旧的纯占地方。
        for toolsDir in toolDirs(home) {
            scope.append(toolsDir)
            cands.append(contentsOf: versions(in: toolsDir))
            cands.append(contentsOf: flatVersions(in: toolsDir))
        }

        // 4. 大安装包/镜像：下完、装完就再没打开过。
        if roots == nil {
            // 废纸篓：唯一「已经决定不要、只差最后一步」的东西。它不属于任何缓存路径，
            // 也从来不会出现在清理清单上，但清完一轮之后它往往就是最大的那一块。
            let trash = (home as NSString).appendingPathComponent(".Trash")
            if isDirectory(trash) {
                cands.append(Candidate(
                    path: trash, name: "Trash", kind: "trash", regenerable: false, restore: nil,
                    whyHint: "Items that were already deleted but not yet purged. Emptying the Trash "
                        + "is the last step — note it also ends DiskWise's ability to undo recent "
                        + "cleanups, since those items live here.",
                    useContainerDate: false, lastUsed: nil, version: nil, groupKey: nil))
            }
            cands.append(contentsOf: historyCandidates(home: home))
            cands.append(contentsOf: orphanAppData(home: home))
            cands.append(contentsOf: bigFiles(home: home))
            cands.append(contentsOf: installerImages(home: home))
            // Data 卷根目录的系统缓存：不在家目录、不在应用缓存路径，前四类都碰不到。
            cands.append(contentsOf: systemCacheCandidates())
        }

        let filtered = cands.filter { c in
            // 同一路径只留一条：家目录顶层的备份目录会同时被「顶层名字匹配」和
            // 「隐藏/子目录线索」抓到一次，不去重就会在清单里出现两遍、算两遍体积。
            !c.path.isEmpty
        }
        var seenPaths = Set<String>()
        let unique = filtered.filter { seenPaths.insert($0.path).inserted }
        let items = await measure(unique, now: now, staleDays: staleDays)
            // 系统缓存即使量出 0 字节也保留：0 的含义常常是「没权限量」，
            // 不是「空的」。把这条藏起来，用户就永远不知道那里可能有几十 G。
            .filter { $0.physicalBytes >= minBytes || $0.kind == "system_index" || $0.kind == "version_history" }
            .sorted { $0.physicalBytes > $1.physicalBytes }

        let totals = totalsOf(items)
        let actions = topActions(items, totals: totals)
        let notes = [
            "RECOMMENDATIONS ONLY — nothing is deleted. 'safe' items can go without losing anything; "
                + "'review' items are probably unused but hold data (conversations, backups, old projects) "
                + "so a human should look first; 'keep' and 'blocked' explain why not.",
            "Sizes are PHYSICAL bytes (st_blocks x 512) — the space you actually get back. "
                + "logical_bytes is the sum of file sizes; when it is much larger than physical_bytes the "
                + "item is sparse (VM disks, preallocated databases) and deleting it frees far less than it claims.",
            "stale_basis says what 'stale_days' was computed from. container_date means the judgement used "
                + "the backup/snapshot's own date, because files inside a snapshot keep their original old "
                + "timestamps (using file mtime there would call a fresh backup 'years old').",
            "This layer covers what scan_disk cannot: apps, session history, backups, duplicate tool "
                + "versions, installers, orphan projects. For caches use scan_disk; for assets inside "
                + "projects (node_modules, .venv, model weights) use scan_project_assets.",
        ]
        return UnusedReport(scope: scope, items: items, totals: totals,
                            topActions: actions, notes: notes)
    }

    // MARK: - 候选发现

    private static func topLevelDirs(_ home: String) -> [String] {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: home) else { return [] }
        return kids.filter { !$0.hasPrefix(".") && $0 != "Trash" }
            .map { (home as NSString).appendingPathComponent($0) }
            .filter { isDirectory($0) }
    }

    /// 会话历史的藏身处：先在隐藏目录一层找，再看几个「工具自己的目录」里有没有
    /// sessions/projects 这一类子目录。
    ///
    /// 为什么必须单独找：这类数据几乎全在隐藏目录里，而隐藏目录被顶层扫描刻意跳过了
    /// （`.Trash`、`.Spotlight-V100` 那些进去就是浪费时间）。实测旧会话历史是这次清盘
    /// 里第三大的可清项，却从来没出现在任何缓存清单上。
    ///
    /// `sessionHosts` 是一张**会过时**的外部工具清单，不是什么业务逻辑：
    /// 新工具冒出来时往里加名字即可，判定规则本身不看工具名。
    private static let sessionHosts: [String] = [
        ".claude", ".codex", ".cursor", ".zcode", ".qoder", ".gemini", ".aider",
        ".continue", ".codeium", ".windsurf", ".opencode", ".trae",
    ]
    private static let hostSessionSubdirs: Set<String> = [
        "projects", "sessions", "session", "history", "transcripts",
        "conversations", "chats", "trajectories",
    ]

    private static func historyCandidates(home: String) -> [Candidate] {
        let fm = FileManager.default
        let skip: Set<String> = [".Trash", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
                                 ".TemporaryItems", ".vol", ".PKInstallSandboxManager"]
        guard let kids = try? fm.contentsOfDirectory(atPath: home) else { return [] }
        var out: [Candidate] = []
        func add(_ p: String, _ name: String, backup: Bool) {
            out.append(Candidate(
                path: p, name: name,
                kind: backup ? "backup_snapshot" : "session_history",
                regenerable: false, restore: nil,
                whyHint: backup
                    ? "Directory name says backup/snapshot. Judged by the container's own date, "
                        + "NOT by the files inside — snapshots keep their original (old) timestamps."
                    : "Stored conversation/session history: deleting it loses the records themselves, "
                        + "not just a cache. Often the largest thing nobody ever looks at again.",
                useContainerDate: backup, lastUsed: nil, version: nil, groupKey: nil))
        }
        for k in kids where !skip.contains(k) {
            let p = (home as NSString).appendingPathComponent(k)
            guard isDirectory(p) else { continue }
            let lower = k.lowercased()
            if k.hasPrefix(".") {
                if backupWords.contains(where: { lower.contains($0) }) {
                    add(p, k, backup: true)
                } else if sessionWords.contains(where: { lower.contains($0) }) {
                    add(p, k, backup: false)
                } else if sessionHosts.contains(k),
                          let subs = try? fm.contentsOfDirectory(atPath: p) {
                    for sub in subs where hostSessionSubdirs.contains(sub.lowercased()) {
                        let sp = (p as NSString).appendingPathComponent(sub)
                        if isDirectory(sp) { add(sp, "\(k)/\(sub)", backup: false) }
                    }
                }
            } else if backupWords.contains(where: { lower.contains($0) }) {
                add(p, k, backup: true)
            }
        }
        return out
    }

    /// Data 卷根目录下的系统缓存。
    ///
    /// 这些东西既不在家目录、也不在任何应用的缓存路径里，所以「按用户目录找」和
    /// 「按应用找」两种扫法都看不见它们——这正是它们能长到几十 GB 却不被发现的原因。
    ///
    /// 实测这台机器：`.Spotlight-V100` 涨到 **47 GB**（三百万文件正常只要 2~5 GB），
    /// 是整机最大的单块可清项；而它的目录时间天天在变，按「多久没动」判会判成「刚刚用过」。
    /// 索引跟「新不新」无关，只跟「比它该有的大多少」有关。
    ///
    /// 所有权是 root 或 `_mds_stores`，普通权限连读都读不了。所以量不到 0 字节时
    /// 不能当空的丢掉——照实说「要 root 才能量」，并给出能直接复制的命令。
    private static func systemCacheCandidates() -> [Candidate] {
        let dataRoot = "/System/Volumes/Data"
        // (目录名, 显示名, 类别, 正常上限字节)
        let known: [(String, String, String, Int64)] = [
            (".Spotlight-V100", "Spotlight index", "system_index", 8_000_000_000),
            (".DocumentRevisions-V100", "Document version history", "version_history", 2_000_000_000),
            (".fseventsd", "Filesystem event log", "system_index", 2_000_000_000),
        ]
        var out: [Candidate] = []
        for (dir, label, kind, normalMax) in known {
            let p = (dataRoot as NSString).appendingPathComponent(dir)
            guard isDirectory(p) else { continue }
            out.append(Candidate(
                path: p, name: label, kind: kind,
                regenerable: true,
                restore: kind == "system_index"
                    ? "macOS rebuilds this automatically after it is removed; search is unavailable "
                        + "until the rebuild finishes (from minutes to a few hours on a large disk)."
                    : "This is a record of past edits. Removing it frees space but the old versions "
                        + "of documents are gone for good.",
                whyHint: "Lives at the root of the Data volume, outside every home folder and app "
                    + "cache path, so scans that walk ~ and /Applications never see it. "
                    + "Normal size is up to \(human(normalMax)); anything far above that is bloat, "
                    + "not data. Its own timestamp changes daily, so age says nothing here.",
                useContainerDate: false, lastUsed: nil, version: nil, groupKey: nil,
                needsRoot: true))
        }
        return out
    }

    /// 应用已经卸载、但数据还躺着的目录。
    ///
    /// 判据只有一条：`~/Library/Application Support` 里这个目录名，在已装应用里
    /// 找不到对应的名字。这类残留很少被清理工具看见，因为它们不在任何「缓存」路径上，
    /// 可里面常常存着登录状态、聊天记录、配置——所以只能是 `review`，不能是 `safe`。
    ///
    /// 名字对不上就跳过（尤其是 com.apple.* 这种 bundle id 目录）：宁可漏报，
    /// 也不要把在用的应用数据说成垃圾。漏报的代价是少省几十 GB，误报的代价是丢东西。
    private static func orphanAppData(home: String) -> [Candidate] {
        let fm = FileManager.default
        let support = (home as NSString).appendingPathComponent("Library/Application Support")
        guard let kids = try? fm.contentsOfDirectory(atPath: support) else { return [] }
        var installed: [String] = []
        for dir in ["/Applications", (home as NSString).appendingPathComponent("Applications")] {
            guard let apps = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            installed += apps.filter { $0.hasSuffix(".app") }
                .map { ($0 as NSString).deletingPathExtension.lowercased() }
        }
        var out: [Candidate] = []
        for k in kids {
            let lower = k.lowercased()
            guard !lower.contains(".apple."), !lower.hasPrefix("com.") else { continue }
            let p = (support as NSString).appendingPathComponent(k)
            guard isDirectory(p) else { continue }
            let key = lower.replacingOccurrences(of: " ", with: "")
            let matched = installed.contains { app in
                let a = app.replacingOccurrences(of: " ", with: "")
                return a == key || a.contains(key) || key.contains(a)
            }
            guard !matched else { continue }
            out.append(Candidate(
                path: p, name: k, kind: "orphan_app_data", regenerable: false, restore: nil,
                whyHint: "No installed application matches this folder name, so it is probably "
                    + "left over from an app that was removed. It can still hold logins, settings "
                    + "and history — check before deleting. Name matching is fuzzy: if the app is "
                    + "actually still installed under a different name, keep it.",
                useContainerDate: false, lastUsed: nil, version: nil, groupKey: nil))
        }
        return out
    }

    /// 下载/桌面/文稿里的大文件。安装包单独算，这里只报「一看就是素材或成品」的那些。
    /// 一律 review：它们可能是用户自己拍的、剪的、要用的东西。
    private static func bigFiles(home: String) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        for sub in ["Downloads", "Desktop", "Documents"] {
            let root = (home as NSString).appendingPathComponent(sub)
            guard let kids = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for k in kids where !k.hasPrefix(".") {
                let p = (root as NSString).appendingPathComponent(k)
                var st = stat()
                guard lstat(p, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
                let ext = (k as NSString).pathExtension.lowercased()
                guard !installerExts.contains(ext) else { continue }
                let physical = Int64(st.st_blocks) * 512
                guard physical >= 1_000_000_000 else { continue }
                let mt = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
                out.append(Candidate(
                    path: p, name: k, kind: "large_file", regenerable: false, restore: nil,
                    whyHint: "A single large file in a downloads/documents folder. This tool cannot "
                        + "know what it is for — look at it before deleting.",
                    useContainerDate: false, lastUsed: mt, version: nil, groupKey: nil))
            }
        }
        return out
    }

    /// 应用：体积从 bundle 量，使用时间问启动服务数据库（mdls）。
    private static func apps(in dir: String) -> [Candidate] {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return kids.filter { $0.hasSuffix(".app") }.map { n in
            let p = (dir as NSString).appendingPathComponent(n)
            let name = (n as NSString).deletingPathExtension
            let used = lastUsedDate(p)
            return Candidate(
                path: p, name: name, kind: "unused_app", regenerable: true,
                restore: "Re-download from the App Store, the vendor's site, or `brew install --cask`.",
                whyHint: "An installed application. The verdict comes from when it was last opened, "
                    + "not from when its files changed (updaters touch files in apps nobody opens).",
                useContainerDate: false, lastUsed: used, version: nil, groupKey: nil)
        }
    }

    /// 旧项目：有代码特征、又很久没有过改动。
    private static func orphanProject(at path: String, name: String) -> [Candidate] {
        let fm = FileManager.default
        let markers = [".git", "package.json", "pyproject.toml", "Cargo.toml", "go.mod",
                       "Package.swift", "requirements.txt", ".venv", "node_modules"]
        let hasMarker = markers.contains { fm.fileExists(atPath: (path as NSString).appendingPathComponent($0)) }
        guard hasMarker else { return [] }
        return [Candidate(
            path: path, name: name, kind: "orphan_project", regenerable: false,
            restore: nil,
            whyHint: "A project directory (has .git or a build manifest). 'Stale' only means no file "
                + "changed recently — it is still source code, so treat it as review, not as junk.",
            useContainerDate: false, lastUsed: nil, version: nil, groupKey: nil)]
    }

    /// 工具目录：pipx 的 venv、hermes 的 tools、Homebrew 的 Cellar。
    /// 这些位置放的是「同一工具的多个版本」——旧版本除了占地方没有任何作用。
    private static func toolDirs(_ home: String) -> [String] {
        let cands = [
            (home as NSString).appendingPathComponent(".local/pipx/venvs"),
            (home as NSString).appendingPathComponent(".hermes/tools"),
            "/opt/homebrew/Cellar",
        ]
        return cands.filter { isDirectory($0) }
    }

    private static func versions(in toolsDir: String) -> [Candidate] {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: toolsDir) else { return [] }
        var out: [Candidate] = []
        for tool in kids where !tool.hasPrefix(".") {
            let toolPath = (toolsDir as NSString).appendingPathComponent(tool)
            guard isDirectory(toolPath) else { continue }
            guard let vs = try? FileManager.default.contentsOfDirectory(atPath: toolPath) else { continue }
            let dirs = vs.filter { !$0.hasPrefix(".") && isDirectory((toolPath as NSString).appendingPathComponent($0)) }
            guard dirs.count > 1 else { continue }
            // 版本号比较：能按数值比就按数值比，否则按名字（Homebrew 用 1.2.3_1 这种）
            let sorted = dirs.sorted { versionLess($0, $1) }
            let newest = sorted.last ?? dirs[0]
            for v in sorted.dropLast() {
                out.append(Candidate(
                    path: (toolPath as NSString).appendingPathComponent(v),
                    name: "\(tool) \(v)", kind: "duplicate_version", regenerable: true,
                    restore: "Reinstall this exact version with the tool's package manager if ever needed.",
                    whyHint: "An older installed version of \(tool). Only one version is in use "
                        + "(\(newest)); the rest are dead weight.",
                    useContainerDate: true, lastUsed: nil, version: v, groupKey: toolPath))
            }
        }
        return out
    }

    /// 版本串比较：数字段按数值，其余按字典序。1.10 > 1.9 这种必须对。
    private static func versionLess(_ a: String, _ b: String) -> Bool {
        let pa = a.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let pb = b.split(whereSeparator: { !$0.isNumber }).map { Int($0) ?? 0 }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y }
        }
        return a < b
    }

    /// 平铺布局：`<tool>-<version>-darwin-<arch>`。同一个工具留下多份版本时，
    /// 只有最新那份在被用。这跟 `tool/version` 两级布局不是一回事，得分开认——
    /// 只按两级找，这类目录永远返回「没有多版本」，明明旧副本就躺在旁边。
    private static func flatVersions(in dir: String) -> [Candidate] {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        var groups: [String: [(path: String, version: String)]] = [:]
        for k in kids where !k.hasPrefix(".") {
            let p = (dir as NSString).appendingPathComponent(k)
            guard isDirectory(p), let (tool, ver) = splitNameVersion(k) else { continue }
            groups[tool, default: []].append((p, ver))
        }
        var out: [Candidate] = []
        for (tool, list) in groups where list.count > 1 {
            let sorted = list.sorted { versionLess($0.version, $1.version) }
            let newest = sorted.last?.version ?? ""
            for item in sorted.dropLast() {
                out.append(Candidate(
                    path: item.path, name: "\(tool) \(item.version)", kind: "duplicate_version",
                    regenerable: true,
                    restore: "Reinstall this exact build with the tool's package manager if ever needed.",
                    whyHint: "An older build of \(tool) next to the current one (\(newest)). "
                        + "Only the newest is used; the older copies are dead weight.",
                    useContainerDate: true, lastUsed: nil, version: item.version,
                    groupKey: (dir as NSString).appendingPathComponent(tool)))
            }
        }
        return out
    }

    /// 从 `node-26.12.1-darwin-arm64` 里切出 (node, 26.12.1)。
    /// 只认「第一个以数字开头的段」——工具名里带数字（如 `python3`）时不能切错。
    private static func splitNameVersion(_ name: String) -> (String, String)? {
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 2 else { return nil }
        for i in 1..<parts.count {
            guard let c = parts[i].first, c.isNumber else { continue }
            return (parts[0..<i].joined(separator: "-"), parts[i])
        }
        return nil
    }

    /// 大安装包：家目录浅层（深度 3）里的 dmg/pkg/iso。跳过缓存与虚拟机目录。
    private static func installerImages(home: String) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        let skip: Set<String> = ["Library", "OrbStack", ".Trash", "node_modules", ".git",
                                 ".build", "DerivedData", ".venv", "Applications"]
        func walk(_ dir: String, depth: Int) {
            guard depth > 0 else { return }
            guard let kids = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for k in kids where !skip.contains(k) {
                let p = (dir as NSString).appendingPathComponent(k)
                var st = stat()
                guard lstat(p, &st) == 0 else { continue }
                let mode = st.st_mode & S_IFMT
                if mode == S_IFDIR {
                    walk(p, depth: depth - 1)
                    continue
                }
                let ext = (k as NSString).pathExtension.lowercased()
                guard installerExts.contains(ext) else { continue }
                let physical = Int64(st.st_blocks) * 512
                guard physical >= 300_000_000 else { continue }
                let mt = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
                out.append(Candidate(
                    path: p, name: k, kind: "installer_image", regenerable: true,
                    restore: "Re-download the installer if it is ever needed again.",
                    whyHint: "An installer/disk image. Once the app is installed these are pure "
                        + "leftovers — the largest of them are often years old.",
                    useContainerDate: false, lastUsed: mt, version: nil, groupKey: nil))
            }
        }
        walk(home, depth: 3)
        return out
    }

    // MARK: - 测量与判定

    private static func measure(_ cands: [Candidate], now: Date,
                                staleDays: Int) async -> [UnusedItem] {
        var out: [UnusedItem] = []
        var i = 0
        while i < cands.count {
            let wave = Array(cands[i..<min(i + 6, cands.count)])
            i += wave.count
            let measured = await withTaskGroup(of: (Candidate, DirScan).self) { group in
                for c in wave {
                    group.addTask {
                        (c, await dirSizeReport(URL(fileURLWithPath: c.path)))
                    }
                }
                var acc: [(Candidate, DirScan)] = []
                for await r in group { acc.append(r) }
                return acc
            }
            for (c, scan) in measured {
                out.append(judge(c, scan: scan, now: now, staleDays: staleDays))
            }
        }
        return out
    }

    /// 一条候选怎么判。顺序即优先级：先看「能不能动」，再看「该不该动」。
    private static func judge(_ c: Candidate, scan: DirScan, now: Date,
                              staleDays: Int) -> UnusedItem {
        let path = c.path
        // 时间依据
        var basis: StaleBasis = .unknown
        var activeAt: Date? = nil
        if c.useContainerDate {
            if let d = containerDate(path) { activeAt = d; basis = .containerDate }
        } else if c.kind == "unused_app" {
            // 应用的「上次打开」只有启动服务数据库记着，而它在真机上经常是 (null)：
            // 这台机器 39 个应用里只有 1 个有值。更糟的是有值时也可能是假的——
            // 实测 iMovie 的 bundle 从 8 月起一个文件都没动过，mdls 却报「今天打开」。
            // 所以只在「mdls 不晚于文件时间」时才认它；晚于文件时间说明这个数是被
            // 索引活动刷出来的，不是用户打开的。两个都拿不到就明说不知道，不猜。
            let fileNewest = scan.newest
            if let used = c.lastUsed, let f = fileNewest,
               used <= f.addingTimeInterval(7 * 86400) {
                activeAt = used
                basis = .lastUsedDate
            } else if let f = fileNewest {
                activeAt = f
                basis = .fileMtime
            }
        } else if let used = c.lastUsed {
            activeAt = used
            basis = .lastUsedDate
        } else if let newest = scan.newest {
            activeAt = newest
            basis = .fileMtime
        }
        let days = activeAt.map { max(0, Int(now.timeIntervalSince($0) / 86400)) } ?? -1
        let dateStr = activeAt.map { isoDay($0) }

        // 能不能动。这里只把「动了会坏」或「根本动不了」判成 blocked。
        //
        // 曾经把「需要管理员密码」也归进 blocked，结果是：/Applications 下几乎每个应用
        // 都成了 blocked，一整屏全是「删不掉」，37 GB 全被算成「工具删不动」。
        // 那是个假结论——访达里拖到废纸篓输一次密码就删了，人做得到。
        // 权限不够只该写成「怎么删」，不该冒充「删不了」。
        var blocked: AdviceBlock = .none
        if isReadOnlyVolume(path) {
            blocked = .readonlyVolume
        } else if isSIPProtected(path) {
            blocked = .sip
        } else if c.kind == "unused_app", protectedAppPrefixes.contains(where: { path.hasPrefix($0) }) {
            blocked = .functionalDependency
        }

        let needsAdmin = blocked == .none && !isWritable(path)
        let running = c.kind == "unused_app" && isRunning(path)

        // 系统缓存（Spotlight 索引、版本历史）的所有者是 root 或系统服务：
        // 量出 0 字节几乎总是「没权限读」，不是「里面空的」。这两种情况必须分开，
        // 否则最大的那一块会被当成 0 悄悄丢掉——这台机器上它值 47 GB。
        let couldNotRead = c.needsRoot && scan.bytes == 0
            && !(scan.needAdmin.isEmpty && scan.needFullDiskAccess.isEmpty)
        if couldNotRead && blocked == .none { blocked = .needsAdmin }

        // 该不该动：分档
        var verdict: AdviceVerdict
        if blocked != .none {
            verdict = .blocked
        } else if running {
            // 正在运行的不能算「没用」：它此刻就在被用
            verdict = .keep
        } else {
            switch c.kind {
            case "trash":
                // 已经在废纸篓里了：用户早就决定不要了，只差清空
                verdict = .safe
            case "duplicate_version":
                // 同一工具只可能在用一个版本，旧的就是旧的
                verdict = .safe
            case "installer_image":
                verdict = (days >= staleDays || days < 0) ? .safe : .keep
            case "backup_snapshot":
                // 快照按容器日期：30 天内的按「还在更新」处理，不能删
                verdict = (days >= max(30, staleDays)) ? .review : .keep
            case "session_history":
                verdict = days >= max(60, staleDays) ? .review : .keep
            case "unused_app":
                verdict = days >= max(90, staleDays) ? .review : .keep
            case "orphan_project":
                verdict = days >= max(180, staleDays) ? .review : .keep
            case "orphan_app_data":
                // 应用都不在了，剩下的数据就是死的；但仍可能是想留的记录
                verdict = days >= max(90, staleDays) ? .review : .keep
            case "large_file":
                verdict = days >= staleDays ? .review : .keep
            case "system_index":
                // 索引的价值跟「多久没动」无关——它天天在写。只看「比该有的大多少」：
                // 三百万文件正常 2~5 GB，超过 8 GB 就是膨胀，重建能直接拿回几十 G。
                verdict = scan.bytes > 8_000_000_000 ? .review : .keep
            case "version_history":
                verdict = scan.bytes > 2_000_000_000 ? .review : .keep
            default:
                verdict = .keep
            }
        }

        // 稀疏文件：报的体积和真能腾出的差一个量级时，把话说在前面
        let sparse = scan.logicalBytes > 0 && scan.bytes > 0
            && Double(scan.bytes) / Double(scan.logicalBytes) < 0.5
        var why = c.whyHint
        if basis == .containerDate {
            why += " Judged by the container's date (\(days)d), not by the old timestamps inside."
        }
        if basis == .fileMtime && c.kind == "unused_app" {
            why += " macOS did not report when this app was last opened, so the age comes from when "
                + "its files last changed — an update resets that, so treat the age as an upper bound."
        }
        if days < 0 {
            why += " No reliable timestamp could be read, so nothing is claimed about age."
        }
        if couldNotRead {
            why += " Its size could not be read without root, so 0 bytes here means "
                + "'not measured' — not 'empty'."
        }
        if sparse {
            why += " Sparse: reports \(human(scan.logicalBytes)) of file sizes but occupies only "
                + "\(human(scan.bytes)) on disk — deleting it frees about \(human(scan.bytes))."
        }
        if scan.symlinksSkipped > 0 {
            why += " \(scan.symlinksSkipped) symlink(s) were not followed, so shared data is not double-counted."
        }
        if scan.crossVolumeSkipped > 0 {
            why += " \(scan.crossVolumeSkipped) separate volume(s) were skipped — their space belongs to another volume."
        }

        var action: String? = nil
        switch blocked {
        case .none: break
        case .needsAdmin: action = "Needs admin: move it to the Trash in Finder and authenticate, or `sudo rm -rf \(path)`."
        case .needsFullDiskAccess: action = "Grant Full Disk Access to DiskWise in System Settings, reopen the tool, then re-scan."
        case .sip: action = "Protected by System Integrity Protection — it cannot be removed, and should not be."
        case .readonlyVolume: action = "Lives on a read-only volume. Remove it through the app that manages it (e.g. uninstall the runtime in Xcode)."
        case .inUse: action = "Quit the app first, then it can be removed."
        case .functionalDependency: action = "Other software or the system depends on it — keep it."
        }
        if blocked == .none {
            if running {
                action = "It is running right now — quit it first if you really want it gone."
            } else if needsAdmin {
                action = "Needs admin: drag it to the Trash in Finder and authenticate, or `sudo rm -rf \"\(path)\"`."
            }
        }

        // 系统缓存必须给出可以直接粘贴的命令，而且要把「mdutil -E 不够」写进去：
        // 它就是不够——实测跑完只标记重建，47 GB 一个字节都没回来，还新写了 6 GB。
        // 只给「重建索引」四个字，用户照做会发现空间没变，然后不再信任任何建议。
        if c.kind == "system_index" {
            let measured = scan.bytes > 0 ? human(scan.bytes) : "unmeasured (needs root)"
            action = "Size now: \(measured). Measure: `sudo du -shx \"\(path)\"`. "
                + "To actually get the space back, use the full sequence — `sudo mdutil -E /` alone "
                + "only marks a rebuild and LEAVES the old index in place, so nothing is freed: "
                + "`sudo mdutil -i off / && sudo killall mds mds_stores; sudo rm -rf \"\(path)\"; "
                + "sudo mdutil -i on /`. Verify afterwards with `df -h /System/Volumes/Data`."
        } else if c.kind == "version_history" {
            action = "Measure: `sudo du -shx \"\(path)\"`. These are earlier versions of documents; "
                + "removing them frees space, but those versions are gone for good."
        }

        return UnusedItem(
            path: path, name: c.name, kind: c.kind,
            physicalBytes: scan.bytes, logicalBytes: scan.logicalBytes, files: scan.files,
            staleDays: days, staleBasis: basis.rawValue, lastActive: dateStr,
            regenerable: c.regenerable,
            recommend: verdict.rawValue, blockedReason: blocked.rawValue,
            userAction: action, why: why, restore: c.restore)
    }

    private static func totalsOf(_ items: [UnusedItem]) -> [String: Int64] {
        var t: [String: Int64] = ["safe_now_bytes": 0, "review_bytes": 0,
                                  "keep_bytes": 0, "blocked_bytes": 0, "total_bytes": 0]
        for i in items {
            t["total_bytes", default: 0] += i.physicalBytes
            switch i.recommend {
            case "safe": t["safe_now_bytes", default: 0] += i.physicalBytes
            case "review": t["review_bytes", default: 0] += i.physicalBytes
            case "blocked": t["blocked_bytes", default: 0] += i.physicalBytes
            default: t["keep_bytes", default: 0] += i.physicalBytes
            }
        }
        return t
    }

    /// 三到五条能直接照着做的话。少而具体，不要罗列。
    private static func topActions(_ items: [UnusedItem], totals: [String: Int64]) -> [String] {
        var out: [String] = []
        let safe = items.filter { $0.recommend == "safe" }
        let review = items.filter { $0.recommend == "review" }
        if !safe.isEmpty {
            let top = safe.prefix(3).map(\.name).joined(separator: ", ")
            out.append("Delete now (\(human(totals["safe_now_bytes"] ?? 0))) — nothing is lost: \(top).")
        }
        if !review.isEmpty {
            let biggest = review.prefix(3)
                .map { "\($0.name) (\(human($0.physicalBytes)), \($0.staleDays)d)" }
                .joined(separator: ", ")
            out.append("Look at these before deciding (\(human(totals["review_bytes"] ?? 0))) — they hold "
                + "data, not just caches: \(biggest).")
        }
        let blockedBytes = totals["blocked_bytes"] ?? 0
        if blockedBytes > 0 {
            let reasons = Set(items.filter { $0.recommend == "blocked" }.map(\.blockedReason))
                .sorted().joined(separator: ", ")
            out.append("\(human(blockedBytes)) cannot be removed by this tool (\(reasons)) — each item "
                + "says what a person can do instead.")
        }
        if out.isEmpty {
            out.append("Nothing looks unused beyond the thresholds. Lower min_bytes or stale_days to widen the search.")
        }
        return out
    }

    // MARK: - 小工具

    /// 整盘账里「这一块大致是什么、能不能动」的粗判。
    ///
    /// 只看名字和所在位置，零额外 IO——整盘账已经在量字节了，不该为了分类再走一遍盘。
    /// 所以这里是**粗判**：它只回答「这块值得进去看看吗」，逐条建议在 `scan()` 里。
    /// 故意不给 `safe`：按目录名断定「整个 ~/Downloads 都能删」正是最危险的那种自信。
    public static func quickView(name: String, path: String) -> (kind: String, recommend: String) {
        let lower = name.lowercased()
        if backupWords.contains(where: { lower.contains($0) }) {
            return ("backup", "review")
        }
        if path.hasPrefix("/System") || path.hasPrefix("/usr/") || path.hasPrefix("/bin")
            || path.hasPrefix("/sbin") || path == "/Library" || path.hasPrefix("/private") {
            return ("system", "keep")
        }
        if path == "/Applications" || name == "~/Applications" {
            return ("apps", "review")
        }
        if name == "~/Library" {
            return ("app_support", "review")
        }
        if name == "~/Downloads" {
            return ("downloads", "review")
        }
        if name == "~/Movies" || name == "~/Music" || name == "~/Pictures"
            || name == "~/Documents" || name == "~/Desktop" {
            return ("media_or_docs", "review")
        }
        if path.hasPrefix("/opt/") || path.hasPrefix("/usr/local/") {
            return ("developer", "review")
        }
        if path.hasPrefix("/Volumes/") {
            return ("external_volume", "keep")
        }
        if let dot = (name as NSString).lastPathComponent.firstIndex(of: "."),
           dot == (name as NSString).lastPathComponent.startIndex {
            return ("hidden_tool_data", "review")
        }
        return ("user_data", "review")
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 「上次打开」来自启动服务数据库（Spotlight 属性）。读不到就返回 nil，
    /// 让判定退回文件时间——绝不编一个日期。
    ///
    /// 为什么值得为每个应用起一个进程：这个时间**只存在于启动服务数据库里**，
    /// 文件 mtime 完全答不了「用户上次用它是哪天」——自动更新会把它刷成上周。
    /// 应用数量是几十个量级，一次几十毫秒，摊在整趟扫描里看不出来。
    private static func lastUsedDate(_ appPath: String) -> Date? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdls")
        p.arguments = ["-name", "kMDItemLastUsedDate", "-raw", appPath]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let out = String(data: data, encoding: .utf8) else { return nil }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s != "(null)" else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        if let d = f.date(from: s) { return d }
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    /// 容器自己的日期：先看目录名里的 8 位日期（20261125 / 2026-11-25），
    /// 没有再退回目录 mtime。备份目录必须用这个——里面的文件保留原始旧时间。
    private static func containerDate(_ path: String) -> Date? {
        let name = (path as NSString).lastPathComponent
        let digits = name.filter(\.isNumber)
        if digits.count >= 8 {
            // 取最早出现的 8 位：2026-11-25T03 这类也能命中
            let s = String(digits.prefix(8))
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone.current
            f.dateFormat = "yyyyMMdd"
            if let d = f.date(from: s) { return d }
        }
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
    }

    private static func isWritable(_ path: String) -> Bool {
        access(path, W_OK) == 0
    }

    private static func isReadOnlyVolume(_ path: String) -> Bool {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return false }
        return (s.f_flags & UInt32(MNT_RDONLY)) != 0
    }

    private static func isRunning(_ appPath: String) -> Bool {
        let target = URL(fileURLWithPath: appPath).standardizedFileURL.resolvingSymlinksInPath()
        return NSWorkspace.shared.runningApplications.contains { app in
            guard let u = app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
            return u.path == target.path
        }
    }

    private static func isoDay(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
