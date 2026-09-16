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

// 2. 路径可移植展开
let home = NSHomeDirectory()
check(expandHome("~/.npm") == home + "/.npm", "展开 ~")
check(expandHome("$HOME/.npm") == home + "/.npm", "展开 $HOME")
check(expandHome("/Users/别人/Library/Caches") == home + "/Library/Caches", "改写别人的 /Users 前缀")
check(expandHome("/Applications/X.app") == "/Applications/X.app", "系统路径不动")

// 2.5 容量格式化（回归：单位错位曾把 6GB 显示成 6TB）
check(human(500) == "500 B", "500 B")
check(human(1500) == "1.5 KB", "1500 → 1.5 KB")
check(human(6_200_000_000) == "5.8 GB", "6.2e9 → 5.8 GB 而不是 TB")
check(human(2 * 1024 * 1024) == "2.0 MB", "2MiB → 2.0 MB")

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

// 6. 占盘统计：2MB 文件 + 1 个符号链接（链接不重复计）
let sbase = fm.temporaryDirectory.appendingPathComponent("sizetest-\(UUID().uuidString)")
try! fm.createDirectory(at: sbase, withIntermediateDirectories: true)
let big = sbase.appendingPathComponent("big.bin")
try! Data(count: 2 * 1024 * 1024).write(to: big)
try! fm.createSymbolicLink(at: sbase.appendingPathComponent("link.bin"), withDestinationURL: big)
let sem = DispatchSemaphore(value: 0)
Task {
    let sz = await dirSize(sbase)
    check(sz >= 2 * 1024 * 1024 && sz < 3 * 1024 * 1024, "占盘约 2MB（得 \(sz)，链接未重复计）")
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
let sem2 = DispatchSemaphore(value: 0)
Task {
    let rows = await walkFiles(dirs: [dbase])
    check(rows.count == 3, "遍历到 3 个文件")
    let gs = findDupGroups(rows)
    check(gs.count == 1 && gs[0].files.count == 2, "检出 1 组重复（a/b），c 不在其中")
    try? fm.removeItem(at: dbase)
    sem2.signal()
}
sem2.wait()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)