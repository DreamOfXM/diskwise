import DiskCleanerCore
import Foundation

// diskwise：把「知识库认识且安全的位置」开放给终端与 AI agent。
//
// 纪律与 App 同源：唯一删除路径是 Core 的 trashItem（只进废纸篓）、risky 永远
// 不放开、trash 只认 plan_id 不收裸路径——强制先 plan 再 trash，和 App 界面上
// 「点两下」确认是同一个理念。stdout 只放结果（agent 要解析它），日志与进度
// 一律走 stderr。

let args = Array(CommandLine.arguments.dropFirst())

/// 退出码契约：0 成功；1 参数错误；2 有项被拒（部分成功也是 2，JSON 里写清
/// 哪些成功）；3 计划过期或不存在。脚本按它分流，别改语义。
enum Exit: Int32 {
    case ok = 0
    case usage = 1
    case refused = 2
    case planGone = 3
}

func versionString() -> String {
    // 打包版从 .app 的 Info.plist 读（brew 的 binary symlink 会被解析回 .app）；
    // swift run / 裸二进制回落 dev
    (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
}

func printHelp() {
    print("""
    diskwise \(versionString()) — let your AI agent (or you) reclaim disk space, safely.

    It never deletes anything permanently: the only removal path moves items to the
    Trash, and every operation can be undone. Agents may only touch locations the
    knowledge base knows and rates safe/redo; risky ones are never touchable.

    Usage:
      diskwise overview [--json]
          Measure where space goes across the whole volume: top-level folders, how much
          was measured vs not, and the APFS volume split. Read-only. Use this to answer
          "why is my disk full"; 'scan' is only the removable-cache list.
      diskwise scan [--category all|dev|ai_models|apps] [--min 100MB] [--json]
          Lists knowledge-base locations plus signature-discovered engine caches
          (hub-layout model repositories, loose model weights, updater download
          caches) — each item carries a "source" field. Signature items are
          redo-tier and agent-untouchable; --i-am-human may take them.
      diskwise project-assets [--roots DIR...] [--min 100MB] [--stale-days 90] [--json]
          Find regenerable assets hidden inside projects (model weights, node_modules,
          .venv, build outputs, old benchmarks) that 'scan' cannot see. Deduplicates
          hard-linked model blocks and reports how long each asset sat untouched.
          Default scans home project dirs + Desktop subdirs; --roots narrows it (faster).
          Read-only; feed the reported paths to 'plan' to actually free the space.
      diskwise unused [--min 200MB] [--stale-days 90] [--roots DIR...] [--json]
          Find what you probably no longer need — apps nobody opened for months, old
          session history, backups, duplicate versions of the same tool, installers,
          stale projects — and rate each one: safe (delete, lose nothing), review
          (probably unused but holds data), keep, or blocked (with the reason and
          what a person can do instead). Sizes are physical bytes; sparse items are
          flagged so you never promise space that will not be freed. Recommendations
          only: nothing is deleted.
      diskwise explain <path> [--json]
      diskwise plan <path>... [--i-am-human] [--json]
          Draw up a cleanup plan. Touches nothing. --i-am-human also admits
          unknown-to-the-KB locations (risky is still refused). Plans expire in
          10 minutes and cover at most 200 items / 200 GB.
      diskwise trash --plan <plan_id> [--json]
          Execute a plan. Takes a plan id only, never raw paths — the two-step
          confirm is deliberate, same idea as the app's double-click confirm.
          Re-validates every item at execution time.
      diskwise undo [<operation_id>] [--json]
      diskwise history [--limit 20] [--json]
      diskwise grant-access
          Open System Settings › Privacy & Security › Full Disk Access. Turn on
          DiskWise so protected folders can be measured; restart this tool/MCP
          server after granting, then re-run overview. macOS cannot self-authorize.
      diskwise mcp
          Run as a Model Context Protocol server over stdio (for Claude Code,
          Cursor, Codex and friends).
      diskwise --version

    Exit codes: 0 ok · 1 usage error · 2 some items refused (partial success
    counts) · 3 plan expired or unknown.
    """)
}

/// AgentAPIError -> (stderr 文案, 退出码)。文案给操作下一步的指引：
/// plan_expired 是常态（用户十几分钟后才同意），必须告诉 agent 重新 plan。
func mapAgentError(_ e: AgentAPIError) -> (String, Exit) {
    switch e {
    case .planExpired:
        return ("plan expired (valid 10 min) — run plan again and get a fresh id", .planGone)
    case .planNotFound:
        return ("no such plan (expired, already executed, or wrong id) — run plan again", .planGone)
    case .planTooLarge(let items, let bytes):
        return ("plan too large: \(items) items / \(human(bytes)) (limits: 200 items / 200 GB) — plan fewer paths", .refused)
    case .invalidPath:
        return ("no trashable path in the request", .usage)
    case .noUndoableOperation:
        return ("nothing to undo", .usage)
    }
}

func failAgentError(_ e: AgentAPIError) -> Never {
    let (msg, code) = mapAgentError(e)
    errLog("diskwise: \(msg)")
    exit(code.rawValue)
}

switch args.first {
case nil, "--help", "-h", "help":
    printHelp()

case "--version", "version":
    print("diskwise \(versionString())")

case "grant-access":
    let opened = MCPServer.openFullDiskAccessSettings()
    if opened {
        print("Opened System Settings › Privacy & Security › Full Disk Access.")
    } else {
        print("Could not open System Settings automatically. Open it manually:")
        print("  \(MCPServer.fullDiskAccessSettingsURL)")
    }
    print("Turn on DiskWise, quit and reopen this tool/MCP server, then re-run 'diskwise overview'.")

case "project-assets":
    var json = false
    var minBytes: Int64 = 100_000_000
    var staleDays = 0
    var roots: [String]? = nil
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--json": json = true; i += 1
        case "--min":
            guard i + 1 < args.count, let b = try? parseSize(args[i + 1]) else {
                failUsage("--min needs a size like 100MB, 2GB or plain bytes")
            }
            minBytes = b; i += 2
        case "--stale-days":
            guard i + 1 < args.count, let d = Int(args[i + 1]) else {
                failUsage("--stale-days needs an integer number of days")
            }
            staleDays = d; i += 2
        case "--roots":
            guard i + 1 < args.count else { failUsage("--roots needs directories") }
            roots = Array(args[(i + 1)...].prefix { !$0.hasPrefix("--") })
            i += 1 + (roots?.count ?? 0)
        default:
            failUsage("project-assets: unknown argument \(args[i])")
        }
    }
    let report = RegenAssetScanner.scan(roots: roots, minBytes: minBytes, staleDays: staleDays)
    if json {
        print(encodeJSON(report))
    } else {
        print("Regenerable project assets hidden from 'scan': \(report.assetCount) roots, "
              + "\(human(report.totalBytes)) deduplicated.\n")
        print("SIZE        AGE    KIND           PATH")
        for a in report.assets {
            let s = a.bytes >= 0 ? human(a.bytes) : "?"
            let size = s + String(repeating: " ", count: max(1, 10 - s.count))
            let age = "\(a.staleDays)d"
            let agePad = age + String(repeating: " ", count: max(1, 6 - age.count))
            let kind = a.kind + String(repeating: " ", count: max(1, 14 - a.kind.count))
            print("\(size) \(agePad) \(kind) \(a.path)")
        }
        print("\nDeleting these does not touch source code — they regenerate. "
              + "Feed the paths to 'diskwise plan' to free the space.")
    }
    exit(Exit.ok.rawValue)

case "unused":
    var json = false
    var minBytes: Int64 = 200_000_000
    var staleDays = 90
    var roots: [String]? = nil
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--json": json = true; i += 1
        case "--min":
            guard i + 1 < args.count, let b = try? parseSize(args[i + 1]) else {
                failUsage("--min needs a size like 200MB, 2GB or plain bytes")
            }
            minBytes = b; i += 2
        case "--stale-days":
            guard i + 1 < args.count, let d = Int(args[i + 1]) else {
                failUsage("--stale-days needs an integer number of days")
            }
            staleDays = d; i += 2
        case "--roots":
            guard i + 1 < args.count else { failUsage("--roots needs directories") }
            roots = Array(args[(i + 1)...].prefix { !$0.hasPrefix("--") })
            i += 1 + (roots?.count ?? 0)
        default:
            failUsage("unused: unknown argument \(args[i])")
        }
    }
    errLog("Looking for things you probably no longer need (read-only)…")
    let report = await AdviceScanner.scan(roots: roots, minBytes: minBytes, staleDays: staleDays)
    if json {
        print(encodeJSON(report))
    } else {
        let t = report.totals
        print("UNUSED CANDIDATES — recommendations only, nothing was deleted.")
        print("  delete now (lose nothing)   \(human(t["safe_now_bytes"] ?? 0))")
        print("  look first (holds data)     \(human(t["review_bytes"] ?? 0))")
        print("  blocked (needs a person)    \(human(t["blocked_bytes"] ?? 0))")
        print("  still in use / too new      \(human(t["keep_bytes"] ?? 0))")
        let groups: [(String, String)] = [
            ("safe", "DELETE NOW — nothing is lost"),
            ("review", "LOOK BEFORE DELETING — these hold data, not just cache"),
            ("blocked", "BLOCKED — cannot be removed; each line says what a person can do"),
            ("keep", "KEEP — still in use or too new"),
        ]
        for (verdict, title) in groups {
            let rows = report.items.filter { $0.recommend == verdict }
            guard !rows.isEmpty else { continue }
            print("")
            print(title + ":")
            for it in rows {
                let size = human(it.physicalBytes)
                let pad = String(repeating: " ", count: max(1, 10 - size.count))
                let age = it.staleDays >= 0 ? "\(it.staleDays)d" : "?"
                let agePad = String(repeating: " ", count: max(1, 5 - age.count))
                print("  \(size)\(pad)\(age)\(agePad)\(it.kind)  \(it.path)")
                if verdict == "blocked" {
                    print("      → \(it.blockedReason): \(it.userAction ?? "")")
                }
                if it.logicalBytes > 0 && it.physicalBytes * 2 < it.logicalBytes {
                    print("      → sparse: claims \(human(it.logicalBytes)), occupies \(human(it.physicalBytes))")
                }
            }
        }
        print("")
        print("WHAT TO DO:")
        for a in report.topActions { print("  · \(a)") }
        print("")
        print("Ages come from the basis on each item (file_mtime / container_date / last_used_date). "
              + "Nothing here was deleted — feed chosen paths to 'diskwise plan'.")
    }
    exit(Exit.ok.rawValue)

case "overview":
    var json = false
    for a in args.dropFirst() {
        switch a {
        case "--json": json = true
        default: failUsage("overview: unknown argument \(a)")
        }
    }
    errLog("Measuring top-level locations across the whole volume…")
    let o = await MCPServer.wholeDiskOverview()
    if json {
        print(encodeJSON(o))
    } else {
        let c = o.coverage
        let used = c["used_physical"] ?? 0, accounted = c["accounted"] ?? 0
        print("Whole-disk accounting (scope \(o.scope)): \(human(used)) physically used, "
              + "all accounted for in \(o.buckets.count) buckets (sum = \(human(accounted))).")
        print("")
        print("WHERE THE SPACE GOES (ALL of it, with delete permission):")
        for b in o.buckets {
            let pct = used > 0 ? Int(Double(b.bytes) / Double(used) * 100) : 0
            let yesNo = b.removable ? "HAS REMOVABLE PARTS — see scan" : "SYSTEM — never delete"
            print("  \(human(b.bytes))  \(pct)%  [\(yesNo)]  \(b.name)")
        }
        print("")
        print("BIGGEST USER-DATA FOLDERS (SIZE / LOCATION / WHAT IT IS):")
        for l in o.locations {
            let s = human(l.bytes)
            var tail: [String] = []
            if l.unreadable { tail.append("partially unreadable") }
            if l.sparseRatio < 0.5 {
                tail.append("sparse: claims \(human(l.logicalBytes)), occupies \(human(l.bytes))")
            }
            if l.skippedVolumes > 0 { tail.append("\(l.skippedVolumes) other volume(s) excluded") }
            let note = tail.isEmpty ? "" : "\n" + String(repeating: " ", count: 11)
                + "↳ " + tail.joined(separator: "; ")
            print("\(s + String(repeating: " ", count: max(1, 10 - s.count)))"
                  + "\(l.name)  [\(l.kind)/\(l.recommend)]\(note)")
        }
        print("")
        print("System buckets are accounting only — never deleted. 'diskwise scan' lists removable caches.")
        print("'diskwise unused' rates everything else (apps, sessions, backups, installers) as "
              + "safe / review / keep / blocked.")
        if o.access.needFullDiskAccessDirs > 0 || o.access.needAdminDirs > 0 {
            print("")
            print("⚠ UNREADABLE: \(o.access.needFullDiskAccessDirs) dir(s) need Full Disk Access, "
                  + "\(o.access.needAdminDirs) need admin/root — sizes above are LOWER BOUNDS.")
            print("FIX: \(o.access.nextStep)")
            print("Run 'diskwise grant-access' to open the settings page.")
        }
    }
    exit(Exit.ok.rawValue)

case "scan":
    var category = AgentCategory.all
    var minBytes: Int64 = 0
    var json = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--category":
            guard i + 1 < args.count, let c = AgentCategory(rawValue: args[i + 1]) else {
                failUsage("--category must be one of all|dev|ai_models|apps")
            }
            category = c; i += 2
        case "--min":
            guard i + 1 < args.count, let b = try? parseSize(args[i + 1]) else {
                failUsage("--min needs a size like 100MB, 2GB or plain bytes")
            }
            minBytes = b; i += 2
        case "--json":
            json = true; i += 1
        default:
            failUsage("scan: unknown argument \(args[i])")
        }
    }
    errLog("Scanning knowledge-base and signature-discovered locations (category \(category.rawValue))…")
    let items = await agentScan(category: category, minBytes: minBytes)
    if json {
        print(encodeJSON(items))
    } else {
        printItemsTable(items, totalLabel: "locations")
    }
    exit(Exit.ok.rawValue)

case "explain":
    guard args.count >= 2 else { failUsage("explain: a path is required") }
    let path = args[1]
    if args.dropFirst(2).contains("--json") {
        print(encodeJSON(await agentExplain(path: path)))
    } else {
        printExplainBlock(await agentExplain(path: path))
    }
    exit(Exit.ok.rawValue)

case "plan":
    var paths: [String] = []
    var human = false
    var json = false
    for a in args.dropFirst() {
        switch a {
        case "--i-am-human": human = true
        case "--json": json = true
        default:
            if a.hasPrefix("-") { failUsage("plan: unknown flag \(a)") }
            paths.append(a)
        }
    }
    guard !paths.isEmpty else { failUsage("plan: at least one path is required") }
    let plan: AgentPlan
    do {
        plan = try await agentPlan(paths: paths, humanOverride: human)
    } catch let e as AgentAPIError {
        failAgentError(e)
    } catch {
        failUsage("plan failed: \(error.localizedDescription)")
    }
    if json {
        print(encodeJSON(plan))
    } else {
        printPlanBlock(plan)
    }
    // 有被拒项时退出码 2：调用方（脚本/agent）据此知道「这次不是全带走」
    if plan.refused.isEmpty { exit(Exit.ok.rawValue) }
    exit(Exit.refused.rawValue)

case "trash":
    var planId: String? = nil
    var json = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--plan":
            guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else {
                failUsage("trash: --plan needs a plan id (from a previous `diskwise plan`)")
            }
            planId = args[i + 1]; i += 2
        case "--json":
            json = true; i += 1
        default:
            // 刻意不接受裸路径：先 plan 再 trash 是两步确认，绕过它等于绕过安全模型
            failUsage("trash: only accepts --plan <plan_id> (raw paths are refused on purpose — run `diskwise plan` first)")
        }
    }
    guard let id = planId else { failUsage("trash: --plan <plan_id> is required") }
    let result: AgentResult
    do {
        result = try agentExecute(planId: id)
    } catch let e as AgentAPIError {
        failAgentError(e)
    } catch {
        failUsage("trash failed: \(error.localizedDescription)")
    }
    if json {
        print(encodeJSON(result))
    } else {
        printResultBlock(result)
    }
    if result.failed.isEmpty { exit(Exit.ok.rawValue) }
    exit(Exit.refused.rawValue)

case "undo":
    var opId: String? = nil
    var json = false
    for a in args.dropFirst() {
        switch a {
        case "--json": json = true
        case "--plan": failUsage("undo takes an operation id (from history), not a plan id")
        default:
            if a.hasPrefix("-") { failUsage("undo: unknown flag \(a)") }
            opId = a
        }
    }
    let statuses: [AgentUndoStatus]
    do {
        statuses = try agentUndo(operationId: opId)
    } catch let e as AgentAPIError {
        failAgentError(e)
    } catch {
        failUsage("undo failed: \(error.localizedDescription)")
    }
    if json {
        print(encodeJSON(statuses))
    } else {
        printUndoBlock(statuses)
    }
    // gone_from_trash 不算失败（东西已不在废纸篓是用户自己的动作），只有 failed 才 2
    if statuses.contains(where: { $0.status == "failed" }) { exit(Exit.refused.rawValue) }
    exit(Exit.ok.rawValue)

case "history":
    var limit = 20
    var json = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--limit":
            guard i + 1 < args.count, let n = Int(args[i + 1]), n > 0 else {
                failUsage("history: --limit needs a positive number")
            }
            limit = n; i += 2
        case "--json":
            json = true; i += 1
        default:
            failUsage("history: unknown argument \(args[i])")
        }
    }
    let ops = agentHistory(limit: limit)
    if json {
        print(encodeJSON(ops))
    } else {
        printHistoryBlock(ops)
    }
    exit(Exit.ok.rawValue)

case "mcp":
    await MCPServer.run()

default:
    failUsage("unknown command \(args.first!)")
}
