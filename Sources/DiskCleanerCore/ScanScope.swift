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

/// 家目录之外、普通用户能读的盘顶目录。
///
/// 走白名单而不是从 `/` 往下爬，因为盘顶那几块各有坑：
/// `/System` 是只读密封卷（SIP 保护，扫它只会让进度条白跑十几 GB），
/// `/Volumes` 会挂进外置盘和时间机器备份盘，`/dev` 是设备结点的家。
/// root-only 的那些（/private/var/db、/private/var/root、.fseventsd）不用列黑名单：
/// `contentsOfDirectory` 失败就自然跳过，不会算成 0 骗人。
///
/// 演示模式下整棵树挪进假家目录，否则 README 的整盘截图会拍到作者的真实盘。
public func systemScanRoots() -> [URL] {
    let base = homeIsDemo ? homePath() : ""
    return ["Applications", "Library", "opt", "private", "Users/Shared", "usr/local"]
        .map { URL(fileURLWithPath: base.isEmpty ? "/\($0)" : "\(base)/\($0)", isDirectory: true) }
        .filter { u in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                && isDir.boolValue
        }
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
