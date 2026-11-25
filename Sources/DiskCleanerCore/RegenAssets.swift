import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// 项目内可再生资产：模型权重、依赖目录、构建产物、字节码缓存、历史跑分。
///
/// 为什么单独做这一类：scan_disk 的白名单只认固定缓存路径（~/.cache、~/Library/Caches），
/// 看不到项目内部的 node_modules / .venv / 模型权重 / dist 这些。它们不是缓存，
/// 但同样能重新获取或重建——删了不丢源代码，代价是下次要重新下载或编译。
/// 在一台开发机上这类东西常常比系统缓存大得多，却从来没进过任何清理清单。
///
/// 只读扫描。硬链接按 inode 去重（HuggingFace 的 snapshots/blobs 是硬链接，
/// 不去重会把 9 GB 报成 26 GB）。聚合到「可删除的资产根」，Agent 拿到路径就能
/// 直接 plan_cleanup——只删 snapshots 这类链接是不释放空间的，必须删整个 hub。
public struct RegenAsset: Encodable {
    public let path: String
    public let name: String
    public let bytes: Int64
    public let kind: String       // model_weights | dependency | build_output | bytecode_cache | history
    public let staleDays: Int
    public let freshness: String  // recent | weeks_old | stale | very_stale
    public let restore: String    // 删了以后怎么恢复
    public let note: String

    enum CodingKeys: String, CodingKey {
        case path, name, bytes, kind, restore, note
        case staleDays = "stale_days"
        case freshness
    }
}

public struct RegenAssetsReport: Encodable {
    public let roots: [String]
    public let assets: [RegenAsset]
    public let totalBytes: Int64
    public let assetCount: Int
    public let notes: [String]

    enum CodingKeys: String, CodingKey {
        case roots, assets, notes
        case totalBytes = "total_bytes"
        case assetCount = "asset_count"
    }
}

public enum RegenAssetScanner {

    /// 资产根的名字。文件路径往上找到第一个命中的目录，就把整块归到它名下。
    private static let rootNames: Set<String> = [
        "node_modules", ".pnpm-store", ".venv", "venv", "site-packages",
        ".m2", ".gradle", "Pods", "Carthage", "__pycache__",
        "dist", "build", ".build", "target", "out", ".next", ".nuxt",
        ".svelte-kit", "DerivedData", ".benchmarks", "checkpoints", "weights", "hub",
    ]

    /// 独立的模型权重文件（不在任何资产根里时，按文件自身当资产）。
    private static let modelExts: Set<String> = ["safetensors", "ckpt", "pth", "onnx", "gguf", "bin"]

    private struct Acc {
        var bytes: Int64 = 0
        var newest: time_t = 0
        var files = 0
        var kind = "build_output"
        var restore = "Rebuild with the project's build command."
        var note = "Generated output; safe to delete."
    }

    /// 这些顶层目录不是代码项目：虚拟机磁盘、媒体、下载、用户数据——遍历它们既慢又找不到
    /// 可再生资产（OrbStack 是几十 GB 的虚拟磁盘，进去递归会拖死扫描）。
    private static let skipTopLevel: Set<String> = [
        "Library", "Applications", "Movies", "Music", "Pictures", "Public",
        "Downloads", "Documents", "Desktop", "OrbStack", "QbotBackups",
        "Parallels", "VirtualBox", ".Trash",
    ]

    /// 默认扫家目录顶层的项目目录 + Desktop 直接子目录（代码通常在 Desktop 下）。
    /// 跳过隐藏目录、媒体/虚拟机/下载这类非项目大块。调用方可传 roots 精确覆盖。
    static func defaultRoots(home: String = NSHomeDirectory()) -> [String] {
        let fm = FileManager.default
        func dirs(in dir: String, skip: Set<String>) -> [String] {
            guard let kids = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
            return kids.compactMap { k in
                guard !k.hasPrefix("."), !skip.contains(k) else { return nil }
                let p = (dir as NSString).appendingPathComponent(k)
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue ? p : nil
            }
        }
        var out = dirs(in: home, skip: skipTopLevel)
        // Desktop 本身在 skip 里（避免整棵当一处递归两遍），但它的直接子目录是项目所在
        out += dirs(in: (home as NSString).appendingPathComponent("Desktop"), skip: [])
        return out
    }

    /// 单个根的局部结果，并发扫描后在主线程合并去重。
    private struct Partial {
        var seen = Set<String>()       // dev+inode，硬链接只算一次
        var groups: [String: Acc] = [:]
    }

    private static func scanOne(root: String) -> Partial {
        var p = Partial()
        guard let en = FileManager.default.enumerator(atPath: root) else { return p }
        while let rel = en.nextObject() as? String {
            let full = (root as NSString).appendingPathComponent(rel)
            // 第一道闸：字符串层面先判断是不是资产，不是就零系统调用跳过
            guard let g = assetRoot(for: full) else { continue }
            // 只有命中的文件才 stat：拿体积 + 硬链接身份
            var st = stat()
            guard lstat(full, &st) == 0 else { continue }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFDIR || mode == S_IFLNK { continue }
            let key = "\(st.st_dev)-\(st.st_ino)"
            if p.seen.contains(key) { continue }
            p.seen.insert(key)

            var a = p.groups[g] ?? Acc()
            a.bytes += Int64(st.st_size)
            a.files += 1
            if st.st_mtimespec.tv_sec > a.newest { a.newest = st.st_mtimespec.tv_sec }
            let c = classify(root: g, file: full)
            a.kind = c.kind; a.restore = c.restore; a.note = c.note
            p.groups[g] = a
        }
        return p
    }

    public static func scan(roots: [String]? = nil, minBytes: Int64 = 100_000_000,
                            staleDays: Int = 0) -> RegenAssetsReport {
        let scanRoots = roots ?? defaultRoots()
        let now = time(nil)
        // 并发扫各根（6 路，跟 wholeDiskOverview 一致）：75 个根顺序扫会拖到几分钟。
        // 每根返回局部结果，主线程合并时按 inode 去重（跨根的硬链接也只算一次）。
        var seen = Set<String>()
        var groups: [String: Acc] = [:]
        var i = 0
        while i < scanRoots.count {
            let wave = Array(scanRoots[i..<min(i + 6, scanRoots.count)])
            i += wave.count
            var partials = Array(repeating: Partial(), count: wave.count)
            DispatchQueue.concurrentPerform(iterations: wave.count) { idx in
                partials[idx] = scanOne(root: wave[idx])
            }
            for part in partials {
                for (g, a) in part.groups {
                    var merged = groups[g] ?? Acc()
                    merged.bytes += a.bytes
                    merged.files += a.files
                    if a.newest > merged.newest { merged.newest = a.newest }
                    merged.kind = a.kind; merged.restore = a.restore; merged.note = a.note
                    groups[g] = merged
                }
                seen.formUnion(part.seen)
            }
        }

        let cal = Calendar(identifier: .gregorian)
        let assets: [RegenAsset] = groups.compactMap { path, a in
            guard a.bytes >= minBytes else { return nil }
            let age = max(0, Int((now - a.newest) / 86400))
            guard age >= staleDays else { return nil }
            let fresh: String
            if age < 7 { fresh = "recent" }
            else if age < 30 { fresh = "weeks_old" }
            else if age < 90 { fresh = "stale" }
            else { fresh = "very_stale" }
            _ = cal   // 保留 Calendar 供以后按自然日统计
            return RegenAsset(path: path,
                              name: (path as NSString).lastPathComponent,
                              bytes: a.bytes, kind: a.kind,
                              staleDays: age, freshness: fresh,
                              restore: a.restore, note: a.note)
        }.sorted { $0.bytes > $1.bytes }

        let total = assets.reduce(Int64(0)) { $0 + $1.bytes }
        let notes = [
            "REGENERABLE ASSETS — not system caches. These were downloaded or generated for projects "
                + "(model weights, dependencies, build outputs). Deleting them does NOT remove source "
                + "code or your own files; it only means re-downloading or rebuilding later.",
            "Hard links are deduplicated by inode: HuggingFace snapshots/blobs sharing the same blocks "
                + "are counted once. Delete the whole reported asset root (e.g. hf/hub, not just "
                + "snapshots) or the space will not actually be reclaimed.",
            "Only the reported paths are safe to pass to plan_cleanup. State/runtime data directories "
                + "are deliberately not classified as assets and will not appear here.",
            "Read-only. Freshness is based on the newest file in each asset; 'very_stale' means nothing "
                + "inside was touched in over 90 days.",
        ]
        return RegenAssetsReport(roots: scanRoots, assets: assets, totalBytes: total,
                                 assetCount: assets.count, notes: notes)
    }

    /// 从文件路径往上找可删除的资产根。HuggingFace 布局特殊处理：
    /// blobs/ 和 models--*/snapshots/ 共用硬链接，必须整体归到 hf/hub，
    /// 否则只删 snapshots 不放空间。
    private static func assetRoot(for path: String) -> String? {
        // 快速短路：路径里没有任何资产关键词就直接返回，避免几十万次 split 分配
        var hit = path.contains("/hf/hub/")
        if !hit {
            for name in rootNames where path.contains("/\(name)/") { hit = true; break }
        }
        if !hit {
            let low = (path as NSString).pathExtension.lowercased()
            hit = modelExts.contains(low)
        }
        guard hit else { return nil }
        if let r = hubRoot(for: path) { return r }
        let comps = path.split(separator: "/").map(String.init)
        if let ext = comps.last?.split(separator: ".").last?.lowercased(),
           modelExts.contains(ext), comps.count >= 2 {
            // 独立的权重文件：归到它自己的父目录（若父目录本身不是资产根）
            return "/" + comps.dropLast().joined(separator: "/")
        }
        if comps.count >= 2 {
            for i in stride(from: comps.count - 2, through: 1, by: -1) {
                if rootNames.contains(comps[i]) {
                    return "/" + comps[0...i].joined(separator: "/")
                }
            }
        }
        return nil
    }

    private static func hubRoot(for path: String) -> String? {
        let marker = "/hf/hub/"
        guard let range = path.range(of: marker, options: .backwards) else { return nil }
        let upto = path.index(range.lowerBound, offsetBy: "/hf/hub".count)
        return String(path[..<upto])
    }

    /// 这个资产是什么、删了怎么恢复。判定按「最具体的线索优先」。
    private static func classify(root: String, file: String) -> (kind: String, restore: String, note: String) {
        let low = file.lowercased()
        if low.contains("/hf/hub/") || low.contains("models--") {
            return ("model_weights",
                    "Re-download the model (e.g. huggingface-cli pull or re-run the setup script).",
                    "Model weights. Delete the whole hf/hub directory — snapshots and blobs are hard-linked.")
        }
        let isWeightFile = low.hasSuffix(".safetensors") || low.hasSuffix(".ckpt")
            || low.hasSuffix(".pth") || low.hasSuffix(".onnx") || low.hasSuffix(".gguf")
        if isWeightFile || low.contains("/weights/") || low.contains("/checkpoints/") {
            return ("model_weights", "Re-download or re-export the model weights.",
                    "Model weights; regenerable but may take time/bandwidth to fetch again.")
        }
        if low.contains("/node_modules/") || low.contains(".pnpm-store") {
            return ("dependency", "Run npm/pnpm install again.",
                    "Installed JavaScript dependencies; fully regenerable from the lockfile.")
        }
        if low.contains("/.venv/") || low.contains("/venv/") || low.contains("site-packages") {
            return ("dependency", "Recreate the virtual environment and install requirements.",
                    "Python virtual environment; fully regenerable.")
        }
        if low.contains("/.m2/") || low.contains("/.gradle/") || low.contains("/pods/") || low.contains("/carthage/") {
            return ("dependency", "Re-resolve dependencies with the project's package manager.",
                    "Downloaded dependency cache; fully regenerable.")
        }
        if low.contains("__pycache__") {
            return ("bytecode_cache", "Regenerated automatically on next run.",
                    "Python bytecode cache; safe to delete anytime.")
        }
        if low.contains(".benchmarks") || low.contains("/evidence/") {
            return ("history", "Historical records — deleting loses the old results, not source code.",
                    "Past benchmark/evidence output; check before deleting if you cite these.")
        }
        if low.contains("/.build/") || low.contains("deriveddata") || low.contains("/.next/")
            || low.contains("/.nuxt/") || low.contains(".svelte-kit") || low.contains("tsbuildinfo")
            || low.contains("/target/") || low.contains("/dist/") || low.contains("/build/") || low.contains("/out/") {
            return ("build_output", "Rebuild with the project's build command.",
                    "Build output; regenerable from source.")
        }
        return ("build_output", "Rebuild or re-download as appropriate.",
                "Generated asset; verify the project still needs it before deleting.")
    }
}
