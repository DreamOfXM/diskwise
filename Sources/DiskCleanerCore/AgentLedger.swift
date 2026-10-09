import Foundation

// ── AI Agent 页的数据层：只算账，不写文案 ──────────────────────────────────
//
// 为什么住在 Core 而不是视图旁边：SelfTest 只连得到 DiskCleanerCore，而这一页
// 摆在用户眼前的每一笔数都必须钉得住——累计口径、撤销三态、来源名、包里到底
// 有没有那个 CLI。四样都是纯函数，给进去数据、拿回来数，不碰磁盘也不碰词表。
//
// 这里一律**不出现中文**：中文进词表是界面层的事（见
// Sources/DiskCleaner/Views/AgentPageView.swift），混进来只会让闸门多一堆
// 「其实屏幕上看不见」的词条。

// MARK: - 整本账的累计口径

/// 操作日志的累计。界面上那一行「N 次操作 · M 项 · 共 X 移入废纸篓」全从这里出。
///
/// 口径写死在这里，因为这一行最容易说错话：
/// - `bytes` 是**移进废纸篓的合计**，不是「释放了多少」——东西还在盘上，
///   清空废纸篓之前它一个字节都没腾出来；
/// - `restoredBytes` 单独一档，绝不从 `bytes` 里减：减了就把「放回」说成
///   「这操作没发生过」，而账本上那一行还在。
public struct AgentLedgerTotals: Equatable {
    public let operations: Int
    public let items: Int
    public let bytes: Int64
    public let restoredOperations: Int
    public let restoredItems: Int
    public let restoredBytes: Int64

    /// 还能整单撤销的那几笔（有 undone 标记的不能再撤）。
    public var undoableOperations: Int { operations - restoredOperations }

    /// 日志为空：界面据此整行不渲染，不占位也不写 0。
    public var isEmpty: Bool { operations == 0 }

    public init(operations: Int, items: Int, bytes: Int64,
                restoredOperations: Int, restoredItems: Int, restoredBytes: Int64) {
        self.operations = operations
        self.items = items
        self.bytes = bytes
        self.restoredOperations = restoredOperations
        self.restoredItems = restoredItems
        self.restoredBytes = restoredBytes
    }

    public static let empty = AgentLedgerTotals(operations: 0, items: 0, bytes: 0,
                                                restoredOperations: 0, restoredItems: 0,
                                                restoredBytes: 0)
}

/// 按整本日志算累计。传进来的应当是**全部**操作，不是截到最近 N 次的那一叠——
/// 累计行说的是这本账，而下面的行只是它最近几页。
public func agentLedgerTotals(_ ops: [AgentOperation]) -> AgentLedgerTotals {
    var items = 0
    var bytes: Int64 = 0
    var rOps = 0
    var rItems = 0
    var rBytes: Int64 = 0
    for op in ops {
        let opBytes = op.items.reduce(Int64(0)) { $0 + $1.bytes }
        items += op.items.count
        bytes += opBytes
        if op.undoneAt != nil {
            rOps += 1
            rItems += op.items.count
            rBytes += opBytes
        }
    }
    return AgentLedgerTotals(operations: ops.count, items: items, bytes: bytes,
                             restoredOperations: rOps, restoredItems: rItems,
                             restoredBytes: rBytes)
}

/// 一次操作里各项字节之和，给「这一行值多少」用。
public func agentOperationBytes(_ op: AgentOperation) -> Int64 {
    op.items.reduce(Int64(0)) { $0 + $1.bytes }
}

// MARK: - 包里到底有没有 CLI

/// CLI 探测结果。`missing` 与「渠道是 App Store」是两件事，所以这里只认磁盘。
public enum AgentCLILocation: Equatable {
    case missing
    /// `stable` = 这个 App 是从「应用程序」里跑起来的，拼出来的路径不会随副本消失
    case present(path: String, stable: Bool)
}

/// 那个可执行文件在不在，实测。
///
/// 不用 `Channel.isAppStore` 猜：打包脚本只在直装渠道拷这个文件，渠道标志和
/// 包内容一旦不一致，页面就在撒谎；而 v1.7 及更早的包本来就没带 CLI，
/// 用户升上来之前得告诉他缺什么。
///
/// `fileExists` 留成参数是给自检用的：造一个不存在的 bundlePath 比造一个真包便宜。
public func agentCLILocation(bundlePath: String,
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> AgentCLILocation {
    guard !bundlePath.isEmpty else { return .missing }
    let bin = bundlePath.hasSuffix(".app")
        ? bundlePath + "/Contents/MacOS/diskwise"
        : bundlePath + "/MacOS/diskwise"
    guard fileExists(bin) else { return .missing }
    return .present(path: bin, stable: bundlePath.hasPrefix("/Applications/"))
}

// MARK: - 撤销的结果分档

/// 一次整单撤销的回执。三种结果分别计数，不合并成一句「成功/失败」。
///
/// `gone`（废纸篓里已经不在）不是失败：那一档要单独摆在行上，旁边给一颗
/// 「打开废纸篓」，让人自己去看一眼是不是真清空了，别靠文案猜。
public struct AgentUndoTally: Equatable {
    public let restored: Int
    public let gone: Int
    public let failed: Int
    /// 真回到原位的字节数（只算 restored）
    public let restoredBytes: Int64

    public var total: Int { restored + gone + failed }
    /// 三项都非零的组合里最麻烦的一种：既回来了又有撤不回的，界面上要各写各的
    public var isPartial: Bool { restored > 0 && gone + failed > 0 }

    public init(restored: Int, gone: Int, failed: Int, restoredBytes: Int64) {
        self.restored = restored
        self.gone = gone
        self.failed = failed
        self.restoredBytes = restoredBytes
    }

    public static let empty = AgentUndoTally(restored: 0, gone: 0, failed: 0, restoredBytes: 0)
}

/// 把 `agentUndo` 的回执和这一行的项对齐，算出各档多少。
///
/// 回执只给原路径，字节要回到 `items` 里去查——查不到就按 0 计，
/// 不虚报「回来了多少」（宁可少说）。
public func agentUndoTally(statuses: [AgentUndoStatus], items: [AgentTrashRecord]) -> AgentUndoTally {
    var bytesByPath: [String: Int64] = [:]
    for it in items { bytesByPath[it.original] = it.bytes }
    var restored = 0, gone = 0, failed = 0
    var restoredBytes: Int64 = 0
    for s in statuses {
        switch s.status {
        case "restored":
            restored += 1
            restoredBytes += bytesByPath[s.path] ?? 0
        case "gone_from_trash":
            gone += 1
        default:
            failed += 1
        }
    }
    return AgentUndoTally(restored: restored, gone: gone, failed: failed,
                          restoredBytes: restoredBytes)
}

/// 这一行还能不能整单放回：逐项看它现在**是否还躺在废纸篓里**。
///
/// 事前查一次，是为了不把「撤不回来」留到用户按下之后才说——废纸篓被清空过的那几笔
/// 按下去只会得到一串 `gone_from_trash`，而按钮看起来一直是可以点的。
/// 只数得清「一个都不剩」和「还剩几个」，不去猜为什么少。
///
/// `exists` 留成参数给自检：造「废纸篓里已经不在了」比真去清空用户的废纸篓体面。
public func agentTrashPresence(_ op: AgentOperation,
                               exists: (String) -> Bool) -> (present: Int, missing: Int) {
    var present = 0
    var missing = 0
    for it in op.items {
        exists(it.inTrash) ? (present += 1) : (missing += 1)
    }
    return (present, missing)
}

// MARK: - 来源名

/// 客户端自报名 → 界面上的名字；`nil` = 这一行该写「未知来源」。
///
/// 日志里存的是自报原名（`claude-code`、`cursor`），旧行压根没这个字段。
/// 认得出的换成写法体面的正名，认不出的一律照抄——那是别人家的名字，
/// 不是我们的翻译对象，把它收成「未知来源」等于把来人抹掉。
public func agentClientLabel(_ raw: String?) -> String? {
    // 先裁首尾空白：客户端递来一个「空格」或空串时，照抄只会在界面上画出一个
    // 看着像名字的空白格——那比「未知来源」更糟，因为它什么都没说却占了一格。
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
        return nil
    }
    // 归一化只用于比对，返回的仍是下面的正名或原样
    let key = raw.lowercased()
        .replacingOccurrences(of: "_", with: "-")
        .replacingOccurrences(of: " ", with: "-")
    if key == "unknown" { return nil }
    if key == "mcp" { return "MCP" }
    // 按前缀认：客户端会把版本号挂在名字后面（`claude-code/1.0.60` 这类）
    if key.hasPrefix("claude") { return "Claude Code" }
    if key.hasPrefix("cursor") { return "Cursor" }
    if key.hasPrefix("codex") { return "Codex" }
    if key.hasPrefix("diskwise-cli") || key == "diskwise" { return "diskwise CLI" }
    return raw
}

// MARK: - 读整本日志

/// 全部操作（新→旧由调用方自己排）。
///
/// 不复用 `agentHistory(limit:)`：那一档是给命令行「看最近几次」用的，
/// 而累计那一行要说的是整本账，截到最近 20 次就是一笔漏记的账。
public func agentAllOperations() -> [AgentOperation] { readAgentOperations() }
