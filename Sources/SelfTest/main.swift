import DiskCleanerCore
import Foundation

// 自检：知识库 / 路径展开 / 通配 / 移废纸篓+撤销 / 保护规则 / 占盘统计。
// 全部在 /tmp 里做，不碰用户数据。任一失败打印 FAIL 并以非零退出。
var failures = 0

func check(_ cond: Bool, _ msg: String) {
    if cond {
        print("PASS  \(msg)")
    } else {
        print("FAIL  \(msg)")
        failures += 1
    }
}

// 1. 知识库（swift run 时 cwd 就是包根目录；直跑二进制时找 exe 旁边）
let _cands = [
    "Sources/DiskCleaner/Resources/safety_db.json",
    URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        .appendingPathComponent("safety_db.json").path,
]
let _dbURL = _cands.compactMap { p -> URL? in
    FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
}.first
let entries = loadSafetyEntries(from: _dbURL)
check(entries.count > 20, "知识库条目 \(entries.count) > 20")
check(entries.contains { $0.name == "npm 缓存" }, "知识库含 npm 缓存")

// 2. 路径可移植展开（用 homePath() 而不是 NSHomeDirectory()：沙盒会改写后者）
let home = homePath()
check(expandHome("~/.npm") == home + "/.npm", "展开 ~")
check(expandHome("$HOME/.npm") == home + "/.npm", "展开 $HOME")
check(expandHome("/Users/别人/Library/Caches") == home + "/Library/Caches", "改写别人的 /Users 前缀")
check(expandHome("/Applications/X.app") == "/Applications/X.app", "系统路径不动")

// 2.2 沙盒家目录层（回归：Foundation 的家目录在沙盒里指向 App 容器，
//     拿它当扫描根不报错，只会扫一个空壳然后报「你机器上几乎没东西」）
check(!HomeAccess.runsSandboxed, "自检跑在非沙盒环境")
check(!HomeAccess.needsGrant, "非沙盒不该拦授权")
check(!realHomeDir().path.contains("/Library/Containers/"), "真实家目录没被改写成容器路径")
check(homeDir() == realHomeDir(), "未授权时 homeDir 落回真实家目录，不是容器")
// 范围只剩一档、且由「扫不扫得动」决定：沙盒里整盘扫不动，就不能拿它当默认，
// 而非沙盒只看用户区等于把大半块盘排除在承诺之外。界面上没有这个开关了。
check(ScanScope.effective == .disk, "非沙盒走整盘：界面上没有开关，默认就得是能扫到的那一档")
check(!HomeAccess.runsSandboxed || ScanScope.effective == .user,
      "沙盒下不把「整盘」当默认（点了也扫不动）")
setenv("DISKWISE_HOME_SHIM", "/tmp/diskwise-selftest-home", 1)
check(homeDir().path == "/tmp/diskwise-selftest-home", "假家目录开关仍然优先")
unsetenv("DISKWISE_HOME_SHIM")
check(!HomeAccess.grant(URL(fileURLWithPath: "/tmp/diskwise-没有这个目录-\(getpid())")),
      "指向不存在的目录不能算授权成功")
// 注：「没经授权面板就不该拿到访问权」这条在非沙盒里量不出来——
// startAccessingSecurityScopedResource() 对没进沙盒的进程永远返回 true。

// 2.5 容量格式化：十进制，跟访达「显示简介」和「关于本机」同口径
// （回归：以前按 1024 算数却标 GB，同一块盘比系统界面少报 7%，494.4 GB 显示成 460.4 GB）
check(human(500) == "500 B", "500 B")
check(human(1500) == "1.5 KB", "1500 → 1.5 KB")
check(human(6_200_000_000) == "6.2 GB", "6.2e9 → 6.2 GB 而不是 TB")
check(human(2 * 1024 * 1024) == "2.1 MB", "2MiB → 2.1 MB（十进制）")
check(human(494_384_795_648) == "494.4 GB", "500GB 盘按系统口径显示 494.4 GB")

// 2.6 演示盘容量：假家目录一定自带容量。少带 DISKWISE_DEMO_USAGE 时读真盘，
// 会把「一棵演示树 + 一台真机的已用」画进同一个环形——那数字看着就是工具扫不动盘。
// 兜底数还必须跟 make_demo_home.sh 那棵树相配：已用 80 GB，量得到约 64 GB。
setenv("DISKWISE_HOME_SHIM", "/tmp/diskwise-selftest-home", 1)
unsetenv("DISKWISE_DEMO_USAGE")
check(volumeUsage()?.total == 96 * GB, "假家目录没带钉容量时用兜底数，不读真盘")
check(volumeUsage()?.used == 80 * GB, "兜底容量的已用只有 80 GB：演示树撑得起，没量到的那块不会虚高成几百 G")
setenv("DISKWISE_DEMO_USAGE", "128:12", 1)
check(volumeUsage()?.free == 12 * GB, "DISKWISE_DEMO_USAGE 按十进制生效")
unsetenv("DISKWISE_HOME_SHIM")
unsetenv("DISKWISE_DEMO_USAGE")

// 3. 通配展开（临时目录里建两个账号目录）
let fm = FileManager.default
let gbase = fm.temporaryDirectory.appendingPathComponent("dctest-\(UUID().uuidString)")
let ga = gbase.appendingPathComponent("acc1_data")
let gb = gbase.appendingPathComponent("acc2_data")
try! fm.createDirectory(at: ga, withIntermediateDirectories: true)
try! fm.createDirectory(at: gb, withIntermediateDirectories: true)
let hits = Set(globExpand(gbase.path + "/*_data").map { $0.path })
check(hits == Set([ga.path, gb.path]), "通配 * 命中两个目录")
check(globExpand(gbase.path + "/nope-*").isEmpty, "不存在的通配返回空（UI 不显示）")
try? fm.removeItem(at: gbase)

// 4. 保护规则
check(isProtected(URL(fileURLWithPath: home)), "家目录本体受保护")
check(isProtected(URL(fileURLWithPath: home + "/Library")), "~/Library 受保护")
check(!isProtected(URL(fileURLWithPath: home + "/Library/Caches/pip")), "缓存子目录可操作")
do {
    _ = try trashItem(URL(fileURLWithPath: home + "/Documents"))
    check(false, "整体删 Documents 应被拦")
} catch let e as TrashError {
    check(e.reasonKey == "系统保护路径，不能整体删除", "整体删 Documents 被拦：\(e.reasonKey)")
} catch {
    check(false, "整体删 Documents 被拦：\(error.localizedDescription)")
}

// 4b. 可删范围：整盘扫描会把系统区摆上列表，但那些位置不是这个按钮的活儿
check(isDeletable(homeDir().appendingPathComponent("Documents/x.iso")), "家目录里的文件可删")
check(isDeletable(URL(fileURLWithPath: applicationsDir()).appendingPathComponent("Foo.app")),
      "装 App 的目录可删")
check(!isDeletable(URL(fileURLWithPath: "/Library/Developer/Xcode/DerivedData")), "系统区不可删")
check(!isDeletable(URL(fileURLWithPath: "/opt/homebrew/lib/libfoo.dylib")), "Homebrew 目录不可删")
do {
    _ = try trashItem(URL(fileURLWithPath: "/Library/Caches"))
    check(false, "删系统区应被拦")
} catch let e as TrashError {
    check(e.reasonKey == "超出允许范围（仅限家目录与 /Applications）",
          "系统区被拦：\(e.reasonKey)")
}

// 4c. 扫描范围根：用户区 = 家目录 + /Applications；整盘再加系统白名单，
//     但绝不爬密封系统卷与挂载点（那会把外置盘和时间机器备份盘算进我们的账）
let userRoots = scanRoots(scope: .user)
check(userRoots.contains(homeDir()), "用户区根含家目录")
check(userRoots.contains(URL(fileURLWithPath: applicationsDir(), isDirectory: true)),
      "用户区根含 /Applications（总览页算它，扫描页不能漏）")
let diskRoots = scanRoots(scope: .disk)
check(diskRoots.first == homeDir(), "整盘根的第一项仍是家目录")
check(diskRoots.count > userRoots.count, "整盘根比用户区多（实得 \(diskRoots.count) 项）")
check(!diskRoots.contains { $0.path == "/System" || $0.path == "/Volumes"
                              || $0.path.hasPrefix("/Volumes/") },
      "整盘根不含密封系统卷与挂载点")
check(diskRoots.filter { $0.path == homeDir().path }.count == 1, "整盘根不把家目录算两遍")
// 数据卷自己那层 /System/Volumes/Data/System 必须算：18.9 GB 的 AssetsV2 住在里面，
// 漏了它「整盘」就凭空少 5%，而那 5% 会被读成「盘上有东西我们扫不动」。
func isDirAt(_ url: URL) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
}
let dataSystem = URL(fileURLWithPath: "/System/Volumes/Data/System", isDirectory: true)
if !homeIsDemo, isDirAt(dataSystem) {
    check(diskRoots.contains(dataSystem), "整盘根含数据卷那层 System（AssetsV2 在这里）")
}
// 别人的家目录也要算进整盘——它是盘上真实占着的地方
if !homeIsDemo {
    let others = ((try? FileManager.default.contentsOfDirectory(atPath: "/Users")) ?? [])
        .map { URL(fileURLWithPath: "/Users/\($0)", isDirectory: true).standardizedFileURL }
        .filter { isDirAt($0) && $0.path != homeDir().path
            && !$0.lastPathComponent.hasPrefix(".") }
    check(others.allSatisfy { diskRoots.contains($0) },
          "整盘根含其他用户的家目录（\(others.map(\.lastPathComponent).joined(separator: "、"))）")
}
check(Set(diskRoots.map { $0.path }).count == diskRoots.count, "整盘根没有重复项")

// 4d. 卷账拆分：环形的「没量到的地方」要按 APFS 卷点名，数据源是 diskutil 的按卷清单
//     （statfs 对每个卷都回同一份容器数；df 的表里没有平时不挂载的恢复卷）
let apfsPlist: [String: Any] = [
    "Containers": [
        ["APFSContainerUUID": "BOOT", "Volumes": [
            ["DeviceIdentifier": "disk3s1", "Roles": ["System"], "CapacityInUse": 12_639_088_640],
            ["DeviceIdentifier": "disk3s2", "Roles": ["Preboot"], "CapacityInUse": 9_033_097_216],
            ["DeviceIdentifier": "disk3s3", "Roles": ["Recovery"], "CapacityInUse": 1_284_472_832],
            ["DeviceIdentifier": "disk3s5", "Roles": ["Data"], "CapacityInUse": 424_415_780_864],
            ["DeviceIdentifier": "disk3s6", "Roles": ["VM"], "CapacityInUse": 22_550_147_072],
        ]],
        // 另一个容器（iOS 模拟器镜像那种）：不是这块盘的账
        ["APFSContainerUUID": "OTHER", "Volumes": [
            ["DeviceIdentifier": "disk10s1", "Roles": [String](), "CapacityInUse": 17_571_344_384],
        ]],
    ]
]
let apfsUsed: Int64 = 470_091_194_368
if let split = volumeSplit(apfsPlist: apfsPlist, diskUsed: apfsUsed) {
    check(split.dataVolume == 424_415_780_864, "数据卷按卷算，不是容器数")
    check(split.sealedSystem == 12_639_088_640, "只读系统卷单列")
    check(split.virtualMemory == 22_550_147_072, "VM 卷单列")
    // 回归：恢复卷平时不挂载，按挂载点拆账就会漏掉它，界面上「启动与恢复分区」
    // 这个名字就跟数字对不上了。
    check(split.bootAndRecovery == 9_033_097_216 + 1_284_472_832,
          "引导分区那一行含未挂载的恢复卷")
    check(split.unattributed == 168_607_744, "残差 = 整盘已用 − 容器里每一个卷")
    check(split.dataVolume + split.sealedSystem + split.virtualMemory
            + split.bootAndRecovery + split.unattributed == apfsUsed,
          "五块加起来正好等于已用总量，环形才不会算歪")
} else {
    check(false, "卷账该拆出来")
}
// 认不出引导容器（非 APFS、字段改名）时必须退回 nil，不能让界面拿 0 当账
check(volumeSplit(apfsPlist: ["Containers": [["Volumes": [["Roles": ["Data"],
                                                           "CapacityInUse": 1]]]]],
                  diskUsed: 1) == nil, "没有系统卷就不认引导容器")
// 真机跑一次：能拆的话点名的卷不能超过物理占用，拆不出（演示模式）就退回整块盘一个数
if let u = volumeUsage(), let real = volumeSplit(diskUsed: u.usedPhysical) {
    check(real.dataVolume + real.sealedSystem + real.virtualMemory + real.bootAndRecovery
            <= u.usedPhysical, "真机卷账各块加起来不超过物理占用 \(human(u.usedPhysical))")
    check(real.dataVolume > 0 && real.sealedSystem > 0 && real.bootAndRecovery > 0,
          "真机卷账点到了名（数据卷 + 系统卷 + 引导恢复）")
} else {
    check(homeIsDemo, "非演示模式该能拆卷账")
}

// 4e. 容量口径：界面上的「可用 / 已用」必须跟系统设置那一屏是同一个数
if let u = volumeUsage() {
    check(u.available == u.free + u.purgeable, "可用 = 空闲 + 系统可清除")
    check(u.used + u.available == u.total, "已用 + 可用 = 总容量，环形才不会画歪")
    check(u.usedPhysical == u.used + u.purgeable, "物理占用 = 已用 + 可清除（可清除此刻还占着盘）")
    check(u.purgeable >= 0, "可清除不为负")
    // 演示树不许掺真机的可清除账：假树配的是编造的容量，掺进来就是两本账记一张图
    if homeIsDemo { check(u.purgeable == 0, "演示盘没有可清除这块") }
}

// 4f. 环形分段：这张图唯一的信用来源是「加起来正好等于已用」，而且「其他已统计」
//     必须能被下面的列表逐段加出来——所以它只能等于「这一轮量到的 − 前三」，
//     不许掺第二本账。（以前这里按用户区/整盘两档拆弧、列表按整盘列，同一屏两个口径，
//     有人对着 134.7 GB 把列表加了三遍加不出来，从此不信这屏的数。）
let ringCovered: Int64 = 297_000_000_000
let ringUsed: Int64 = 374_500_000_000
if let r = ringSplit(covered: ringCovered, used: ringUsed, topSum: 100_000_000_000) {
    check(r.topSum + r.restMeasured + r.untouched == ringUsed, "环形三段加起来等于已用")
    check(r.topSum + r.restMeasured == ringCovered, "前三＋其他已统计 = 这一轮量到的，列表才摊得开")
    check(r.restMeasured == 197_000_000_000, "量到但没进前三的归「其他已统计」")
    check(r.untouched == 77_500_000_000, "没量到的剩下多少就说多少")
} else {
    check(false, "量完一轮后环形该拆得开")
}
// 拿不准就不拆：宁可含糊，不可画出一张加起来不等于已用的图
check(ringSplit(covered: 0, used: 400_000_000_000, topSum: 0) == nil, "还没量完一轮时不拆")
check(ringSplit(covered: 500_000_000_000, used: 400_000_000_000, topSum: 0) == nil,
      "量到的比整块盘的已用还多时不拆")
check(ringSplit(covered: 60_000_000_000, used: 400_000_000_000, topSum: 80_000_000_000) == nil,
      "前三名比整趟量到的还大时不拆")

// 5. 移废纸篓 + 撤销（/tmp 文件，来回一遍再清掉）
let src = fm.temporaryDirectory.appendingPathComponent("trashme-\(UUID().uuidString).txt")
try! "hello".write(to: src, atomically: true, encoding: .utf8)
var out: NSURL?
try! fm.trashItem(at: src, resultingItemURL: &out)
check(!fm.fileExists(atPath: src.path), "移入废纸篓后原位置消失")
let rec = TrashRecord(original: src, inTrash: out! as URL, size: 5, displayName: src.lastPathComponent)
try! untrash(rec)
check(fm.fileExists(atPath: src.path), "撤销后文件回来")
try? fm.removeItem(at: src)

// 6. 占盘统计：2MB 文件 + 1 个符号链接（链接不重复计）+ 一个进不去的目录要交代
let sbase = fm.temporaryDirectory.appendingPathComponent("sizetest-\(UUID().uuidString)")
try! fm.createDirectory(at: sbase, withIntermediateDirectories: true)
let big = sbase.appendingPathComponent("big.bin")
try! Data(count: 2 * 1024 * 1024).write(to: big)
try! fm.createSymbolicLink(at: sbase.appendingPathComponent("link.bin"), withDestinationURL: big)
let locked = sbase.appendingPathComponent("locked")
try! fm.createDirectory(at: locked, withIntermediateDirectories: true)
chmod(locked.path, mode_t(0))
let sem = DispatchSemaphore(value: 0)
Task {
    let r = await dirSizeReport(sbase)
    check(r.bytes >= 2 * 1024 * 1024 && r.bytes < 3 * 1024 * 1024,
          "占盘约 2MB（得 \(r.bytes)，链接未重复计）")
    check(r.needAdmin.contains(locked.path),
          "读不动的目录按 EACCES 记成「只有管理员能读」，不是悄悄算成 0")
    check(r.needFullDiskAccess.isEmpty, "没缺 FDA 时不该报缺权限")
    chmod(locked.path, mode_t(0o755))
    try? fm.removeItem(at: sbase)
    sem.signal()
}
sem.wait()

// 7. 通用遍历 + 重复检测：两个相同文件 + 一个不同文件
let dbase = fm.temporaryDirectory.appendingPathComponent("duptest-\(UUID().uuidString)")
try! fm.createDirectory(at: dbase, withIntermediateDirectories: true)
try! Data("same-content".utf8).write(to: dbase.appendingPathComponent("a.txt"))
try! Data("same-content".utf8).write(to: dbase.appendingPathComponent("b.txt"))
try! Data("different!!".utf8).write(to: dbase.appendingPathComponent("c.txt"))
try! fm.createDirectory(at: dbase.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! Data("nested-file!".utf8).write(to: dbase.appendingPathComponent("sub/d.txt"))
let sem2 = DispatchSemaphore(value: 0)
Task {
    let r = await walkFiles(dirs: [dbase])
    check(r.rows.count == 4 && r.matched == 4, "遍历到 4 个文件")
    let gs = findDupGroups(r.rows)
    check(gs.count == 1 && gs[0].files.count == 2, "检出 1 组重复（a/b），c、d 不在其中")
    let capped = await walkFiles(dirs: [dbase], top: 2)
    check(capped.rows.count == 2 && capped.matched == 4, "top 2 只留两条，命中总数仍是 4")
    // 根套根（演示树里整盘根全落在假家目录底下）：同一份文件只能算一次
    let nested = await walkFiles(dirs: [dbase, dbase.appendingPathComponent("sub")])
    check(nested.rows.count == 4, "嵌套根不重复计数（实得 \(nested.rows.count) 条）")
    check(Set(nested.rows.map { $0.url.path }).count == nested.rows.count, "嵌套根交出来的路径不重复")
    try? fm.removeItem(at: dbase)
    sem2.signal()
}
sem2.wait()

// 8. 总览行内摊开下一级：点开一行报的是这一层的子目录，界面上还要拿
//    「父行那一格 − 摊出来的这几格」报剩下的量，所以子层之和不能超过父行，
//    而且同一份字节不能因为一个符号链接就被数第二遍。
let cbase = fm.temporaryDirectory.appendingPathComponent("kidtest-\(UUID().uuidString)")
for (n, mb) in [("small", 1), ("mid", 2), ("big", 3)] {
    let d = cbase.appendingPathComponent(n)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    try! Data(count: mb * 1024 * 1024).write(to: d.appendingPathComponent("f.bin"))
}
try! fm.createSymbolicLink(atPath: cbase.appendingPathComponent("linkdir").path,
                           withDestinationPath: cbase.appendingPathComponent("big").path)
let sem3 = DispatchSemaphore(value: 0)
Task {
    let kids = await childDirSizes(cbase, limit: 2)
    check(kids.map(\.name) == ["big", "mid"], "下一级按占盘从大到小排并掐到上限（得 \(kids.map(\.name))）")
    check(kids.allSatisfy { $0.size > 0 }, "摊出来的每一格都得有自己的数")
    check(!kids.contains { $0.name == "linkdir" },
          "指向目录的符号链接不摊成第二格")
    let parent = await dirSize(cbase)
    let sum = kids.reduce(Int64(0)) { $0 + $1.size }
    check(sum <= parent, "摊出来的格子加起来不超过父行那一格（\(sum) ≤ \(parent)）")
    check(await childDirSizes(cbase.appendingPathComponent("big")).isEmpty,
          "一层里没子目录时摊不出东西，不编一行 0 出来")
    try? fm.removeItem(at: cbase)
    sem3.signal()
}
sem3.wait()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)