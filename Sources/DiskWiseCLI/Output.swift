import DiskCleanerCore
import Foundation

// 输出层：给人的表格 / 给程序的 JSON（--json），stdout 只放结果。
// 人看的输出用英文——CLI 的第一受众是开发者和 agent，且本目录不进 l10n 词表。

var stderrHandle = FileHandle.standardError

func errLog(_ msg: String) {
    stderrHandle.write(Data(("diskwise: " + msg + "\n").utf8))
}

func failUsage(_ msg: String) -> Never {
    stderrHandle.write(Data(("diskwise: " + msg + "\nTry 'diskwise --help'.\n").utf8))
    exit(Exit.usage.rawValue)
}

/// --json 的统一口径：pretty + 键排序，人调试、机解析都稳；
/// 不转义斜杠（默认的 \/ 挡在路径正中间，人读 JSON 全是噪声）。
func encodeJSON<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder.agentAPI
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = (try? enc.encode(value)) ?? Data("{}".utf8)
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - 表格

/// 路径显示：家目录换回 ~（终端里人读绝对路径要扫半行）。
func displayPath(_ path: String) -> String {
    let home = homePath()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

private func padded(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}

private func mayFlag(_ item: AgentItem) -> String {
    item.agentMayTrash ? "yes" : (item.humanMayTrash ? "human" : "no")
}

/// 通用清单表：大小 / 判词 / 可动 / 路径。 refusal 单列一行不进表——
/// 表要保持窄，原因跟在拒绝项后面。
func printItemsTable(_ items: [AgentItem], totalLabel: String) {
    if items.isEmpty {
        print("Nothing to show.")
        return
    }
    let total = contentsUnionSize(items.map { ($0.path, $0.bytes) })
    print("\(items.count) \(totalLabel), \(human(total)) total (nested paths counted once)")
    print()
    print("\(padded("SIZE", 10)) \(padded("TIER", 8)) \(padded("TRASH", 6)) PATH")
    for it in items {
        let tier = it.exact ? it.tier : "\(it.tier)~"   // ~ = 命中的是上层条目，不是本体
        print("\(padded(human(it.bytes), 10)) \(padded(tier, 8)) \(padded(mayFlag(it), 6)) \(displayPath(it.path))")
        if let r = it.refusal {
            print("\(padded("", 10)) \(padded("", 8)) \(padded("", 6)) refusal: \(r.rawValue)")
        }
    }
}

func printExplainBlock(_ item: AgentItem) {
    print("\(displayPath(item.path)) · \(human(item.bytes)) on disk")
    if let n = item.name { print("  what        : \(n)") }
    if let w = item.what { print("              \(w)") }
    if let d = item.ifDeleted { print("  if deleted  : \(d)") }
    if let r = item.howToRestore { print("  how to undo : \(r)") }
    print("  tier        : \(item.tier)\(item.exact ? "" : " (inside a known location, not the location itself)")")
    print("  agent may trash : \(item.agentMayTrash ? "yes" : "no")"
          + (item.agentMayTrash ? "" : " (refusal: \(item.refusal?.rawValue ?? "?"))"))
    print("  human may trash: \(item.humanMayTrash ? "yes" : "no")")
}

func printPlanBlock(_ plan: AgentPlan) {
    let mins = Int(plan.expiresAt.timeIntervalSince(Date()) / 60)
    print("Plan \(plan.planId)")
    print("  valid for ~\(max(0, mins)) min · execute with: diskwise trash --plan \(plan.planId)")
    print()
    printItemsTable(plan.items, totalLabel: "items to move to Trash")
    if !plan.refused.isEmpty {
        print()
        print("\(plan.refused.count) refused (will NOT be touched):")
        for it in plan.refused {
            print("  \(displayPath(it.path)) — \(it.refusal?.rawValue ?? "?")")
        }
    }
}

func printResultBlock(_ result: AgentResult) {
    if !result.trashed.isEmpty {
        print("Moved \(result.trashed.count) item(s), \(human(result.totalBytes)) to the Trash.")
        print("Undo with: diskwise undo\(result.operationId.isEmpty ? "" : " \(result.operationId)")")
    } else {
        print("Nothing was moved.")
    }
    for f in result.failed {
        print("  refused: \(displayPath(f.path)) — \(f.reason)" + (f.detail.map { " (\($0))" } ?? ""))
    }
}

func printUndoBlock(_ statuses: [AgentUndoStatus]) {
    for s in statuses {
        switch s.status {
        case "restored": print("restored : \(displayPath(s.path))")
        case "gone_from_trash": print("skipped  : \(displayPath(s.path)) — already gone from the Trash")
        default: print("FAILED   : \(displayPath(s.path)) — \(s.detail ?? "unknown error")")
        }
    }
}

func printHistoryBlock(_ ops: [AgentOperation]) {
    if ops.isEmpty {
        print("No operations yet.")
        return
    }
    // 时间正序（账本读法）；要最新的自己看最后一行
    print("\(ops.count) operation(s), oldest first:")
    for op in ops {
        let bytes = op.items.reduce(Int64(0)) { $0 + $1.bytes }
        let df = ISO8601DateFormatter()
        print("  \(op.id) · \(df.string(from: op.at)) · \(op.items.count) item(s) · \(human(bytes))"
              + (op.undoneAt == nil ? "" : " · undone"))
    }
}
