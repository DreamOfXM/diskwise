import Foundation

// MARK: - 类别规则（诊断转储族）
//
// 设计出处：plans/design-diagnostic-dumps-velocity-provenance-2026-10-27.md §2–3。
// 类别是「规则」不是名单：识别器按结构特征匹配，新应用自动落网；
// 与 safety_db 的逐应用条目互补——知识库答「这个已知应用有哪些已知缓存」，
// 类别规则答「这种格式的垃圾长什么样」。
//
// 识别只看结构（目录名 / 子目录 / 文件存在性），不读文件内容；
// 内容级的归属旁证（PR-3 的 ContentProbe）另挂在 CategoryRule 上，不进识别器。

/// 一个类别的行为描述。v1 只带识别与可清理面；流速快照（PR-2）、内容探针（PR-3）、
/// 保留策略（PR-4）都在这份结构上往上叠，不动识别器本身。
public struct CategoryRule {
    public let id: String
    /// 侧栏与页头显示名的 l10n key（中文原文即 key）
    public let titleKey: String
    public let matcher: StructuralMatcher
    /// 再生型：删了还会长回来，迟早要用保留策略管（PR-4）
    public let regenerable: Bool
    public let safeDeleteSpec: SafeDeleteSpec?

    public init(id: String, titleKey: String, matcher: StructuralMatcher,
                regenerable: Bool, safeDeleteSpec: SafeDeleteSpec? = nil) {
        self.id = id
        self.titleKey = titleKey
        self.matcher = matcher
        self.regenerable = regenerable
        self.safeDeleteSpec = safeDeleteSpec
    }
}

/// 结构识别器。输入候选目录，输出命中与否与目录归属。
public protocol StructuralMatcher {
    func match(_ url: URL) -> MatchResult
}

public enum MatchResult: Equatable {
    /// 命中。`host` = 目录归属（路径宿主），比如 Chrome 名下的 Crashpad 归 Chrome。
    /// 探不出宿主就给 nil，界面不冒名。
    case matched(host: String?)
    case no
}

/// 可清理面：哪些子目录的**内容**算垃圾、哪些东西必须留下。
/// 崩溃转储的约定：completed / pending / new / attachments 里的东西可清，
/// settings.dat 与目录骨架保留——引擎自管的索引文件搬走了，下次崩溃就写不进同一处。
public struct SafeDeleteSpec: Equatable {
    /// 内容可清的子目录名
    public let cleanableDirs: [String]
    /// 无条件保留的文件与子目录名
    public let keepNames: [String]

    public init(cleanableDirs: [String], keepNames: [String]) {
        self.cleanableDirs = cleanableDirs
        self.keepNames = keepNames
    }

    /// 这一条目下会被整目录移走的子目录（不存在的成员不列）。
    /// 移的是子目录而不是里面的单个 dump：16 万个文件逐个进废纸篓在系统侧就是
    /// 16 万次回收登记，子目录作单位是四笔。settings.dat 不在其中，骨架不动。
    public func cleanTargets(under root: URL) -> [URL] {
        cleanableDirs.map { root.appendingPathComponent($0, isDirectory: true) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

// MARK: - 识别器

/// Crashpad 目录：名字就叫 Crashpad，且带 settings.dat 或标准子目录之一。
/// 缺全部结构特征的同名目录**不判定**——用户自建一个叫 Crashpad 的文件夹不该被当垃圾
/// （反向用例见自检 §18）。
public struct CrashpadMatcher: StructuralMatcher {
    public init() {}

    public func match(_ url: URL) -> MatchResult {
        guard url.lastPathComponent == "Crashpad" else { return .no }
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(atPath: url.path) else { return .no }
        let hasStructure = children.contains("settings.dat")
            || ["completed", "pending", "new"].contains { children.contains($0) }
        guard hasStructure else { return .no }
        return .matched(host: Self.host(of: url))
    }

    /// 目录归属 = 路径宿主：父链上第一个 `*.app` 的包名；没有 .app 就取紧邻的上级目录名
    /// （…/Application Support/Google/Chrome/Crashpad → Chrome，…/Foo/Crashpad → Foo）。
    /// 直接顶在 Application Support 底下的没有宿主层，返回 nil。
    /// 注意这是**目录归属**；崩溃进程自己的身份（内容归属）在 .dmp 里，
    /// 靠 PR-3 的内容探针说话，这一层永远不猜。
    static public func host(of url: URL) -> String? {
        var dir = url.deletingLastPathComponent()
        let stop = dir.deletingLastPathComponent().path
        while dir.path != "/" && dir.path != stop {
            if dir.pathExtension == "app" {
                return dir.deletingPathExtension().lastPathComponent
            }
            dir = dir.deletingLastPathComponent()
        }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        guard !parentName.isEmpty, parentName != "Application Support" else { return nil }
        return parentName
    }
}

/// 一份诊断报告文件（.ips / .hang / .panic）。
/// 归属从文件名解析（macOS 命名 `进程名-日期-机器.ips`），不读内容。
public struct ReportFile: Identifiable, Equatable {
    public let url: URL
    /// 文件名里解出的进程名；解不出（名字里没有 `-`）就是 nil，界面不冒名
    public let process: String?
    public let size: Int64
    public var id: String { url.path }

    public init(url: URL) {
        self.url = url
        self.size = Self.statSize(url)
        let name = url.deletingPathExtension().lastPathComponent
        if let dash = name.firstIndex(of: "-"), dash > name.startIndex {
            let head = String(name[name.startIndex..<dash]).trimmingCharacters(in: .whitespaces)
            self.process = head.isEmpty ? nil : head
        } else {
            self.process = nil
        }
    }

    private static func statSize(_ url: URL) -> Int64 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return Int64(clamping: st.st_size)
    }
}

/// 诊断报告目录：`~/Library/Logs/DiagnosticReports` 与 `/Library/Logs/DiagnosticReports`。
/// 家目录内那份可清；`/Library` 那份在 isDeletable 白名单外，只能进观察区。
public struct DiagnosticReportsMatcher: StructuralMatcher {
    public static let reportExtensions: Set<String> = ["ips", "hang", "panic"]

    public init() {}

    public func match(_ url: URL) -> MatchResult {
        guard url.lastPathComponent == "DiagnosticReports",
              FileManager.default.fileExists(atPath: url.path) else { return .no }
        return .matched(host: nil)
    }

    /// 列出目录下的报告文件（按名字排序）。目录读不动时给空数组——
    /// 读不动 ≠ 没有报告，但 v1 不给假数。
    public func reportFiles(under root: URL) -> [ReportFile] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        return names
            .filter { Self.reportExtensions.contains((($0 as NSString).pathExtension).lowercased()) }
            .sorted()
            .map { ReportFile(url: root.appendingPathComponent($0)) }
    }
}

// MARK: - 类别目录

public extension CategoryRule {
    /// 崩溃转储（Crashpad 族）
    static let crashDumps = CategoryRule(
        id: "crash-dumps",
        titleKey: "崩溃转储",
        matcher: CrashpadMatcher(),
        regenerable: true,
        safeDeleteSpec: SafeDeleteSpec(
            cleanableDirs: ["completed", "pending", "new", "attachments"],
            keepNames: ["settings.dat"]))

    /// 系统诊断报告（.ips / .hang / .panic）
    static let diagnosticReports = CategoryRule(
        id: "diagnostic-reports",
        titleKey: "系统诊断报告",
        matcher: DiagnosticReportsMatcher(),
        regenerable: true,
        safeDeleteSpec: nil)
}

/// 诊断转储族现在认得的全部类别。
public let diagnosticCategoryRules: [CategoryRule] = [.crashDumps, .diagnosticReports]

// MARK: - 命中与观察

/// 一条命中：某类别在某位置上的一个实例。
/// `path` 是规范化后的稳定 key（PR-2 的流速快照按它对比）；路径改名即新条目，
/// v1 的简化，设计文档明示。
public struct CategoryHit: Identifiable, Equatable {
    public let ruleID: String
    public let path: String
    public let host: String?
    public var bytes: Int64
    public var files: Int
    public var newest: Date?
    /// 这一条在不在允许清理的范围（家目录 + /Applications）内。
    /// 范围外的不进删除清单，落观察区——「看见」不设门槛，「删除」才设（issue #7）。
    public let deletable: Bool
    public var id: String { path }

    public init(ruleID: String, path: String, host: String?, bytes: Int64,
                files: Int, newest: Date?, deletable: Bool) {
        self.ruleID = ruleID
        self.path = path
        self.host = host
        self.bytes = bytes
        self.files = files
        self.newest = newest
        self.deletable = deletable
    }
}

/// 观察区的原因码。词表与 agent 通道的拒绝词同源（`outside_allowed` 等），
/// 不另造同义词——同一件事在两个入口必须叫同一个名字。
public enum ObservationReason: String, CaseIterable, Equatable {
    case outsideAllowed = "outside_allowed"
    case blacklistedSystemDir = "blacklisted_system_dir"
    case unknownClass = "unknown_class"
    case appDataUnattributed = "app_data_unattributed"
}

/// 观察区的一行：能看见、动不了的东西。量不到的数给 nil，界面显示「—」，不冒充 0。
public struct ObservationItem: Identifiable, Equatable {
    public let path: String
    public let reason: ObservationReason
    public let bytes: Int64?
    public let files: Int?
    public var id: String { path + "|" + reason.rawValue }

    public init(path: String, reason: ObservationReason, bytes: Int64? = nil, files: Int? = nil) {
        self.path = path
        self.reason = reason
        self.bytes = bytes
        self.files = files
    }
}

// MARK: - 类别发现遍历

/// 一趟类别发现的结果。
public struct CategoryDiscoveryReport: Equatable {
    /// Crashpad 命中（家目录内，可清），按体积降序
    public var hits: [CategoryHit] = []
    /// ~/Library/Logs/DiagnosticReports 里的报告文件
    public var userReports: [ReportFile] = []
    /// 观察区条目（含 /Library 诊断报告、结构不完整的同名目录、系统黑名单根）
    public var observation: [ObservationItem] = []
}

/// 定向、有界的类别发现：不是全盘扫。
///
/// 范围只有三处：`~/Library/Application Support` 下深度 ≤4 找 Crashpad 结构、
/// 两个 DiagnosticReports 目录直查。深度上限罩住的是厂商层两级（Google/Chrome）加余量；
/// 再深的 Crashpad 不存在——引擎都把它写在这几层里。
///
/// 成本口径（事故复算的 161,833 文件 <3s 预算压在这条遍历上）：只 readdir/lstat 不读内容，
/// 大小走 `dirSizeReport`（st_blocks 真占盘）。
///
/// `systemReportsRoot` 与 `blacklistRoots` 默认指向真机位置；自检传入自己的假树，
/// 不碰真实 /Library。
public func discoverDiagnosticCategories(
    home: URL,
    systemReportsRoot: URL? = nil,
    blacklistRoots: [String] = ["/System", "/Library"]
) async -> CategoryDiscoveryReport {
    var out = CategoryDiscoveryReport()
    let fm = FileManager.default
    let crashRule = CategoryRule.crashDumps

    // 1) Application Support 定向找 Crashpad：命中即停（不再往 Crashpad 里下钻），
    //    其余目录按深度下钻。符号链接不跟——跟出去就出这条遍历的界了。
    let appSupport = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    var candidates: [URL] = []
    var frontier = [appSupport]
    for depth in 0..<4 {
        guard !frontier.isEmpty else { break }
        var next: [URL] = []
        for dir in frontier {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names {
                if Task.isCancelled { break }
                let u = dir.appendingPathComponent(name, isDirectory: true)
                var st = stat()
                guard lstat(u.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { continue }
                if name == "Crashpad" {
                    candidates.append(u)
                } else if depth < 3 {
                    next.append(u)
                }
            }
        }
        frontier = next
    }

    for c in candidates {
        if Task.isCancelled { break }
        if case .matched(let host) = crashRule.matcher.match(c) {
            let norm = c.standardizedFileURL.path
            let scan = await dirSizeReport(c)
            out.hits.append(CategoryHit(ruleID: crashRule.id, path: norm, host: host,
                                        bytes: scan.bytes, files: scan.files, newest: scan.newest,
                                        deletable: isDeletable(c)))
        } else {
            // 名字像但结构不完整：不判定，降级为观察项。看见不设门槛，删除才设。
            out.observation.append(ObservationItem(path: c.standardizedFileURL.path,
                                                   reason: .unknownClass))
        }
    }
    out.hits.sort { $0.bytes > $1.bytes }

    // 2) 诊断报告：家目录那份可清；/Library 那份在白名单外，整目录落观察区
    let reports = DiagnosticReportsMatcher()
    let userRoot = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    if reports.match(userRoot) != .no {
        out.userReports = reports.reportFiles(under: userRoot)
    }
    let sysRoot = systemReportsRoot ?? URL(fileURLWithPath: "/Library/Logs/DiagnosticReports",
                                           isDirectory: true)
    if reports.match(sysRoot) != .no {
        let files = reports.reportFiles(under: sysRoot)
        if !files.isEmpty {
            out.observation.append(ObservationItem(
                path: sysRoot.standardizedFileURL.path,
                reason: .outsideAllowed,
                bytes: files.reduce(0) { $0 + $1.size },
                files: files.count))
        }
    }

    // 3) 观察区的固定底账：扫描会走进、但永远动不了的系统根。
    //    这是「看见 / 删除分层」对黑名单的交代：黑名单不是消失了，是搬进了观察区。
    for root in blacklistRoots {
        out.observation.append(ObservationItem(path: root, reason: .blacklistedSystemDir))
    }

    return out
}
