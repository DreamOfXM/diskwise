import Foundation
import AppKit
import Darwin

// ── 目录占盘统计：st_blocks*512 实际占盘（删掉后真能拿回的空间）──
//
// 读不动的目录不能悄悄算成 0：一趟整盘扫描里有上百个目录是普通用户进不去的，
// 把它们吞掉之后剩下的差额会在界面上变成一块灰色「没量到的地方」，用户既不知道是谁，
// 也不知道能不能要回来。所以目录打不开时按 errno 分两类记下来——EPERM 是缺
// 「完全磁盘访问权限」（给个按钮就能要回来），EACCES 是只有管理员能读（给不了）。

public struct DirScan {
    public var bytes: Int64
    /// 缺「完全磁盘访问权限」的目录（errno=EPERM）
    public var needFullDiskAccess: [String]
    /// 只有管理员能读的目录（errno=EACCES）
    public var needAdmin: [String]

    public init(bytes: Int64 = 0, needFullDiskAccess: [String] = [], needAdmin: [String] = []) {
        self.bytes = bytes
        self.needFullDiskAccess = needFullDiskAccess
        self.needAdmin = needAdmin
    }

    public mutating func merge(_ other: DirScan) {
        bytes += other.bytes
        needFullDiskAccess.append(contentsOf: other.needFullDiskAccess)
        needAdmin.append(contentsOf: other.needAdmin)
    }
}

/// 目录能打开却读不出条目时返回 0；打不开时返回 errno。
private func probeErrno(_ path: String) -> Int32 {
    guard let d = opendir(path) else { return errno }
    closedir(d)
    return 0
}

/// 当前进程到底有没有「完全磁盘访问权限」——实测，不猜。
///
/// 哨兵挑的是「POSIX 权限本来就放行、只有 TCC 拦着」的位置：两个文件都是 0644，
/// 一个 root:wheel 在盘顶、一个在自己的家目录里。读得动就等于 FDA 已经落到这个进程上，
/// 读到 EPERM/EACCES 就等于没落。文件不存在（ENOENT）不算答案，换下一个哨兵。
///
/// 为什么不拿扫描里的 EPERM 计数当授权状态：勾是在「系统设置」里点的，macOS 要 App
/// 退出重开才把授权落到进程上，而这趟扫描很可能正是重开之前跑的。只看 EPERM 就会对着
/// 已经勾过的人说「点下面的按钮去开」——那是把人往回踢。
public func fullDiskAccessGranted() -> Bool {
    let sentinels = ["/Library/Application Support/com.apple.TCC/TCC.db",
                     (homePath() as NSString).appendingPathComponent("Library/Safari/Bookmarks.plist")]
    for path in sentinels {
        let fd = Darwin.open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        if errno != ENOENT && errno != ENOTDIR { return false }
    }
    return false
}

public func dirSizeReport(_ url: URL) async -> DirScan {
    var out = DirScan()
    var seen = Set<String>()   // 硬链接去重（dev+ino）
    var stack = [url.path]
    let fm = FileManager.default
    let rootDev = deviceOf(url)
    var ticks = 0
    while let dir = stack.popLast() {
        if Task.isCancelled { break }
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else {
            switch probeErrno(dir) {
            case EPERM: out.needFullDiskAccess.append(dir)
            case EACCES: out.needAdmin.append(dir)
            default: break        // 不存在/正在消失：不是权限问题，别报
            }
            continue
        }
        for name in items {
            if name == ".Trash" { continue }
            let p = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            if lstat(p, &st) != 0 { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK { continue }
            if mode == S_IFDIR {
                // 跨卷就停：挂载点后面可能是外置盘或备份盘，不是这块盘的账
                if let d = rootDev, st.st_dev != d { continue }
                stack.append(p)
                continue
            }
            if st.st_nlink > 1 {
                let key = "\(st.st_dev)-\(st.st_ino)"
                if seen.contains(key) { continue }
                seen.insert(key)
            }
            out.bytes += Int64(st.st_blocks) * 512
            ticks += 1
            if ticks % 5000 == 0 && Task.isCancelled { break }
        }
    }
    return out
}

public func dirSize(_ url: URL) async -> Int64 {
    await dirSizeReport(url).bytes
}

/// 一个目录的下一级，按占盘从大到小取前 `limit` 个。环形上「其他已统计」那一块
/// 要能一路摊到名字，靠的就是这个：点开一格才量它的一级子目录，不预先递归整棵树，
/// 也不跨卷。符号链接不进名单（跟 `dirSizeReport` 同一条规矩，不然共享的字节会被数两遍）。
///
/// 并发掐在 6：~/Library 一级就有四十多个目录，全塞进一个 TaskGroup 会跟主扫描
/// 抢同一批工作线程，结果是两边一起变慢。
public func childDirSizes(_ url: URL, limit: Int = 12) async -> [(name: String, path: String, size: Int64)] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(atPath: url.path) else { return [] }
    let rootDev = deviceOf(url)
    var dirs: [(name: String, url: URL)] = []
    for name in items where name != ".Trash" {
        let p = (url.path as NSString).appendingPathComponent(name)
        var st = stat()
        guard lstat(p, &st) == 0 else { continue }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { continue }
        if let d = rootDev, st.st_dev != d { continue }
        dirs.append((name, URL(fileURLWithPath: p)))
    }
    var out: [(name: String, path: String, size: Int64)] = []
    var i = 0
    while i < dirs.count {
        if Task.isCancelled { break }
        let wave = Array(dirs[i..<min(i + 6, dirs.count)])
        i += wave.count
        await withTaskGroup(of: (String, String, Int64).self) { group in
            for d in wave {
                group.addTask { (d.name, d.url.path, await dirSizeReport(d.url).bytes) }
            }
            for await (name, path, size) in group where size > 0 {
                out.append((name, path, size))
            }
        }
    }
    out.sort { $0.size > $1.size }
    return Array(out.prefix(max(1, limit)))
}

/// 单个文件占盘
public func fileSize(_ url: URL) -> Int64 {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return 0 }
    return Int64(st.st_blocks) * 512
}

// ── 通配展开：支持 * 与 [...]（微信/QQ/钉钉这类按账号存放的路径用）──

public func globExpand(_ pattern: String) -> [URL] {
    let expanded = expandHome(pattern)
    if !expanded.contains("*") && !expanded.contains("?") && !expanded.contains("[") {
        let u = URL(fileURLWithPath: expanded)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) {
            return [u]
        }
        return []
    }
    // 逐段展开：把含通配的段用 fnmatch 匹配
    var current = ["/"]
    let stripped = expanded.hasPrefix("/") ? String(expanded.dropFirst()) : expanded
    for seg in stripped.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
        if seg.isEmpty { continue }
        if seg.contains("*") || seg.contains("?") || seg.contains("[") {
            var next: [String] = []
            for base in current {
                let kids = (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? []
                for k in kids where fnmatch(seg, k, 0) == 0 {
                    next.append((base as NSString).appendingPathComponent(k))
                }
            }
            current = next
        } else {
            current = current.map { ($0 as NSString).appendingPathComponent(seg) }
        }
        if current.isEmpty { break }
    }
    return current.compactMap { p -> URL? in
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: p)
    }
}

// ── 知识库加载（bundle 内 safety_db.json，缺失则返回空——调用方显示内置兜底）──

public func loadSafetyEntries(from url: URL?) -> [SafetyEntry] {
    guard let url = url,
          let data = try? Data(contentsOf: url),
          let db = try? JSONDecoder().decode(SafetyDB.self, from: data) else {
        return []
    }
    return db.entries
}

// ── 磁盘用量 ──

public struct VolumeUsage {
    public var total: Int64
    /// 真空着的（statfs）。倒完废纸篓涨的就是这个数。
    public var free: Int64
    /// 系统记作「可用」、但此刻还占着盘的那部分：本地快照、缓存、日志一类。
    /// 拿不到系统估算时为 0，那时 available 退化成 free，界面跟没这块账时一模一样。
    public var purgeable: Int64

    public init(total: Int64, free: Int64, purgeable: Int64 = 0) {
        self.total = total
        self.free = free
        self.purgeable = max(0, purgeable)
    }

    /// 「可用」——跟系统设置 ▸ 通用 ▸ 储存空间、访达简介、关于本机同一个数。
    public var available: Int64 { free + purgeable }
    /// 「已用」——同上口径，等于总量减上面那个可用。
    public var used: Int64 { total - available }
    /// 物理占用。卷账（diskutil 每个卷的 CapacityInUse）只对得上这个数，
    /// 因为可清除那部分此刻确实在盘上占着格子。
    public var usedPhysical: Int64 { total - free }
}

/// 演示盘容量：`DISKWISE_DEMO_USAGE=<总GB>:<可用GB>`（十进制，跟界面显示同口径）。
///
/// 只在假家目录生效，而且**假家目录一定有值**：没给就用兜底数。
/// 早先没给就直接读真盘，于是截图脚本少带一个变量时，界面上会画出
/// 「一棵几十 G 的假树 + 一台真机的已用总量」，没量到的那一块虚高到几百 G——
/// 看着像工具扫不到，其实是两本不同的账被记在了一张图上。
private func demoVolume() -> VolumeUsage? {
    guard homeIsDemo else { return nil }
    // 兜底数就是 make_demo_home.sh 那棵树配套的那一档：可量到约 64 GB、已用 80 GB，
    // 覆盖八成，跟真机上整盘范围的实测同一量级。故意不取大容量——演示树只有几十 G，
    // 配一块 500G 的假盘，环形上「没量到的地方」会占掉八成，那是把演示拍成事故现场。
    var total = 96.0, free = 16.0
    let parts = (ProcessInfo.processInfo.environment["DISKWISE_DEMO_USAGE"] ?? "")
        .split(separator: ":")
    if parts.count == 2, let t = Double(parts[0]), let f = Double(parts[1]), t > f, f >= 0 {
        total = t
        free = f
    }
    return VolumeUsage(total: Int64(total * Double(GB)), free: Int64(free * Double(GB)))
}

public func volumeUsage() -> VolumeUsage? {
    if let demo = demoVolume() { return demo }
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
          let total = attrs[.systemSize] as? Int64,
          let free = attrs[.systemFreeSize] as? Int64 else {
        return nil
    }
    let important = systemAvailable() ?? free
    return VolumeUsage(total: total, free: free, purgeable: important - free)
}

/// 系统界面那个「可用」从哪来：访达宗卷简介、关于本机、系统设置的储存空间页
/// 读的都是 `volumeAvailableCapacityForImportantUsage`，它把可清除空间也算成可用，
/// 所以比 statfs 的物理空闲大出一截。
///
/// 我们跟着它，不是因为准，而是因为**它是用户手里唯一的对照物**：差 10 GB 就永远
/// 有人来问「你是不是在编数」，而这工具卖的就是数字可信。差额不藏——单列一块
/// 「系统可清除」，既跟系统对得上，也没说那 10 GB 是真空着。
/// 这个键取不到（沙盒、非 APFS、字段变更）时返回 nil，界面退回物理口径，不编数。
private func systemAvailable() -> Int64? {
    let values = try? URL(fileURLWithPath: "/")
        .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    guard let bytes = values?.volumeAvailableCapacityForImportantUsage, bytes > 0 else { return nil }
    return bytes
}

/// 整块盘的账按 APFS 卷拆开。
///
/// 环形上那块「没量到的地方」不能只是一坨灰：它是几种完全不同的东西——你自己还没扫到的
/// 文件、只读封存的系统卷、虚拟内存与休眠镜像、引导与恢复分区。第一种能要回来，
/// 后三种任何清理工具都删不动，揉在一块等于什么都没说。
///
/// 数据源是 `diskutil apfs list -plist`，不是 `df`：卷的账要按角色点齐，而恢复卷
/// 平时根本不挂载，`df` 的表里没有它——用 df 拆出来的「启动与恢复分区」会少了 1.3 GB
/// 的恢复卷，那 1.3 GB 只能掉进残差，界面上就成了名字和数字对不上。
/// statfs 更不行：一台 APFS 机器上几个卷共用一个空间池，`attributesOfFileSystem`
/// 和裸 statfs 对每个挂载点都回同一份容器数（实测 500 GB 的机器五个卷全报
/// 494.4 / 24.3 GB），连数据卷和 VM 卷都分不开。
public struct VolumeSplit {
    /// 用户数据卷：扫描能覆盖的就是这一块
    public var dataVolume: Int64
    /// 只读密封的系统卷（SIP）
    public var sealedSystem: Int64
    /// 交换文件与休眠镜像所在的 VM 卷
    public var virtualMemory: Int64
    /// Preboot / Recovery / Update：引导和恢复，含没挂载的卷
    public var bootAndRecovery: Int64
    /// 整块盘已用减去容器里所有卷：APFS 容器自己的元数据与共享空间
    public var unattributed: Int64

    public init(dataVolume: Int64 = 0, sealedSystem: Int64 = 0, virtualMemory: Int64 = 0,
                bootAndRecovery: Int64 = 0, unattributed: Int64 = 0) {
        self.dataVolume = dataVolume
        self.sealedSystem = sealedSystem
        self.virtualMemory = virtualMemory
        self.bootAndRecovery = bootAndRecovery
        self.unattributed = unattributed
    }
}

/// 从 `diskutil apfs list` 的 plist 里按角色拆账。纯函数，自检直接喂一张假表。
/// 认不出引导容器（非 APFS、字段变了）时返回 nil，让界面退回整块盘一个数。
public func volumeSplit(apfsPlist plist: [String: Any], diskUsed: Int64) -> VolumeSplit? {
    guard let containers = plist["Containers"] as? [[String: Any]] else { return nil }
    // 一台机器可能有好几个 APFS 容器：外置盘、iOS 模拟器镜像各占一个。
    // 引导容器 = 同时带 System 和 Data 角色的那一个，别的容器不进这块盘的账。
    func roles(_ v: [String: Any]) -> [String] { v["Roles"] as? [String] ?? [] }
    func volumes(_ c: [String: Any]) -> [[String: Any]] { c["Volumes"] as? [[String: Any]] ?? [] }
    guard let boot = containers.first(where: { c in
        let r = volumes(c).flatMap(roles)
        return r.contains("System") && r.contains("Data")
    }) else { return nil }

    var out = VolumeSplit()
    var everyVolumeInBootContainer: Int64 = 0
    for v in volumes(boot) {
        let bytes = (v["CapacityInUse"] as? NSNumber)?.int64Value ?? 0
        everyVolumeInBootContainer += bytes
        switch roles(v).first {
        case "Data":     out.dataVolume += bytes
        case "System":   out.sealedSystem += bytes
        case "VM":       out.virtualMemory += bytes
        case "Preboot", "Recovery", "Update": out.bootAndRecovery += bytes
        default: break   // 别的角色（xarts、iSCPreboot 之类）留在残差里
        }
    }
    guard out.dataVolume > 0 else { return nil }
    // 残差只可能是容器元数据与取整的差。负数说明 diskutil 的卷账比容器数还大
    // （两边各自取整），夹成 0，别让界面画出一行负数。
    out.unattributed = max(0, diskUsed - everyVolumeInBootContainer)
    return out
}

/// 跑一次 `diskutil apfs list -plist` 拿卷账。演示模式一定返回 nil：假家目录那棵树
/// 配的是编造的盘容量，掺进真机的卷账就是把两本账记在一张图上。
/// 沙盒里能不能起这个进程还没实测过，所以失败只当「拆不出」，界面退回一行总数。
public func volumeSplit(diskUsed: Int64) -> VolumeSplit? {
    guard !homeIsDemo else { return nil }
    guard let out = runTool("/usr/sbin/diskutil", ["apfs", "list", "-plist"]),
          let data = out.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [],
                                                                  format: nil) as? [String: Any]
    else { return nil }
    return volumeSplit(apfsPlist: plist, diskUsed: diskUsed)
}

/// 环形的账：前 3 大 + 其余量到的 + 这一轮没量到的，三块加起来正好是已用。
///
/// 拆成纯函数是因为这块的错法是「图看着挺满、数字全是编的」：分段一旦加起来不等于
/// 已用，环形就成了装饰而不是账本。自检不用像素、不用真盘就能把这条钉住。
public struct RingSplit {
    public var topSum: Int64
    /// 量到了、但没挤进前 3 的部分（列表封顶 20，剩下的都归这里）
    public var restMeasured: Int64
    /// 这一轮没量到：密封系统卷、VM 卷、以及读不动的目录
    public var untouched: Int64

    public init(topSum: Int64 = 0, restMeasured: Int64 = 0, untouched: Int64 = 0) {
        self.topSum = topSum
        self.restMeasured = restMeasured
        self.untouched = untouched
    }
}

/// `covered` 是这一轮量完的合计，`topSum` 是列表前三。顺序不成立（前三比总量还大、
/// 或者盘的账比量到的还小）就返回 nil：宁可退回单块灰，也不画一张加起来不等于已用的图。
public func ringSplit(covered: Int64, used: Int64, topSum: Int64) -> RingSplit? {
    guard covered > 0, used >= covered, topSum >= 0, topSum <= covered else { return nil }
    return RingSplit(topSum: topSum, restMeasured: covered - topSum, untouched: used - covered)
}

/// 起一个系统自带的小工具并收 stdout。失败回 nil，不抛。
private func runTool(_ path: String, _ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

// ── 移入废纸篓 + 撤销（只进废纸篓是铁律：全 App 唯一删除路径）──

public struct TrashRecord {
    public var original: URL
    public var inTrash: URL
    public var size: Int64
    public var displayName: String

    public init(original: URL, inTrash: URL, size: Int64, displayName: String) {
        self.original = original
        self.inTrash = inTrash
        self.size = size
        self.displayName = displayName
    }
}

/// 删除失败的原因。Core 只给「原因标识 + 现场数据」，句子由界面拼——
/// 后端吐文案是双语化的头号障碍。
public enum TrashError: Error {
    case protected(String)
    case outsideAllowed(String)
    case failed(String)
    case noTrashLocation
    case noFinderScript
    case finderRefused(String)
    /// 系统没放行本工具指挥访达（自动化权限），跟「访达自己不肯干」是两回事
    case automationDenied(String)
    /// 访达弹了自己的确认框并且被点了「取消」——不是故障，别按失败说
    case finderCanceled(String)

    /// 交给 L() 查词表的源文案
    public var reasonKey: String {
        switch self {
        case .protected: return "系统保护路径，不能整体删除"
        case .outsideAllowed: return "超出允许范围（仅限家目录与 /Applications）"
        case .failed: return "移入废纸篓失败"
        case .noTrashLocation: return "系统未返回废纸篓位置"
        case .noFinderScript: return "无法创建访达指令"
        case .finderRefused: return "访达拒绝执行"
        case .automationDenied: return "没有控制访达的权限"
        case .finderCanceled: return "访达的确认被取消了"
        }
    }

    /// 路径或系统原话，不翻译
    public var detail: String {
        switch self {
        case .protected(let s), .outsideAllowed(let s), .failed(let s),
             .finderRefused(let s), .automationDenied(let s), .finderCanceled(let s): return s
        case .noTrashLocation, .noFinderScript: return ""
        }
    }
}

public func trashItem(_ url: URL) throws -> URL {
    guard !isProtected(url) else { throw TrashError.protected(url.path) }
    guard isDeletable(url) else { throw TrashError.outsideAllowed(url.path) }
    var out: NSURL?
    do {
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
    } catch {
        throw TrashError.failed(error.localizedDescription)
    }
    guard let t = out as URL? else { throw TrashError.noTrashLocation }
    return t
}

public func untrash(_ record: TrashRecord) throws {
    let fm = FileManager.default
    var dst = record.original
    // 原位置已有同名：加后缀，绝不覆盖
    if fm.fileExists(atPath: dst.path) {
        let ext = dst.pathExtension
        let base = dst.deletingPathExtension().lastPathComponent
        var k = 1
        repeat {
            let name = ext.isEmpty ? "\(base) (\(k))" : "\(base) (\(k)).\(ext)"
            dst = record.original.deletingLastPathComponent().appendingPathComponent(name)
            k += 1
        } while fm.fileExists(atPath: dst.path)
    }
    try fm.moveItem(at: record.inTrash, to: dst)
}

// ── 废纸篓：大小 + 在访达中打开 + 交给访达清空 ──

/// 废纸篓概况：条目数 + 实际占盘（文件夹连内部一起算，口径同访达）。
/// `nil` = 读不到（商店沙盒禁止访问 ~/.Trash，与「空的」是两回事）
public func trashInfo() async -> (items: Int, bytes: Int64)? {
    let trash = homeDir().appendingPathComponent(".Trash")
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(
        at: trash, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
        return nil
    }
    var total: Int64 = 0
    for u in items {
        if Task.isCancelled { return nil }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
        total += isDir.boolValue ? await dirSize(u) : fileSize(u)
    }
    return (items.count, total)
}

public func openTrashInFinder() {
    NSWorkspace.shared.open(homeDir().appendingPathComponent(".Trash"))
}

/// 访达的回执 → 失败原因。错误号才是分诊依据：-1743（没放行自动化）和「访达自己
/// 不肯干」的下一步完全不同，所以不能只抄 errorMessage 让用户去猜。
/// 单独拆成函数是因为真跑一次要么真清空废纸篓、要么动系统权限，都不该进自检。
public func finderError(number: Int, message: String) -> TrashError {
    let detail = message.isEmpty ? "AppleScript 错误 \(number)" : "\(message)（错误 \(number)）"
    switch number {
    case -1743, -1744: return .automationDenied(detail)   // 事件没被 TCC 放行
    case -128: return .finderCanceled(detail)             // 访达自己的确认框被点了取消
    default: return .finderRefused(detail)
    }
}

/// 清空废纸篓交给访达执行（系统层面再确认一次；首次需授权自动化）
public func emptyTrashViaFinder() throws {
    let src = "tell application \"Finder\" to empty the trash"
    guard let script = NSAppleScript(source: src) else {
        throw TrashError.noFinderScript
    }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    guard let e = err else { return }
    throw finderError(number: (e[NSAppleScript.errorNumber as String] as? Int) ?? 0,
                      message: (e[NSAppleScript.errorMessage as String] as? String) ?? "")
}
