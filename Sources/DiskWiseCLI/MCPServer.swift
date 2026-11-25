import DiskCleanerCore
import Foundation
import AppKit

// MCP server（stdio）：按行分帧的 JSON-RPC 2.0，不引第三方库。
//
// 协议面刻意做窄：initialize / notifications/initialized / tools/list /
// tools/call / ping，其余带 id 的方法回 -32601——未知方法在 MCP 里几乎总是
// 客户端版本差异，明确报错比静默成功安全。
//
// stdout 只写协议帧（调试一律 stderr），业务错误（被拒/过期/超限）用
// isError: true 的**结果**返回而不是 JSON-RPC error：模型要看的是原因码与
// 下一步指引，不是传输层的报错。

// 整盘账：跟「知识库里能删的位置」是两回事。
// scan_disk 只答「哪些缓存可以清」，落在 500 GB 的盘上往往只有几十 GB；
// 拿它当「磁盘空间都去哪了」的答案就会漏掉九成。disk_overview 才答后者：
// 量家目录顶层 + 系统根，给出量到多少、剩多少没量到，以及每块 APFS 卷各占多少。
// 只量不删——删除仍走 plan_cleanup/trash 那条受限的路。
struct WholeDiskLocation: Encodable {
    let path: String
    let name: String
    /// 真占盘（st_blocks×512）。判断「这块能腾多少」只认它。
    let bytes: Int64
    /// 文件大小相加。与 bytes 差一个量级就是稀疏文件——别按它算可清量。
    let logicalBytes: Int64
    /// physical / logical。远小于 1 说明这块里全是「号称很大、实际只占一点」的文件。
    let sparseRatio: Double
    let files: Int
    let unreadable: Bool
    let needFullDiskAccess: Int
    let needAdmin: Int
    /// 这块是什么（user_data / system / developer / app_support / media …）。
    let kind: String
    /// 这一块大致该怎么看：has_removable | review | keep。
    /// 是**粗判**，只按名字和所属位置；逐条建议在 scan_unused 里。
    let recommend: String
    /// 这块里最近一次文件改动距今多少天。-1 = 拿不到。
    ///
    /// 顶层目录几乎总是 0（总有某个文件今天被写过），所以它**不是**「这块还在用」的证据，
    /// 只是「最近有人碰过里面某个文件」。判断新旧请用 scan_unused 的 stale_days。
    let newestFileDays: Int
    /// 因是软链/跨卷而没算进来的条目数——解释「为什么比 Finder 少」。
    let skippedLinks: Int
    let skippedVolumes: Int

    enum CodingKeys: String, CodingKey {
        case path, name, bytes, files, unreadable, kind, recommend
        case logicalBytes = "logical_bytes"
        case sparseRatio = "sparse_ratio"
        case needFullDiskAccess = "need_full_disk_access"
        case needAdmin = "need_admin"
        case newestFileDays = "newest_file_days"
        case skippedLinks = "skipped_symlinks"
        case skippedVolumes = "skipped_volumes"
    }
}

/// 授权状态：哪些目录因为权限读不到、当前有没有「完全磁盘访问」。
/// macOS 不允许程序自己给自己授权，所以这个结构自带 next_step——
/// 告诉调用方（Agent 或人）去哪勾、勾完怎么让新权限生效。
struct AccessStatus: Encodable {
    let hasFullDiskAccess: Bool
    let needFullDiskAccessDirs: Int
    let needAdminDirs: Int
    let settingsURL: String
    let nextStep: String

    enum CodingKeys: String, CodingKey {
        case hasFullDiskAccess = "has_full_disk_access"
        case needFullDiskAccessDirs = "need_full_disk_access_dirs"
        case needAdminDirs = "need_admin_dirs"
        case settingsURL = "settings_url"
        case nextStep = "next_step"
    }
}

/// 整盘账里的一块：有名字、有字节、说明它是什么、能不能删。
/// 要求：所有 bucket 加起来 == used_physical，一块都不许是「没量到」的黑洞。
struct WholeDiskBucket: Encodable {
    let name: String
    let bytes: Int64
    let kind: String        // user_data | system_volume | apfs_internal
    let removable: Bool     // 这个工具能不能动它
    let explanation: String

    enum CodingKeys: String, CodingKey {
        case name, bytes, kind, removable, explanation
    }
}

struct WholeDiskOverview: Encodable {
    let scope: String
    let volume: [String: Int64]
    let apfsVolumes: [String: Int64]
    let coverage: [String: Int64]
    let locations: [WholeDiskLocation]
    /// 闭合账：每块都有归属，总和 == used_physical
    let buckets: [WholeDiskBucket]
    /// 权限读不到的目录 + 授权入口。不是「盘上有黑洞」，是「去哪把这段量回来」。
    let access: AccessStatus
    let notes: [String]

    enum CodingKeys: String, CodingKey {
        case scope, volume, coverage, locations, buckets, access, notes
        case apfsVolumes = "apfs_volumes"
    }
}

enum MCPServer {

    /// 客户端在 initialize 里自报的名字（clientInfo.name），落进操作日志回答
    /// 「这次是谁干的」。没 initialize 就直接调、或没报名字的，记 "mcp"。
    static var clientName = "mcp"

    static func run() async {
        let stdin = FileHandle.standardInput
        var buffer = Data()
        // 同步逐块读 + 手动按 \n 分帧：readabilityHandler 的回调不保证行完整，
        // 而每条消息必须独占一行（MCP stdio 规范，正文不得内嵌换行）
        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }   // EOF：客户端走了，跟着退
            buffer.append(chunk)
            while let idx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<idx]
                buffer = Data(buffer[buffer.index(after: idx)...])
                let line = String(data: lineData, encoding: .utf8) ?? ""
                if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    await handle(line: line)
                }
            }
        }
    }

    // MARK: - 帧处理

    static func handle(line: String) async {
        guard let req = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            reply(id: nil, error: (code: -32700, message: "Parse error"))
            return
        }
        let id = req["id"]
        let method = req["method"] as? String ?? ""
        // 通知（无 id）不回包——回了客户端只会当协议错误
        guard id != nil else { return }
        let params = req["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            let version = (requested != nil && supported.contains(requested!)) ? requested! : "2025-06-18"
            // 自报名字记下来：execute 时随操作落日志（来源标注见 clientName）
            if let info = params["clientInfo"] as? [String: Any],
               let name = info["name"] as? String, !name.isEmpty {
                clientName = name
            }
            reply(id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "diskwise", "version": cliVersion()],
                "instructions": "DiskWise has four different views, do not confuse them. "
                    + "disk_overview answers 'where did my disk space go' by measuring top-level locations "
                    + "across the whole volume (read-only), with every byte closed into named buckets. "
                    + "scan_disk answers 'what can be safely removed' for locations the cleanup "
                    + "knowledge base knows — its total is NOT the disk's used space. "
                    + "scan_project_assets finds regenerable assets INSIDE projects (model weights, "
                    + "node_modules, .venv, build outputs, old benchmarks) that the whitelist misses. "
                    + "scan_unused finds the rest of what people stop needing — apps nobody opened, old "
                    + "session history, backups, duplicate tool versions, installers, stale projects — and "
                    + "rates each one safe / review / keep / blocked with the reason. "
                    + "For 'why is my disk full' call disk_overview; for 'what can I get rid of' call "
                    + "scan_unused AND scan_disk AND scan_project_assets, then present the combined "
                    + "recommendation. Never report an item as deletable unless its recommend is 'safe' "
                    + "or 'review' — 'blocked' items need a human action, and 'keep' items must stay. "
                    + "If a scan reports unreadable directories, call open_access_settings to open "
                    + "System Settings › Privacy & Security › Full Disk Access; the user must enable "
                    + "DiskWise there and the MCP server must be restarted before re-scanning. "
                    + "Use explain_path, plan_cleanup, then execute_cleanup (Trash only, undoable) to "
                    + "actually free space. Always show the plan summary and get consent before execute_cleanup.",
            ])
        case "notifications/initialized", "initialized":
            // 到这里说明它带了 id（不合规但无害）：按通知处理，不回包
            break
        case "ping":
            reply(id: id, result: [:])
        case "tools/list":
            reply(id: id, result: ["tools": tools()])
        case "tools/call":
            guard let name = params["name"] as? String else {
                reply(id: id, error: (code: -32602, message: "Invalid params: missing tool name"))
                return
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            let (payload, isError) = await dispatch(name: name, arguments: arguments)
            var result: [String: Any] = [
                "content": [["type": "text", "text": payload.text]],
                "structuredContent": payload.structured,
            ]
            if isError { result["isError"] = true }
            reply(id: id, result: result)
        default:
            reply(id: id, error: (code: -32601, message: "Method not found: \(method)"))
        }
    }

    static func reply(id: Any?, result: [String: Any]) {
        var msg: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result]
        if id == nil { msg.removeValue(forKey: "id") }
        write(msg)
    }

    static func reply(id: Any?, error: (code: Int, message: String)) {
        var envelope: [String: Any] = ["jsonrpc": "2.0", "error": [
            "code": error.code, "message": error.message,
        ]]
        if let id { envelope["id"] = id } else { envelope["id"] = NSNull() }
        write(envelope)
    }

    static func write(_ msg: [String: Any]) {
        let opt: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let data = try? JSONSerialization.data(withJSONObject: msg, options: opt) else { return }
        var out = data
        out.append(0x0A)   // 一行一帧，不带内嵌换行
        FileHandle.standardOutput.write(out)
    }

    // MARK: - 工具表

    static func tools() -> [[String: Any]] {
        let readOnly = ["readOnlyHint": true] as [String: Any]
        func tool(_ name: String, _ desc: String, props: [String: Any], required: [String],
                  annotations: [String: Any] = [:]) -> [String: Any] {
            [
                "name": name,
                "description": desc,
                "inputSchema": ["type": "object", "properties": props, "required": required],
                "annotations": annotations.isEmpty ? readOnly : annotations,
            ]
        }
        let pathProp = ["type": "string",
                        "description": "Absolute path; ~ and $HOME are expanded"] as [String: Any]
        return [
            tool("disk_overview",
                 "WHERE SPACE GOES: measure the whole volume's top-level locations (home folders, "
                 + "system roots) and report how much was measured vs not, plus the APFS volume split "
                 + "(data / sealed system / VM / boot). Read-only, touches nothing. This is the right "
                 + "tool for 'why is my disk full'. For 'what can I delete' use scan_disk instead. "
                 + "When it reports unreadable directories, call open_access_settings — those sizes "
                 + "are undercounts until the user grants Full Disk Access.",
                 props: [:], required: []),
            tool("open_access_settings",
                 "Opens System Settings › Privacy & Security › Full Disk Access so the user can "
                 + "grant DiskWise access to protected folders (Safari, MobileSync, CloudDocs, other "
                 + "users' data). macOS forbids an app granting itself access — a human must toggle "
                 + "it. After enabling, the MCP server must be QUIT AND REOPENED for the grant to "
                 + "take effect, then re-run disk_overview. Call this when disk_overview reports "
                 + "unreadable directories. Opens a settings window; changes nothing on disk.",
                 props: [:], required: [],
                 annotations: ["readOnlyHint": false, "openWorldHint": true]),
            tool("scan_disk",
                 "CLEANUP LIST ONLY — NOT a whole-disk accounting. Lists cache/developer locations "
                 + "the knowledge base knows how to remove, plus signature-discovered engine caches. "
                 + "Its total is far smaller than used disk space by design; use disk_overview for "
                 + "where space goes. Each item carries a source field (knowledge_base | signature). "
                 + "signature-discovered engine caches (hub-layout model repositories like HuggingFace, "
                 + "loose model weights, updater download caches). Every item carries a source field "
                 + "(knowledge_base | signature); signature items are redo-tier and agent-untouchable. "
                 + "Read-only. Categories: all | dev | ai_models | apps. min_bytes filters small entries (decimal).",
                 props: [
                     "category": ["type": "string", "enum": ["all", "dev", "ai_models", "apps"]] as [String: Any],
                     "min_bytes": ["type": "integer", "description": "Minimum size in bytes (decimal), e.g. 100000000"] as [String: Any],
                 ], required: []),
            tool("scan_project_assets",
                 "REGENERABLE ASSETS HIDDEN INSIDE PROJECTS — the piece scan_disk CANNOT see. "
                 + "Scans project folders for downloaded/generated things that are safe to remove "
                 + "because they can be fetched or rebuilt: model weights (HuggingFace hubs, "
                 + ".safetensors/.ckpt), dependency installs (node_modules, .venv, .m2, Pods), "
                 + "build outputs (dist, build, .build, target, .next), bytecode caches and old "
                 + "benchmark/evidence records. Hard links are deduplicated by inode so shared "
                 + "model blocks are counted once. Each asset has size, staleness (days untouched), "
                 + "kind and how to restore. THIS IS THE RIGHT TOOL for 'stale/expired junk that "
                 + "isn't a cache' and often finds far more than scan_disk. Read-only; pass the "
                 + "reported paths to plan_cleanup to actually free space. Optional: roots (array "
                 + "of absolute dirs; default = home top-level, excluding Library), min_bytes "
                 + "(default 100000000), stale_days (e.g. 90 to show only untouched-for-90-days).",
                 props: [
                     "roots": ["type": "array", "items": ["type": "string"],
                               "description": "Absolute directories to scan; default home top-level"] as [String: Any],
                     "min_bytes": ["type": "integer", "description": "Minimum asset size in bytes (decimal), default 100000000"] as [String: Any],
                     "stale_days": ["type": "integer", "description": "Only assets untouched for at least this many days; default 0 (all)"] as [String: Any],
                 ], required: []),
            tool("scan_unused",
                 "WHAT YOU PROBABLY NO LONGER NEED — the layer the other tools miss. Finds "
                 + "installed apps nobody opened for months, old session/conversation history, "
                 + "backup and snapshot folders, duplicate versions of the same tool (pipx, "
                 + "homebrew Cellar), installers/disk images that were never deleted, and stale "
                 + "project folders. Every item carries a verdict: safe (delete, lose nothing), "
                 + "review (probably unused but holds data — a human should look), keep, or "
                 + "blocked with a reason (needs_admin | sip | readonly_volume | in_use | "
                 + "functional_dependency) plus what a person can do instead. Sizes are physical "
                 + "bytes; logical_bytes and sparse items are flagged so you never promise space "
                 + "that will not be freed. Staleness always states its basis: file_mtime | "
                 + "container_date | last_used_date (snapshots are judged by the container, never "
                 + "by the old timestamps inside). RECOMMENDATIONS ONLY — it deletes nothing. "
                 + "Pair with disk_overview (where space goes) and scan_disk (caches) for the "
                 + "full picture; this is the right tool for 'is there anything useless left?'.",
                 props: [
                     "roots": ["type": "array", "items": ["type": "string"],
                               "description": "Absolute dirs to inspect instead of the default home top level"] as [String: Any],
                     "min_bytes": ["type": "integer", "description": "Minimum item size in bytes (decimal), default 200000000"] as [String: Any],
                     "stale_days": ["type": "integer", "description": "How long 'unused' means, default 90 days"] as [String: Any],
                 ], required: []),
            tool("explain_path",
                 "Explain one path: what it is, what happens if deleted, how to restore, and whether the "
                 + "agent may trash it (refusal codes tell you why not). Read-only.",
                 props: ["path": pathProp], required: ["path"]),
            tool("plan_cleanup",
                 "Draw up a cleanup plan for the given paths. Touches NOTHING — returns plan_id, per-item "
                 + "sizes/tiers and refusals. ALWAYS show the summary to the user and get explicit consent "
                 + "before calling execute_cleanup. Plans expire after 10 minutes; re-plan if expired.",
                 props: ["paths": ["type": "array", "items": ["type": "string"]] as [String: Any]],
                 required: ["paths"]),
            tool("execute_cleanup",
                 "Execute a plan by id: moves the planned items to the Trash (the ONLY removal path — "
                 + "nothing is ever permanently deleted) and records an undoable operation. Every item is "
                 + "re-validated at execution time.",
                 props: ["plan_id": ["type": "string"] as [String: Any]],
                 required: ["plan_id"],
                 annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false,
                               "openWorldHint": false] as [String: Any]),
            tool("undo_cleanup",
                 "Restore every item of an operation (or the latest one) from the Trash to its original "
                 + "place. Items already gone from the Trash are reported, not treated as failures.",
                 props: ["operation_id": ["type": "string"] as [String: Any]], required: [],
                 annotations: ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false,
                               "openWorldHint": false] as [String: Any]),
            tool("cleanup_history",
                 "List recent operations with their items and whether they were undone. Read-only.",
                 props: ["limit": ["type": "integer"] as [String: Any]], required: []),
            tool("diag_coverage",
                 "Diagnostics coverage: run the bounded category discovery (crash-dump structures under "
                 + "app data, .ips/.hang/.panic report folders) and report hits plus every observed "
                 + "location the app cannot touch (outside_allowed, blacklisted_system_dir, "
                 + "unknown_class). Read-only; deletion is not offered here.",
                 props: [:], required: []),
            tool("diag_velocity",
                 "Growth velocity per crash-dump entry: compares the latest scan snapshot with the "
                 + "previous one (>= 10 min apart). tier 'fast' means a burst (red badge in the app), "
                 + "'growth' means accumulated volume over a long gap. Read-only.",
                 props: [:], required: []),
            tool("diag_probe",
                 "Content attribution for one crash-dump directory: reads the first 64 KB of up to 5 "
                 + "sample .dmp files to tell which process wrote them. Origin fingerprints are ALWAYS "
                 + "redacted in output. Requires the local 'content probe' switch to be enabled in the "
                 + "app's settings; refuses otherwise. Read-only.",
                 props: ["path": pathProp], required: ["path"]),
        ]
    }

    // MARK: - 分发

    struct ToolOut {
        let text: String
        let structured: [String: Any]
    }

    /// 整盘扫描：把 App 总览页那套「每个顶层目录单独量」的口径搬到 CLI。
    /// 并发只开 6 路——跟 Core 的 dirLevel 一样，多了会跟主流程抢线程；
    /// 而且这里每个目标都是一整棵子树，并发太高只会把磁盘 IO 打满。
    static func wholeDiskOverview() async -> WholeDiskOverview {
        let scope = ScanScope.effective
        let home = homePath()
        var targets: [(name: String, path: String)] = []
        var seen = Set<String>()
        func add(_ name: String, _ path: String) {
            guard seen.insert(URL(fileURLWithPath: path).standardizedFileURL.path).inserted else { return }
            targets.append((name, path))
        }
        // 家目录顶层逐个量，而不是把整个 ~ 当一处——整棵量完只有一个总数，
        // 回答不了「哪个目录吃掉了空间」。废纸篓不进账（它在废纸篓弧上另算）。
        if let kids = try? FileManager.default.contentsOfDirectory(atPath: home) {
            for k in kids.sorted() where k != ".Trash" {
                let p = (home as NSString).appendingPathComponent(k)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                    add("~/\(k)", p)
                }
            }
        }
        add("/Applications", applicationsDir())
        if scope == .disk {
            for r in systemScanRoots() where r.lastPathComponent != "Applications" {
                let name: String
                if homeIsDemo {
                    let h = homePath()
                    name = r.path.hasPrefix(h + "/") ? String(r.path.dropFirst(h.count)) : r.path
                } else {
                    name = r.path
                }
                add(name, r.path)
            }
        }

        var reports: [(name: String, path: String, scan: DirScan)] = []
        var i = 0
        while i < targets.count {
            let wave = Array(targets[i..<min(i + 6, targets.count)])
            i += wave.count
            let batch = await withTaskGroup(of: (String, String, DirScan).self) { group in
                for t in wave {
                    group.addTask {
                        let s = await dirSizeReport(URL(fileURLWithPath: t.path))
                        return (t.name, t.path, s)
                    }
                }
                var out: [(String, String, DirScan)] = []
                for await r in group { out.append(r) }
                return out
            }
            reports.append(contentsOf: batch)
        }
        let now = Date()
        let locations = reports.map { r -> WholeDiskLocation in
            let view = AdviceScanner.quickView(name: r.name, path: r.path)
            let logical = max(r.scan.logicalBytes, r.scan.bytes)
            let ratio = logical > 0 ? Double(r.scan.bytes) / Double(logical) : 1
            let stale = r.scan.newest.map { max(0, Int(now.timeIntervalSince($0) / 86400)) } ?? -1
            return WholeDiskLocation(path: r.path, name: r.name, bytes: r.scan.bytes,
                                     logicalBytes: r.scan.logicalBytes,
                                     sparseRatio: (ratio * 1000).rounded() / 1000,
                                     files: r.scan.files,
                                     unreadable: !r.scan.needFullDiskAccess.isEmpty || !r.scan.needAdmin.isEmpty,
                                     needFullDiskAccess: r.scan.needFullDiskAccess.count,
                                     needAdmin: r.scan.needAdmin.count,
                                     kind: view.kind, recommend: view.recommend,
                                     newestFileDays: stale,
                                     skippedLinks: r.scan.symlinksSkipped,
                                     skippedVolumes: r.scan.crossVolumeSkipped)
        }.sorted { $0.bytes > $1.bytes }
        let covered = locations.reduce(Int64(0)) { $0 + $1.bytes }

        let usage = volumeUsage()
        let split = usage.flatMap { volumeSplit(diskUsed: $0.usedPhysical) }
        let usedPhysical = usage?.usedPhysical ?? 0
        var volume: [String: Int64] = [:]
        if let u = usage {
            volume = ["total": u.total, "free": u.free, "purgeable": u.purgeable,
                      "available": u.available, "used": u.used, "used_physical": u.usedPhysical]
        }
        var apfs: [String: Int64] = [:]
        if let s = split {
            apfs = ["data_volume": s.dataVolume, "sealed_system": s.sealedSystem,
                    "virtual_memory": s.virtualMemory, "boot_and_recovery": s.bootAndRecovery,
                    "unattributed": s.unattributed]
        }
        // 闭合账：整块盘已用的每一字节都归到一块有名字、标明能不能删的桶里，
        // 所有桶加起来 == usedPhysical，不再留「没量到」这种说不清的黑洞。
        //
        // 账的推法（拿不到 APFS 分卷账时降级到最下面一支）：
        //   用户数据(扫到的目录) + data 卷内部块 + 密封系统卷 + VM 卷
        //   + 引导/恢复/更新卷 + 容器其余卷与元数据 = 整块盘已用
        // 其中「data 卷内部块」= data 卷报的占用 − 逐目录扫到的和。这部分是克隆块、
        // 稀疏文件、快照保留块和文件系统元数据：它们占物理块，但不对应任何可见文件，
        // du / Finder / 本工具都列不出具体文件，只能作为系统结构整体报一个名字。
        var buckets: [WholeDiskBucket] = []
        if let s = split, usedPhysical > 0 {
            let dataInternal = max(0, s.dataVolume - covered)
            buckets.append(WholeDiskBucket(
                name: "User data (scanned)", bytes: covered, kind: "user_data", removable: true,
                explanation: "Files under home folders and shared roots, including some system-owned folders such as /Applications and /private. Only the removable subset listed by scan_disk may be deleted; do NOT delete this whole bucket — drill into scan_disk for the safe list. Top sizes are in locations[]."))
            buckets.append(WholeDiskBucket(
                name: "Data volume internals", bytes: dataInternal, kind: "apfs_internal", removable: false,
                explanation: "Physical blocks on the data volume that no directory scan could name. Two very different things land here: (a) clones, sparse files, snapshot-held blocks and filesystem metadata, which really are undeletable; and (b) any system cache the scan could not read without root — most often /System/Volumes/Data/.Spotlight-V100, seen at 47 GB on one machine where the normal size is 2-5 GB. If this bucket is unusually large, check the caches with `sudo du -shx /System/Volumes/Data/.Spotlight-V100` BEFORE concluding it is all system structure: that single index was the largest reclaimable item on the whole disk."))
            buckets.append(WholeDiskBucket(
                name: "Sealed system volume", bytes: s.sealedSystem, kind: "system_volume", removable: false,
                explanation: "Read-only macOS system, SIP protected. Cannot be deleted."))
            buckets.append(WholeDiskBucket(
                name: "VM volume", bytes: s.virtualMemory, kind: "system_volume", removable: false,
                explanation: "Swap files and hibernation image. System-managed, cannot be deleted."))
            buckets.append(WholeDiskBucket(
                name: "Boot / Recovery / Update", bytes: s.bootAndRecovery, kind: "system_volume", removable: false,
                explanation: "Preboot, Recovery and Update volumes that boot and restore macOS. Cannot be deleted."))
            // 余下的：容器里别的角色卷（xarts、iSCPreboot 等）和容器级记账。
            // 用整块盘已用减掉前面所有块，保证与前五块严格闭合。
            let otherVolumes = max(0, usedPhysical - covered - dataInternal
                - s.sealedSystem - s.virtualMemory - s.bootAndRecovery)
            buckets.append(WholeDiskBucket(
                name: "Other APFS volumes & metadata", bytes: otherVolumes, kind: "apfs_internal", removable: false,
                explanation: "Remaining APFS volumes (xarts, iSCPreboot, etc.) and container bookkeeping. System-managed, cannot be deleted."))
        } else {
            // 拿不到分卷账：仍不黑洞，整块归到一块有名字的桶里
            buckets.append(WholeDiskBucket(
                name: "User data (scanned)", bytes: covered, kind: "user_data", removable: true,
                explanation: "Files under home folders and shared roots. The removable subset is listed by scan_disk."))
            buckets.append(WholeDiskBucket(
                name: "Outside scan scope", bytes: max(0, usedPhysical - covered),
                kind: "system_volume", removable: false,
                explanation: "System volumes and on-disk structures outside the scan roots; APFS per-volume split unavailable on this machine."))
        }

        var notes: [String] = [
            "CLOSED ACCOUNTING: buckets[] sum to used_physical — every byte of used space has a named bucket. coverage splits the total into measured_user_data (walked by the scanner) and system_side (volumes, VM and unnamed blocks); system_side is NOT a hole, it is the floor.",
            "Buckets with removable=false are system or filesystem structures: they are reported so you can see why the disk is full, but this tool will never delete them.",
            "To see WHAT CAN BE DELETED, call scan_disk — it lists only cleanup locations the knowledge base knows about.",
            "IMPORTANT: scan_disk misses regenerable assets INSIDE projects (model weights, node_modules, .venv, build outputs) — often the biggest removable space on a dev machine. ALWAYS also call scan_project_assets for a complete cleanup picture; it deduplicates hard-linked model blocks and reports staleness.",
        ]
        let access = accessStatus(for: locations)
        if locations.contains(where: \.unreadable) {
            notes.append("\(access.needFullDiskAccessDirs) directory(ies) need Full Disk Access and "
                + "\(access.needAdminDirs) need admin/root; their sizes are lower bounds. "
                + "Sizes here are undercounts until access is granted — see access.next_step.")
        }
        if split == nil {
            notes.append("APFS per-volume split unavailable on this machine; system space is one combined bucket.")
        }
        let accounted = buckets.reduce(Int64(0)) { $0 + $1.bytes }
        // 这里的键只描述「体积怎么分」。早先叫 unmeasured，读起来像「没量到」，
        // 实际含义是「不在用户数据里的那部分」（系统卷 + VM + 无名块）——实测被
        // 理解成「还有几十 G 是黑洞」，而那个数其实就是系统地基。计数也别塞进来：
        // 顶层本来就有 locations[] 和 buckets[] 两个数组，长度自己数得出来。
        let coverage: [String: Int64] = [
            "measured_user_data": covered,
            "system_side": max(0, usedPhysical - covered),
            "used_physical": usedPhysical,
            "accounted": accounted,
        ]
        return WholeDiskOverview(scope: scope.rawValue, volume: volume, apfsVolumes: apfs,
                                 coverage: coverage, locations: locations, buckets: buckets,
                                 access: access, notes: notes)
    }

    /// 系统设置的「完全磁盘访问」页。跟 App 里的「去授权」按钮同一个地址。
    /// macOS 不允许程序自己给自己授权，只能把人送到这一页亲自勾。
    static let fullDiskAccessSettingsURL =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"

    /// 打开授权页。NSWorkspace.open 在 CLI 里也能唤起系统设置；返回值说明有没有真的递出去。
    @discardableResult
    static func openFullDiskAccessSettings() -> Bool {
        guard let url = URL(string: fullDiskAccessSettingsURL) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// 从扫描结果算出授权状态。needFullDiskAccess/needAdmin 是**目录个数**，不是字节——
    /// 读不到的目录没有字节数，所以只报「有几处」，绝不假装一个骗人的体积。
    static func accessStatus(for locations: [WholeDiskLocation]) -> AccessStatus {
        let fda = locations.reduce(0) { $0 + $1.needFullDiskAccess }
        let admin = locations.reduce(0) { $0 + $1.needAdmin }
        let granted = fullDiskAccessGranted()
        var step: String
        if fda == 0 && admin == 0 {
            step = "No permission blockers — all scanned directories were readable."
        } else if granted {
            step = "Full Disk Access is already on, but \(fda) directory(ies) still need it and "
                + "\(admin) need admin/root. The already-on grant may not have reached this "
                + "process yet: quit and reopen DiskWise, then re-run disk_overview."
        } else {
            step = "Call open_access_settings to open System Settings › Privacy & Security › "
                + "Full Disk Access, turn on DiskWise, then QUIT AND REOPEN the DiskWise MCP "
                + "server (macOS applies the grant only to newly launched processes), and "
                + "re-run disk_overview. The \(admin) admin/root-only directory(ies) are system "
                + "or another user's data — not removable, and not fixable by this grant."
        }
        return AccessStatus(hasFullDiskAccess: granted, needFullDiskAccessDirs: fda,
                            needAdminDirs: admin, settingsURL: fullDiskAccessSettingsURL,
                            nextStep: step)
    }

    static func dispatch(name: String, arguments: [String: Any]) async -> (ToolOut, Bool) {
        switch name {
        case "scan_project_assets":
            let roots = arguments["roots"] as? [String]
            let minBytes = (arguments["min_bytes"] as? NSNumber)?.int64Value ?? 100_000_000
            let staleDays = (arguments["stale_days"] as? NSNumber)?.intValue ?? 0
            let report = RegenAssetScanner.scan(roots: roots, minBytes: minBytes, staleDays: staleDays)
            var lines = ["REGENERABLE PROJECT ASSETS (invisible to scan_disk's cache whitelist): "
                + "\(report.assetCount) asset roots, \(human(report.totalBytes)) deduplicated."]
            if report.assets.isEmpty {
                lines.append("None found at or above the size threshold. Try a smaller min_bytes.")
            } else {
                lines.append("")
                lines.append("SIZE       AGE      KIND           PATH  (delete the whole root to reclaim space)")
                for a in report.assets.prefix(40) {
                    lines.append("  \(human(a.bytes))  \(String(a.staleDays).padding(toLength: 4, withPad: " ", startingAt: 0))d  "
                        + "\(a.kind.padding(toLength: 14, withPad: " ", startingAt: 0)) \(a.path)")
                }
                if report.assets.count > 40 { lines.append("  ... and \(report.assets.count - 40) more (see structured.assets)") }
            }
            lines.append("")
            lines.append("Deleting these does NOT touch source code — they are re-downloaded/rebuilt. "
                + "Call plan_cleanup with the chosen asset paths (never delete only snapshots of a "
                + "hard-linked hub). To focus on genuinely old ones, pass stale_days (e.g. 90).")
            return (ToolOut(text: lines.joined(separator: "\n"),
                            structured: ["report": structify(report)]), false)

        case "scan_unused":
            let roots = arguments["roots"] as? [String]
            let minBytes = (arguments["min_bytes"] as? NSNumber)?.int64Value ?? 200_000_000
            let staleDays = (arguments["stale_days"] as? NSNumber)?.intValue ?? 90
            let report = await AdviceScanner.scan(roots: roots, minBytes: minBytes,
                                                  staleDays: staleDays)
            let t = report.totals
            var lines = ["UNUSED CANDIDATES — recommendations only, nothing was deleted."]
            lines.append("Delete now (lose nothing): \(human(t["safe_now_bytes"] ?? 0)) · "
                + "Look first (holds data): \(human(t["review_bytes"] ?? 0)) · "
                + "Blocked: \(human(t["blocked_bytes"] ?? 0)) · "
                + "Still in use: \(human(t["keep_bytes"] ?? 0))")
            // 按分档分组：同一档里的条目才可比。混在一起排，最大的那条会盖掉
            // 「这条其实不能删」这件事。
            let groups: [(String, String)] = [
                ("safe", "DELETE NOW — nothing is lost"),
                ("review", "LOOK BEFORE DELETING — these hold data, not just cache"),
                ("blocked", "BLOCKED — cannot be removed (reason + what a person can do)"),
                ("keep", "KEEP — still in use or too new"),
            ]
            for (verdict, title) in groups {
                let rows = report.items.filter { $0.recommend == verdict }
                guard !rows.isEmpty else { continue }
                lines.append("")
                lines.append("\(title):")
                for i in rows.prefix(20) {
                    let age = i.staleDays >= 0 ? "\(i.staleDays)d" : "?"
                    let sparse = i.logicalBytes > 0 && i.physicalBytes * 2 < i.logicalBytes
                        ? " (sparse: reports \(human(i.logicalBytes)))" : ""
                    lines.append("  \(human(i.physicalBytes))  \(age)  \(i.kind)  \(i.path)\(sparse)")
                    if verdict == "blocked" {
                        lines.append("      why: \(i.blockedReason) — \(i.userAction ?? "")")
                    }
                }
                if rows.count > 20 { lines.append("  ... and \(rows.count - 20) more (see structured.items)") }
            }
            lines.append("")
            lines.append("Next steps:")
            for a in report.topActions { lines.append("  · \(a)") }
            lines.append("")
            lines.append("Ages are computed from the basis named on each item (file_mtime, "
                + "container_date for backups/snapshots, last_used_date for apps). Use plan_cleanup "
                + "with the paths you decide on; this tool never deletes.")
            return (ToolOut(text: lines.joined(separator: "\n"),
                            structured: ["report": structify(report)]), false)

        case "open_access_settings":
            let opened = openFullDiskAccessSettings()
            let text = opened
                ? "Opened System Settings › Privacy & Security › Full Disk Access. "
                    + "Turn on DiskWise, then QUIT AND REOPEN this MCP server so the grant "
                    + "reaches the process, then re-run disk_overview to re-measure."
                : "Could not open System Settings from this process. Open it manually: "
                    + "\(fullDiskAccessSettingsURL) — turn on DiskWise, restart this MCP server, "
                    + "and re-run disk_overview."
            return (ToolOut(text: text, structured: [
                "opened": opened,
                "settings_url": fullDiskAccessSettingsURL,
                "next_step": "Enable DiskWise, restart the MCP server, re-run disk_overview.",
            ]), !opened)

        case "disk_overview":
            let o = await wholeDiskOverview()
            let cov = o.coverage
            let used = cov["used_physical"] ?? 0
            let accounted = cov["accounted"] ?? 0
            var lines = ["Whole-disk accounting (scope \(o.scope)): \(human(used)) physically used. "
                + "Every byte is accounted for in \(o.buckets.count) buckets below "
                + "(sum = \(human(accounted)), nothing left unmeasured)."]
            lines.append("")
            lines.append("WHERE THE SPACE GOES (ALL of it, with delete permission):")
            for b in o.buckets {
                let pct = used > 0 ? Int(Double(b.bytes) / Double(used) * 100) : 0
                let yesNo = b.removable ? "HAS REMOVABLE PARTS — see scan_disk" : "SYSTEM — never delete"
                lines.append("  \(human(b.bytes))  \(pct)%  [\(yesNo)]  \(b.name)")
            }
            lines.append("")
            if !o.locations.isEmpty {
                lines.append("BIGGEST USER-DATA FOLDERS (drill into the scanned bucket):")
                for l in o.locations.prefix(14) {
                    var flags: [String] = []
                    if l.unreadable { flags.append("partially unreadable") }
                    if l.sparseRatio < 0.5 { flags.append("sparse: claims \(human(l.logicalBytes)), occupies \(human(l.bytes))") }
                    if l.skippedVolumes > 0 { flags.append("\(l.skippedVolumes) other volume(s) excluded") }
                    let tail = flags.isEmpty ? "" : " — " + flags.joined(separator: "; ")
                    lines.append("  \(human(l.bytes)) · \(l.name) [\(l.kind)/\(l.recommend)]\(tail)")
                }
                lines.append("")
            }
            lines.append("System buckets are reported for accounting only — this tool will not delete them. "
                + "For the removable list call scan_disk.")
            lines.append("ALSO call scan_project_assets: scan_disk's whitelist cannot see regenerable "
                + "assets inside projects (model weights, node_modules, .venv, build outputs) — often "
                + "the largest removable space on a development machine.")
            lines.append("AND call scan_unused: it rates everything else people stop needing (unused apps, "
                + "old sessions, backups, duplicate tool versions, installers, stale projects) as "
                + "safe / review / keep / blocked, so the advice covers more than caches.")
            // 扫不到就必须当场给出口，不能只说「读不全」。这是调用方（Agent）最容易
            // 漏掉、也是用户最容易以为「盘上有黑洞」的地方。
            if o.access.needFullDiskAccessDirs > 0 || o.access.needAdminDirs > 0 {
                lines.append("")
                lines.append("⚠ UNREADABLE DIRECTORIES — numbers above are LOWER BOUNDS:")
                lines.append("  \(o.access.needFullDiskAccessDirs) dir(s) need Full Disk Access, "
                    + "\(o.access.needAdminDirs) need admin/root. Currently granted: "
                    + "\(o.access.hasFullDiskAccess).")
                lines.append("  FIX: \(o.access.nextStep)")
                lines.append("  Call open_access_settings to open the page automatically.")
            }
            return (ToolOut(text: lines.joined(separator: "\n"),
                            structured: ["overview": structify(o)]), false)

        case "scan_disk":
            let category = (arguments["category"] as? String).flatMap(AgentCategory.init(rawValue:)) ?? .all
            let minBytes = (arguments["min_bytes"] as? NSNumber)?.int64Value ?? 0
            let items = await agentScan(category: category, minBytes: minBytes)
            let trashable = items.filter(\.agentMayTrash)
            let total = contentsUnionSize(trashable.map { ($0.path, $0.bytes) })
            // 这句话必须留在返回文本里：模型看到「25 GB」很容易当成整块盘的用量。
            let text = "CLEANUP LIST ONLY — locations the knowledge base knows how to remove, "
                + "NOT a whole-disk accounting (use disk_overview for where space goes).\n"
                + "\(items.count) known locations found; agent may trash \(trashable.count) "
                + "of them (\(human(total)) total, nested paths counted once). "
                + "Use plan_cleanup with chosen paths."
            return (ToolOut(text: text, structured: structify(items)), false)

        case "explain_path":
            guard let path = arguments["path"] as? String, !path.isEmpty else {
                return (ToolOut(text: "explain_path requires a non-empty 'path'",
                                structured: ["error": "invalid_params"]), true)
            }
            let item = await agentExplain(path: path)
            var text = "\(item.path) · \(human(item.bytes)) · tier \(item.tier)"
            if let n = item.name { text += "\n\(n)" }
            if let d = item.ifDeleted { text += "\nIf deleted: \(d)" }
            text += "\nagent may trash: \(item.agentMayTrash ? "yes" : "NO (\(item.refusal?.rawValue ?? "?"))")"
            return (ToolOut(text: text, structured: structify(item)), false)

        case "plan_cleanup":
            let paths = arguments["paths"] as? [String] ?? []
            guard !paths.isEmpty else {
                return (ToolOut(text: "plan_cleanup requires a non-empty 'paths' array",
                                structured: ["error": "invalid_params"]), true)
            }
            do {
                let plan = try await agentPlan(paths: paths)
                var text = "Plan \(plan.planId) created — valid ~10 min.\n"
                text += "\(plan.items.count) item(s), \(human(plan.totalBytes)) to free"
                if !plan.refused.isEmpty {
                    text += "; \(plan.refused.count) refused:\n"
                    text += plan.refused.map { "  \($0.path) — \($0.refusal?.rawValue ?? "?")" }
                        .joined(separator: "\n")
                }
                text += "\nShow this summary to the user and get consent, then execute_cleanup "
                    + "with plan_id \(plan.planId)."
                return (ToolOut(text: text, structured: structify(plan)), plan.refused.isEmpty ? false : true)
            } catch let e as AgentAPIError {
                return (agentErrorOut(e), true)
            } catch {
                return (ToolOut(text: "plan failed: \(error.localizedDescription)",
                                structured: ["error": "plan_failed"]), true)
            }

        case "execute_cleanup":
            guard let planId = arguments["plan_id"] as? String, !planId.isEmpty else {
                return (ToolOut(text: "execute_cleanup requires a non-empty 'plan_id'",
                                structured: ["error": "invalid_params"]), true)
            }
            do {
                let result = try agentExecute(planId: planId, client: clientName)
                var text = "Moved \(result.trashed.count) item(s), \(human(result.totalBytes)) to the Trash."
                if !result.failed.isEmpty {
                    text += "\nRefused/failed items:"
                    text += result.failed.map { "  \($0.path) — \($0.reason)" }.joined(separator: "\n")
                }
                text += "\nUndo anytime with undo_cleanup"
                    + (result.operationId.isEmpty ? "" : " (operation_id \(result.operationId))") + "."
                return (ToolOut(text: text, structured: structify(result)), result.failed.isEmpty ? false : true)
            } catch let e as AgentAPIError {
                return (agentErrorOut(e), true)
            } catch {
                return (ToolOut(text: "execute failed: \(error.localizedDescription)",
                                structured: ["error": "execute_failed"]), true)
            }

        case "undo_cleanup":
            let opId = arguments["operation_id"] as? String
            do {
                let statuses = try agentUndo(operationId: opId)
                let restored = statuses.filter { $0.status == "restored" }.count
                let text = "Restored \(restored)/\(statuses.count) item(s) to their original places."
                    + statuses.filter { $0.status != "restored" }
                        .map { "\n  \($0.path) — \($0.status)" }.joined()
                return (ToolOut(text: text, structured: structify(statuses)),
                        statuses.contains { $0.status == "failed" })
            } catch let e as AgentAPIError {
                return (agentErrorOut(e), true)
            } catch {
                return (ToolOut(text: "undo failed: \(error.localizedDescription)",
                                structured: ["error": "undo_failed"]), true)
            }

        case "cleanup_history":
            let limit = (arguments["limit"] as? NSNumber)?.intValue ?? 20
            let ops = agentHistory(limit: limit)
            let text = ops.isEmpty
                ? "No operations yet."
                : "\(ops.count) operation(s), oldest first:\n"
                    + ops.map { op -> String in
                        let bytes = op.items.reduce(Int64(0)) { $0 + $1.bytes }
                        return "  \(op.id) · \(op.client ?? "unknown") · \(op.items.count) item(s) · \(human(bytes))"
                            + (op.undoneAt == nil ? "" : " · undone")
                    }.joined(separator: "\n")
            return (ToolOut(text: text, structured: structify(ops)), false)

        case "diag_coverage":
            let home = homeDir()
            let report = await discoverDiagnosticCategories(home: home)
            let roots = [
                home.appendingPathComponent("Library/Application Support").path,
                home.appendingPathComponent("Library/Logs/DiagnosticReports").path,
                "/Library/Logs/DiagnosticReports",
            ]
            let hits: [[String: Any]] = report.hits.map {
                ["path": $0.path, "host": $0.host ?? NSNull(), "bytes": $0.bytes,
                 "files": $0.files, "deletable": $0.deletable] as [String: Any]
            }
            let observed: [[String: Any]] = report.observation.map {
                ["path": $0.path, "reason": $0.reason.rawValue,
                 "bytes": $0.bytes ?? NSNull(), "files": $0.files ?? NSNull()] as [String: Any]
            }
            let structured: [String: Any] = ["scanned_roots": roots, "hits": hits,
                                             "observed_not_deletable": observed]
            let text = hits.isEmpty
                ? "No crash-dump structures found; \(observed.count) observed (read-only) location(s)."
                : "\(hits.count) crash-dump hit(s):\n"
                    + hits.map { "  \($0["path"] ?? "") · \(human($0["bytes"] as? Int64 ?? 0)) · \($0["files"] ?? 0) files" }
                        .joined(separator: "\n")
                    + "\nObserved (cannot delete): \(observed.count)."
            return (ToolOut(text: text, structured: structured), false)

        case "diag_velocity":
            let home = homeDir()
            let report = await discoverDiagnosticCategories(home: home)
            let store = SnapshotStore(path: SnapshotStore.defaultPath())
            var entries: [[String: Any]] = []
            for hit in report.hits {
                guard let pair = store.latestTwo(entryKey: hit.path) else { continue }
                let v = VelocityReport.compute(current: pair.current, baseline: pair.baseline)
                entries.append(["path": hit.path,
                                "delta_files": v.deltaFiles,
                                "delta_bytes": v.deltaBytes,
                                "interval_sec": Int(v.intervalSeconds),
                                "files_per_minute": Int(v.filesPerMinute),
                                "tier": v.tier == .red ? "fast" : (v.tier == .yellow ? "growth" : "none")]
                               as [String: Any])
            }
            let flagged = entries.filter { ($0["tier"] as? String) != "none" }
            let text = flagged.isEmpty
                ? "No growth flagged. \(entries.count) entries have a comparable baseline."
                : "\(flagged.count) growing entries:\n"
                    + flagged.map { "  \($0["path"] ?? "") · +\($0["delta_files"] ?? 0) files · \(human($0["delta_bytes"] as? Int64 ?? 0)) · \($0["tier"] ?? "")" }
                        .joined(separator: "\n")
            return (ToolOut(text: text, structured: ["entries": entries]), false)

        case "diag_probe":
            guard let raw = arguments["path"] as? String else {
                return (ToolOut(text: "Invalid params: missing path.",
                                structured: ["error": "invalid_params"]), true)
            }
            guard diagnosticProbeEnabled() else {
                return (ToolOut(text: "Content probe is disabled locally. Enable it in the app "
                    + "(Settings → Diagnostics), or ask the user to. Refusing to read file contents.",
                                structured: ["error": "probe_disabled"]), true)
            }
            let expanded = URL(fileURLWithPath: expandHome(raw))
            let spec = CategoryRule.crashDumps.safeDeleteSpec
            let dirs = spec?.cleanTargets(under: expanded) ?? [expanded]
            let samples = probeSampleFiles(under: dirs)
            let probe = CrashpadProbe()
            let outcome = resolveAttribution(directoryOwner: CrashpadMatcher.host(of: expanded),
                                             results: samples.map { probe.probe($0) })
            let structured: [String: Any] = [
                "path": expanded.path,
                "probed": outcome.probed,
                "samples": outcome.samples,
                "directory_owner": outcome.directoryOwner ?? NSNull(),
                "content_owner": outcome.contentOwner ?? NSNull(),
                "mixed": outcome.mixed,
                "cross_attribution": outcome.crossAttribution,
                "origin_hints_redacted": outcome.redactedHints,   // 永远脱敏，无本地例外
            ]
            let text = outcome.probed
                ? "directory: \(outcome.directoryOwner ?? "?") · content: \(outcome.contentOwner ?? "?")"
                  + (outcome.mixed ? " · MIXED" : (outcome.crossAttribution ? " · CROSS" : ""))
                  + " · samples: \(outcome.samples)"
                : "Not probed (no readable minidumps)."
            return (ToolOut(text: text, structured: structured), false)

        default:
            return (ToolOut(text: "Unknown tool: \(name)", structured: ["error": "unknown_tool"]), true)
        }
    }

    /// AgentAPIError -> 给模型的文案：必须自带下一步（plan_expired 是长对话常态）
    static func agentErrorOut(_ e: AgentAPIError) -> ToolOut {
        let msg: String
        switch e {
        case .planExpired: msg = "Plan expired (valid 10 min). Call plan_cleanup again for a fresh plan."
        case .planNotFound: msg = "No such plan. Call plan_cleanup to create one."
        case .planTooLarge(let items, let bytes):
            msg = "Plan too large: \(items) items / \(human(bytes)) (limits: 200 items / 200 GB). Plan fewer paths."
        case .invalidPath: msg = "No trashable path in the request."
        case .noUndoableOperation: msg = "Nothing to undo."
        }
        return ToolOut(text: msg, structured: ["error": e.description])
    }

    // MARK: - 结构化输出

    /// Encodable -> JSONSerialization 可写回的任意 JSON（structuredContent 用）
    static func structify<T: Encodable>(_ value: T) -> [String: Any] {
        guard let data = try? JSONEncoder.agentAPI.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    static func structify<T: Encodable>(_ value: [T]) -> [String: Any] {
        ["items": structifyArray(value)]
    }

    static func structifyArray<T: Encodable>(_ value: [T]) -> [[String: Any]] {
        guard let data = try? JSONEncoder.agentAPI.encode(value),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr
    }
}

/// 与 main.swift 的 versionString 同源（MCP serverInfo 用）
func cliVersion() -> String {
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
}
