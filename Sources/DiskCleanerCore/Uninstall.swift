import Foundation

// ══ 卸载 App：一台机器上装着什么，以及哪几处数据确实属于某一个 App ══
//
// 这一页只回答一个问题：「把这个 App 连同它留下的东西一起搬走，要动哪几处」。
// 它跟卸载残留页共用同一份 App 盘点和同一份「App 数据可能待在哪」的清单，
// 但两边的匹配口径相反：
//   · 卸载残留页找的是**没主**的目录，宁可漏报——猜错了只是少显示一行；
//   · 卸载页找的是**某个 App 的**目录，宁可少认——多认一条，用户点一次卸载
//     就删掉了别的 App 的数据。所以那边允许 token 包含这类模糊判断，这里一条都不许。
//
// 2.1 的范围刻意窄：只动家里（`~/Library` 下那几处）和 App 本体，不碰 `/Library`，
// 不调管理员；一次只卸一个 App；删就是搬进废纸篓，跟着现有的整页撤销走。

// ── 已装 App 的盘点 ────────────────────────────────────────────────────────

/// 一个装着的 App。`id` 用解析过符号链接的真实路径：同一份 App 被链进
/// `~/Applications` 时只算一个，列表也不会出现两行点哪行都一样的怪事。
public struct InstalledApp: Identifiable, Sendable, Hashable {
    public let id: String
    /// Finder 里那个名字（去掉 `.app`）。用户认的是这个，不是包名。
    public var name: String
    /// 小写包名；`Info.plist` 没写就是空串（那种 App 只能按名字认）。
    public var bundleID: String
    /// 摆着这个 App 的那条路径（可能是 `~/Applications` 里的符号链接）。
    public var path: URL
    /// 有 App Store 的收据。界面上据此说「卸了也能从 App Store 免费装回来」。
    public var isAppStore: Bool
    /// 这一份搬得走吗：系统目录里的不算；父目录不可写（非管理员）也不算。
    /// 卸载页只列 `canUninstall` 为真的——列出来却搬不动，比不列更糟。
    public var canUninstall: Bool
    /// 这一行是从符号链接列出来的，不是 App 本体。只当「装着」的凭据，不进卸载列表。
    var isLink: Bool = false
}

/// 一次盘点。卸载页拿它当「卸哪一个」的列表，残留页拿它当「哪些数据还算有主」的基准。
public struct AppInventory: Sendable {
    public var apps: [InstalledApp]
    /// 弱匹配用的词：App 名、包名、以及拆出来的段。**只有残留页读它**。
    public var tokens: Set<String>
    /// 包名本身。残留页最后那道分段判断要拿它比对。
    public var bundleIDs: Set<String>

    public var appCount: Int { apps.count }

    public func app(id: String) -> InstalledApp? { apps.first { $0.id == id } }

    /// 强匹配：这条目录（`~/Library/Caches/com.foo.bar` 的最后一节）是不是就属于这些 App。
    ///
    /// 三条判据，一条都不能松：
    /// 1. 目录名 == 包名（`com.tencent.xinWeChat`）；
    /// 2. 目录名以「包名 + 点」开头（`com.microsoft.Word.helper`）——加这个点，
    ///    是为了不把 `com.foo.bar2` 认成 `com.foo.bar` 的；
    /// 3. 目录名 == App 名去空格小写（`googlechrome`）。
    ///
    /// 判据里没有「包含」「相似」：那些留给残留页。返回**全部**认领者，是因为
    /// 两个以上 App 都认领的目录谁都不能删（见 `scanUninstall`）。
    public func strongMatches(_ dirName: String) -> [InstalledApp] {
        let key = appDataKey(dirName)
        guard !key.isEmpty else { return [] }
        return apps.filter { app in
            if !app.bundleID.isEmpty {
                if key == app.bundleID { return true }
                if key.hasPrefix(app.bundleID + ".") { return true }
            }
            let named = appNameKey(app.name)
            return !named.isEmpty && key == named
        }
    }
}

func stripTeamID(_ s: String) -> String {
    if s.count > 11, s[s.index(s.startIndex, offsetBy: 10)] == ".",
       s.prefix(10).allSatisfy({ $0.isLetter || $0.isNumber }) {
        return String(s.dropFirst(11))
    }
    return s
}

/// 拆出长度 ≥4 的词。`com.tencent.xinWeChat` → `com / tencent / xinwechat`。
/// 只给残留页的弱匹配用；卸载页不做这种拆分比对。
func splitTokens(_ s: String) -> [String] {
    s.lowercased().split { ". -_".contains($0) }.map(String.init).filter { $0.count >= 4 }
}

/// 目录名 → 比对键。`ABC1234567.com.foo.bar` 那种带 Team ID 的组目录先去掉前缀，
/// 否则同一个 App 的 Group Containers 永远对不上它的包名（2026-09-27 实测写的是
/// `HUAQ24HBR6.dev.orbstack`，真包名并不带这十位）。
func appDataKey(_ dirName: String) -> String {
    stripTeamID(dirName).lowercased().trimmingCharacters(in: .whitespaces)
}

/// App 名 → 比对键。`Google Chrome` 的数据目录叫 `googlechrome`，中间没有那个空格。
func appNameKey(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespaces).lowercased()
        .replacingOccurrences(of: " ", with: "")
}

/// 盘点本机装着的 App。默认就是三个 App 目录；`roots` 是给自检用的同一趟口径。
public func inventoryApps(progress: ScanProgress? = nil) async -> AppInventory {
    let home = homePath()
    return await inventoryApps(at: [applicationsDir(), "/System/Applications", home + "/Applications"],
                               progress: progress)
}

public func inventoryApps(at roots: [String], progress: ScanProgress? = nil) async -> AppInventory {
    // 演示模式下 `applicationsDir()` 本身就是假家目录里的 Applications，别走两遍。
    var seenRoots = Set<String>()
    let dirs = roots.filter { seenRoots.insert(URL(fileURLWithPath: $0).standardizedFileURL.path).inserted }
    // 清单三段：这一趟要翻的就是这几个 App 目录。用户点开卸载页先看到它们在亮，
    // 而不是一句「正在盘点…」——盘点这一步在慢机器上也要一两秒。
    let stations = progress.map { $0.plan(dirs) } ?? []
    var apps: [InstalledApp] = []
    /// 真实路径 → `apps` 里的位置。同一份 App 被链进两个 App 目录时只留一条。
    var slot: [String: Int] = [:]
    var tokens = Set<String>(), bundleIDs = Set<String>()
    for (k, root) in dirs.enumerated() {
        let si = k < stations.count ? stations[k] : -1
        if si >= 0 { progress?.enter(si) }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        progress?.walk(files: names.count, bytes: 0, in: root)
        for a in names where a.hasSuffix(".app") {
            let url = URL(fileURLWithPath: (root as NSString).appendingPathComponent(a))
            let isLink = (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
            let real = url.resolvingSymlinksInPath().path
            let name = String(a.dropLast(4)).trimmingCharacters(in: .whitespaces)
            let info = url.appendingPathComponent("Contents/Info.plist").path
            var bid = ""
            if let data = try? Data(contentsOf: URL(fileURLWithPath: info)),
               let pl = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let raw = pl["CFBundleIdentifier"] as? String, !raw.isEmpty {
                // 包名自己也可能带 Team ID（本机实测 DingTalk 写的是
                // `5zsl2cju2t.com.dingtalk.mac`）。目录那一侧会去掉这十位，
                // 两边不去同一种前缀就永远对不上。
                bid = appDataKey(raw)
                tokens.insert(raw.lowercased())
            }
            // 名字与包名都进弱匹配的词表：残留页靠它们认「这堆数据像不像某个已装 App 的」。
            let stem = name.lowercased()
            tokens.insert(stem.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: ""))
            tokens.formUnion(splitTokens(stem))
            if !bid.isEmpty {
                bundleIDs.insert(bid)
                tokens.insert(bid)
                tokens.formUnion(splitTokens(bid))
            }
            let isSystem = URL(fileURLWithPath: root).standardizedFileURL.path == "/System/Applications"
            let receipt = url.appendingPathComponent("Contents/_MASReceipt/receipt").path
            let app = InstalledApp(
                id: real,
                name: name,
                bundleID: bid,
                path: url,
                isAppStore: FileManager.default.fileExists(atPath: receipt),
                // 符号链接不进卸载列表：搬走的是链接本身，真 App 还留在盘上，
                // 而它的数据已经被删干净了——那是最坏的一种「卸了一半」。
                canUninstall: !isSystem && !isLink && isDeletable(url)
                    && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path),
                isLink: isLink)
            // 同一份 App 可能被链进两个 App 目录：留本体那条，不留链接那条。
            // 不立这条规矩的话，谁先被列出来取决于目录项顺序，同一台机器两次盘点
            // 可能给出两种 `canUninstall`。
            if let i = slot[real] {
                if apps[i].isLink && !isLink { apps[i] = app }
                continue
            }
            slot[real] = apps.count
            apps.append(app)
        }
        if si >= 0 { progress?.finish(si, bytes: 0) }
        if Task.isCancelled { break }
    }
    apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return AppInventory(apps: apps, tokens: tokens, bundleIDs: bundleIDs)
}

// ── App 的数据可能待在哪 ──────────────────────────────────────────────────

/// `~/Library` 下会留下 App 数据的几处。卸载页和卸载残留页走**同一份清单**：
/// 两份只要在「哪些地方算一处」上分叉，就会出现一页看得见、另一页看不见的目录。
///
/// `/Library`（系统级）刻意不在内：那一层要管理员权限，而 2.1 的承诺是
/// 「只动你自己的东西、不弹密码」。
public struct LibraryLocation {
    /// 界面上那一处叫什么（`Application Support` 等，本来就是英文，不进词表）
    public var label: String
    /// 家目录下的相对路径
    public var subpath: String
    /// dir | plist | state | file
    public var kind: String
    /// safe | warn
    public var level: String
}

public let appDataLocations: [LibraryLocation] = [
    LibraryLocation(label: "Application Support", subpath: "Library/Application Support", kind: "dir", level: "warn"),
    LibraryLocation(label: "Group Containers", subpath: "Library/Group Containers", kind: "dir", level: "warn"),
    LibraryLocation(label: "Preferences", subpath: "Library/Preferences", kind: "plist", level: "warn"),
    LibraryLocation(label: "Containers", subpath: "Library/Containers", kind: "dir", level: "safe"),
    LibraryLocation(label: "Caches", subpath: "Library/Caches", kind: "dir", level: "safe"),
    LibraryLocation(label: "Saved Application State", subpath: "Library/Saved Application State", kind: "state", level: "safe"),
    LibraryLocation(label: "HTTPStorages", subpath: "Library/HTTPStorages", kind: "file", level: "safe"),
    LibraryLocation(label: "WebKit", subpath: "Library/WebKit", kind: "dir", level: "safe"),
    LibraryLocation(label: "Logs", subpath: "Library/Logs", kind: "dir", level: "safe"),
    LibraryLocation(label: "Application Scripts", subpath: "Library/Application Scripts", kind: "dir", level: "safe"),
    // 第 11 处（稿子④，2026-09-30 拍板「只加一行」）：App 卸载了、它的自启动还留着。
    // 这一档不是「列全自启动项」——那是启动管理工具的事；这里要的正是没主的那几个 plist。
    // 系统态那两个目录（/Library/LaunchAgents、/Library/LaunchDaemons）不接：09-30 实测
    // 沙盒里读得到，但本机那 3 条属于**在装**的软件（搜狗、OrbStack），「残留」这个语义
    // 在它们身上不成立。
    LibraryLocation(label: "LaunchAgents", subpath: "Library/LaunchAgents", kind: "plist", level: "warn"),
]

/// 在某一处里列一级条目，把条目名还原成「比对用的原名」：
/// `com.foo.bar.plist` → `com.foo.bar`，`com.foo.bar.savedState` → `com.foo.bar`。
/// 只认这几处该有的形态（`Preferences` 里不是 plist 的、`Containers` 里不是目录的），
/// 免得把同一处里别的东西也当成 App 数据。
public func firstLevelEntries(_ loc: LibraryLocation, root: String) -> [(stem: String, path: String)] {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
    var out: [(stem: String, path: String)] = []
    for n in names.sorted() {
        if n.hasPrefix(".") { continue }
        let p = (root as NSString).appendingPathComponent(n)
        var stem: String
        switch loc.kind {
        case "plist":
            guard n.lowercased().hasSuffix(".plist") else { continue }
            stem = String(n.dropLast(6))
        case "state":
            guard n.hasSuffix(".savedState") else { continue }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            stem = String(n.dropLast(11))
        case "file":
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue else { continue }
            stem = n
        default:
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            stem = n
        }
        // 这几处按包名走，别把 `pip`、`Homebrew` 这类工具目录也算成 App 名里的词。
        if loc.label == "Caches" || loc.label == "HTTPStorages" || loc.label == "Containers"
            || loc.label == "Saved Application State" || loc.label == "LaunchAgents" {
            if !stem.contains(".") { continue }
        }
        out.append((stem, p))
    }
    return out
}

// ── 单个 App 的卸载清单 ────────────────────────────────────────────────────

/// 一行要搬走的数据。实体在 `path`，勾不勾在 `selected`——风险档默认只勾「删了会自己重建」的那批。
public struct AppDataItem: Identifiable, Sendable {
    public var id: String { path.path }
    /// 真实目录名 / 文件名（`com.foo.bar`），界面原样印，不翻译
    public var name: String
    /// 留在哪一处（`Caches` 等）
    public var loc: String
    public var path: URL
    public var size: Int64?
    public var files: Int
    public var newest: Date?
    /// safe | warn。跟卸载残留页同一套两档：safe 默认勾上，warn 要用户自己判。
    public var level: String
    public var selected: Bool
}

/// 一个 App 的卸载计划。本体不在 `items` 里：它总是要搬的，不需要勾。
public struct AppUninstallPlan: Sendable {
    public var app: InstalledApp
    /// 本体占多少；没量到（被取消、读不动）就是 nil
    public var bundleBytes: Int64?
    public var items: [AppDataItem]
    /// 两个以上已装 App 都认领的目录。不列进可勾选，只用来向用户解释
    /// 「为什么这一处没算给你」——删了这个，另一个 App 就缺一块。
    public var sharedPaths: [URL]

    public var selectedBytes: Int64 { items.reduce(0) { $0 + ($1.selected ? ($1.size ?? 0) : 0) } }
    public var dataBytes: Int64 { items.reduce(0) { $0 + ($1.size ?? 0) } }
}

/// 量一个 App 的本体 + 它自己的那几处数据。
///
/// `inventory` 由调用方持有：一页只盘一次「装了哪些 App」，之后点哪个 App 都拿它来认。
/// 这一步会递归量本体（一个 Xcode 就是几个 GB、上百万个文件），所以一次只做一个 App——
/// 列表页不该为了显示体积先把每个 App 都量一遍。
public func scanUninstall(_ app: InstalledApp, inventory: AppInventory,
                          progress: ScanProgress? = nil) async -> AppUninstallPlan {
    let home = homePath()
    let locPaths = appDataLocations.map { (home as NSString).appendingPathComponent($0.subpath) }
    let stations = progress.map { $0.plan([app.path.path] + locPaths) } ?? []
    var bundleBytes: Int64? = nil
    if Task.isCancelled {
        return AppUninstallPlan(app: app, bundleBytes: nil, items: [], sharedPaths: [])
    }
    if !stations.isEmpty { progress?.enter(stations[0]) }
    let b = await pathStat(app.path, progress: progress)
    bundleBytes = b.bytes
    if !stations.isEmpty { progress?.finish(stations[0], bytes: b.bytes) }

    var cands: [(loc: String, level: String, path: String, name: String)] = []
    var shared: [URL] = []
    for (k, loc) in appDataLocations.enumerated() {
        let si = k + 1 < stations.count ? stations[k + 1] : -1
        if si >= 0 { progress?.enter(si) }
        let entries = firstLevelEntries(loc, root: locPaths[k])
        progress?.walk(files: entries.count, bytes: 0, in: locPaths[k])
        for e in entries {
            let owners = inventory.strongMatches(e.stem)
            guard owners.contains(where: { $0.id == app.id }) else { continue }
            // 两个以上 App 都认领：谁都不删。它可能真是两个 App 共用的（同一家
            // 厂商的套件共用 Group Container），删掉一家，另一家下次启动就少数据。
            if owners.count > 1 {
                shared.append(URL(fileURLWithPath: e.path))
                continue
            }
            cands.append((loc.label, loc.level, e.path, e.stem))
        }
        if si >= 0 { progress?.finish(si, bytes: 0) }
        if Task.isCancelled { break }
    }

    // 清单上这一段是「逐个量」。短名就是那一处的目录名，用户看得出正在量什么。
    let itemStations = progress.map { $0.plan(cands.map(\.path)) } ?? []
    var items: [AppDataItem] = []
    await withTaskGroup(of: AppDataItem?.self) { group in
        for (k, c) in cands.enumerated() {
            group.addTask {
                let si = k < itemStations.count ? itemStations[k] : -1
                if si >= 0 { progress?.enter(si) }
                if Task.isCancelled { return nil }
                let u = URL(fileURLWithPath: c.path)
                let st = await pathStat(u, progress: progress)
                if si >= 0 { progress?.finish(si, bytes: st.bytes) }
                guard st.bytes > 0 else { return nil }
                return AppDataItem(name: c.name, loc: c.loc, path: u, size: st.bytes,
                                   files: st.files, newest: st.newest,
                                   level: c.level, selected: c.level == "safe")
            }
        }
        for await r in group {
            if let r { items.append(r) }
        }
    }
    items.sort { ($0.size ?? 0) > ($1.size ?? 0) }
    return AppUninstallPlan(app: app, bundleBytes: bundleBytes, items: items, sharedPaths: shared)
}
