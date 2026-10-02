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
    /// 这一棵子里数到的文件个数（不含目录本身、不含符号链接和跨卷）。
    /// 展开行里那句「4 812 个文件」用它：只有字节数的话，13 GB 的缓存和 13 GB 的
    /// 一个镜像文件在界面上长得一样，而前者能一条条清、后者不能。
    public var files: Int
    /// 这一棵子里最近一次改动的时间。整个「这一页的账」和行内副标题都靠它判断
    /// 「还在用」还是「落灰」，所以量字节的那一趟必须顺手把它记下来。
    public var newest: Date?
    /// 缺「完全磁盘访问权限」的目录（errno=EPERM）
    public var needFullDiskAccess: [String]
    /// 只有管理员能读的目录（errno=EACCES）
    public var needAdmin: [String]

    public init(bytes: Int64 = 0, files: Int = 0, newest: Date? = nil,
                needFullDiskAccess: [String] = [], needAdmin: [String] = []) {
        self.bytes = bytes
        self.files = files
        self.newest = newest
        self.needFullDiskAccess = needFullDiskAccess
        self.needAdmin = needAdmin
    }

    public mutating func merge(_ other: DirScan) {
        bytes += other.bytes
        files += other.files
        if let n = other.newest { newest = max(newest ?? n, n) }
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

public func dirSizeReport(_ url: URL, progress: ScanProgress? = nil) async -> DirScan {
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
        var dFiles = 0
        var dBytes: Int64 = 0
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
            out.files += 1
            dFiles += 1
            dBytes += Int64(st.st_blocks) * 512
            let mt = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
            if out.newest == nil || mt > out.newest! { out.newest = mt }
            ticks += 1
            if ticks % 5000 == 0 && Task.isCancelled { break }
        }
        progress?.walk(files: dFiles, bytes: dBytes, in: dir)
    }
    return out
}

public func dirSize(_ url: URL) async -> Int64 {
    await dirSizeReport(url).bytes
}

/// 一处路径的三件套：占盘字节、文件个数、最近一次改动。
///
/// 各页统计一个条目时统一走这里，别再各自 `dirSize` + `fileSize` 拼——那三页最后
/// 会在展开行里要同样的数，而目录和单文件的拿法根本不同（一个要遍历，一个只要 lstat）。
public func pathStat(_ url: URL, progress: ScanProgress? = nil) async -> DirScan {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return DirScan() }
    if isDir.boolValue { return await dirSizeReport(url, progress: progress) }
    let mt: Date? = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    return DirScan(bytes: fileSize(url), files: 1, newest: mt)
}

/// 某一层的**完整拆分**：子目录 + 文件混排，按占盘降序。
///
/// 总览页「摊开下一级」与「文件夹详情」页共用这一份，只差 `includeFiles` 那一档——
/// 总览只摊目录，详情页目录和文件都要（用户钻进来恰恰是要看「这个文件夹底下的具体文件」）。
/// 同一层在两页上必须列同一批东西：两份实现只要有一处分歧，就会出现
/// 「总览里怎么点都看不见、详情页里躺着」的目录。
///
/// 文件不跑 `dirSizeReport`（那是遍历整棵子树），`lstat` 一次读 `st_blocks * 512` 就够，
/// 与 `fileSize` 同一口径。目录仍按子树递归量、并发压 6（同 `childDirSizes` 的理由：
/// 一级四十多个目录全塞进一个 TaskGroup 会跟主扫描抢线程）。
///
/// 符号链接不进名单、不跨卷——两条都跟 `dirSizeReport` 同规矩，不然共享的字节会被数两遍。
/// `total` 覆盖**全部**子项（不只是 `entries` 里列出来那些），所以页面上
/// 「列出来的几行 ＋ 尾巴那句」永远等于 `total`。
///
/// **量到 0 的目录照样进榜。** 0 在这个层级上几乎总是「读不动」，不是「不存在」：
/// `~/Library` 一级九十多个目录里就有二十多个是系统看着的，把它们按 `size > 0` 剔掉，
/// 等于从界面上抹掉用户最想进去看的那一批，逼他去访达——而下钻页的全部意义就是
/// 「系统区也让你进去看」。真的空目录进榜也无妨，它本来就是这一层的一个事实。
///
/// `fileLimit` **只掐文件**。目录是这一页的导航骨架，少一格就少一条往下走的路；
/// 文件是内容，一个几万项的目录全列出来没人滚得完，所以按占盘降序留前几条、
/// 其余并进 `unlistedCount` / `unlistedBytes`。
public func dirLevel(_ url: URL, includeFiles: Bool = true, fileLimit: Int = 200) async -> DirLevel {
    let fm = FileManager.default
    guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return DirLevel() }
    let rootDev = deviceOf(url)
    var dirs: [(name: String, path: String)] = []
    var files: [(name: String, path: String, size: Int64, newest: Date?)] = []
    for name in names where name != ".Trash" {
        let p = (url.path as NSString).appendingPathComponent(name)
        var st = stat()
        guard lstat(p, &st) == 0 else { continue }
        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK { continue }
        if let d = rootDev, st.st_dev != d { continue }
        if mode == S_IFDIR {
            dirs.append((name, p))
        } else if includeFiles {
            let size = Int64(st.st_blocks) * 512
            if size > 0 {
                let mt = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
                files.append((name, p, size, mt))
            }
        }
    }
    var out: [ChildEntry] = []
    var i = 0
    while i < dirs.count {
        if Task.isCancelled { break }
        let wave = Array(dirs[i..<min(i + 6, dirs.count)])
        i += wave.count
        await withTaskGroup(of: (String, String, Int64, Int, Date?, Bool).self) { group in
            for d in wave {
                group.addTask {
                    let report = await dirSizeReport(URL(fileURLWithPath: d.path))
                    // 权限是**跟着这一棵子树**报的：`dirSizeReport` 只在 `contentsOfDirectory`
                    // 失败且 errno 是 EPERM/EACCES 时才记，所以只要数组非空，就说明这里面
                    // 有一块我们没量到——那么这个 0 就不能当「空的」往外说。
                    let stuck = !report.needFullDiskAccess.isEmpty || !report.needAdmin.isEmpty
                    return (d.name, d.path, report.bytes, report.files, report.newest, stuck)
                }
            }
            for await (name, path, size, files, newest, stuck) in group {
                out.append(ChildEntry(path: path, name: name, size: size, isDir: true,
                                      files: files, newest: newest, unreadable: stuck))
            }
        }
    }
    for f in files {
        out.append(ChildEntry(path: f.path, name: f.name, size: f.size, isDir: false,
                              files: 1, newest: f.newest))
    }
    out.sort { $0.size > $1.size }
    let total = out.reduce(Int64(0)) { $0 + $1.size }
    // 上限只作用在文件上：目录一个都不能少。整表已经按占盘降序排好，这里顺序扫一遍、
    // 把超出上限的那些**文件**挑出去，剩下的相对次序原样不动。
    var kept: [ChildEntry] = []
    var droppedFiles: [ChildEntry] = []
    var filesKept = 0
    for e in out {
        if e.isDir { kept.append(e); continue }
        if filesKept < max(0, fileLimit) { kept.append(e); filesKept += 1 } else { droppedFiles.append(e) }
    }
    return DirLevel(entries: kept,
                    total: total,
                    unlistedCount: droppedFiles.count,
                    unlistedBytes: droppedFiles.reduce(Int64(0)) { $0 + $1.size },
                    dirCount: out.lazy.filter { $0.isDir }.count,
                    fileCount: out.lazy.filter { !$0.isDir }.count)
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

/// 环形的账：前 3 大 + 其余量到的 + 这一轮没量到的 + 本次移进废纸篓的，
/// 四块加起来正好等于整块盘的已用。
///
/// 拆成纯函数是因为这块的错法是「图看着挺满、数字全是编的」：分段一旦加起来不等于
/// 已用，环形就成了装饰而不是账本。自检不用像素、不用真盘就能把这条钉住。
public struct RingSplit {
    /// 前三名**此刻**的体积（已经扣掉被搬走的那部分）
    public var topSum: Int64
    /// 量到了、但没挤进前 3 的部分（列表封顶 20，剩下的都归这里），同样已扣
    public var restMeasured: Int64
    /// 这一轮没量到：密封系统卷、VM 卷、以及读不动的目录
    public var untouched: Int64
    /// 量完这一轮之后，被本工具搬进废纸篓、还没让位的字节。
    /// 它单列成一条弧，是因为这些人刚做过一个动作——账上看不见就等于没发生。
    public var trash: Int64

    public init(topSum: Int64 = 0, restMeasured: Int64 = 0, untouched: Int64 = 0,
                trash: Int64 = 0) {
        self.topSum = topSum
        self.restMeasured = restMeasured
        self.untouched = untouched
        self.trash = trash
    }
}

/// `covered` 是这一轮量完的合计，`topSum` 是列表前三**量到当时**的合计。顺序不成立
/// （前三比总量还大、或者盘的账比量到的还小）就返回 nil：宁可退回单块灰，
/// 也不画一张加起来不等于已用的图。
///
/// `movedOutTop` / `movedOutRest` 是量完之后被搬进废纸篓的字节，按它原本落在哪一条弧分开给。
/// 搬走不等于腾出：`used` 一个字节都没变，所以这些字节只能**在弧之间挪家**——
/// 从原来那条弧上减掉、加到「本次移入」这条弧上。「没量到」仍按 `已用 − 量到` 算：
/// 废纸篓本来就躺在已用里，量它的那一轮也认过它，再挪一次就是记两遍账。
public func ringSplit(covered: Int64, used: Int64, topSum: Int64,
                      movedOutTop: Int64 = 0, movedOutRest: Int64 = 0) -> RingSplit? {
    let outTop = max(0, movedOutTop), outRest = max(0, movedOutRest)
    guard covered > 0, used >= covered, topSum >= 0, topSum <= covered,
          outTop <= topSum, outRest <= covered - topSum else { return nil }
    let untouched = used - covered
    let top = topSum - outTop
    let rest = covered - topSum - outRest
    guard top >= 0, rest >= 0, untouched >= 0 else { return nil }
    return RingSplit(topSum: top, restMeasured: rest, untouched: untouched, trash: outTop + outRest)
}

/// 本次会话搬进废纸篓的账，按「它原本站在环形哪条弧上」归好。
public struct RingLedger {
    /// 前三名各自被搬走多少（键 = 热点的真实路径）
    public var perTop: [String: Int64] = [:]
    /// 前三名之外那些目录各自被搬走多少（含没进列表的小目录：它们也在那条弧上）
    public var perOther: [String: Int64] = [:]
    /// 归不到任何一条弧上的：源目录这轮压根没量到，那些字节本来就不在图上
    public var unattributed: Int64 = 0
    /// 被水位线作废掉的：源目录在那笔之后重新量过了，那些字节已经不在它的尺寸里，
    /// 再扣一遍就是扣两次
    public var absorbed: Int64 = 0

    public var topOut: Int64 { perTop.values.reduce(0) { $0 + $1 } }
    /// 「其他已统计」那条弧被搬走多少
    public var restOut: Int64 { perOther.values.reduce(0) { $0 + $1 } }
    /// 环形上「本次移入废纸篓」那条弧的体积
    public var trashArc: Int64 { topOut + restOut }

    /// 某个目录名下被搬走了多少——弧上、列表里那一行、尾巴那句对账要用同一个数。
    public func out(of path: String) -> Int64 { perTop[path] ?? perOther[path] ?? 0 }
}

/// 把「本次移入废纸篓」的每一笔记到它原本所在的那条弧上。
///
/// 为什么要归位而不是直接取 `store.trashedBytes`：环形上每条弧都是**这一轮量到的某个目录**，
/// 搬走一个字节就得从那条弧上减掉，否则一圈加起来就不是整块盘了。归不进去的那些
/// （源目录没被这一轮量到）**不进环形**——它们的字节本来就没在图上占地方，
/// 硬加一段就是凭空多出来一块。
///
/// 归属认**最长匹配**：`~/A` 和 `~/A/B` 都在列表时，删掉 `~/A/B/x.mov` 记在 `~/A/B` 那条弧上，
/// 不在父目录那条弧上再记一遍（父目录量到的那一轮本来就含着它）。
///
/// `voidedUpTo` 是每条弧的**水位线**：`[弧的路径: 量完它那一刻已有几笔记录]`。
/// 下标小于水位的记录作废——那一轮量出来的尺寸本来就不含搬走的字节（它们在废纸篓，
/// 而环形不量废纸篓），这笔账要还记着，就会把「~/X 剩下的 5G」画成「废纸篓的 5G」：
/// 加起来仍是整块盘，名字却全是错的。水位之上的记录照扣，因为那是量完之后又搬走的。
///
/// 为什么用「第几笔」而不是「哪些目录量过了」：记录是只往尾巴上追加的（撤销和清空
/// 都只削尾巴），所以下标就是时间顺序。用集合记「量过了」会把**量完之后**新搬走的那些
/// 一起作废掉——清完一轮再点重新扫描，环上就再也长不出废纸篓那条弧。
public func ringMoveLedger(records: [(original: String, bytes: Int64)],
                           topPaths: [String], otherPaths: [String],
                           voidedUpTo: [String: Int] = [:]) -> RingLedger {
    func standardized(_ p: String) -> String {
        URL(fileURLWithPath: p).standardizedFileURL.path
    }
    func belongs(_ item: String, _ dir: String) -> Bool {
        item == dir || item.hasPrefix(dir + "/")
    }
    // 每条记录都要跟几串路径比，所以先各标准化一次拿在手里——一趟重复文件清理能留下
    // 几百条记录，在循环里现造 URL 等于每笔账重建几百次路径。
    let tops = topPaths.map(standardized)
    let others = otherPaths.map(standardized)
    var out = RingLedger()
    for (i, r) in records.enumerated() {
        let item = standardized(r.original)
        var topAt = -1, topLen = -1, otherAt = -1, otherLen = -1
        for (j, p) in tops.enumerated() where belongs(item, p) && p.count > topLen {
            topAt = j; topLen = p.count
        }
        for (j, p) in others.enumerated() where belongs(item, p) && p.count > otherLen {
            otherAt = j; otherLen = p.count
        }
        // 归到哪条弧先定，再拿那条弧的水位判这笔作不作废——顺序反了就会拿父目录的水位
        // 去作废儿子名下那笔还活着的账。
        let owner: String?
        if topAt >= 0, topLen >= otherLen { owner = topPaths[topAt] }
        else if otherAt >= 0 { owner = otherPaths[otherAt] }
        else { owner = nil }
        if let owner {
            if i < (voidedUpTo[owner] ?? 0) {
                out.absorbed += r.bytes
            } else if topAt >= 0, topLen >= otherLen {
                out.perTop[owner, default: 0] += r.bytes
            } else {
                out.perOther[owner, default: 0] += r.bytes
            }
        } else {
            out.unattributed += r.bytes
        }
    }
    return out
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

public struct TrashRecord: Equatable {
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
    /// 指令压根没送到访达：沙盒掐住了这条发送，或访达当时不收事件。
    /// 报「访达拒绝执行」是错怪访达——它没收到过任何东西。
    case finderUnreachable(String)
    /// 访达弹了自己的确认框并且被点了「取消」——不是故障，别按失败说
    case finderCanceled(String)

    /// 交给 L() 查词表的源文案
    public var reasonKey: String {
        switch self {
        case .protected: return "系统保护路径，不能整体删除"
        case .outsideAllowed: return "超出允许范围（仅限家目录、/Applications 与 /tmp、/var/tmp）"
        case .failed: return "移入废纸篓失败"
        case .noTrashLocation: return "系统未返回废纸篓位置"
        case .noFinderScript: return "无法创建访达指令"
        case .finderRefused: return "访达拒绝执行"
        case .automationDenied: return "没有控制访达的权限"
        case .finderUnreachable: return "指令没能送到访达"
        case .finderCanceled: return "访达的确认被取消了"
        }
    }

    /// 路径或系统原话，不翻译
    public var detail: String {
        switch self {
        case .protected(let s), .outsideAllowed(let s), .failed(let s),
             .finderRefused(let s), .automationDenied(let s), .finderUnreachable(let s),
             .finderCanceled(let s): return s
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
    case -600, -609: return .finderUnreachable(detail)    // 事件压根没送到访达，不是它不肯干
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
