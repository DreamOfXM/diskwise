import Foundation

// ── 安全知识库（safety_db.json，与 Python 版同源，可互相同步）──

public struct SafetyEntry: Decodable {
    public var name: String
    public var what: String
    public var whatif: String
    public var rec: String
    public var path: String
    public var level: String          // safe | warn
    public var grp: String?
    public var docs: String?

    private enum CodingKeys: String, CodingKey {
        case name, what, whatif, rec, path, level, grp, docs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        what = try c.decode(String.self, forKey: .what)
        whatif = try c.decode(String.self, forKey: .whatif)
        rec = try c.decode(String.self, forKey: .rec)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        level = (try? c.decode(String.self, forKey: .level)) ?? "safe"
        grp = try? c.decode(String.self, forKey: .grp)
        docs = try? c.decode(String.self, forKey: .docs)
    }
}

public struct SafetyDB: Decodable {
    public var entries: [SafetyEntry]
}

// ── 家目录：定义在 HomeAccess.swift（沙盒下要走真实家目录 + 授权书签）──

public func homePath() -> String { homeDir().path }

/// 家目录是否被换到演示用的假树上（见 build_app/make_demo_home.sh）
public var homeIsDemo: Bool {
    !(ProcessInfo.processInfo.environment["DISKWISE_HOME_SHIM"] ?? "").isEmpty
}

/// 装 App 的目录。演示模式下跟着搬进假树：真 /Applications 有几十万个文件，
/// 扫得慢，还会把作者装了哪些 App 晒进 README。
public func applicationsDir() -> String {
    homeIsDemo ? homePath() + "/Applications" : "/Applications"
}

// ── 路径可移植展开：~ / $HOME / /Users/<别人>/ 一律落到当前用户家目录 ──

public func expandHome(_ raw: String) -> String {
    let home = homePath()
    var s = raw
    if s.hasPrefix("~") {
        s = home + s.dropFirst()
    }
    if s.contains("$HOME") || s.contains("${HOME}") {
        s = s.replacingOccurrences(of: "${HOME}", with: home)
        s = s.replacingOccurrences(of: "$HOME", with: home)
    }
    if s.hasPrefix("/Users/") {
        let rest = s.dropFirst("/Users/".count)
        if let slash = rest.firstIndex(of: "/") {
            s = home + rest[slash...]
        }
    }
    return s
}

// ── 缓存条目（UI 模型）──

public struct CacheItem: Identifiable {
    public let id = UUID()
    public var entry: SafetyEntry
    public var resolvedPaths: [URL] = []
    public var size: Int64? = nil      // nil = 统计中
    public var selected = false

    public init(entry: SafetyEntry, resolvedPaths: [URL] = [], size: Int64? = nil, selected: Bool = false) {
        self.entry = entry
        self.resolvedPaths = resolvedPaths
        self.size = size
        self.selected = selected
    }

    /// 分组标识，不是文案——排序认它，界面显示前才查词表
    public var groupKey: String { entry.grp ?? "general" }
    public var isSafe: Bool { entry.level != "warn" }
}

// ── 容量格式化：十进制（1 GB = 10⁹ B），与访达「显示简介」、「关于本机」、diskutil 同口径 ──
//
// 曾经按 1024 进制算数却写着 GB：同一块 494.4 GB 的盘报成 460.4 GB，比系统界面少 7%。
// 用户拿我们的数跟「关于本机」对，对不上就是工具的错——数字可以小，单位不能错。

public func human(_ bytes: Int64) -> String {
    if bytes < 1000 { return "\(bytes) B" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var v = Double(bytes) / 1000.0
    var u = 0
    while v >= 1000 && u < units.count - 1 {
        v /= 1000
        u += 1
    }
    return String(format: "%.1f %@", v, units[u])
}

/// 十进制单位常量：界面上所有「多少 GB」的阈值都用它，别再手写 1024 的三次方。
public let kB: Int64 = 1_000
public let MB: Int64 = 1_000 * kB
public let GB: Int64 = 1_000 * MB
public let TB: Int64 = 1_000 * GB

// ── 受保护路径：整体不允许移入废纸篓（里面的子项可以）──

public func protectedPaths() -> Set<String> {
    let home = homePath()
    let subs = ["", "/Library", "/Documents", "/Desktop", "/Downloads",
                "/Pictures", "/Movies", "/Music", "/Applications",
                "/Public", "/.Trash"]
    var set = Set(subs.map { home + $0 })
    set.insert("/")
    set.formUnion(["/Applications", "/System", "/Library", "/usr",
                   "/bin", "/sbin", "/etc", "/var", "/opt"])
    return set
}

public func isProtected(_ url: URL) -> Bool {
    let p = url.standardizedFileURL.path
    return protectedPaths().contains(p)
}

/// 我们能动手的范围：家目录与 /Applications（演示模式下后者在假树里）。
///
/// 整盘扫描会把系统区的大文件也摆上列表——那是账，不是活儿：那些位置要么只有管理员写得动，
/// 要么是 Homebrew / Xcode 自己的地盘，它们的清理命令比这个按钮靠谱。所以这类行只展示、
/// 勾选框锁死；删除路径仍然只有 trashItem 这一条。
public func isDeletable(_ url: URL) -> Bool {
    let p = url.standardizedFileURL.path
    let home = homePath()
    let apps = applicationsDir()
    return p == home || p.hasPrefix(home + "/") || p == apps || p.hasPrefix(apps + "/")
}
