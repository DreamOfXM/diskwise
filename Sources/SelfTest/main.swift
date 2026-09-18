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
check(volumeUsage()?.used == 80 * GB, "兜底容量的已用只有 80 GB：演示树撑得起，未覆盖不会虚高成几百 G")
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

// 4c. 扫描范围根：用户区 = 家目录 + /Applications；整盘再加系统白名单，且永远不碰 /System 和 /Volumes
let userRoots = scanRoots(scope: .user)
check(userRoots.contains(homeDir()), "用户区根含家目录")
check(userRoots.contains(URL(fileURLWithPath: applicationsDir(), isDirectory: true)),
      "用户区根含 /Applications（总览页算它，扫描页不能漏）")
let diskRoots = scanRoots(scope: .disk)
check(diskRoots.first == homeDir(), "整盘根的第一项仍是家目录")
check(diskRoots.count > userRoots.count, "整盘根比用户区多（实得 \(diskRoots.count) 项）")
check(!diskRoots.contains { $0.path.contains("/System") || $0.path.contains("/Volumes") },
      "整盘根不含 /System 与 /Volumes")
check(Set(diskRoots.map { $0.path }).count == diskRoots.count, "整盘根没有重复项")

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

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)