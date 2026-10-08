import Foundation

// ── 安全知识库（safety_db.json，与 Python 版同源，可互相同步）──

public struct SafetyEntry: Decodable {
    public var name: String
    public var what: String
    public var whatif: String
    public var rec: String
    public var path: String
    public var level: String          // safe | warn
    /// 这一条**删了要付什么代价**。只在 `warn` 上写，`safe` 一律没有：
    ///
    /// - `redo`：原始数据不丢，重新下载或重装就能回来（模型权重、依赖仓库、模拟器运行镜像）
    /// - `data`：删了就没了，重下也回不来（模拟器里的 App 数据、聊天里的图片、会话记录）
    ///
    /// 分这一刀，是因为 `warn` 底下混着这两种性质完全不同的东西：一个只要花时间重下，
    /// 一个真要丢东西。混进同一档，用户既不敢删那些其实能删的，
    /// 也没意识到另一些更该先看一眼——两头都错。
    ///
    /// **漏写按 `data` 兜底**：宁可把「重下」说重，不能把「丢数据」说轻。缺了它的条目
    /// 由自检顶出来，不会就这么混过去。
    public var cost: String?
    public var grp: String?
    public var docs: String?
    /// 归属 App 的包名。只给「路径里查不出包名、但确实属于某个 App」的条目用
    /// （`~/Library/Developer/Xcode/**` 这类），行首那一格靠它挂 App 图标。
    /// 商店版签名带 team 前缀的 App（钉钉那种）不填——对不上就不对，宁可不挂。
    public var app: String?
    /// 跨分组的横向标签（如 ai_models）：grp 是缓存页的展示分组，tags 是
    /// 「同一类东西跨 grp 归拢」的查询口径，CLI/MCP 的 --category 按它筛。
    /// 旧条目没有它，解码按缺省处理，不影响已有知识库。
    public var tags: [String]?
    /// 官方品牌标的文件名（不带扩展名）。
    ///
    /// 给那些**没有 .app 可查**的工具：`~/.ollama/models`、`~/.cache/uv` 这类只有命令行，
    /// LaunchServices 里查不到包名，真图标那一档永远取不到东西。填了 `app` 的条目也可以填这里：
    /// 真图标优先，但「Xcode 已卸载、模拟器还留着」这种机器上就轮到标上岗，比一张通用文件夹认得出。
    public var icon: String?

    private enum CodingKeys: String, CodingKey {
        case name, what, whatif, rec, path, level, cost, grp, docs, app, icon, tags
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        what = try c.decode(String.self, forKey: .what)
        whatif = try c.decode(String.self, forKey: .whatif)
        rec = try c.decode(String.self, forKey: .rec)
        path = (try? c.decode(String.self, forKey: .path)) ?? ""
        level = (try? c.decode(String.self, forKey: .level)) ?? "safe"
        cost = try? c.decode(String.self, forKey: .cost)
        grp = try? c.decode(String.self, forKey: .grp)
        docs = try? c.decode(String.self, forKey: .docs)
        app = try? c.decode(String.self, forKey: .app)
        icon = try? c.decode(String.self, forKey: .icon)
        tags = try? c.decode([String].self, forKey: .tags)
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

/// 商店产品页取图模式。演示横幅是给挑图的人防身用的（真拿假账当实测数字汇报），
/// 而真实用户永远不会去设 `DISKWISE_HOME_SHIM`，也就永远看不到它——所以出商店图时
/// 把它收起来，让画面回到用户实际会看到的样子。README 截图和日常使用不受影响。
public var storeShotMode: Bool {
    ProcessInfo.processInfo.environment["DISKWISE_STORE_SHOTS"] == "1"
}

/// 界面上要不要自报「这一屏是演示数据」。
public var demoDisclosed: Bool { homeIsDemo && !storeShotMode }

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

/// 一条路径的面包屑：**该路径自己的每一级**，每一格都是一个能点回去的真实祖先。
///
/// **不含盘顶 `/`**：界面上最左那一格固定是「空间总览」——那是这一页的来处，而整盘的账
/// 本来就是空间总览那一页在做，再单列一格 `/` 等于把同一件事说第二遍；更要紧的是它把
/// 「上一级」引到一页没什么可干的空账上（那页全是「本工具不碰」，一个字节也清不动）。
///
/// 也不从「包含它的那条扫描根」起头：`/Library`、`/Applications` 本身就是扫描根，
/// 以根为起点的话那些地方只剩孤零零一格，上面全不见——而人恰恰是在「进太深了、
/// 想退出去」的时候才看这一条。
///
/// 家目录那两段（`Users` ＋ 自己）并成一格 `~`：全 App 都把它写成 `~`，
/// 拆成两格只是把同一个意思写两遍。
public func crumbChain(for path: String, home: String = homePath()) -> [String] {
    let std = URL(fileURLWithPath: path).standardizedFileURL.path
    let homeStd = URL(fileURLWithPath: home).standardizedFileURL.path
    let me = (homeStd as NSString).lastPathComponent
    var out: [String] = []
    var cur = ""
    for part in std.split(separator: "/").map(String.init) {
        if cur == "/Users", part == me {
            // 刚补上的 `/Users` 撤掉：它跟 `~` 指的是同一处。
            out.removeLast()
            cur = homeStd
        } else {
            cur += "/" + part
        }
        out.append(cur)
    }
    return out
}

/// 下钻页「上一级」的落点：上一层目录。`nil` = 已经到顶，再往上是面包屑最左那格「空间总览」。
///
/// 盘顶 `/` **不算一站**：从 `/Applications`、`/Library` 这类顶层目录往上退，落点直接是
/// 空间总览，而不是 `/`。理由与 `crumbChain` 同一条——整盘的账是空间总览那一页在做，
/// 而 `/` 那份报告一个字节也清不动。
public func drillParent(of path: String) -> String? {
    guard !path.isEmpty else { return nil }
    let up = (path as NSString).deletingLastPathComponent
    // `up.isEmpty` 是给相对路径留的：只有一段的那种退出来是空的，同样当到顶，
    // 不能让调用方拿一个空串去当下一站。
    if up.isEmpty || up == path || up == "/" { return nil }
    return up
}

// ── 缓存条目（UI 模型）──

public struct CacheItem: Identifiable {
    public let id = UUID()
    public var entry: SafetyEntry
    public var resolvedPaths: [URL] = []
    public var size: Int64? = nil      // nil = 统计中
    /// 每条解析路径各自的体积。`size` 是它们的和，够缓存页那一行用，但不够总览用：
    /// 总览要把这一条拆到环形不同的弧上去归账，只能拿到「一共 3.7 GB」就归不了。
    public var pathSizes: [String: Int64] = [:]
    /// 这一条目下的文件个数与最近一次改动，给展开行用。
    ///
    /// 只有字节数的那一版，13 GB 的一堆缓存和 13 GB 的单个镜像在界面上长得一样，
    /// 而前者可以一条条判、后者不能。个数和日期是「这一处到底装着什么」的另外两条信息。
    public var files: Int = 0
    public var newest: Date? = nil
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

private let hUnits = ["KB", "MB", "GB", "TB", "PB"]
private let hScales: [Int64] = [kB, MB, GB, TB, 1_000 * TB]

/// 这个数该用哪个单位印：跟 `human()` 走的是同一条台阶，两处必须一起动。
private func hUnitIndex(_ v: Int64) -> Int {
    var u = 0
    while u < hUnits.count - 1 && v >= 1000 * hScales[u] { u += 1 }
    return u
}

/// `parts` 是不是真能被收成「加得起来的一列」：有东西、没有负数、而且逐字节加起来
/// 正好等于 `total`。最后这条是命门——不等就说明调用方给的不是同一个集合，
/// 那时候补差数就是编数。
private func partsAddUp(_ parts: [Int64], _ total: Int64) -> Bool {
    total > 0 && parts.contains(where: { $0 > 0 })
        && parts.allSatisfy { $0 >= 0 } && parts.reduce(Int64(0), +) == total
}

/// 最大余数法：每行先向下取到 0.1 个单位，再把缺的那几格按余数从大到小补回去。
/// 每行仍与真值差不到 0.1 个单位，这一列却加得起来。调用方先过 `partsAddUp`。
private func apportionTenths(_ parts: [Int64], _ total: Int64, unit u: Int) -> [String] {
    let div = Double(hScales[u]) / 10.0          // 一格 = 0.1 个单位
    let exact = parts.map { Double($0) / div }
    var cells = exact.map { Int($0.rounded(.down)) }
    let short = Int((Double(total) / div).rounded()) - cells.reduce(0, +)
    if short > 0 {
        let order = exact.indices.sorted { a, b in
            let ra = exact[a] - Double(cells[a]), rb = exact[b] - Double(cells[b])
            return ra == rb ? a < b : ra > rb
        }
        for i in order.prefix(short) { cells[i] += 1 }
    }
    let suffix = " " + hUnits[u]
    return cells.map { String(format: "%.1f%@", Double($0) / 10.0, suffix) }
}

/// 一组「加起来必须等于总数」的字节，收成同一单位、一位小数，而且**印出来的这几行
/// 相加正好等于印出来的那个总数**。
///
/// 为什么不能各自 `human()`：每行独立四舍五入会各自往上飘。实拍过一屏
/// 「12.0 + 6.3 + 4.2 = 22.5」而圆心写着 22.4——同一屏两本账，用户第一个抓的就是这个。
///
/// 三种情况整体退回逐行 `human()`——宁可各说各的，也不许凑出一个数：
/// 1. 各行之和不等于 `total`：调用方给的不是同一个集合，补差数就是编数；
/// 2. 有任何一行落在别的单位（总数是 GB、这行显示成 MB）：那一列本来就不能相加；
/// 3. 一行都没有。
public func addableHuman(_ parts: [Int64], total: Int64) -> [String] {
    let plain = parts.map(human)
    guard partsAddUp(parts, total) else { return plain }
    let u = hUnitIndex(total)
    let suffix = " " + hUnits[u]
    guard parts.allSatisfy({ $0 == 0 || human($0).hasSuffix(suffix) }) else { return plain }
    return apportionTenths(parts, total, unit: u)
}

/// 跟 `addableHuman` 同一件事，但**整列强行统一到总数那个单位**：那一列允许某一行
/// 落在 MB（因为它本来就不相加），这一列不行——屏幕上明写着「各段之和」，
/// 那就得真加得起来，而里面混着一行 501.6 MB 时 `addableHuman` 会整列退回逐行四舍五入，
/// 2026-09-25 真机实拍到的正是这个：那一列印出来加成 494.5，右边写着 494.4。
///
/// 被分摊到 0 格的那一行（有地方、却不到一个最小刻度）印 `< 0.1`：它确实占着盘，
/// 印成 `0.0` 等于让这一行从这一列里消失，用户按行数就加不回来了。
/// 只在「各行根本不是同一笔账」时整体退回逐行 `human()`（见 `partsAddUp`）。
public func addableHumanColumn(_ parts: [Int64], total: Int64) -> [String] {
    addableHumanColumn(parts, total: total, inRulerOf: total)
}

/// 同上，但那一列的**单位由屏幕上另一个数定**。
///
/// 废纸篓的操作记录就是一个例子：列里最大一条只有 20 MB，右上角那张「本次移入」却按
/// 整个废纸篓的体量印成 GB。各选各的单位，同一屏就是两把尺；给这一列传进去的
/// `ruler` 就是那张卡用的那个数，于是列加起来的和**正好等于卡上那串字**。
public func addableHumanColumn(_ parts: [Int64], total: Int64, inRulerOf ruler: Int64) -> [String] {
    let plain = parts.map(human)
    guard partsAddUp(parts, total) else { return plain }
    let u = hUnitIndex(max(1, ruler))
    let out = apportionTenths(parts, total, unit: u)
    let zero = "0.0 " + hUnits[u]
    return zip(parts, out).map { byte, shown in
        byte > 0 && shown == zero ? belowTickle(u) : shown
    }
}

private let hUnitScale: [String: Double] = ["B": 1, "KB": 1e3, "MB": 1e6,
                                            "GB": 1e9, "TB": 1e12, "PB": 1e15]

/// 一串 `human()` 印出来的字背后的字节数；认不出来（不是「数字 空格 单位」）返回 nil。
private func shownBytes(_ s: String) -> Int64? {
    let p = s.split(separator: " ")
    guard p.count == 2, let v = Double(p[0]), let sc = hUnitScale[String(p[1])]
    else { return nil }
    return Int64((v * sc).rounded())
}

/// 把屏幕上**已经印出来的那几串数**加起来，印成它们的和；认不出任何一串时返回 nil。
///
/// 为什么不拿字节相加再四舍五入：2026-09-25 圆心实拍那一屏印的是「可用 14.2」
/// 「可回收 18.6」「全部清空后可用 32.7」——真值各自偏低（14.1x ＋ 18.5x = 32.7x），
/// 字节加法一步没错，错在那三个**印出来的数**加不起来。人核对的是屏幕上那三串字，
/// 差的那 0.1 要记在「每一项都各自四舍五入过」上，不能记在两个口径上。
public func sumShown(_ shown: [String]) -> String? {
    var t = Int64(0)
    for s in shown {
        guard let b = shownBytes(s) else { return nil }
        t += b
    }
    return human(t)
}

/// 同上，减法版：「整块盘 494.4 − 可用 14.2」印出来的「已用」必须是 480.2，
/// 而不是各拿字节四舍五入之后凑出来的那个数（两者可以差 0.1）。
public func diffShown(_ whole: String, _ part: String) -> String? {
    guard let a = shownBytes(whole), let b = shownBytes(part), a >= b else { return nil }
    return human(a - b)
}

/// 会被印成 `0.0` 的那个阈值：不到半个最小刻度。
private func roundsToZero(_ v: Int64, unit u: Int) -> Bool {
    Double(v) < Double(hScales[u]) * 0.05
}

/// 一行有地方、却不到这一列的最小刻度时印成什么。
///
/// 不能印 `0.0`：那一行当场从这一列里消失了，用户按行数加不回来，而且「0.0 GB」
/// 读起来像「这里没量到」。`< 0.1` 说的是同一件事，但它承认自己占着地方。
private func belowTickle(_ u: Int) -> String { "< 0.1 " + hUnits[u] }

/// 一个数按第 `u` 档单位印：正好为 0 印 `0.0`（那是真没有），
/// 有地方却不到最小刻度印 `< 0.1`，其余一位小数。
private func printAt(_ v: Int64, unit u: Int) -> String {
    let suffix = " " + hUnits[u]
    if v == 0 { return String(format: "0.0%@", suffix) }
    if roundsToZero(v, unit: u) { return belowTickle(u) }
    return String(format: "%.1f%@", Double(v) / Double(hScales[u]), suffix)
}

/// 一组数**印成同一个单位**、各留一位小数，但**不做分摊**。
///
/// 用它的地方是那些「这一组不是加得起来的账」的场合：Docker 的镜像明细已经算在
/// 上面那段「· 合计」里，废纸篓两块卡的「本次移入」也躺在「现在」那个数里面。
/// 它们不能相加，但并排印的时候必须同一把尺——25.7 GB 挨着 501.6 MB，两行就没法比大小。
public func unifiedHuman(_ values: [Int64]) -> [String] {
    let u = hUnitIndex(values.max() ?? 0)
    return values.map { printAt($0, unit: u) }
}

/// 单个数按「总数为 `total` 的那一列」同一把尺印出来。
///
/// 底部清理条那句「已选 X」跟上面那一列是同一个量的两种口径：一列全是 GB 而底下冒出
/// 一个 400.0 MB，读的人得先心算一次才能知道自己选的是这页的大头还是零头。
/// 单位的台阶取 `total` 那个（跟 `addableHumanColumn` 同一句 `hUnitIndex`），
/// 所以传进来的 `total` 就是上面那一列的合计。
public func human(_ bytes: Int64, inRulerOf total: Int64) -> String {
    printAt(max(0, bytes), unit: hUnitIndex(max(1, total)))
}

// ── 受保护路径：整体不允许移入废纸篓（里面的子项可以）──

/// 允许动手的共享临时区（连同它们在 `/private` 下的真身，见 `isDeletable`）。
///
/// 列在这里是为了让「这两个目录本身不许搬」有个单一出处：`protectedPaths` 收它们，
/// 而 `isDeletable` 只认**底下**的项。
let sharedTempRoots = ["/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]

public func protectedPaths() -> Set<String> {
    let home = homePath()
    let subs = ["", "/Library", "/Documents", "/Desktop", "/Downloads",
                "/Pictures", "/Movies", "/Music", "/Applications",
                "/Public", "/.Trash"]
    var set = Set(subs.map { home + $0 })
    set.insert("/")
    set.formUnion(["/Applications", "/System", "/Library", "/usr",
                   "/bin", "/sbin", "/etc", "/var", "/opt"])
    // 临时区里**里面的东西**能动，但这两个目录本身搬走等于把整个系统的临时空间端掉
    set.formUnion(sharedTempRoots)
    return set
}

public func isProtected(_ url: URL) -> Bool {
    let p = url.standardizedFileURL.path
    return protectedPaths().contains(p)
}

/// 我们能动手的范围：家目录、/Applications（演示模式下它在假树里），以及两个共享临时区。
///
/// 整盘扫描会把系统区的大文件也摆上列表——那是账，不是活儿：那些位置要么只有管理员写得动，
/// 要么是 Homebrew / Xcode 自己的地盘，它们的清理命令比这个按钮靠谱。所以这类行只展示、
/// 勾选框锁死；删除路径仍然只有 `trashItem` 这一条。
///
/// `/tmp` 与 `/var/tmp` 是**家目录之外唯一两处放行的地方**：它们名字里就写着「临时」——
/// 正是用来放随时可以丢掉的东西的。而整盘扫描会走进 `/private`，把这两处底下的东西
/// （构建残留、演示树、解压到一半的包，动辄几十 G）原样列出来；不给删的话，
/// 用户只能看着本工具报一个自己动不了的数。
///
/// 两个细节：
/// - 只认**底下**的项。`/tmp` 本身不许删（那等于端掉整个系统的临时空间），
///   所以这里比的是 `root + "/"` 前缀，`p == root` 落不进来；`protectedPaths` 再兜一道。
/// - `/tmp` 与 `/var/tmp` 都是指向 `/private` 的符号链接，而 `standardizedFileURL`
///   **不解析软链**——同一个位置会以 `/tmp/x` 和 `/private/tmp/x` 两种写法同时出现
///   （从 `/` 钻进去走前者，整盘扫 `/private` 走后者）。少认一种，同一份东西换个入口
///   就会一会儿能删、一会儿不能删。
public func isDeletable(_ url: URL) -> Bool {
    let p = url.standardizedFileURL.path
    let home = homePath()
    let apps = applicationsDir()
    if p == home || p.hasPrefix(home + "/") { return true }
    if p == apps || p.hasPrefix(apps + "/") { return true }
    return sharedTempRoots.contains { p.hasPrefix($0 + "/") }
}

/// 这一处**整块**能不能搬进废纸篓：`isDeletable` 说「这个位置归本工具管」，
/// `isProtected` 说「这一处整块不许动」，两道都得过。
///
/// 判据必须跟 `trashItem` 走同一条，否则界面上会开出空头支票：`~/Library` 在家目录里，
/// 只查 `isDeletable` 那一行就标成「能删」，而真点下去 `trashItem` 是拒绝的。
/// 环形上那道「点我，能收走」的亮沿读的正是这条，标错一次那一格就是骗人点击。
public func isReclaimableWhole(_ url: URL) -> Bool {
    isDeletable(url) && !isProtected(url)
}

// ── 环形那本「可回收」账的目标集 ──
//
// 环形只认整段可搬，实测一台机器上就报成「96 GB 里 6.3 GB 动得了」，而同一 App 的
// 缓存页能清 22 GB。招牌画面那个数是产品的承诺，少报三倍跟报错了没区别。
// 所以可回收量必须落到**具体一处一处**的目标上，而不是「这一整段」。

/// 一个点名能搬走的东西：路径 + 它此刻占着多少。
public struct ReclaimTarget: Equatable, Hashable {
    public let path: String
    public let size: Int64

    public init(path: String, size: Int64) {
        self.path = path
        self.size = size
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

/// 「其余」这个桶的归账键：不属于任何一条具名弧的可回收处都归到它下面。
///
/// 它住 Core 而不是界面里，是因为它和 `reclaimBucket` 是一对约定——自检要能钉住
/// 「回 nil 的那些最终去了哪儿」，而 SelfTest 只依赖 Core、摸不到 App target。
/// 用一个不可能当路径的串：真目录永远不会撞上它。
public let reclaimRestKey = "__rest__"

/// 收成互不嵌套的一组：父项已经计入，就不该再把子项加第二遍。
///
/// 知识库的条目本来就互相套着（`~/Library/Caches` 与它下面的 `~/Library/Caches/Homebrew`
/// 是同一段字节）。缓存页靠「未勾选就不加总」躲开这件事，环形要加总，只能先去嵌套。
public func dropNested(_ paths: [String]) -> [String] {
    let sorted = Set(paths).sorted()
    return sorted.filter { p in
        !sorted.contains { q in
            q != p && (p == q || p.hasPrefix(q + "/"))
        }
    }
}

/// 一批路径**实际**占了多少字节：互相套着的只留最外面那个。
///
/// 每个 `bytes` 都是那条路径整棵子树的量，父的数本来就含着子，把子再加一遍就是数两遍。
/// 所以先去嵌套、再只加留下来的那几个。缓存页的全选合计走这里，
/// 别按条目自己的 `size` 相加——`~/Library/Caches` 和它下面的 `Caches/Home` 是同一段字节。
public func contentsUnionSize(_ sizes: [(path: String, bytes: Int64)]) -> Int64 {
    let byPath = Dictionary(sizes.map { ($0.path, $0.bytes) }, uniquingKeysWith: { a, _ in a })
    return dropNested(Array(byPath.keys)).reduce(Int64(0)) { $0 + (byPath[$1] ?? 0) }
}

// ── 一层里的一个子项：子目录或文件（文件夹下钻页用）──

/// 下钻页某一行的身份。跟缓存页那些「解释条目」不同，这里没有知识库、没有四元组解释——
/// 它只是「这个目录底下有这么个东西，占这么多」。判「动不动得了」靠 `isDeletable`，
/// 不靠知识库白名单：这一页列的是**任意**一层，绝大多数位置本来就不在知识库里。
public struct ChildEntry: Identifiable, Hashable {
    public let path: String
    public let name: String
    public let size: Int64
    /// 目录能继续钻，文件不能——这一格决定行尾给不给「进入」。
    public let isDir: Bool
    /// 这一棵子里的文件个数（文件行恒为 1）。光有字节数的话，10 GB 的一堆碎缓存和
    /// 10 GB 的单个镜像在界面上长得一样，而前者能一条条判、后者不能。
    public let files: Int
    /// 最近一次改动。`nil` = 没读到（权限、或路上全失败）。
    public let newest: Date?
    /// 这棵子树里有没有读不动的目录（errno 是 EPERM/EACCES）。
    ///
    /// 为真时 `size` 只是**读得动的那部分**，不是它真实占盘。界面上得把两种情形分开：
    /// `size == 0` 是整棵读不动，那个 0 一个字都不能信，不能写成 `0 B`；
    /// `size > 0` 是只缺了一块，数字照给，但得说明它是个下限。
    public let unreadable: Bool

    public var id: String { path }
    public var url: URL { URL(fileURLWithPath: path) }

    public init(path: String, name: String, size: Int64, isDir: Bool,
                files: Int = 0, newest: Date? = nil, unreadable: Bool = false) {
        self.path = path
        self.name = name
        self.size = size
        self.isDir = isDir
        self.files = files
        self.newest = newest
        self.unreadable = unreadable
    }
}

/// 一个目录**这一层**的完整拆分。
///
/// `entries` 是逐行列出来的那几行（目录与文件混排、按占盘降序），`total` 是这一层
/// **全部**子项的合计。两者之差就是尾巴那句「另有 N 项，合计 X」——所以列表里那几行
/// 加上尾巴那句，正好等于 `total`，这一屏的账加得起来。
///
/// 全应用只此一份「下一级」的实现：总览页摊开一行、文件夹详情页列一层，都走同一个
/// `dirLevel`（后者多要文件那一档）。两套之间只要差一格，同一台机器上点开同一层
/// 就会看见两份不一样的名单。
public struct DirLevel {
    public var entries: [ChildEntry]
    public var total: Int64
    public var unlistedCount: Int
    public var unlistedBytes: Int64
    public var dirCount: Int
    public var fileCount: Int

    public init(entries: [ChildEntry] = [], total: Int64 = 0, unlistedCount: Int = 0,
                unlistedBytes: Int64 = 0, dirCount: Int = 0, fileCount: Int = 0) {
        self.entries = entries
        self.total = total
        self.unlistedCount = unlistedCount
        self.unlistedBytes = unlistedBytes
        self.dirCount = dirCount
        self.fileCount = fileCount
    }
}

/// 一批桶路径里谁离得最近算谁的：给 `path` 找**最长**的那个祖先前缀。
///
/// 用最长而不是第一个，是因为环形同时有 `~/Library` 和 `~/Library/Developer` 这样的父子桶，
/// 归到父桶会让子桶那一段被计两次。
public func reclaimBucket(of path: String, in buckets: [String]) -> String? {
    var best: String? = nil
    for b in buckets where path == b || path.hasPrefix(b + "/") {
        if best == nil || b.count > best!.count { best = b }
    }
    return best
}
