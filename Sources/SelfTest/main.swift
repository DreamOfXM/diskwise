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
check(entries.contains { $0.name == "npm 缓存目录" }, "知识库含 npm 缓存目录")

// 1.5 品牌标：safety_db 里每个 `icon` 都要有对应的图，否则那一格静默退回通用文件夹，
//     而「退回通用文件夹」正是这一档要消灭的东西——拼错 slug 是不会有人发现的。
let _brandDir = "Sources/DiskCleaner/Resources/BrandIcons"
let brandSlugs = Set(entries.compactMap { $0.icon })
let shippedSlugs = Set(
    (try? FileManager.default.contentsOfDirectory(atPath: _brandDir))?.compactMap { f in
        f.hasSuffix("@2x.png") || !f.hasSuffix(".png") ? nil : String(f.dropLast(4))
    } ?? [])
for slug in brandSlugs.subtracting(shippedSlugs).sorted() {
    check(false, "品牌标 \(slug) 在库里没有对应的 PNG")
}
check(!brandSlugs.isEmpty && brandSlugs.isSubset(of: shippedSlugs),
      "库里声明的 \(brandSlugs.count) 个品牌标全部有图（打包 \(shippedSlugs.count) 个）")

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

// 4b-1. 家目录之外唯一放行的两处：两个共享临时区。
//       `/tmp` 与 `/var/tmp` 都是指向 `/private` 的软链，而 `standardizedFileURL` **不解析软链**
//       ——同一个位置会以 `/tmp/x` 与 `/private/tmp/x` 两种写法同时出现（从 `/` 钻进去走前者，
//       整盘扫 `/private` 走后者）。少认一种，同一份东西换个入口就一会儿能删、一会儿只能看。
check(isDeletable(URL(fileURLWithPath: "/tmp/dw-junk/x.bin")), "临时区里的文件可删")
check(isDeletable(URL(fileURLWithPath: "/private/tmp/dw-junk/x.bin")),
      "临时区的另一种写法也认——软链不解析，两种前缀都在")
check(isDeletable(URL(fileURLWithPath: "/var/tmp/dw-junk/x.bin")), "/var/tmp 同样放行")
// 放行的是「里面的东西」，不是这两个目录本身：搬走 `/tmp` 等于端掉整个系统的临时空间。
check(!isDeletable(URL(fileURLWithPath: "/tmp")), "临时目录本体不可删")
check(!isDeletable(URL(fileURLWithPath: "/var/tmp")), "/var/tmp 本体同样不可删")
check(isProtected(URL(fileURLWithPath: "/tmp")), "临时目录本体另进受保护集，两道闸都拦得住")
// 边界另一侧：`$TMPDIR` 那一片名字里也有「临时」，但它归系统管，**不**放行。
// 这条是防止日后「顺手再划大一点」把范围挪到别处去。
check(!isDeletable(URL(fileURLWithPath: "/private/var/folders/ab/cdef/T/x.bin")),
      "家目录之外的临时区（$TMPDIR 那一片）仍然不动")
do {
    _ = try trashItem(URL(fileURLWithPath: "/Library/Caches"))
    check(false, "删系统区应被拦")
} catch let e as TrashError {
    check(e.reasonKey == "超出允许范围（仅限家目录、/Applications 与 /tmp、/var/tmp）",
          "系统区被拦：\(e.reasonKey)")
}

// 4c. 访达回执的分诊：清空失败时界面要说出「哪一种失败 + 下一步」，
//     所以错误号必须落到不同的案上——-1743 是系统没放行，-128 是他自己点了取消
check(finderError(number: -1743, message: "").reasonKey == "没有控制访达的权限",
      "-1743 归成「没放行自动化」")
check(finderError(number: -128, message: "User canceled.").reasonKey == "访达的确认被取消了",
      "-128 归成「被取消」，不当故障报")
// -600 实测来自沙盒版：发往访达的事件被系统掐掉，访达压根没收到，
// 说成「访达拒绝执行」是把责任推给了访达。
check(finderError(number: -600, message: "Application isn’t running.").reasonKey == "指令没能送到访达",
      "-600 归成「没送到访达」，不冤枉访达拒绝")
check(finderError(number: -609, message: "").reasonKey == "指令没能送到访达",
      "-609（目标连接已断）同案")
check(finderError(number: -10010, message: "err").reasonKey == "访达拒绝执行",
      "其它错误号仍算访达拒绝")
check(finderError(number: -1743, message: "Not authorized").detail.contains("-1743"),
      "详情里留着错误号，远程排查才问得出来")

// 4d. 扫描范围根：用户区 = 家目录 + /Applications；整盘再加系统白名单，
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

// 4e. 卷账拆分：环形的「没量到的地方」要按 APFS 卷点名，数据源是 diskutil 的按卷清单
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

// 4f. 容量口径：界面上的「可用 / 已用」必须跟系统设置那一屏是同一个数
if let u = volumeUsage() {
    check(u.available == u.free + u.purgeable, "可用 = 空闲 + 系统可清除")
    check(u.used + u.available == u.total, "已用 + 可用 = 总容量，环形才不会画歪")
    check(u.usedPhysical == u.used + u.purgeable, "物理占用 = 已用 + 可清除（可清除此刻还占着盘）")
    check(u.purgeable >= 0, "可清除不为负")
    // 演示树不许掺真机的可清除账：假树配的是编造的容量，掺进来就是两本账记一张图
    if homeIsDemo { check(u.purgeable == 0, "演示盘没有可清除这块") }
}

// 4g. 环形分段：这张图唯一的信用来源是「加起来正好等于已用」，而且「其他已统计」
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

// 4h. 搬进废纸篓不等于腾出空间：used 一个字节都没变，那些字节只能在弧之间挪家。
//     这条要是算错，环形就会「点一下少一圈」——图上凭空消失的字节比报多个数更糟。
let mvTop: Int64 = 40_000_000_000, mvRest: Int64 = 7_000_000_000
if let r = ringSplit(covered: ringCovered, used: ringUsed, topSum: 100_000_000_000,
                     movedOutTop: mvTop, movedOutRest: mvRest) {
    check(r.topSum + r.restMeasured + r.untouched + r.trash == ringUsed,
          "搬走之后四块加起来仍等于已用（字节只挪家、不掉盘）")
    check(r.trash == mvTop + mvRest, "「本次移入废纸篓」= 从各条弧上减掉的合计")
    check(r.topSum == 60_000_000_000 && r.restMeasured == 190_000_000_000,
          "前三与「其他已统计」各自减掉自己名下被搬走的那部分")
    check(r.untouched == 77_500_000_000, "没量到的那块不因搬动而变：废纸篓本来就已在已用里")
} else {
    check(false, "搬走一部分后环形该拆得开")
}
// 报不出来的账就不画：搬走的比那条弧本身还大，说明两本账对不上
check(ringSplit(covered: ringCovered, used: ringUsed, topSum: 100_000_000_000,
                movedOutTop: 120_000_000_000) == nil,
      "前三名名下搬走的比它们量到的还多时不拆")
check(ringSplit(covered: ringCovered, used: ringUsed, topSum: 100_000_000_000,
                movedOutRest: 300_000_000_000) == nil,
      "「其他已统计」名下搬走的超过它自己时不拆")

// 4i. 搬走的每一笔记在哪条弧上：认最长匹配，父子两条弧不许各记一遍，
//     归不进去的那些必须单列——它们不许偷偷变成一条凭空多出来的弧。
let ledRecords: [(original: String, bytes: Int64)] = [
    (home + "/.ollama/models/q3.bin", 30_000_000_000),   // 前三名下
    (home + "/.ollama", 4_000_000_000),                  // 目录本身被整个搬走
    (home + "/tmpcase/thing.bin", 2_000_000_000),        // 「其他已统计」名下
    (home + "/Deep/nested/x.mkv", 5_000_000_000),        // 父在前三、子在其余 → 记更深的那条
    (home + "/Solo/a.mov", 6_000_000_000),               // 只在前三名下
    ("/Volumes/Other/x.raw", 9_000_000_000)              // 这一轮压根没量到
]
let led = ringMoveLedger(records: ledRecords,
                         topPaths: [home + "/.ollama", home + "/Deep", home + "/Solo"],
                         otherPaths: [home + "/tmpcase", home + "/Deep/nested"])
check(led.perTop[home + "/.ollama"] == 34_000_000_000, "同一目录名下的多笔记在它自己那条弧上")
check(led.perTop[home + "/Solo"] == 6_000_000_000, "只在前三名下的记进前三")
check(led.perTop[home + "/Deep"] == nil, "父目录那条弧不替儿子记账（否则同一块字节记两遍）")
check(led.perOther[home + "/tmpcase"] == 2_000_000_000
        && led.perOther[home + "/Deep/nested"] == 5_000_000_000,
      "「其他已统计」里也要点得出是哪几个目录被搬走——列表逐行复述时按这个减")
check(led.topOut == 40_000_000_000 && led.restOut == 7_000_000_000,
      "父子都认得时只记最深的那条")
check(led.out(of: home + "/Deep/nested") == 5_000_000_000
        && led.out(of: home + "/.ollama") == 34_000_000_000
        && led.out(of: "/Volumes/Other") == 0,
      "同一个查询口覆盖前三名与其余，动不到的回 0")
check(led.unattributed == 9_000_000_000, "这轮没量到的位置删掉的，归不进环形")
check(led.topOut + led.restOut + led.unattributed + led.absorbed
        == ledRecords.reduce(Int64(0)) { $0 + $1.bytes },
      "每一笔字节恰好落进一个桶——不多记也不漏记")
check(led.trashArc == 47_000_000_000, "环上那条「本次移入」= 能归到弧上的合计")
if let r = ringSplit(covered: ringCovered, used: ringUsed, topSum: 100_000_000_000,
                     movedOutTop: led.topOut, movedOutRest: led.restOut) {
    check(r.topSum + r.restMeasured + r.untouched + r.trash == ringUsed,
          "账本喂进分段函数后四块仍等于已用")
    check(r.trash == 47_000_000_000,
          "环上只有 47 GB 那段是搬进来的——归不进弧的 9 GB 不许凭空变成弧")
} else {
    check(false, "这本账该拆得开")
}

// 4j. 清完一轮再点「重新扫描」：重新量到的尺寸里已经不含搬走的字节了（它们在废纸篓，
//     环形不量废纸篓），这笔账这时候要还记着，就会把「~/X 剩下的 5G」画成
//     「废纸篓的 5G」——一圈加起来还是整块盘，名字却全是错的。所以量过那条弧之后
//     落下水位线，水位线以下的旧账当场作废。
//     记录只往尾巴上追加，所以下标就是时间顺序：水位线之上那些是**量完之后**又搬走的。
let led2 = ringMoveLedger(records: ledRecords,
                          topPaths: [home + "/.ollama", home + "/Deep", home + "/Solo"],
                          otherPaths: [home + "/tmpcase", home + "/Deep/nested"],
                          voidedUpTo: [home + "/.ollama": 2])
check(led2.perTop[home + "/.ollama"] == nil, "重新量过的目录，旧账不许再扣第二遍")
check(led2.absorbed == 34_000_000_000, "作废的那 34 GB 明写在 absorbed 里，不是悄悄消失")
check(led2.perTop[home + "/Solo"] == 6_000_000_000, "没重量过的目录照旧记账")
check(led2.topOut + led2.restOut + led2.unattributed + led2.absorbed
        == ledRecords.reduce(Int64(0)) { $0 + $1.bytes },
      "重量过的、归不进弧的、还在弧上的，三类加起来仍是全部记录")
// 量完之后又搬走的那些必须**还**在弧上：这一条正是「用集合记哪些目录量过了」的旧写法
// 会做错的地方——它会把 8 GB 那笔一起作废掉，于是清空一轮后再删，环上永远长不出废纸篓弧。
let ledLate = ringMoveLedger(records: ledRecords + [(original: home + "/.ollama/cache.bin", bytes: Int64(8_000_000_000))],
                             topPaths: [home + "/.ollama", home + "/Deep", home + "/Solo"],
                             otherPaths: [home + "/tmpcase", home + "/Deep/nested"],
                             voidedUpTo: [home + "/.ollama": 2])
check(ledLate.perTop[home + "/.ollama"] == 8_000_000_000,
      "重量完成之后新搬走的那笔仍然要扣在那条弧上（环上就此长出废纸篓那段）")
check(ledLate.absorbed == 34_000_000_000 && ledLate.trashArc == 21_000_000_000,
      "作废的与作数的各归各：环上那段 21 GB = 新的 8 + Solo 6 + 其余 7")
// 整轮重扫：每条弧都刷新了自己的水位线 → 环上那条弧当场归零（一格不剩，因为已并进热点弧）
let ledAll = ringMoveLedger(records: ledRecords,
                            topPaths: [home + "/.ollama", home + "/Deep", home + "/Solo"],
                            otherPaths: [home + "/tmpcase", home + "/Deep/nested"],
                            voidedUpTo: [home + "/.ollama": 6, home + "/Deep": 6,
                                         home + "/Solo": 6, home + "/tmpcase": 6,
                                         home + "/Deep/nested": 6])
check(ledAll.trashArc == 0 && ledAll.unattributed == 9_000_000_000,
      "整轮重量过后环上不再单列搬走的，只有没量到的那 9 GB 仍在环外")
check(ledAll.absorbed == 47_000_000_000,
      "整轮重量过后作废的是全部能归弧的 47 GB，那 9 GB 走的是 unattributed 不是作废")

// 4k. 环形几何：「这一点归哪一段」决定的是第二下要把哪个目录搬进废纸篓。
//     算错的代价是删错东西，所以这段数学住在 Core 的 `RingGeometry.swift`，
//     在这里逐段断言，而不是只能靠真鼠标一遍遍试。（上一版它长在 `SweepRing` 里，
//     于是「无论点哪儿都是左上角有反应」只能由用户报出来。）
//     注意锁的口径：这里判的是**落点 → 段号**；弧画在哪个角度由截图对，单元测试管不着。
let ringVals: [Int64] = [23_200_000_000, 9_100_000_000, 6_300_000_000,
                         26_100_000_000, 15_300_000_000, 16_000_000_000]   // 演示数据集那六格
let ringDia: Double = 340
let ringBand = ringDia * 0.145
let ringRIn = ringDia / 2 - ringBand, ringROut = ringDia / 2
let segs = ringArcs(values: ringVals)
check(segs.count == 6, "六段都画得出来（含空闲那段）")
check(abs(segs.reduce(0) { $0 + $1.span } - 1.0) < 1e-9, "各段占比加起来正好一圈")
check(segs.allSatisfy { $0.from < $0.to }, "每段都是正宽度：发丝缝不吃掉整段")
check(ringArcs(values: [10, 0, 10]).count == 2, "值为 0 的不占一段")
check(ringArcs(values: [-5, 10]).count == 1 && ringArcs(values: [-5, 10])[0].span == 1,
      "负数当 0 处理，不吞占比也不产生整段")
check(ringArcs(values: [0, 0]).isEmpty, "整圈没东西时一段都不画")
// 归属区间必须无缝铺满一圈：命中层比的正是它，中间露一道缝就是死区，
// 多叠一段就是点错了人。
check(segs.first?.claimFrom == 0 && segs.last?.claimTo == 1
        && zip(segs, segs.dropFirst()).allSatisfy { $0.0.claimTo == $0.1.claimFrom }
        && segs.allSatisfy { $0.from >= $0.claimFrom && $0.to <= $0.claimTo },
      "各段的归属区间首尾相接铺满一圈，画出来那截收在自己归属区间里")

/// 环心坐标系里、12 点钟顺时针 `deg` 度、半径 `r` 的那个点的段号。
func at(_ deg: Double, _ r: Double, reveal: Double = 1) -> Int? {
    let a = deg * .pi / 180
    return ringArcIndex(x: ringDia / 2 + r * sin(a), y: ringDia / 2 - r * cos(a),
                        diameter: ringDia, rIn: ringRIn, rOut: ringROut,
                        arcs: segs, reveal: reveal)
}

// 绝对角度锚点：96 GB 折成一圈就是 0→87→121.125→144.75→242.625→300→360。
// 写死数而不是从 `segs` 反算，才拦得住「原点或旋向跑偏」——那种错在自证式的断言里是隐形的。
check(at(45, 145) == 0 && at(100, 145) == 1 && at(130, 145) == 2
        && at(200, 145) == 3 && at(270, 145) == 4 && at(330, 145) == 5,
      "六段各占自己那截角度，且顺时针排在 12 点钟之后")
let bounds: [(Double, Int)] = [(87, 0), (121.125, 1), (144.75, 2), (242.625, 3), (300, 4)]
var edgeBad = [String]()
for (deg, i) in bounds where at(deg - 3, 145) != i || at(deg + 3, 145) != i + 1 {
    edgeBad.append(String(format: "%.3f", deg))
}
check(edgeBad.isEmpty,
      "五道段界两侧 3° 各自归隔壁，不串段" + (edgeBad.isEmpty ? "" : "（出错：\(edgeBad.joined(separator: " "))）"))
check(at(0.05, 145) == 0 && at(359.95, 145) == 5, "12 点钟那道缝两头都有归属")

var dead = [String]()
var deadCount = 0
for deg in stride(from: 0.0, through: 359.9, by: 0.2) where at(deg, 145) == nil {
    if dead.count < 3 { dead.append(String(format: "%.1f", deg)) }
    deadCount += 1
}
check(deadCount == 0, "整圈 1800 个采样点无一死区" + (dead.isEmpty ? "" : "（首批无主角度：\(dead)）"))

// 半径：带子以外一律不算。上一版按 frame 方框收事件，孔里与环外都会点到弧上。
check(at(45, 60) == nil && at(45, 179) == nil, "孔里与环外都不认领")
check(at(45, 119) != nil && at(45, 171) != nil, "带的内外沿各 1pt 仍在带里")
check(at(45, 117) == nil && at(45, 173) == nil, "越出外沿 1pt 就交给隔壁层（圆心那格取消）")

// 入场那 0.9 秒：弧是压缩着画的（`trim(from:·reveal)`），落点必须跟着**画出来的**那段走。
check(at(45, 145, reveal: 0) == nil, "一圈还没画时整环都不接受悬停")
check(at(185, 145, reveal: 0.5) == nil, "半圈时未画到的那半边不提前接受悬停")
check(at(120, 145, reveal: 0.5) == 3, "半圈时 120° 落的是压缩后压在那儿的段，不是最终归它的第 1 段")
check(at(120, 145, reveal: 1) == 1, "画完之后同一点回到它自己的段")

// 细段：0.6° 的发丝缝在 4 TB 盘上是 6.7 GB，比缝还窄的那段过去算出 from > to，
// 于是既看不见也点不着——写死减缝不行，得按占比收。
let thin = ringArcs(values: [999_000_000_000, 500_000_000])
check(thin.count == 2 && thin[1].from < thin[1].to, "0.05% 的细段量窄于缝也要留得下")
let thinMid = (thin[1].from + thin[1].to) / 2 * 360
let thinHit = ringArcIndex(x: ringDia / 2 + 145 * sin(thinMid * .pi / 180),
                           y: ringDia / 2 - 145 * cos(thinMid * .pi / 180),
                           diameter: ringDia, rIn: ringRIn, rOut: ringROut, arcs: thin)
check(thinHit == 1, "细段在自己的中点上点得着")

var midBad = [String]()
for (i, s) in segs.enumerated() where at((s.from + s.to) / 2 * 360, 145) != i {
    midBad.append("\(i)")
}
check(midBad.isEmpty, "每段的角度中点都归回自己" + (midBad.isEmpty ? "" : "（错位：\(midBad)）"))

// 4l. 「还能腾出」这个数由缓存知识库拼出来，靠的是 Core 那两个纯函数。
//     它们决定圆心那个数与按钮真搬走的量是不是同一批字节：归错一次，人按下去就会发现
//     「说好的 22 GB 只搬回来 9 GB」——招牌画面报的数一旦复核不上，这一屏就再没人信。
let cach = home + "/Library/Caches", brew = home + "/Library/Caches/Homebrew"
check(dropNested([brew, cach, home + "/.npm"]) == [home + "/.npm", cach],
      "父项已计入就不重复加子项，剩下的按路径定死顺序（同一批输入必须每次出同一串）")
check(dropNested([cach, cach]) == [cach], "同一条路径出现两次只算一次")
check(dropNested([cach, home + "/Library/CachesX"]) == [cach, home + "/Library/CachesX"],
      "名字像儿子但不是儿子的不许被吃掉：比的是路径段，不是字符串前缀")
check(dropNested([brew, cach, home + "/Library/Caches/Google", home + "/.npm"])
        == [home + "/.npm", cach],
      "父、子、孙三代套在一起也只留最外那一层：同一段字节不许按三遍")

// 缓存页那一列的每一行都是「整棵子树」的量，所以全选合计不能按行相加：
// `~/Library/Caches` 3.0 GB 里本来就躺着 `Caches/Homebrew` 0.8 GB，
// 相加会报 3.8 GB，而用户按下去只搬回来 3.0 GB——这一格差多少，招牌那屏就失信多少。
check(contentsUnionSize([(cach, 3_000_000_000), (brew, 800_000_000)]) == 3_000_000_000,
      "父子同勾只算父那份：0.8 GB 已经在 3.0 GB 里面")
check(contentsUnionSize([(cach, 3_000_000_000), (brew, 800_000_000),
                         (home + "/.npm", 500_000_000)]) == 3_500_000_000,
      "不相交的那一段照加，被套住的那一段不重复计")
check(contentsUnionSize([(brew, 800_000_000)]) == 800_000_000,
      "只勾了孙子那一行时按孙子自己那一份算，不把父行的 3.0 GB 顺带算进去")
check(contentsUnionSize([(cach, 3_000_000_000), (cach, 3_000_000_000)]) == 3_000_000_000,
      "同一条路径出现两次只算一次")
check(contentsUnionSize([]) == 0, "一个都没勾是 0，不是 nil 也不是负数")

// 容器页：页头那个数答的是「容器这一类吃掉这块盘多少」，所以进展式的只有一行一个运行时的磁盘实占。
// 以前是 `docker system df` 四段相加（2026-09-26 实拍：页头 41.2 GB 就是四段之和），可那是引擎
// 自己报的逻辑大小：本机实测（2026-09-27）OrbStack 四段相加 38.4 GB，同一块磁盘实占只有 22.8 GB。
// 两本账同桌相加就是把同一段字节数两遍，所以段和镜像明细一并降级成批注。
check(DockerKind.runtime.countsInTotal,
      "页头那个数只由「一行一个运行时」的磁盘实占构成")
check([DockerKind.dfImages, .dfContainers, .dfVolumes, .dfCache, .other,
       .image, .danglingImage].allSatisfy { !$0.countsInTotal },
      "引擎报的账和镜像明细都不进展式：它们与磁盘实占那行量的是同一块盘")

// 一行一个运行时，包名得由运行时自己报：OrbStack 的数据目录叫
// `~/Library/Group Containers/HUAQ24HBR6.dev.orbstack`，顺着路径找包名找到的是 team 前缀，
// 那样行首永远挂不上它真正的图标（真包名是 dev.kdrag0n.MacVirt，2026-09-27 实测 Info.plist）。
check(DockerRuntime.orbstack.bundleID == "dev.kdrag0n.MacVirt"
        && DockerRuntime.dockerDesktop.bundleID == "com.docker.docker"
        && DockerRuntime.podman.bundleID == nil && DockerRuntime.colima.bundleID == nil,
      "四家运行时的归属包名：能查到 App 的两家各自报对，命令行那两家不硬凑")
check(DockerRuntime.allCases.allSatisfy { d in
          guard let p = d.dataDir?.path else { return true }
          return p.hasPrefix(homePath() + "/")
      },
      "哪家装了，它的数据目录就在这台机器的家目录里——不报系统区，也不报别人家")

// Docker 报的 Reclaimable 是一串它自己格式化的字（`13.04GB (54%)`，go-units 的 HumanSize：
// 底数 1000、单位粘在数字上）。直接印出来就和这一页其余各行的两档数字是两种口径，
// 所以先拆成字节 + 占比再交给界面。
check(parseDockerReclaimable("13.04GB (54%)") == (Int64(13.04 * 1_000_000_000), "54%"),
      "带占比的那种写法：字节段按 Docker 自己的十进制底数换算，占比原样带过来")
check(parseDockerSize("23.91GB") == Int64(23.91 * 1_000_000_000),
      "Docker 的 23.91GB 不能显示成 25.7 GB——按 1024 读就飘 7.4%")
check(parseDockerSize("44KiB") == 44 * 1024 && parseDockerSize("577.5kB") == 577_500,
      "带 i 的才是 1024，不带 i 的是 1000，两种都认得对")
check(parseDockerReclaimable("5.651GB").share == nil,
      "Build Cache 只写体积不写占比，不能凭空编一个 0% 出来")
check(parseDockerReclaimable("0B (0%)").bytes == 0,
      "一格 0 就是 0，界面据此决定这句话要不要说")

let arcs = [home + "/Library", home + "/Movies", reclaimRestKey]
check(reclaimBucket(of: brew, in: arcs) == home + "/Library", "归到最长的那个祖先前缀")
check(reclaimBucket(of: home + "/Library", in: arcs) == home + "/Library", "自己就是一条弧时归自己")
check(reclaimBucket(of: home + "/Documents/x", in: arcs) == nil,
      "不属于任何一条弧的必须回 nil，由调用方落到「其余」——不许硬塞进某条弧把它撑大")
check(reclaimBucket(of: home + "/Library/Caches", in: [home + "/Library/CachesX",
                                                       home + "/Library"]) == home + "/Library",
      "两条弧都能包住时认那条真的包住的（前缀像不算包住）")

// 4m. 同一屏那几行「可回收」必须加得起来。圆心写 22.4、三行相加却是 22.5，
//     用户的第一反应就是「这软件连自己的数都对不上」——2026-09-25 实拍到的就是这个。
//     钉的是最大余数法：先各自向下取到 0.1，缺的那几格发给最接近进位的那几行。
func tenths(_ s: String) -> Int { Int((Double(s.split(separator: " ").first ?? "") ?? -1) * 10) }
let drift: [Int64] = [11_960_000_000, 6_300_000_000, 4_180_000_000]
check(drift.map(human) == ["12.0 GB", "6.3 GB", "4.2 GB"],
      "各自四舍五入确实会飘：这三行单独印就是 12.0 + 6.3 + 4.2")
let fixed = addableHuman(drift, total: drift.reduce(0, +))
check(fixed.map(tenths).reduce(0, +) == tenths(human(drift.reduce(0, +))),
      "收成同一列之后三行相加正好等于圆心那个总数（\(fixed) 加起来 = \(human(22_440_000_000))）")
check(fixed.allSatisfy { $0.hasSuffix(" GB") },
      "整列还在同一个单位上，没为了凑数把某一行换成 MB")
var driftOK = true
for i in fixed.indices {
    let shown = (Double(fixed[i].dropLast(3)) ?? -1) * Double(GB)
    if abs(shown - Double(drift[i])) > 100_000_000 { driftOK = false }
}
check(driftOK, "补的那几格每行离真值都不超过 0.1 个单位：加得起来不是靠把某一行改离谱")
check(addableHuman([12_000_000_000, 6_300_000_000], total: 30_000_000_000)
        == ["12.0 GB", "6.3 GB"],
      "各行之和对不上总数时整体退回逐行 human——宁可各说各的，也不许凑出一列加得起来的假账")
check(addableHuman([900_000_000, 800_000_000, 300_000_000], total: 2_000_000_000)
        == ["900.0 MB", "800.0 MB", "300.0 MB"],
      "有一行落在别的单位（总数是 GB、这行是 MB）就不跨单位凑：那一列本来就不能相加")
check(addableHuman([22_440_000_000], total: 22_440_000_000) == ["22.4 GB"],
      "只有一行时它就得等于总数本身")

// 4n. 环形旁边那一列右边明写着「各段之和 494.4 GB」——那是一句算术承诺，
//     各行印出来的数必须真加得出它。可这一列里混着一行「系统可清除 501.6 MB」，
//     上面那条不跨单位凑的规矩于是让整列退回逐行四舍五入。2026-09-25 真机实拍：
//     那七行印出来加成 494.5，右边写着 494.4。
func asBytes(_ s: String) -> Int64 {
    let p = s.split(separator: " ")
    let mult = ["B": 1.0, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12, "PB": 1e15]
    return Int64(((Double(p.first ?? "") ?? 0) * (mult[String(p.last ?? "")] ?? 0)).rounded())
}
let ringCol: [Int64] = [78_240_000_000, 76_060_000_000, 60_270_000_000, 222_050_000_000,
                        43_530_000_000, 501_600_000, 13_790_000_000]
let ringTotal = ringCol.reduce(Int64(0), +)
check(addableHuman(ringCol, total: ringTotal) == ringCol.map(human),
      "有一行落在 MB 时 addableHuman 依旧不跨单位凑（上面那条规矩原样留着）")
check(ringCol.map(human).map(asBytes).reduce(Int64(0), +) != asBytes(human(ringTotal)),
      "逐行 human 确实加不出总数：这就是实拍到的那 0.1 漂移，不是我们凭空担心的")
let colFixed = addableHumanColumn(ringCol, total: ringTotal)
check(colFixed.allSatisfy { $0.hasSuffix(" GB") },
      "整列统一到总数的单位，那一行 501.6 MB 印成 0.5 GB（\(colFixed)）")
check(colFixed.map(asBytes).reduce(Int64(0), +) == asBytes(human(ringTotal)),
      "印出来的这几行相加正好等于「各段之和」那句（\(colFixed) 加起来 = \(human(ringTotal))）")
check(zip(colFixed, ringCol).allSatisfy { abs(Double(asBytes($0.0) - $0.1)) <= 100_000_000 },
      "统一单位没把任何一行改离谱：每行离真值都不超过 0.1 个单位")
check(addableHumanColumn([494_300_000_000, 20_000_000], total: 494_320_000_000)
        == ["494.3 GB", "< 0.1 GB"],
      "被分摊到 0 格的那一行印「< 0.1」而不是 0.0：它确实占着盘，印 0.0 等于这一行消失了")
check(asBytes("494.3 GB") + 0 == asBytes(human(494_320_000_000)),
      "改成印 < 0.1 之后这一列仍然加得起来：那一行本来就贡献 0 格")
check(addableHumanColumn([494_300_000_000, 40_000_000, 30_000_000],
                         total: 494_370_000_000)
        == ["494.3 GB", "0.1 GB", "< 0.1 GB"],
      "两行都小到不足一个刻度时不退成两个 0.0：余数大的那行拿到那一格（0.1），另一行印 < 0.1，"
      + "整列照样加得起来（\(addableHumanColumn([494_300_000_000, 40_000_000, 30_000_000], total: 494_370_000_000))）")
check(addableHumanColumn([12_000_000_000], total: 13_000_000_000) == ["12.0 GB"],
      "各行之和对不上总数时同样退回：不许为了凑上「各段之和」去补一个不存在的数")

// 废纸篓那一屏：操作记录相加等于「本次移入」，可那一页的展示级数字是**整个废纸篓**，
// 单位由它定。不指定这把尺，就会出现「1.3 GB」旁边挂着一列「900.0 MB」——
// 同一屏两把尺，规矩 2 与规矩 7 互相打架。
let trashRec: [Int64] = [780_000_000, 460_000_000]
let trashed = trashRec.reduce(Int64(0), +)
check(addableHumanColumn(trashRec, total: trashed, inRulerOf: 1_300_000_000)
        == ["0.8 GB", "0.4 GB"],
      "列的单位跟着屏上那个大数，不跟着自己那段（\(addableHumanColumn(trashRec, total: trashed, inRulerOf: 1_300_000_000))）")
check(addableHumanColumn(trashRec, total: trashed, inRulerOf: 1_300_000_000).map(asBytes)
        .reduce(Int64(0), +) == asBytes(human(trashed)),
      "换了尺照样加得起来：0.8 + 0.4 = 1.2，正是「本次移入」那个数")
check(addableHumanColumn([645_900, 87_900_000], total: 88_545_900, inRulerOf: 41_300_000_000)
        == ["< 0.1 GB", "0.1 GB"],
      "升到高一级单位后够不着一个刻度的行照样印 < 0.1，不退成 0.0")

// 4p. 「这一组不是同一笔账」的那几列（明细已算在段里、两块卡互相包含）不能分摊，
//     但并排印必须同一把尺：25.7 GB 挨着 501.6 MB 就没法比大小（设计稿规矩 2、7）。
check(unifiedHuman([25_700_000_000, 501_600_000]) == ["25.7 GB", "0.5 GB"],
      "整列统一到最大那档的单位，不做分摊：\(unifiedHuman([25_700_000_000, 501_600_000]))")
check(unifiedHuman([1_300_000_000, 0]) == ["1.3 GB", "0.0 GB"],
      "正好为 0 的照印 0.0——那是真没有，跟「有地方但不足一个刻度」是两件事")
check(unifiedHuman([645_900, 87_900_000, 1_300_000_000]) == ["< 0.1 GB", "0.1 GB", "1.3 GB"],
      "会被四舍五入压成 0.0 的印 < 0.1：容器 645.9 KB 那一行不是没量到")
check(unifiedHuman([900_000_000, 800_000_000]) == ["900.0 MB", "800.0 MB"],
      "整列都在 MB 时硬升到 GB 就没法比：单位跟这一组里最大那档走")
// 底部清理条那个「已选」跟着上面那一列同一把尺：整列是 GB、底下忽然冒出 400.0 MB，
// 读的人得先心算一次才知道自己选的是这页的大头还是零头。
check(human(400_000_000, inRulerOf: 23_000_000_000) == "0.4 GB",
      "单位由那一列的总数定，不由这个数自己定")
check(human(400_000_000, inRulerOf: 900_000_000) == "400.0 MB",
      "整列本来就在 MB 上时跟着 MB，不硬升到 GB")
check(human(0, inRulerOf: 23_000_000_000) == "0.0 GB",
      "一个都没勾时印 0.0 GB 而不是「0 B」：跟上面那一列同一把尺")
check(human(4_900_000, inRulerOf: 23_000_000_000) == "< 0.1 GB",
      "选了不到半个刻度的那些行不许印成 0.0——那是「什么都没选」")
check(human(-5, inRulerOf: 23_000_000_000) == "0.0 GB",
      "负数按 0 处理，不印出「-0.0 GB」这种屏幕上不存在的东西")

// 4o. 圆心那一格是「三个数当场加得起来」的现场：可用 ＋ 可回收 ＝ 全部清空后可用。
//     拿字节相加再四舍五入做不到——2026-09-25 实拍那屏印的是 14.2 / 18.6 / 32.7：
//     真值各自偏低（14.1x ＋ 18.5x = 32.7x），字节加法一步没错，
//     错在屏幕上那三串字加不起来。
check(human(14_160_000_000) == "14.2 GB" && human(18_660_000_000) == "18.7 GB",
      "屏上那两行各自印成 14.2 和 18.7")
check(human(14_160_000_000 + 18_660_000_000) == "32.8 GB",
      "字节相加再四舍五入印 32.8，跟上面两行加出来的 32.9 差 0.1——正是实拍那个形状")
check(sumShown(["14.2 GB", "18.7 GB"]) == "32.9 GB",
      "拿印出来的那两串字相加：圆心那三行当场加得起来")
check(sumShown(["14.1 GB", "18.6 GB", "0 B"]) == "32.7 GB",
      "真机 2026-09-25 实拍那一屏：可用 14.1 ＋ 可回收 18.6 ＝ 全部清空后可用 32.7")
check(sumShown(["14.2 GB", "18.7 GB", "0 B"]) == "32.9 GB",
      "废纸篓是空的时候把「0 B」加进来不改变和")
check(sumShown(["13.6 GB", "545.5 MB"]) == "14.1 GB",
      "跨单位也认：先按印出来的字换算，再相加")
check(diffShown("494.4 GB", "14.2 GB") == "480.2 GB",
      "「已用」＝印出来的整块盘 − 印出来的可用，跟圆心那一格同一套算法")
check(diffShown("14.2 GB", "494.4 GB") == nil, "减成负数不认，交回调用方按字节算")
check(sumShown(["14.2 GB", "全部清空后"]) == nil,
      "认不出的串不猜：返回 nil，由调用方退回 human(字节)")

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

// 7. 通用遍历 + 重复检测：三个相同文件（其中两个同秒）+ 一个不同文件
let dbase = fm.temporaryDirectory.appendingPathComponent("duptest-\(UUID().uuidString)")
try! fm.createDirectory(at: dbase, withIntermediateDirectories: true)
try! Data("same-content".utf8).write(to: dbase.appendingPathComponent("a.txt"))
try! Data("same-content".utf8).write(to: dbase.appendingPathComponent("b.txt"))
try! Data("same-content".utf8).write(to: dbase.appendingPathComponent("e.txt"))
try! Data("different!!".utf8).write(to: dbase.appendingPathComponent("c.txt"))
try! fm.createDirectory(at: dbase.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! Data("nested-file!".utf8).write(to: dbase.appendingPathComponent("sub/d.txt"))
// 给 a/b/e 钉上明确的先后：留哪一份就是由日期定的，全同秒的话这条测不出东西。
// b 和 e 故意同秒——同秒里留谁必须由路径定死，不能看字典遍历的心情。
let olderMtime = Date(timeIntervalSince1970: 1_600_000_000)
let newerMtime = Date(timeIntervalSince1970: 1_700_000_000)
try! fm.setAttributes([.modificationDate: olderMtime],
                      ofItemAtPath: dbase.appendingPathComponent("a.txt").path)
try! fm.setAttributes([.modificationDate: newerMtime],
                      ofItemAtPath: dbase.appendingPathComponent("b.txt").path)
try! fm.setAttributes([.modificationDate: newerMtime],
                      ofItemAtPath: dbase.appendingPathComponent("e.txt").path)
let sem2 = DispatchSemaphore(value: 0)
Task {
    let r = await walkFiles(dirs: [dbase])
    check(r.rows.count == 5 && r.matched == 5, "遍历到 5 个文件")
    let gs = findDupGroups(r.rows).groups
    check(gs.count == 1 && gs[0].files.count == 3, "检出 1 组重复（a/b/e），c、d 不在其中")
    // files[0] 就是界面上那颗「保留」。备份/导出目录按日期递增，留最旧等于删最新备份
    check(gs[0].files.first?.lastPathComponent == "b.txt",
          "重复组保留日期最新那份（实留 \(gs[0].files.first?.lastPathComponent ?? "无")）")
    check(gs[0].files.dropFirst().map(\.lastPathComponent) == ["e.txt", "a.txt"],
          "同秒的两份按路径定死先后（实排 \(gs[0].files.dropFirst().map(\.lastPathComponent))）")
    check(shortDate(fileDate(gs[0].files[0])) == shortDate(newerMtime),
          "行上标的日期就是排序依据（\(shortDate(fileDate(gs[0].files[0])))）")
    let capped = await walkFiles(dirs: [dbase], top: 2)
    check(capped.rows.count == 2 && capped.matched == 5, "top 2 只留两条，命中总数仍是 5")
    // 根套根（演示树里整盘根全落在假家目录底下）：同一份文件只能算一次
    let nested = await walkFiles(dirs: [dbase, dbase.appendingPathComponent("sub")])
    check(nested.rows.count == 5, "嵌套根不重复计数（实得 \(nested.rows.count) 条）")
    check(Set(nested.rows.map { $0.url.path }).count == nested.rows.count, "嵌套根交出来的路径不重复")
    try? fm.removeItem(at: dbase)
    sem2.signal()
}
sem2.wait()

// 7b. 受管环境（venv / site-packages / node_modules / DerivedData）里的副本不参与比对：
//     那些是某个环境自己装的零件，删一份那个环境就缺一块，要回收得卸掉整个环境。
let ebase = fm.temporaryDirectory.appendingPathComponent("envtest-\(UUID().uuidString)")
func mk(_ rel: String, _ text: String) -> URL {
    let u = ebase.appendingPathComponent(rel)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: u)
    return u
}
let payload = "同一份 wheel 里的二进制"
mk("Documents/setup.bin", payload)
mk("proj/venv/lib/python3.12/site-packages/pkg/setup.bin", payload)
mk("web/node_modules/esbuild/bin/setup.bin", payload)
mk("Library/Developer/Xcode/DerivedData/App-abc/Build/setup.bin", payload)
let semEnv = DispatchSemaphore(value: 0)
Task {
    // 先只放一份自由副本：凑不成一组，就不该报「可回收」
    var rows = (await walkFiles(dirs: [ebase])).rows
    let only = findDupGroups(rows)
    check(rows.count == 4, "四份内容相同的东西都遍历到了（实得 \(rows.count) 条）")
    check(only.groups.isEmpty,
          "只剩一份自由副本，凑不成一组，就不报「可回收」（实得 \(only.groups.count) 组）")
    check(only.excluded.count == 1 && only.excluded[0].files.count == 3,
          "三份环境副本归进名单同一组（实得 \(only.excluded.count) 组 / \(only.excluded.first?.files.count ?? 0) 份）")
    check(Set(only.excluded.first?.envs ?? []) ==
          Set([ebase.appendingPathComponent("proj/venv").path,
               ebase.appendingPathComponent("web/node_modules").path,
               ebase.appendingPathComponent("Library/Developer/Xcode/DerivedData/App-abc").path]),
          "名单报得出这三份各自住在哪个环境里")
    // 再加一份自由副本：自由的那两份照旧成组，环境那三份只在名单里出现
    mk("Downloads/setup.bin", payload)
    rows = (await walkFiles(dirs: [ebase])).rows
    let mixed = findDupGroups(rows)
    check(mixed.groups.count == 1 && mixed.groups[0].files.count == 2,
          "摘掉环境副本后，两份自由副本仍算一组（实得 \(mixed.groups.first?.files.count ?? 0) 份）")
    check(mixed.groups.first?.files.allSatisfy { managedEnv(of: $0) == nil } == true,
          "主列表里不会出现任何住在环境里的路径")
    check(mixed.excluded.first?.files.count == 3, "被摘出去的三份照旧列进名单")
    try? fm.removeItem(at: ebase)
    semEnv.signal()
}
semEnv.wait()

// 7c. managedEnv 认的是哪一层：环境根 = 标记那颗本身，site-packages 要往上退到 lib 的上一层
func envOf(_ p: String) -> String? { managedEnv(of: URL(fileURLWithPath: p)) }
check(envOf("/Users/x/Documents/a.bin") == nil, "普通文档不是环境里的零件")
check(envOf("/Users/x/a/node_modules/esbuild/bin/b") == "/Users/x/a/node_modules", "node_modules 归到那一层")
check(envOf("/Users/x/p/venv/lib/python3.12/site-packages/pkg/b") == "/Users/x/p/venv", "venv 里的包归到 venv")
check(envOf("/Users/x/.browser-use-env/lib/python3.12/site-packages/b") == "/Users/x/.browser-use-env", "点开头的手搓环境同样认")
check(envOf("/Users/x/opt/miniconda3/envs/dl/lib/python3.11/site-packages/b") == "/Users/x/opt/miniconda3/envs/dl", "conda 环境归到自己那个")
check(envOf("/Users/x/Library/Python/3.9/lib/python/site-packages/playwright/driver/node") == "/Users/x/Library/Python/3.9", "系统 python 的用户站点目录归到版本号那层")
check(envOf("/Users/x/.local/pipx/venvs/playwright/lib/python3.14/site-packages/b") == "/Users/x/.local/pipx/venvs/playwright", "pipx 环境归到工具名那一层")
check(envOf("/Users/x/Library/Developer/Xcode/DerivedData/App-abc/Build/b") == "/Users/x/Library/Developer/Xcode/DerivedData/App-abc", "DerivedData 归到具体那一个 App")
check(envOf("/Users/x/node_modules") == nil, "环境名字本身不能算一份副本")
check(envOf("/relative/venv/lib/python3.12/site-packages/b") == "/relative/venv", "相对路径也照规则走")

// 8. 总览行内摊开下一级：走的是 `dirLevel` 的「只要目录」那一档（`includeFiles: false`），
//    与文件夹详情页同一份实现。两页必须列同一批目录——只要差一处，同一台机器上点开
//    同一层就会看见两份不一样的名单。子层之和也不能超过父行，而且同一份字节
//    不能因为一个符号链接就被数第二遍。
let cbase = fm.temporaryDirectory.appendingPathComponent("kidtest-\(UUID().uuidString)")
for (n, mb) in [("small", 1), ("mid", 2), ("big", 3)] {
    let d = cbase.appendingPathComponent(n)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    try! Data(count: mb * 1024 * 1024).write(to: d.appendingPathComponent("f.bin"))
}
// 一个比所有子目录都大的文件：只列目录那一档必须把它挡在外面。
try! Data(count: 5 * 1024 * 1024).write(to: cbase.appendingPathComponent("big.bin"))
try! fm.createSymbolicLink(atPath: cbase.appendingPathComponent("linkdir").path,
                           withDestinationPath: cbase.appendingPathComponent("big").path)
let sem3 = DispatchSemaphore(value: 0)
Task {
    let kids = await dirLevel(cbase, includeFiles: false, fileLimit: 0).entries
    check(kids.map(\.name) == ["big", "mid", "small"],
          "下一级按占盘从大到小排（得 \(kids.map(\.name))）")
    check(kids.allSatisfy(\.isDir),
          "总览那一档只摊目录：那个 5 MB 的文件比任何子目录都大，也不占一列")
    check(kids.allSatisfy { $0.size > 0 }, "摊出来的每一格都得有自己的数")
    check(!kids.contains { $0.name == "linkdir" },
          "指向目录的符号链接不摊成第二格")
    let parent = await dirSize(cbase)
    let sum = kids.reduce(Int64(0)) { $0 + $1.size }
    check(sum <= parent, "摊出来的格子加起来不超过父行那一格（\(sum) ≤ \(parent)）")
    check(await dirLevel(cbase.appendingPathComponent("big"),
                         includeFiles: false, fileLimit: 0).entries.isEmpty,
          "一层里没子目录时摊不出东西，不编一行 0 出来")
    try? fm.removeItem(at: cbase)
    sem3.signal()
}
sem3.wait()

// 9. 模拟器逐台摊开：一台 = 一个装着 `device.plist` 的目录，名字与系统都从那一份里取。
//    认 plist 而不是认 UUID 形状：同一层还散着 Caches 之类的目录，按形状认会把不是台子的算进来。
let simbase = fm.temporaryDirectory.appendingPathComponent("simtest-\(UUID().uuidString)")
func makeSim(_ udid: String, _ plist: [String: Any]?, mb: Int) {
    let d = simbase.appendingPathComponent(udid)
    try! fm.createDirectory(at: d.appendingPathComponent("data"), withIntermediateDirectories: true)
    if let p = plist {
        try! (p as NSDictionary).write(to: d.appendingPathComponent("device.plist"))
    }
    if mb > 0 {
        try! Data(count: mb * 1024 * 1024).write(to: d.appendingPathComponent("data/img.bin"))
    }
}
let booted = Date(timeIntervalSince1970: 1_700_000_000)
makeSim("AAAA", ["name": "iPhone 17",
                 "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
                 "lastBootedAt": booted], mb: 3)
makeSim("BBBB", ["name": "iPad Pro",
                 "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0"], mb: 1)
makeSim("CCCC", nil, mb: 2)                                   // 没有 plist：不是台子
try! fm.createDirectory(at: simbase.appendingPathComponent("Caches"), withIntermediateDirectories: true)
let sem4 = DispatchSemaphore(value: 0)
Task {
    let sims = await scanSimulators(under: simbase)
    check(sims.map(\.id) == ["AAAA", "BBBB"],
          "一台模拟器 = 一个装着 device.plist 的目录，空目录与 Caches 都不算（得 \(sims.map(\.id))）")
    check(sims.first?.name == "iPhone 17" && sims.first?.os == "iOS 26.5",
          "台子叫什么、跑哪个系统，都取设备自己那份 plist，不是我们猜的（\(sims.first?.name ?? "-") · \(sims.first?.os ?? "-")）")
    check(sims.first?.lastBooted == booted && sims.last?.lastBooted == nil,
          "启动过的那台带着日期，从没启动过的就是 nil，不编一个日期出来")
    check(sims.allSatisfy { $0.size > 0 } && sims.first!.size > sims.last!.size,
          "占盘从大到小排：摊开这一行就是为了先看谁在吃盘")
    try? fm.removeItem(at: sbase)
    sem4.signal()
}
sem4.wait()

// 10. 文件夹下钻（dirLevel）：目录与文件混排、按占盘降序，`total` 覆盖**全部**子项。
//     「列出来的那几行 ＋ 尾巴那句」必须正好等于页头那个合计——这是这一页唯一的账，
//     对不上就等于让人拿两本凑不起来的数做决定。
let lbase = fm.temporaryDirectory.appendingPathComponent("leveltest-\(UUID().uuidString)")
for (n, mb) in [("small", 1), ("mid", 2), ("big", 3)] {
    let d = lbase.appendingPathComponent(n)
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    try! Data(count: mb * 1024 * 1024).write(to: d.appendingPathComponent("f.bin"))
}
try! Data(count: 4 * 1024 * 1024).write(to: lbase.appendingPathComponent("top.bin"))
try! Data(count: 4096).write(to: lbase.appendingPathComponent("tiny.bin"))
try! fm.createSymbolicLink(atPath: lbase.appendingPathComponent("linkdir").path,
                           withDestinationPath: lbase.appendingPathComponent("big").path)
let lbaseEmpty = lbase.appendingPathComponent("empty")
try! fm.createDirectory(at: lbaseEmpty, withIntermediateDirectories: true)
// 读不动的目录：自己名下 2 MB，但整棵子树设成 000——`dirSizeReport` 会在它这一层
// 拿到 EACCES，于是它的量出 0。这个 0 跟 `empty` 那个 0 在屏幕上必须分得开。
let lbaseBlocked = lbase.appendingPathComponent("blocked")
try! fm.createDirectory(at: lbaseBlocked, withIntermediateDirectories: true)
try! Data(count: 2 * 1024 * 1024).write(to: lbaseBlocked.appendingPathComponent("f.bin"))
try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lbaseBlocked.path)
// 只缺一块的目录：自己读得动、量得出 1 MB，里面却藏着一个 000 的子目录。
// 它跟 `blocked` 在界面上必须长得不一样——一个给破折号，一个给数字。
let lbasePartial = lbase.appendingPathComponent("partial")
let lbasePartialSub = lbasePartial.appendingPathComponent("sub")
try! fm.createDirectory(at: lbasePartialSub, withIntermediateDirectories: true)
try! Data(count: 1 * 1024 * 1024).write(to: lbasePartial.appendingPathComponent("f.bin"))
try! Data(count: 2 * 1024 * 1024).write(to: lbasePartialSub.appendingPathComponent("f.bin"))
try! fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lbasePartialSub.path)
let sem5 = DispatchSemaphore(value: 0)
Task {
    let lv = await dirLevel(lbase)
    check(lv.entries.first?.name == "top.bin",
          "目录和文件混在一张榜上按占盘降序（第一名 \(lv.entries.first?.name ?? "-")）")
    check(lv.entries.contains { $0.name == "top.bin" && !$0.isDir },
          "这一层自己的文件也要列出来——钻进来多半就是为了看它们")
    check(!lv.entries.contains { $0.name == "linkdir" },
          "指向目录的符号链接不占一格（不然共享的字节被数两遍）")
    check(lv.dirCount == 6 && lv.fileCount == 2,
          "一层里 6 个目录 2 个文件（得 \(lv.dirCount) 目录 / \(lv.fileCount) 文件）")
    let listed = lv.entries.reduce(Int64(0)) { $0 + $1.size }
    check(listed + lv.unlistedBytes == lv.total,
          "列出来的几行 ＋ 尾巴那句 ＝ 页头那个合计（\(listed) + \(lv.unlistedBytes) = \(lv.total)）")
    check(["small", "mid", "big"].allSatisfy { n in
        lv.entries.contains { $0.name == n && $0.files > 0 } },
        "有内容的目录带得住它名下有多少文件")
    check(lv.entries.allSatisfy { $0.isDir || $0.files == 1 },
          "文件那一格恒为 1")
    check(lv.entries.contains { $0.name == "empty" && $0.size == 0 && !$0.unreadable },
          "空目录也占一行：量到 0 ≠ 不存在，而且它的 0 是真 0（不标 unreadable）")
    check(lv.entries.contains { $0.name == "blocked" && $0.unreadable },
          "读不动的目录照样进榜并标上 unreadable——把它按 size>0 剔掉，就等于把"
          + "用户最想进去看的那一批从界面上抹掉（~/Library 一级丢 25 个）")
    check(lv.entries.first { $0.name == "blocked" }?.size == 0,
          "读不懂的那棵子树量出 0，界面据此显示破折号而不是 0 B")
    let partial = lv.entries.first { $0.name == "partial" }
    check(partial?.unreadable == true && (partial?.size ?? 0) > 0,
          "只缺一块的目录照样给出量到的数（这里是 1 MB）——把它也画成破折号，"
          + "是从一处错改成另一处错（得 \(partial?.size ?? -1) 字节）")
    let parentTotal = await dirSize(lbase)
    check(lv.total <= parentTotal,
          "这一层量到的合计量不超过父目录整棵树的量（\(lv.total) ≤ \(parentTotal)）")

    let capped = await dirLevel(lbase, fileLimit: 1)
    check(capped.entries.filter { !$0.isDir }.count == 1,
          "上限掐文件：只留 1 行（得 \(capped.entries.filter { !$0.isDir }.count)）")
    check(capped.entries.filter(\.isDir).count == capped.dirCount && capped.dirCount == 6,
          "上限不掐目录：6 个目录一个不少——少一个就是少一条往下走的路（得 \(capped.dirCount)）")
    check(capped.entries.contains { $0.name == "blocked" },
          "读不动的目录也不受上限影响，任何情况下都推不到榜外")
    check(capped.total == lv.total, "掐不动合计：total 覆盖全部子项，不只是列出来那几行")
    check(capped.unlistedCount == 1 && capped.unlistedBytes > 0,
          "没逐行列出的文件并进尾巴那句（\(capped.unlistedCount) 项 / \(capped.unlistedBytes) 字节）")

    let dirsOnly = await dirLevel(lbase, includeFiles: false)
    check(dirsOnly.fileCount == 0 && dirsOnly.entries.allSatisfy(\.isDir),
          "只要目录时，文件一格都不掺进来")

    let onlyFiles = await dirLevel(lbase.appendingPathComponent("small"))
    check(onlyFiles.dirCount == 0 && onlyFiles.fileCount == 1
          && onlyFiles.entries.first?.isDir == false,
          "只有文件的目录：列出来的是文件，目录数归 0")

    let empty = await dirLevel(lbaseEmpty)
    check(empty.entries.isEmpty && empty.total == 0 && empty.unlistedCount == 0,
          "空目录里面不编一行 0 出来")

    let missing = await dirLevel(lbase.appendingPathComponent("no-such-dir-\(UUID().uuidString)"))
    check(missing.entries.isEmpty && missing.total == 0,
          "读不动的目录给一层空的，不崩、也不编数")

    // 收尾：先把自己设的 000 摘掉，再删——留着它，下面 removeItem 会递归进不去。
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lbaseBlocked.path)
    try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lbasePartialSub.path)
    try? fm.removeItem(at: lbase)
    sem5.signal()
}
sem5.wait()

// 10b. 面包屑：**该路径自己的每一级**，每一格都是一个能点回去的真实祖先。
//      **不含盘顶 `/`**：界面上最左那一格固定是「空间总览」——那是这一页的来处，
//      而整盘的账本来就是空间总览那一页在做，再单列一格 `/` 等于把同一件事说第二遍；
//      更要紧的是它把「上一级」引到一页没什么可干的空账上（那页全是「本工具不碰」）。
//      也不从扫描根起头：`/Library` 本身就是一条扫描根，以根起头那一屏就只剩一格，
//      上面全不见——而人是在「进太深了、想退出去」的时候才看这一条。
check(crumbChain(for: "/") == [], "盘顶自己不占一格——它上面就是「空间总览」")
check(crumbChain(for: "/Library") == ["/Library"],
      "本身就是扫描根的地方，照样只有它自己这一格（得 \(crumbChain(for: "/Library"))）")
check(crumbChain(for: "/Applications/Xcode.app") == ["/Applications", "/Applications/Xcode.app"],
      "两格都在，一路能点回去")
let deep = home + "/Library/Developer/CoreSimulator"
check(crumbChain(for: deep) == [home, home + "/Library",
                                home + "/Library/Developer", deep],
      "家目录那两段并成一格 `~`，中间每一级都不落（得 \(crumbChain(for: deep))）")
check(crumbChain(for: deep).allSatisfy { deep.hasPrefix($0) },
      "每一格都是当前路径的祖先，没有一格是编出来的")
check(crumbChain(for: "/Users/别人/Documents") == ["/Users", "/Users/别人", "/Users/别人/Documents"],
      "别人的家目录不折叠：那里没有 `~` 可写")
check(crumbChain(for: home) == [home], "就在家目录本身时，`~` 是最后一格")
check(crumbChain(for: deep).first != "/" && crumbChain(for: "/Library").first != "/",
      "哪一格都不是盘顶 `/`——最左那格由界面固定摆成「空间总览」")

// 10c. 「上一级」的落点：`/Applications`、`/Library` 这类顶层目录再往上是**空间总览**，
//      不是盘顶那一站。两者同一口径，否则面包屑说着「空间总览 › Applications」，
//      按下去却落在一页只有「本工具不碰」、一个字节也清不动的空账上。
check(drillParent(of: "/Applications") == nil, "顶层的上一级是空间总览，不经过盘顶")
check(drillParent(of: "/") == nil, "盘顶自己没有上一级")
check(drillParent(of: "") == nil, "还没进任何目录时没有落点")
check(drillParent(of: "单个名字") == nil, "非绝对路径退出来是空的，同样当到顶")
check(drillParent(of: home + "/Library/Caches") == home + "/Library",
      "普通目录退到它的父目录")
check(drillParent(of: home) == (home as NSString).deletingLastPathComponent,
      "家目录自己也还有上一级（`/Users`），只有盘顶那两档才折回总览")
check(drillParent(of: "/Applications/Xcode.app") == "/Applications",
      "顶层下面一层照常退到父目录——折叠只发生在顶层那一跳")

// 11. 知识库判词（`VerdictIndex`）：总览与文件夹详情是从一个**已经量出来的目录**
//     反查「这一处是什么、能不能放心删」，走的是逐段比对，不是「截到第一个通配为止」的
//     前缀——后者会把 `~/Library/Application Support/*[Dd]ing[Tt]alk*/log` 截成
//     `~/Library/Application Support`，那一层住着几十个 App 的真实数据，却会被判成「删了没影响」。
//
//     `warn` 那一档还要再分两刀：「删了要重新下载」和「删了会丢数据」是两件对着干的事，
//     混进同一枚徽章，用户既不敢删该删的，也看不出哪个更该躲着走。
let vix = VerdictIndex(entries: entries)

let vNpm = vix.verdict(for: home + "/.npm")
check(vNpm.tier == .safe && vNpm.exact && vNpm.entry?.name == "npm 缓存目录",
      "精确命中一条 safe 条目（得 \(vNpm.tier.rawValue) / \(vNpm.entry?.name ?? "-")）")
check(vix.verdict(for: home + "/.ollama/models").tier == .redo,
      "标 warn + cost=redo 的条目判成「删了要重新下载」，不是「删了没影响」，也不是「删了会丢数据」")
check(vix.verdict(for: home + "/Library/Developer/CoreSimulator/Devices").tier == .risky,
      "标 warn + cost=data 的条目判成「删了会丢数据」——模拟器里装着已装 App 的数据与登录态")
// 大文件 / 很久没动那两页列出来的是**文件**，比条目深好几层，命中靠的是它上面的那一格。
// 这条钉的就是这个机制：exact 为 false，档位照祖先走。截图里那些
// `…/Devices/<UDID>/data/private/var/MobileAsset/…/UC_SIRL_….dmg` 正是这种路径——
// 修那条「大文件页对它们一个字都不说」的缺陷，靠的就是它。
let vSimFile = vix.verdict(for: home
    + "/Library/Developer/CoreSimulator/Devices/5BF3AD51-2DC2-4716-9526-F1D347F294E0"
    + "/data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_UAF_Siri_Understanding/x.dmg")
check(vSimFile.tier == .redo && !vSimFile.exact
        && vSimFile.entry?.name == "模拟器内的系统资产",
      "模拟器里按需下载的资产落到更细的那一条上，判「删了要重新下载」——"
      + "不再被整条 Devices 的 warn=data 盖成「会丢数据」"
      + "（得 \(vSimFile.tier.rawValue) / \(vSimFile.entry?.name ?? "-") / exact=\(vSimFile.exact)）")
check(vix.verdict(for: home
        + "/Library/Developer/CoreSimulator/Devices/5BF3AD51-2DC2-4716-9526-F1D347F294E0"
        + "/data/var/db/uuidtext/dsc/x").tier == .redo,
      "模拟器内的共享缓存同样可重建，也不落进「会丢数据」")
// 同一批 warn 里两档必须真的分得开：这两条都是 warn，但代价一个天一个地。
check(vix.verdict(for: home + "/.ollama/models").tier
        != vix.verdict(for: home + "/Library/Developer/CoreSimulator/Devices").tier,
      "「重下几十 G」和「丢数据」不许落进同一档")
// 最长命中优先，两条要在同一棵树上对照：~/Library/Caches 自己是 warn，
// 它底下的 pip 是 safe——深的先命中，浅的那条不能把深的拉下水。
check(vix.verdict(for: home + "/Library/Caches").tier == .redo,
      "父目录照它自己那条 warn 判")
let vPip = vix.verdict(for: home + "/Library/Caches/pip")
check(vPip.tier == .safe && vPip.exact,
      "更深的条目先命中：pip 是 safe，不被父目录那条 warn 盖住（得 \(vPip.tier.rawValue)）")
// 落在条目**上面**的那层不算命中。这一条正是第一版实现错掉的地方。
let vAppSup = vix.verdict(for: home + "/Library/Application Support")
check(vAppSup.tier == .unknown && vAppSup.entry == nil,
      "住在它下面的条目不许把这一层判成「删了没影响」——那一层是几十个 App 的真实数据")
check(vAppSup.knownBelow >= 3,
      "但「底下有几处认得」要数得出来，否则「不认识」就是一句死话（得 \(vAppSup.knownBelow)）")
// 通配段：同一层里对得上的命中、对不上的不跟着命中。
check(vix.verdict(for: home + "/Library/Application Support/DingTalkMac/log").tier == .safe,
      "含通配的那一段走 fnmatch，正对得上的命中")
check(vix.verdict(for: home + "/Library/Application Support/DingTalkMac/别的").tier == .unknown,
      "同一层里对不上的子目录不跟着命中")
// Group Container 那一级带团队 ID，每条机器不一样，条目里写的是通配。
check(vix.verdict(for: home + "/Library/Group Containers/HUAQ24HBR6.dev.orbstack").tier == .risky,
      "Group Container 用通配匹团队 ID")
check(vix.verdict(for: "/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime").tier == .redo,
      "家目录外的系统资产也认得出")
// 最后一档必须存在：没命中 ≠ 可以删。
check(vix.verdict(for: "/tmp/没这条-\(UUID().uuidString)").tier == .unknown,
      "知识库里没有的路径报「不认识」，不默认成「删了没影响」")
check(vix.verdict(for: "相对路径/不该认").tier == .unknown,
      "相对路径一律不认——认了会把判词挂到想不到的地方去")

// 12. 知识库的 `cost` 字段：`warn` 的每一条都要标，`safe` 的一条都不该有。
//     漏标一件「删了会丢数据」的，界面就会把它说成「删了要重新下载」——那不是文案问题，是让人
//     把不该删的东西删掉。所以这一层由自检从 JSON 里逐条盯，不靠写的人自觉。
let noCost = entries.filter { $0.level == "warn" && $0.cost == nil }.map(\.name)
check(noCost.isEmpty, "每条 warn 都标了 cost（缺：\(noCost.joined(separator: "、"))）")
let strayCost = entries.filter { $0.level != "warn" && $0.cost != nil }.map(\.name)
check(strayCost.isEmpty, "safe 条目不带 cost——那是「不用付代价」，不是「代价是空的」（多：\(strayCost.joined(separator: "、"))）")
let badCost = entries.filter { $0.cost != nil && $0.cost != "redo" && $0.cost != "data" }.map(\.name)
check(badCost.isEmpty, "cost 只认 redo / data（越界：\(badCost.joined(separator: "、"))）")
let tOllama = entries.first { $0.name == "Ollama 模型" }?.tier
let tSim = entries.first { $0.name == "Xcode 模拟器设备" }?.tier
let tNpm = entries.first { $0.name == "npm 缓存目录" }?.tier
check(tOllama == .redo && tSim == .risky && tNpm == .safe,
      "三档映射：warn+redo→删了要重新下载，warn+data→删了会丢数据，safe→删了没影响（得 \(tOllama?.rawValue ?? "-") / \(tSim?.rawValue ?? "-") / \(tNpm?.rawValue ?? "-")）")
let danglingWarn = entries.filter { $0.level == "warn" && $0.cost == nil }
check(danglingWarn.count == 0,
      "没有一条 warn 漏在 cost 之外")
// 兜底方向也要钉住：真漏了一条，它得往「更重」那档掉。
// 说轻了会让人把不该删的删掉；说重了只是白紧张一下——两种错代价不对等。
let rawNoCost = #"{"name":"x","what":"w","whatif":"i","rec":"r","path":"/tmp/x","level":"warn"}"#
if let e = try? JSONDecoder().decode(SafetyEntry.self, from: Data(rawNoCost.utf8)) {
    check(e.tier == .risky, "漏标 cost 的 warn 按「删了会丢数据」算，不许悄悄退回「删了要重新下载」（得 \(e.tier.rawValue)）")
} else {
    check(false, "缺 cost 字段的条目要能解得出来，不能整条解不动")
}

// 13. 导航历史：去重那一条是这套「返回」里唯一会算错的地方。
//     「上一级」往回走时父目录本来就在栈里，当成新的一站追加的话，
//     历史会变成「…父、子、父」，按返回又跳回子目录，来回打转出不去。
var nav = NavStack<String>(first: "总览")
check(!nav.canGoBack, "只有一站时不能返回")
check(nav.current == "总览", "栈顶就是此刻这一屏")
check(nav.arrive("大文件"), "落一站算真的动了地方")
check(nav.canGoBack, "两站之后能返回")
check(nav.previous == "总览", "上一站就是出发的那一站")
check(nav.pop() == "总览", "退一步回到出发那一站")
check(!nav.canGoBack, "退到底之后返回失效")
check(nav.pop() == nil, "只剩一站时退不动，也不许把栈退空")

var drill = NavStack<String>(first: "总览")
drill.arrive("/A"); drill.arrive("/A/B"); drill.arrive("/A/B/C")
check(drill.stops == ["总览", "/A", "/A/B", "/A/B/C"],
      "三层都记下来了（得 \(drill.stops)）")
check(drill.arrive("/A/B"), "「上一级」也是一次落站")
check(drill.stops == ["总览", "/A", "/A/B"],
      "回到去过的那一站，把它后面的整段丢掉（得 \(drill.stops)）")
check(drill.pop() == "/A", "再退一步到上一层——不是又跳回 /A/B/C")
check(drill.pop() == "总览", "继续退到最外面")
check(!drill.canGoBack, "退到栈底就停住")

var same = NavStack<String>(first: "总览")
check(!same.arrive("总览"), "落在同一站上不算动地方——视图据此不做多余的重量")
check(same.stops == ["总览"], "同一站不会把自己叠两层")

var root = NavStack<String>(first: "总览")
root.arrive("大文件"); root.arrive("缓存")
root.reset(to: "缓存")
check(root.stops == ["缓存"] && !root.canGoBack,
      "点侧栏是重新挑目的地，返回随即失效（得 \(root.stops)）")

// 14. 扫描清单的格子短名：清单答的是「现在走到哪一处」，两格同名就等于没答。
let hm = homePath()
check(ScanProgress.shortName(hm) == "~", "家目录那一格就是 ~")
check(ScanProgress.shortName("\(hm)/Library/Caches") == "Caches",
      "家目录里的一处只写尾段（面包屑已经说了在哪一层）")
check(ScanProgress.shortName("\(hm)/Library/Application Support") == "Application Support",
      "名字里带空格的原样留着（得 \(ScanProgress.shortName("\(hm)/Library/Application Support"))）")
check(ScanProgress.shortName("/opt") == "opt", "盘顶那几处本来就是一段")
// 这两条是整盘范围里的真根：只写尾段会跟别处混成同一件事
check(ScanProgress.shortName("/usr/local") == "usr/local",
      "深层绝对路径至少留两段，不写成一个光秃秃的 local")
check(ScanProgress.shortName("/System/Volumes/Data/System") == "Data/System",
      "数据卷底下那层 System 不能印成 System——那会跟密封系统卷混成一件事")
check(ScanProgress.shortName("com.example.legacyeditor") == "com.example.legacyeditor",
      "本来就不是路径的那几处（残留按目录名走）原样留着")

// 三处 Applications（用户装 App 的地方有两条，系统那条一条）必须分得开
let appNames = ScanProgress.labels(for: ["/Applications", "/System/Applications",
                                         "\(hm)/Applications"])
check(Set(appNames).count == 3, "三处 Applications 分开（得 \(appNames)）")
check(appNames[0] == "Applications", "盘顶那条仍是最短写法（得 \(appNames[0])）")
check(appNames[1] == "System/Applications", "系统那条补上一段（得 \(appNames[1])）")
check(appNames[2] == "~/Applications", "家目录那条把 ~ 摆回来（得 \(appNames[2])）")
// 不重名时不许无谓加长
let oneNames = ScanProgress.labels(for: ["/Applications", "/opt", "\(hm)/Library/Caches"])
check(oneNames == ["Applications", "opt", "Caches"],
      "没有重名就不加长（得 \(oneNames)）")
// 加长也不够分时继续往下加：两个都叫 Caches 的目录
let twoCaches = ScanProgress.labels(for: ["\(hm)/Library/Caches", "\(hm)/Caches"])
check(twoCaches == ["~/Library/Caches", "~/Caches"],
      "家目录里重名时补成从家目录起的两段（得 \(twoCaches)）")

// 15. Agent 通道（AgentAPI）：判定管线 / 两步确认 / 执行重校验 / 撤销日志
//     整节跑在假家目录里；移废纸篓走注入的假实现（搬进 /tmp 下的目录），
//     不往真实 ~/.Trash 丢测试垃圾——真废纸篓的往返由 CLI 手测覆盖。
//
//     正文必须包在 detached 任务里：顶层代码一旦出现 await，main.swift 的顶层
//     就变成 MainActor 异步函数，上面第 6/7/8…节沿用多年的 Task+semaphore
//     模式会集体死锁（Task 转为继承 MainActor，而主线程正阻塞在 sem.wait 上）。
//     保持顶层同步、async 正文挪进 detached 任务（落全局执行器），旧节原样不动。
func agentSelfTest() async throws {
    let aroot = fm.temporaryDirectory.appendingPathComponent("dwagent-\(UUID().uuidString)")
    let ahome = aroot.appendingPathComponent("home")
    func afile(_ rel: String) -> URL { ahome.appendingPathComponent(rel) }
    // safe（whisper）/ redo（ollama）/ risky（Xcode 归档）各造一处，
    // 外加知识库外的目录与认识位置内部的子路径
    for rel in [".cache/whisper", ".ollama/models", "Library/Developer/Xcode/Archives",
                "my-stuff", ".cache/whisper/inner"] {
        try fm.createDirectory(at: afile(rel), withIntermediateDirectories: true)
        try "payload".write(to: afile(rel).appendingPathComponent("model.bin"),
                            atomically: true, encoding: .utf8)
    }
    try fm.createDirectory(at: afile("Documents"), withIntermediateDirectories: true)
    // 对抗：软链指向 ~/Documents，试图借它搬走别处的东西
    try fm.createSymbolicLink(atPath: afile("lnk").path,
                              withDestinationPath: afile("Documents").path)

    setenv("DISKWISE_HOME_SHIM", ahome.path, 1)
    // 关键：判词索引必须在 setenv 之后建——.shared 在首次访问时已把 ~ 展开
    // 到当时的家目录，假家目录下的路径只有「事后自建」的索引才认得
    let aidx = VerdictIndex(entries: loadSafetyEntries(from: _dbURL))

    // 15.1 判定管线的每条出口
    let xp = await agentExplain(path: "~/.cache/whisper", index: aidx)
    check(xp.agentMayTrash && xp.tier == "safe" && xp.exact && xp.refusal == nil,
          "Agent：safe 条目本体可动（\(xp.refusal?.rawValue ?? "ok")）")
    let inner = await agentExplain(path: "~/.cache/whisper/inner", index: aidx)
    check(!inner.agentMayTrash && inner.refusal == .notAKnownLocation && inner.humanMayTrash,
          "Agent：认识位置的子路径拒 not_a_known_location，--i-am-human 可动")
    let rsky = await agentExplain(path: "~/Library/Developer/Xcode/Archives", index: aidx)
    check(!rsky.agentMayTrash && !rsky.humanMayTrash && rsky.refusal == .mayLoseData,
          "Agent：risky 条目人与 agent 都拒 may_lose_data")
    let unk = await agentExplain(path: "~/my-stuff", index: aidx)
    check(!unk.agentMayTrash && unk.refusal == .unknownToKnowledgeBase && unk.humanMayTrash,
          "Agent：知识库外路径拒 unknown_to_knowledge_base")
    let docs = await agentExplain(path: "~/Documents", index: aidx)
    check(docs.refusal == .protected && !docs.agentMayTrash, "Agent：~/Documents 整体 protected")
    let usr = await agentExplain(path: "/usr/local/x", index: aidx)
    check(usr.refusal == .outsideAllowed,
          "Agent：/usr/local/x 报 outside_allowed（不因不存在报 not_found）")
    let miss = await agentExplain(path: "~/no-such-dir", index: aidx)
    check(miss.refusal == .notFound, "Agent：家目录里不存在的路径 not_found")
    let lnk = await agentExplain(path: "~/lnk", index: aidx)
    check(lnk.refusal == .symlink, "Agent：指向 Documents 的软链拒 symlink")
    let dotdot = await agentExplain(path: "~/.cache/../Documents", index: aidx)
    check(dotdot.refusal == .protected, "Agent：.. 词法折叠后按真实位置判 protected")
    let redo = await agentExplain(path: "~/.ollama/models", index: aidx)
    check(redo.agentMayTrash && redo.tier == "redo",
          "Agent：redo 条目（模型权重）可动但 tier 如实标注")

    // 15.2 scan：与缓存页同一个宇宙，产出的路径天然 exact
    let devScan = await agentScan(category: .dev, minBytes: 0, index: aidx)
    check(devScan.contains { $0.path == afile(".cache/whisper").path && $0.agentMayTrash },
          "Agent scan(dev) 含 whisper 且可动")
    // 断言只限定假家目录内的结果：知识库里有绝对系统路径的条目（模拟器运行时
    // 资产那类），scan 会在真机上如实解析出来并标 outside_allowed——那是产品
    // 行为，不该让断言依赖这台机器上装没装模拟器
    let devFake = devScan.filter { $0.path.hasPrefix(ahome.path) }
    check(devFake.allSatisfy { $0.exact },
          "Agent scan 的路径全是知识库条目本体（非 exact：\(devFake.filter { !$0.exact }.map(\.path))）")
    check(devScan.filter { !$0.path.hasPrefix(ahome.path) }
              .allSatisfy { !$0.agentMayTrash },
          "Agent scan：家目录与临时区之外的位置（系统区的知识库条目）一律不可动")
    let appsScan = await agentScan(category: .apps, index: aidx)
    check(appsScan.allSatisfy { $0.path != afile(".cache/whisper").path },
          "Agent scan(apps) 不含 dev 条目")

    // 15.3 plan → execute → undo 全链路（trash 注入假实现）
    let fakeTrashDir = aroot.appendingPathComponent("fake-trash")
    func fakeTrash(_ u: URL) throws -> URL {
        try fm.createDirectory(at: fakeTrashDir, withIntermediateDirectories: true)
        let dst = fakeTrashDir.appendingPathComponent(u.lastPathComponent)
        try fm.moveItem(at: u, to: dst)
        return dst
    }
    let plan1 = try await agentPlan(paths: ["~/.cache/whisper"], index: aidx)
    check(plan1.items.count == 1 && plan1.totalBytes > 0, "Agent plan：1 项、字节为实测值")
    let res1 = try agentExecute(planId: plan1.planId, index: aidx, trash: fakeTrash)
    check(res1.trashed.count == 1 && res1.failed.isEmpty, "Agent execute：搬走 1 项零失败")
    check(!fm.fileExists(atPath: afile(".cache/whisper/model.bin").path), "Agent：原文件已不在原处")
    check(fm.fileExists(atPath: fakeTrashDir.appendingPathComponent("whisper/model.bin").path),
          "Agent：文件进了（假）废纸篓")
    check(agentHistory(limit: 10).count == 1 && agentHistory(limit: 10)[0].undoneAt == nil,
          "Agent：操作日志记了 1 笔且未撤销")
    let undo1 = try agentUndo()
    check(undo1.count == 1 && undo1[0].status == "restored", "Agent undo：恢复 1 项")
    check(fm.fileExists(atPath: afile(".cache/whisper/model.bin").path), "Agent：文件回到原处")
    check(agentHistory(limit: 10)[0].undoneAt != nil, "Agent：撤销标记回填且不改写原行")
    check((try? agentUndo()) == nil, "Agent：没有可撤销的操作时抛 no_undoable_operation")

    // 15.4 计划生成后调包成软链：该项拒绝、其余照做（部分成功语义）
    let plan2 = try await agentPlan(paths: ["~/.cache/whisper", "~/.ollama/models"], index: aidx)
    try fm.removeItem(at: afile(".ollama/models"))
    try fm.createSymbolicLink(atPath: afile(".ollama/models").path,
                              withDestinationPath: afile("Documents").path)
    let res2 = try agentExecute(planId: plan2.planId, index: aidx, trash: fakeTrash)
    check(res2.trashed.count == 1 && res2.failed.contains { $0.reason == "symlink" },
          "Agent：调包成软链的项拒绝、其余照做（trashed=\(res2.trashed.map(\.original)) failed=\(res2.failed.map(\.reason))）")
    _ = try agentUndo()

    // 15.5 inode 绑定：路径还在、判词没变，但内容被原地换过
    let plan3 = try await agentPlan(paths: ["~/.cache/whisper"], index: aidx)
    try fm.removeItem(at: afile(".cache/whisper"))
    try fm.createDirectory(at: afile(".cache/whisper"), withIntermediateDirectories: true)
    try "other".write(to: afile(".cache/whisper/model.bin"), atomically: true, encoding: .utf8)
    let res3 = try agentExecute(planId: plan3.planId, index: aidx, trash: fakeTrash)
    check(res3.trashed.isEmpty && res3.failed.contains { $0.reason == "changed_since_plan" },
          "Agent：原地换内容被 inode 绑定拦下")

    // 15.6 过期与伪造：直接改计划文件的 expires_at（落盘结构是公开的磁盘格式）
    let plan4 = try await agentPlan(paths: ["~/.cache/whisper"], index: aidx)
    let plan4URL = agentPlansDir().appendingPathComponent("\(plan4.planId).json")
    var rec4 = try JSONDecoder.agentAPI.decode(AgentPlanRecord.self,
                                               from: Data(contentsOf: plan4URL))
    rec4.expiresAt = Date().addingTimeInterval(-60)
    try JSONEncoder.agentAPI.encode(rec4).write(to: plan4URL)
    check((try? agentExecute(planId: plan4.planId, index: aidx, trash: fakeTrash)) == nil,
          "Agent：过期计划抛 plan_expired")
    check((try? agentExecute(planId: "not-a-plan", index: aidx, trash: fakeTrash)) == nil,
          "Agent：伪造 plan_id 抛 plan_not_found")
    check((try? agentExecute(planId: "../evil", index: aidx, trash: fakeTrash)) == nil,
          "Agent：plan_id 带路径段一律 plan_not_found（不拼路径）")

    // 15.7 条数上限：201 个可动位置一次 plan → plan_too_large
    for k in 1...201 {
        try fm.createDirectory(at: ahome.appendingPathComponent("bulk/t\(k)"),
                               withIntermediateDirectories: true)
    }
    let bulkPaths = (1...201).map { "~/bulk/t\($0)" }
    do {
        _ = try await agentPlan(paths: bulkPaths, humanOverride: true, index: aidx)
        check(false, "Agent：201 项计划应抛 plan_too_large")
    } catch AgentAPIError.planTooLarge {
        check(true, "Agent：201 项计划抛 plan_too_large")
    } catch {
        check(false, "Agent：201 项计划抛了别的错：\(error)")
    }

    // 15.8 废纸篓里已不在的项：gone_from_trash，不算失败也不挡其余
    let plan5 = try await agentPlan(paths: ["~/.cache/whisper"], index: aidx)
    _ = try agentExecute(planId: plan5.planId, index: aidx, trash: fakeTrash)
    try fm.removeItem(at: fakeTrashDir.appendingPathComponent("whisper"))
    let undo5 = try agentUndo()
    check(undo5.count == 1 && undo5[0].status == "gone_from_trash",
          "Agent：废纸篓里已不在报 gone_from_trash")

    // 15.9 来源标注：client 落操作日志；不带 client 的旧行照常解析（向后兼容）
    try fm.createDirectory(at: afile(".cache/whisper"), withIntermediateDirectories: true)
    try "again".write(to: afile(".cache/whisper/model.bin"), atomically: true, encoding: .utf8)
    let plan6 = try await agentPlan(paths: ["~/.cache/whisper"], index: aidx)
    _ = try agentExecute(planId: plan6.planId, index: aidx,
                         client: "selftest-agent", trash: fakeTrash)
    check(agentHistory(limit: 10).last?.client == "selftest-agent",
          "Agent：操作日志记录来源客户端")
    _ = try agentUndo()
    let opsFile = agentStateDir().appendingPathComponent("operations.jsonl")
    let legacyFH = try FileHandle(forWritingTo: opsFile)
    try legacyFH.seekToEnd()
    try legacyFH.write(contentsOf: Data("{\"id\":\"legacy-op\",\"at\":\"2026-01-01T00:00:00Z\",\"items\":[]}\n".utf8))
    try legacyFH.close()
    let histLegacy = agentHistory(limit: 10)
    check(histLegacy.contains { $0.id == "legacy-op" && $0.client == nil && $0.undoneAt == nil },
          "Agent：旧格式日志行（无 client 字段）照常解析")

    unsetenv("DISKWISE_HOME_SHIM")
    try? fm.removeItem(at: aroot)
}
let agentDone = DispatchSemaphore(value: 0)
Task.detached {
    do {
        try await agentSelfTest()
    } catch {
        check(false, "Agent 节自身抛错：\(error)")
        unsetenv("DISKWISE_HOME_SHIM")
    }
    agentDone.signal()
}
agentDone.wait()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)