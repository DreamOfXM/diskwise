import Foundation

// ── 扫描范围 ──
//
// 这个 App 卖的是「大文件」，那就得真的覆盖整块盘：只看 ~/Downloads 那类目录
// 等于把 90% 的空间排除在自己的承诺之外，用户按我们的列表清完还是满的。
// 所以范围是一等公民：每个扫描页都从同一份根清单出发，并且把自己扫了哪里写在脸上。

public enum ScanScope: String, CaseIterable, Identifiable {
    /// 家目录（含隐藏项）+ /Applications。沙盒版能稳定拿到的最大范围。
    case user
    /// 用户区 + 系统里普通用户可读的那几块。
    case disk

    public var id: String { rawValue }
}

extension ScanScope {
    /// 这一版实际用的范围——界面上没有开关，只有这一个值。
    ///
    /// 以前这里有两档可选，实测一台机器上就出了事：环形的「其他已统计」按用户区的账画，
    /// 下面的列表按整盘的账列，同一屏两个口径，谁都对不上谁，而「对不上」是直接砸信任的。
    /// 沙盒里整盘又物理上扫不到，留着开关等于留一格点了没反应的选择。所以只走能扫到的最大范围。
    public static var effective: ScanScope { HomeAccess.runsSandboxed ? .user : .disk }
}

/// 家目录之外、普通用户读得动的盘顶位置。
///
/// 走白名单而不是从 `/` 往下爬，因为盘顶那几块各有坑：
/// 密封的 `/System` 只读（SIP 看着，扫它只会让进度条白跑十几 GB），
/// `/Volumes` 会挂进外置盘和时间机器备份盘，`/dev` 是设备结点的家。
/// root-only 的那些（/private/var/db、/private/var/root、.fseventsd）不用列黑名单：
/// `contentsOfDirectory` 失败就自然跳过，不会算成 0 骗人。
///
/// 但 `/System/Volumes/Data/System` 不在那条黑名单里——它是数据卷自己底下的一层，
/// 只是路径长得像系统卷。实测一台机器上它装着 18.9 GB 的 AssetsV2
/// （App Store 与系统更新的下载缓存）。漏掉它，「整盘」就凭空少扫 5%，
/// 而那 5% 正好落进环形「没量到的地方」里，等于把我们自己的疏漏说成盘的账。
///
/// 演示模式下整棵树挪进假家目录，否则 README 的整盘截图会拍到作者的真实盘。
public func systemScanRoots() -> [URL] {
    let base = homeIsDemo ? homePath() : ""
    let names = ["Applications", "Library", "opt", "private", "usr/local",
                 "System/Volumes/Data/System"]
    let roots = names
        .map { URL(fileURLWithPath: base.isEmpty ? "/\($0)" : "\(base)/\($0)", isDirectory: true) }
        .filter(isDirectory)
    return roots + otherHomeRoots(base: base)
}

/// 别人的家目录。整盘要是连它都不算，「没量到的那几十 G」里就有一块我们连提都没提。
/// 只算不删：删除路径由 `isDeletable` 卡死在自己的家目录与 /Applications。
func otherHomeRoots(base: String) -> [URL] {
    let usersDir = URL(fileURLWithPath: base.isEmpty ? "/Users" : "\(base)/Users",
                       isDirectory: true)
    let mine = homeDir().standardizedFileURL.path
    guard let kids = try? FileManager.default.contentsOfDirectory(atPath: usersDir.path)
    else { return [] }
    return kids.sorted()
        .map { usersDir.appendingPathComponent($0).standardizedFileURL }
        .filter { u in
            guard u.path != mine, !u.lastPathComponent.hasPrefix(".") else { return false }
            return isDirectory(u)
        }
}

private func isDirectory(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        && isDir.boolValue
}

/// 某个范围的完整扫描根。家目录本身作为一条，由调用方决定要不要展开一级。
///
/// /Applications 两个范围都在：那是用户自己装 App 的地方，我们的删除路径也覆盖它
/// （见 `isDeletable`）。总览页早就把它算进账，扫描页要是漏了，「大文件」列表第一名
/// 就会跟总览那一行对不上。
public func scanRoots(scope: ScanScope) -> [URL] {
    var out = [homeDir(), URL(fileURLWithPath: applicationsDir(), isDirectory: true)]
    if scope == .disk { out.append(contentsOf: systemScanRoots()) }
    var seen = Set<String>()
    return out.filter { seen.insert($0.standardizedFileURL.path).inserted }
}

/// 文件系统边界。跨卷守卫靠它：不挡住的话，一次「整盘」扫描会顺着挂载点
/// 爬进外置硬盘和时间机器备份盘，既慢又会在别人的盘上算我们的账。
public func deviceOf(_ url: URL) -> dev_t? {
    var st = stat()
    guard stat(url.path, &st) == 0 else { return nil }
    return st.st_dev
}
