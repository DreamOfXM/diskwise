import Foundation

// ── 家目录访问权 ──
//
// 进沙盒以后，Foundation 的 NSHomeDirectory() 和 homeDirectoryForCurrentUser 都会被
// 改写成 ~/Library/Containers/<bundle id>/Data。拿它当扫描根不会报错，而是安静地扫一个
// 空壳——总览页显示「几乎没东西」，这比崩掉坏得多。所以：
//   1. 真实家目录只从 passwd 取（见 realHomeDir）；
//   2. 沙盒里能不能读它，取决于用户有没有通过授权面板给过 security-scoped bookmark；
//   3. 没给到之前，界面只显示授权页，不显示任何扫描结果。

/// 不受容器改写的真实家目录。
public func realHomeDir() -> URL {
    guard let pw = getpwuid(getuid()) else {
        return FileManager.default.homeDirectoryForCurrentUser
    }
    return URL(fileURLWithPath: String(cString: pw.pointee.pw_dir), isDirectory: true)
}

public enum HomeAccess {
    static let bookmarkKey = "diskwise.home.bookmark"

    /// 用户授权过的目录。非沙盒渠道永远是 nil，homeDir() 直接走真实家目录。
    public private(set) static var granted: URL?
    private static var accessing: URL?

    /// 当前进程是否跑在沙盒里。运行时判定，不靠编译开关——同一个二进制在两种环境下
    /// 都该表现正确，而且容器路径本身就是最直接的证据。
    public static var runsSandboxed: Bool {
        FileManager.default.homeDirectoryForCurrentUser.path.contains("/Library/Containers/")
    }

    /// 需要授权但还没拿到，界面就该停在授权页。
    public static var needsGrant: Bool { runsSandboxed && granted == nil }

    /// 用户从授权面板里选完目录后由 UI 层调用：存书签 + 当场持有访问权。
    /// 返回 false 说明系统没给到 security scope，界面得提示重试而不是假装成功。
    @discardableResult
    public static func grant(_ url: URL) -> Bool {
        guard let data = try? bookmarkData(for: url) else { return false }
        // 实测：面板返回的那个 URL 直接 startAccessing 会给出 false，
        // 必须把刚写下的书签解析回来、拿解析出的 URL 去访问才认。
        var stale = false
        guard let scoped = try? URL(resolvingBookmarkData: data,
                                    options: [.withSecurityScope],
                                    relativeTo: nil, bookmarkDataIsStale: &stale) else { return false }
        guard adopt(scoped) else { return false }
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        return true
    }

    /// 授权完成后由 UI 层调用；会持有 security scope 直到进程退出。
    @discardableResult
    public static func adopt(_ url: URL) -> Bool {
        stopAccessing()
        guard url.startAccessingSecurityScopedResource() else { return false }
        accessing = url
        granted = url.standardizedFileURL
        return true
    }

    static func stopAccessing() {
        if let a = accessing { a.stopAccessingSecurityScopedResource() }
        accessing = nil
    }

    static func bookmarkData(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope],
                             includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// 启动时恢复上次的授权。书签失效（目录被挪走 / App 重新签名换了身份）就清掉存档，
    /// 让界面回到授权页，而不是拿着一个读不到的路径假装扫过了。
    @discardableResult
    public static func restore() -> Bool {
        guard runsSandboxed,
              let raw = UserDefaults.standard.data(forKey: bookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: raw,
                                 options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return false
        }
        if stale {
            if let fresh = try? bookmarkData(for: url) {
                UserDefaults.standard.set(fresh, forKey: bookmarkKey)
            }
        }
        return adopt(url)
    }

    /// 换一台机器或重新签名后书签可能解不开，给用户一个重新授权的出口。
    public static func revoke() {
        stopAccessing()
        granted = nil
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
    }
}

/// 家目录唯一入口。
///
/// 所有取家目录的地方都必须走这里，别再用 NSHomeDirectory()
/// 或 homeDirectoryForCurrentUser——两者在沙盒里都会被改写成容器路径。
///
/// DISKWISE_HOME_SHIM 指到一棵假目录树时，全盘扫描/废纸篓统计都只在那棵树里跑。
/// README 截图靠它，免得把作者的真实目录晒出去。
public func homeDir() -> URL {
    let shim = ProcessInfo.processInfo.environment["DISKWISE_HOME_SHIM"] ?? ""
    if !shim.isEmpty {
        return URL(fileURLWithPath: (shim as NSString).expandingTildeInPath, isDirectory: true)
    }
    if let g = HomeAccess.granted { return g }
    return HomeAccess.runsSandboxed ? realHomeDir() : FileManager.default.homeDirectoryForCurrentUser
}
