import Foundation
import AppKit
import Darwin

// ── 目录占盘统计：st_blocks*512 实际占盘（删掉后真能拿回的空间），与 Python 版同口径 ──

public func dirSize(_ url: URL) async -> Int64 {
    var total: Int64 = 0
    var seen = Set<String>()   // 硬链接去重（dev+ino）
    var stack = [url.path]
    let fm = FileManager.default
    let rootDev = deviceOf(url)
    var ticks = 0
    while let dir = stack.popLast() {
        if Task.isCancelled { break }
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
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
            total += Int64(st.st_blocks) * 512
            ticks += 1
            if ticks % 5000 == 0 && Task.isCancelled { break }
        }
    }
    return total
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
    public var free: Int64
    public var used: Int64 { total - free }
}

/// 演示盘容量：`DISKWISE_DEMO_USAGE=<总GB>:<可用GB>`。
///
/// 只在假家目录生效。环形图的「未覆盖」是拿整盘已用减去扫到的量，
/// 不钉住盘容量的话，README 那几张图的主角数字就取决于跑脚本的人那天盘里剩多少——
/// 说好的可复现就没了。
private func demoVolume() -> VolumeUsage? {
    guard homeIsDemo,
          let raw = ProcessInfo.processInfo.environment["DISKWISE_DEMO_USAGE"],
          !raw.isEmpty else { return nil }
    let parts = raw.split(separator: ":")
    guard parts.count == 2,
          let t = Double(parts[0]), let f = Double(parts[1]), t > f, f >= 0 else { return nil }
    let gib = Int64(1024 * 1024 * 1024)
    return VolumeUsage(total: Int64(t * Double(gib)), free: Int64(f * Double(gib)))
}

public func volumeUsage() -> VolumeUsage? {
    if let demo = demoVolume() { return demo }
    guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
          let total = attrs[.systemSize] as? Int64,
          let free = attrs[.systemFreeSize] as? Int64 else {
        return nil
    }
    return VolumeUsage(total: total, free: free)
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

    /// 交给 L() 查词表的源文案
    public var reasonKey: String {
        switch self {
        case .protected: return "系统保护路径，不能整体删除"
        case .outsideAllowed: return "超出允许范围（仅限家目录与 /Applications）"
        case .failed: return "移入废纸篓失败"
        case .noTrashLocation: return "系统未返回废纸篓位置"
        case .noFinderScript: return "无法创建访达指令"
        case .finderRefused: return "访达拒绝执行"
        }
    }

    /// 路径或系统原话，不翻译
    public var detail: String {
        switch self {
        case .protected(let s), .outsideAllowed(let s), .failed(let s), .finderRefused(let s): return s
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

/// 清空废纸篓交给访达执行（系统层面再确认一次；首次需授权自动化）
public func emptyTrashViaFinder() throws {
    let src = "tell application \"Finder\" to empty the trash"
    guard let script = NSAppleScript(source: src) else {
        throw TrashError.noFinderScript
    }
    var err: NSDictionary?
    script.executeAndReturnError(&err)
    if let e = err {
        throw TrashError.finderRefused("\(e[NSAppleScript.errorMessage as String] ?? "")")
    }
}
