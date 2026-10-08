import Foundation
import Darwin

// ── Agent 通道：把「知识库认识且判为安全的位置」开放给 CLI / MCP ──
//
// App 的入口是人点鼠标；这一层把同一套判词、同一条删除路径开放给程序调用，
// 但收得更紧：agent 只能动知识库认识的位置**本体**（exact），risky 永远不放开，
// 连人也不行。两步确认从界面上的「点两下」变成 plan 文件 + execute 重校验——
// 计划只有 10 分钟有效，执行时每一项都要重新过一遍管线并核对 inode，
// 防止计划生成之后路径被换成别的东西。
//
// 状态目录（plans/ 与 operations.jsonl）全部基于 homeDir() 拼：自检靠
// DISKWISE_HOME_SHIM 把整棵状态树搬进 /tmp，绝不能写死 NSHomeDirectory()。
//
// 本文件面向 agent 的输出一律英文（agent 读英文最稳），错误用原因码不拼句子；
// 注意 l10n 覆盖闸门会扫本目录的字符串字面量，所以这里不写中文文案。

// 单次计划的上限。限制的是「一次 plan 最多带走多少」，不是单条目大小：
// 没有它，一个被说服的 agent 可以一次把整台机器的缓存全部端走。
let agentPlanTTL: TimeInterval = 600
let agentPlanMaxItems = 200
let agentPlanMaxBytes: Int64 = 200 * GB

// MARK: - 类型

public enum AgentCategory: String, Codable {
    case all
    case dev
    case aiModels = "ai_models"
    case apps
}

/// agent_may_trash / human_may_trash 为 false 时的原因码。
/// 顺序就是判定管线的顺序，别单独改动某一档的语义。
public enum AgentRefusal: String, Codable {
    case notFound = "not_found"
    case symlink
    case protected
    case outsideAllowed = "outside_allowed"
    case unknownToKnowledgeBase = "unknown_to_knowledge_base"
    case mayLoseData = "may_lose_data"
    /// 路径落在某个认识的位置**里面**，但它本身不是认识的位置。
    /// 缓存目录里用户自己建的文件夹就是这一档：agent 不能点名它，人可以。
    case notAKnownLocation = "not_a_known_location"
}

/// 一个路径在 agent 眼里的完整画像。给人看的解释字段（what 等）是英文。
public struct AgentItem: Codable {
    public let path: String            // 绝对路径（已展开 ~、已词法折叠 ..）
    public let bytes: Int64            // 实测占盘（st_blocks × 512 口径）
    public let name: String?           // 知识库条目名（英文，查不到回落中文）
    public let tier: String            // safe | redo | risky | unknown
    public let exact: Bool             // 是否就是知识库条目（或其通配实例）本体
    public let what: String?
    public let ifDeleted: String?
    public let howToRestore: String?
    /// 严格模式（agent / MCP）下能否进计划并执行。
    public let agentMayTrash: Bool
    /// --i-am-human 下能否进计划（unknown 与非 exact 放开，risky 仍拒）。
    public let humanMayTrash: Bool
    /// 严格模式被拒时的原因；通过时为 nil。
    public let refusal: AgentRefusal?

    enum CodingKeys: String, CodingKey {
        case path, bytes, name, tier, exact, what
        case ifDeleted = "if_deleted"
        case howToRestore = "how_to_restore"
        case agentMayTrash = "agent_may_trash"
        case humanMayTrash = "human_may_trash"
        case refusal
    }

    init(path: String, bytes: Int64, name: String?, tier: String, exact: Bool,
         what: String?, ifDeleted: String?, howToRestore: String?,
         agentMayTrash: Bool, humanMayTrash: Bool, refusal: AgentRefusal?) {
        self.path = path
        self.bytes = bytes
        self.name = name
        self.tier = tier
        self.exact = exact
        self.what = what
        self.ifDeleted = ifDeleted
        self.howToRestore = howToRestore
        self.agentMayTrash = agentMayTrash
        self.humanMayTrash = humanMayTrash
        self.refusal = refusal
    }
}

/// plan 的返回值，也是计划文件里除校验数据外的展示部分。
public struct AgentPlan: Codable {
    public let planId: String
    public let createdAt: Date
    public let expiresAt: Date
    public let items: [AgentItem]       // 可执行项
    public let refused: [AgentItem]     // 被拒项（ refusal 字段说明原因）
    /// 去嵌套后的真实可腾出：互相套着的路径只数最外面那个，
    /// 按条目 bytes 直接相加会虚高（缓存页全选实测虚高过 5.5 GB）。
    public let totalBytes: Int64

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case items, refused
        case totalBytes = "total_bytes"
    }
}

/// 执行结果里「搬走了什么」。original/in_trash 是撤销的依据。
public struct AgentTrashRecord: Codable {
    public let original: String
    public let inTrash: String
    public let bytes: Int64
    public let name: String?

    enum CodingKeys: String, CodingKey {
        case original
        case inTrash = "in_trash"
        case bytes, name
    }

    init(original: String, inTrash: String, bytes: Int64, name: String?) {
        self.original = original
        self.inTrash = inTrash
        self.bytes = bytes
        self.name = name
    }
}

/// 执行时单项被拒或失败。reason 是原因码（AgentRefusal 的 rawValue，
/// 外加 trash_failed / changed_since_plan / covered_by_earlier_item）。
public struct AgentFailure: Codable {
    public let path: String
    public let reason: String
    public let detail: String?
}

public struct AgentResult: Codable {
    public let operationId: String
    public let trashed: [AgentTrashRecord]
    public let failed: [AgentFailure]
    public let totalBytes: Int64

    enum CodingKeys: String, CodingKey {
        case operationId = "operation_id"
        case trashed, failed
        case totalBytes = "total_bytes"
    }
}

public struct AgentUndoStatus: Codable {
    public let path: String             // 原位置
    /// restored | gone_from_trash | failed
    public let status: String
    public let detail: String?
}

public struct AgentOperation: Codable {
    public let id: String
    public let at: Date
    public let items: [AgentTrashRecord]
    /// 撤销后由追加的标记行回填；nil = 尚未撤销
    public let undoneAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, at, items
        case undoneAt = "undone_at"
    }

    init(id: String, at: Date, items: [AgentTrashRecord], undoneAt: Date? = nil) {
        self.id = id
        self.at = at
        self.items = items
        self.undoneAt = undoneAt
    }
}

/// 撤销标记：只追加、不改写原行——操作日志是账本，账本不许涂改。
struct AgentUndoneMarker: Codable {
    let id: String
    let undoneAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case undoneAt = "undone_at"
    }
}

/// 计划文件的落盘结构。公开是因为它是磁盘格式：自检需要直接改
/// expires_at 来造过期计划，不能为了测试在 Core 里开后门。
public struct AgentPlanRecord: Codable {
    public var planId: String
    public var createdAt: Date
    public var expiresAt: Date
    /// 计划生成时是否处于 --i-am-human：execute 重校验必须按同一档执行
    public var human: Bool
    public var items: [AgentPlanItemRecord]
    public var refused: [AgentItem]
    public var totalBytes: Int64

    enum CodingKeys: String, CodingKey {
        case planId = "plan_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case human, items, refused
        case totalBytes = "total_bytes"
    }

    public init(planId: String, createdAt: Date, expiresAt: Date, human: Bool,
                items: [AgentPlanItemRecord], refused: [AgentItem], totalBytes: Int64) {
        self.planId = planId
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.human = human
        self.items = items
        self.refused = refused
        self.totalBytes = totalBytes
    }
}

/// 计划项的执行绑定：路径之外再记 dev/ino——计划生成之后原地 rename
/// 换一份内容，路径还是那个路径、判词也没变，只有 inode 能拆穿它。
public struct AgentPlanItemRecord: Codable {
    public var path: String
    public var bytes: Int64
    public var dev: UInt64
    public var ino: UInt64

    public init(path: String, bytes: Int64, dev: UInt64, ino: UInt64) {
        self.path = path
        self.bytes = bytes
        self.dev = dev
        self.ino = ino
    }
}

public enum AgentAPIError: Error, CustomStringConvertible {
    case planExpired
    case planNotFound
    case planTooLarge(items: Int, bytes: Int64)
    case invalidPath(String)
    case noUndoableOperation

    public var description: String {
        switch self {
        case .planExpired: return "plan_expired"
        case .planNotFound: return "plan_not_found"
        case .planTooLarge: return "plan_too_large"
        case .invalidPath: return "invalid_path"
        case .noUndoableOperation: return "no_undoable_operation"
        }
    }
}

// MARK: - 统一 JSON 口径（CLI 与 MCP 共用；显式键名，不用自动转换策略）

extension JSONEncoder {
    public static var agentAPI: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    public static var agentAPI: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - 判定管线（所有入口共用，顺序固定）

struct AgentPathCheck {
    let url: URL               // 已展开、已标准化的绝对路径
    let tier: VerdictTier      // entry 为 nil 时是 .unknown
    let exact: Bool
    let entry: SafetyEntry?
    /// 严格模式（agent / MCP）的拒绝原因；nil = 通过
    let refusal: AgentRefusal?
    /// --i-am-human 模式的拒绝原因；nil = 通过（risky 与管线硬拒两种模式下都拒）
    let humanRefusal: AgentRefusal?
}

/// 管线顺序：展开 → 保护 → 范围 → lstat → 判词。
/// 保护与范围放在 lstat 之前是刻意的：`/usr/local/x` 不存在时，
/// 对 agent 有用的答案是「这里永远动不了」（outside_allowed），
/// 而不是 not_found——前者能终结这个话题，后者只会招来下一次试探。
/// 词法折叠在这里完成：`~/.npm/../Documents` 进管线前就折叠成 `~/Documents`。
func agentPipeline(_ raw: String, index: VerdictIndex) -> AgentPathCheck {
    let url = URL(fileURLWithPath: expandHome(raw)).standardizedFileURL
    if isProtected(url) {
        return .init(url: url, tier: .unknown, exact: false, entry: nil,
                     refusal: .protected, humanRefusal: .protected)
    }
    if !isDeletable(url) {
        return .init(url: url, tier: .unknown, exact: false, entry: nil,
                     refusal: .outsideAllowed, humanRefusal: .outsideAllowed)
    }
    var st = stat()
    if lstat(url.path, &st) != 0 {
        return .init(url: url, tier: .unknown, exact: false, entry: nil,
                     refusal: .notFound, humanRefusal: .notFound)
    }
    // 软链一律拒绝：搬的是链接本身没错，但「计划里那个位置」与「实际内容」
    // 从此对不上号，为了让语义简单，宁可在这一档就说不。
    if (st.st_mode & S_IFMT) == S_IFLNK {
        return .init(url: url, tier: .unknown, exact: false, entry: nil,
                     refusal: .symlink, humanRefusal: .symlink)
    }
    let v = index.verdict(for: url.path)
    var refusal: AgentRefusal? = nil
    var humanRefusal: AgentRefusal? = nil
    switch v.tier {
    case .risky:
        // 删了就没了：agent、--i-am-human、MCP，谁都不放
        refusal = .mayLoseData
        humanRefusal = .mayLoseData
    case .unknown:
        refusal = .unknownToKnowledgeBase
    case .safe, .redo:
        // 认识的位置里面的子路径不是认识的位置：人可以（下钻页同款自由），agent 不行
        if !v.exact { refusal = .notAKnownLocation }
    }
    return .init(url: url, tier: v.tier, exact: v.exact, entry: v.entry,
                 refusal: refusal, humanRefusal: humanRefusal)
}

/// 把管线结果装配成对外画像。解释字段查 en 词表，查不到回落中文原文——
/// 宁可中英混排，也不在现场编一句英文。
func agentItem(_ c: AgentPathCheck, bytes: Int64) -> AgentItem {
    func en(_ zh: String?) -> String? {
        guard let zh else { return nil }
        return enText(zh) ?? zh
    }
    return AgentItem(path: c.url.path,
                     bytes: bytes,
                     name: en(c.entry?.name),
                     tier: c.tier.rawValue,
                     exact: c.exact,
                     what: en(c.entry?.what),
                     ifDeleted: en(c.entry?.whatif),
                     howToRestore: en(c.entry?.rec),
                     agentMayTrash: c.refusal == nil,
                     humanMayTrash: c.humanRefusal == nil,
                     refusal: c.refusal)
}

// MARK: - 状态目录

public func agentStateDir() -> URL {
    // 基于 homeDir() 而不是 NSHomeDirectory()：后者在沙盒里是容器路径，
    // 自检的假家目录也只认前者。公开是因为它是磁盘格式的根：
    // 自检要直接进 plans/ 改计划文件造过期场景，不能为测试在 Core 里开后门。
    homeDir().appendingPathComponent("Library/Application Support/DiskWise/agent", isDirectory: true)
}

public func agentPlansDir() -> URL { agentStateDir().appendingPathComponent("plans", isDirectory: true) }

func agentOperationsFile() -> URL { agentStateDir().appendingPathComponent("operations.jsonl") }

func appendJSONL<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let data = try JSONEncoder.agentAPI.encode(value)
    let fh = try FileHandle(forWritingTo: url)
    try fh.seekToEnd()
    try fh.write(contentsOf: data)
    try fh.write(contentsOf: Data([0x0A]))
    try fh.close()
}

/// 读全部操作并回填撤销标记。日志只追加：操作行在前、标记行在后，
/// 按 id 合并即是完整历史。
func readAgentOperations() -> [AgentOperation] {
    guard let text = try? String(contentsOf: agentOperationsFile(), encoding: .utf8) else { return [] }
    let dec = JSONDecoder.agentAPI
    var ops: [AgentOperation] = []
    var undone: [String: Date] = [:]
    for line in text.split(separator: "\n") where !line.isEmpty {
        let d = Data(line.utf8)
        if let op = try? dec.decode(AgentOperation.self, from: d) {
            ops.append(op)
        } else if let m = try? dec.decode(AgentUndoneMarker.self, from: d) {
            undone[m.id] = m.undoneAt
        }
        // 两类都解不开的行直接跳过：日志是账本，坏行不该掀翻整个历史
    }
    return ops.map { o in
        o.undoneAt == nil && undone[o.id] != nil
            ? AgentOperation(id: o.id, at: o.at, items: o.items, undoneAt: undone[o.id])
            : o
    }
}

// MARK: - en 词表（只读；位置与 safetyDBFileURL 同构）

private func enTableURL() -> URL? {
    // 测试覆盖入口：指到一个资源目录（下含 en.lproj/Localizable.strings）
    if let dir = ProcessInfo.processInfo.environment["DISKWISE_RESOURCES"], !dir.isEmpty {
        let u = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("en.lproj/Localizable.strings")
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    // 打包版（含 brew 的 binary symlink——proc_pidpath 解析回 .app）：
    // 明确点名 en.lproj，不跟随系统语言，agent 拿到的永远是英文
    if let u = Bundle.main.url(forResource: "Localizable", withExtension: "strings",
                               subdirectory: "en.lproj") { return u }
    // swift run 的兜底：cwd 就是包根目录（与 safetyDBFileURL 同一条约定）
    let dev = "Sources/DiskCleaner/Resources/en.lproj/Localizable.strings"
    return FileManager.default.fileExists(atPath: dev) ? URL(fileURLWithPath: dev) : nil
}

/// 词表是机器校验过的单行一条格式（"原文" = "译文";），逐行取前两个字符串
/// 字面量即可，与 build_app/l10n_tool.swift 的 readTable 同一算法。
private func loadEnTable() -> [String: String] {
    guard let url = enTableURL(), let text = try? String(contentsOf: url, encoding: .utf8) else {
        return [:]
    }
    var out: [String: String] = [:]
    for rawLine in text.split(separator: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("/") { continue }    // 空行与注释
        let segs = quotedSegments(line)
        if segs.count >= 2 { out[segs[0]] = segs[1] }
    }
    return out
}

private func quotedSegments(_ line: String) -> [String] {
    var out: [String] = []
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        guard chars[i] == "\"" else { i += 1; continue }
        var body = ""
        var j = i + 1
        var closed = false
        while j < chars.count {
            if chars[j] == "\\" && j + 1 < chars.count {
                body.append(chars[j + 1] == "n" ? "\n" : String(chars[j + 1]))
                j += 2
                continue
            }
            if chars[j] == "\"" { closed = true; break }
            body.append(chars[j])
            j += 1
        }
        if closed { out.append(body) }
        i = closed ? j + 1 : chars.count
    }
    return out
}

// 全局常量惰性初始化自带线程安全（scan 的 TaskGroup 里并发查表也不出事）
private let enTable: [String: String] = loadEnTable()

/// 中文原文 → 英文译文；词表没有这条时返回 nil，调用方回落中文原文。
public func enText(_ key: String) -> String? { enTable[key] }

// MARK: - 六个入口

/// 遍历知识库条目（与缓存页同一个宇宙），量出每处的真实占盘。
/// 产出的路径天然 exact；量到 0 的行不留——与缓存页同一条纪律，
/// 那个 0 多半是「读不动」而不是「空」。
public func agentScan(category: AgentCategory = .all, minBytes: Int64 = 0,
                      index: VerdictIndex = .shared) async -> [AgentItem] {
    let entries = loadSafetyEntries(from: safetyDBFileURL()).filter { e in
        switch category {
        case .all: return true
        case .dev: return e.grp == "dev"
        case .apps: return e.grp == "general" || e.grp == "cn_app"
        case .aiModels: return e.tags?.contains("ai_models") == true
        }
    }
    var targets: [(entry: SafetyEntry, url: URL)] = []
    var seen = Set<String>()
    for e in entries where !e.path.isEmpty {
        for u in globExpand(e.path) where !seen.contains(u.path) {
            seen.insert(u.path)
            targets.append((e, u))
        }
    }
    var sizes: [String: Int64] = [:]
    await withTaskGroup(of: (String, Int64).self) { group in
        for t in targets {
            group.addTask {
                (t.url.path, await pathStat(t.url).bytes)
            }
        }
        for await (p, b) in group { sizes[p] = b }
    }
    var out: [AgentItem] = []
    for t in targets {
        let c = agentPipeline(t.url.path, index: index)
        let item = agentItem(c, bytes: sizes[t.url.path] ?? 0)
        if item.bytes > 0 && item.bytes >= minBytes { out.append(item) }
    }
    out.sort { $0.bytes > $1.bytes }
    return out
}

/// 单个路径的完整画像（只读，不动任何文件）。
public func agentExplain(path: String, index: VerdictIndex = .shared) async -> AgentItem {
    let c = agentPipeline(path, index: index)
    return agentItem(c, bytes: await pathStat(c.url).bytes)
}

/// 生成计划：不动任何文件，只写计划文件。humanOverride 对应 --i-am-human
/// （放开 unknown 与非 exact；risky 仍拒）。超出条数或字节上限直接抛错，
/// 一个文件都不写——上限存在的意义就是让「一次端走整台机器」在源头失败。
public func agentPlan(paths: [String], humanOverride: Bool = false,
                      index: VerdictIndex = .shared) async throws -> AgentPlan {
    guard !paths.isEmpty else { throw AgentAPIError.invalidPath("no paths given") }
    var items: [AgentItem] = []
    var refused: [AgentItem] = []
    var records: [AgentPlanItemRecord] = []
    var seenPaths = Set<String>()
    for raw in paths {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        let c = agentPipeline(raw, index: index)
        if seenPaths.contains(c.url.path) { continue }
        seenPaths.insert(c.url.path)
        let bytes = await pathStat(c.url).bytes
        let item = agentItem(c, bytes: bytes)
        let allowed = c.refusal == nil || (humanOverride && c.humanRefusal == nil)
        if allowed {
            items.append(item)
            var st = stat()
            _ = lstat(c.url.path, &st)   // 管线刚确认存在；这里只为取绑定用的 inode
            records.append(AgentPlanItemRecord(path: c.url.path, bytes: bytes,
                                               dev: UInt64(st.st_dev), ino: UInt64(st.st_ino)))
        } else {
            refused.append(item)
        }
    }
    if items.isEmpty { throw AgentAPIError.invalidPath("no trashable paths in plan") }
    if items.count > agentPlanMaxItems {
        throw AgentAPIError.planTooLarge(items: items.count, bytes: 0)
    }
    // 汇总必须去嵌套：agent 给的列表可能套着（~/Library/Caches 与其子项），
    // 按条目相加会把同一份字节数两遍，用户看到的「将腾出」就虚高
    let total = contentsUnionSize(items.map { ($0.path, $0.bytes) })
    if total > agentPlanMaxBytes {
        throw AgentAPIError.planTooLarge(items: items.count, bytes: total)
    }
    let id = UUID().uuidString
    let now = Date()
    let record = AgentPlanRecord(planId: id, createdAt: now,
                                 expiresAt: now.addingTimeInterval(agentPlanTTL),
                                 human: humanOverride, items: records,
                                 refused: refused, totalBytes: total)
    let dir = agentPlansDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try JSONEncoder.agentAPI.encode(record)
        .write(to: dir.appendingPathComponent("\(id).json"))
    return AgentPlan(planId: id, createdAt: record.createdAt, expiresAt: record.expiresAt,
                     items: items, refused: refused, totalBytes: total)
}

/// 只执行此前生成的计划，对每一项重跑管线并核对 inode。计划过期或不存在是
/// 硬失败——整体拒绝，一个文件都不动；单项被拒是软失败——记录后继续，
/// 其余照做（与 CLI 退出码 2「部分成功」的语义对齐）。
///
/// trash 参数默认接 Core 唯一的删除路径 trashItem；自检注入假的搬法，
/// 不往真实废纸篓里丢测试垃圾——真废纸篓的往返由 CLI 手测覆盖。
public func agentExecute(planId: String, index: VerdictIndex = .shared,
                         trash: (URL) throws -> URL = trashItem) throws -> AgentResult {
    // plan_id 是我们自己签发的 UUID：带路径分隔符或向上的段一律当「不存在」，
    // 不给拼路径留缝（下面的 removeItem 只会碰自己签发、且解码合法的计划文件）
    guard !planId.isEmpty, !planId.contains("/"), !planId.contains("\\"),
          !planId.hasPrefix(".") else {
        throw AgentAPIError.planNotFound
    }
    let fileURL = agentPlansDir().appendingPathComponent("\(planId).json")
    guard let data = try? Data(contentsOf: fileURL),
          let rec = try? JSONDecoder.agentAPI.decode(AgentPlanRecord.self, from: data) else {
        throw AgentAPIError.planNotFound
    }
    guard Date() < rec.expiresAt else {
        // 过期计划就地删除：它已经不能被任何一次执行接受，留着只会堆积。
        // 删的是自家记账文件（agent/ 下的 JSON），不进废纸篓——铁律管的是
        // 用户数据；把内部状态丢进用户废纸篓才是错的一方。
        try? FileManager.default.removeItem(at: fileURL)
        throw AgentAPIError.planExpired
    }
    var trashed: [AgentTrashRecord] = []
    var failed: [AgentFailure] = []
    var trashedPaths: [String] = []
    for item in rec.items {
        let c = agentPipeline(item.path, index: index)
        var st = stat()
        let lstatOK = lstat(c.url.path, &st) == 0
        var fail: String? = nil
        if !lstatOK {
            // 前一项已经把父目录搬走：这一项不是「失败」，是被上一项顺路带走了
            if let anc = trashedPaths.first(where: { item.path == $0 || item.path.hasPrefix($0 + "/") }) {
                failed.append(AgentFailure(path: item.path, reason: "covered_by_earlier_item", detail: anc))
                continue
            }
            fail = AgentRefusal.notFound.rawValue
        } else if c.refusal != nil, !(rec.human && c.humanRefusal == nil) {
            // 管线拒绝优先于 inode 比对：换成软链就报 symlink、换成 risky 内容就报
            // may_lose_data——比 changed_since_plan 更能告诉 agent 下一步怎么办
            fail = c.refusal!.rawValue
        } else if UInt64(st.st_dev) != item.dev || UInt64(st.st_ino) != item.ino {
            // 路径还在、判词也没变，但 inode 换了：计划生成后原地换过内容
            fail = "changed_since_plan"
        }
        if let fail {
            failed.append(AgentFailure(path: item.path, reason: fail, detail: nil))
            continue
        }
        do {
            let inTrash = try trash(c.url)
            trashed.append(AgentTrashRecord(original: c.url.path, inTrash: inTrash.path,
                                            bytes: item.bytes,
                                            name: (c.url.path as NSString).lastPathComponent))
            trashedPaths.append(c.url.path)
        } catch let e as TrashError {
            // 原因码对齐管线；其余归 trash_failed，系统原话放 detail
            let reason: String
            switch e {
            case .protected: reason = AgentRefusal.protected.rawValue
            case .outsideAllowed: reason = AgentRefusal.outsideAllowed.rawValue
            default: reason = "trash_failed"
            }
            failed.append(AgentFailure(path: c.url.path, reason: reason, detail: e.detail))
        } catch {
            failed.append(AgentFailure(path: c.url.path, reason: "trash_failed",
                                       detail: error.localizedDescription))
        }
    }
    if !trashed.isEmpty {
        let opID = UUID().uuidString
        try appendJSONL(AgentOperation(id: opID, at: Date(), items: trashed),
                        to: agentOperationsFile())
        try? FileManager.default.removeItem(at: fileURL)   // 计划已消费
        return AgentResult(operationId: opID, trashed: trashed, failed: failed,
                           totalBytes: trashed.reduce(0) { $0 + $1.bytes })
    }
    // 一项都没搬成：不记操作（什么都没发生），但计划照删——重试也只会全拒
    try? FileManager.default.removeItem(at: fileURL)
    return AgentResult(operationId: "", trashed: [], failed: failed, totalBytes: 0)
}

/// 撤销一次操作（nil = 最近一次未撤销的）。走 untrash 的同名不覆盖逻辑；
/// 废纸篓里已不在的项报 gone_from_trash，不因一项失败中止其余恢复。
public func agentUndo(operationId: String? = nil) throws -> [AgentUndoStatus] {
    let ops = readAgentOperations()
    let target = operationId == nil
        ? ops.last { $0.undoneAt == nil }
        : ops.last { $0.id == operationId && $0.undoneAt == nil }
    guard let op = target else { throw AgentAPIError.noUndoableOperation }
    var out: [AgentUndoStatus] = []
    for it in op.items {
        guard FileManager.default.fileExists(atPath: it.inTrash) else {
            out.append(AgentUndoStatus(path: it.original, status: "gone_from_trash", detail: nil))
            continue
        }
        do {
            try untrash(TrashRecord(original: URL(fileURLWithPath: it.original),
                                    inTrash: URL(fileURLWithPath: it.inTrash),
                                    size: it.bytes, displayName: it.name ?? ""))
            out.append(AgentUndoStatus(path: it.original, status: "restored", detail: nil))
        } catch {
            out.append(AgentUndoStatus(path: it.original, status: "failed",
                                       detail: error.localizedDescription))
        }
    }
    try appendJSONL(AgentUndoneMarker(id: op.id, undoneAt: Date()), to: agentOperationsFile())
    return out
}

/// 最近 limit 次操作（按时间正序；调用方自己决定怎么摆）。
public func agentHistory(limit: Int = 20) -> [AgentOperation] {
    let ops = readAgentOperations()
    return Array(ops.suffix(max(0, limit)))
}
