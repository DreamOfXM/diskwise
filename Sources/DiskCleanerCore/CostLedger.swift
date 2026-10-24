import Foundation

// ── 代价四类：把盘上的字节按「清掉它要付什么」分成四堆 ──
//
// 这是总览那枚「按空间 / 按代价」开关背后的账。按空间问「谁占了地方」；按代价问同一块盘
// 「清掉之后要付什么」。两问必须落在**同一块盘、同一个分母**上：四类相加就是整盘，
// 一个字节不多、一个字节不少。
//
// 设计稿原来那本账混着两个分母：零代价按整段体积算、需重下按可回收量算、不可逆按整段
// 体积算、不碰按系统+空闲算。四行加起来 62.4 GB，而盘是 96 GB——「需重下」量的是**能收走
// 多少**，其余三行量的是**那一段有多大**。两种量摆进同一排数字，用户没法判断哪一头更大。
//
// 这里只留一条判据：**每一段字节归给覆盖它的最轻那一档**。一处字节同时落在几条知识库
// 路径下时，本工具真会走的路线是最轻的那条——能整块当缓存删掉的部分，不该按「重下」记账。
// 判词取最轻、嵌套只算一次，跟候选池「safe 优先、同档去嵌套」同源。两本账的分工是：
// 池子回答「这一次搬哪几处」，账本回答「每一段字节清掉要付什么」——父项被池子剔掉时
// （它底下压着 safe），账本仍会把父项不重叠的那截按它自己的代价记上。
//
// 轻重次序：零代价 < 需重下 < 不可逆 < 不碰。前三档由知识库给，第四档是整盘的补集：
// 空闲、系统区、知识库不认得的字节全在里面——它不是「删了没事」，是「本工具不动」。

/// 清掉这一堆字节要付的代价。界面上的四个名字：零代价 / 需重下 / 不可逆 / 不碰。
public enum CostTier: String, CaseIterable, Sendable {
    /// 删了会自己再生成：缓存、构建产物。付的是时间，不是数据。
    case free
    /// 删了要重新下载或重建：模型权重、依赖仓库、模拟器运行镜像。
    case redo
    /// 删了就没了：模拟器里的 App 数据、聊天图片、会话记录。
    case irreversible
    /// 本工具不碰。也是整盘减掉前三类之后的补集。
    case off

    /// 轻重编号：同一段字节落在几条路径下时取最小的那一档。
    var weight: Int {
        switch self {
        case .free: return 0
        case .redo: return 1
        case .irreversible: return 2
        case .off: return 3
        }
    }
}

public extension VerdictTier {
    /// 判词那四档在代价账里各归哪一堆。
    ///
    /// `unknown` 归「不碰」而不是「不可逆」：这本账只数**本工具真会动**的字节，
    /// 知识库不认得的那些从来不在候选里，它们和空闲、系统区一样是补集的一部分。
    /// 「不碰」说的是「本工具不动」，不是「删了没事」——后者是 `safe`，两条轴不在这里合并。
    var cost: CostTier {
        switch self {
        case .safe: return .free
        case .redo: return .redo
        case .risky: return .irreversible
        case .unknown: return .off
        }
    }
}

/// 候选池里的一处字节：路径、此刻占着多少、知识库怎么判它。
///
/// 跟 `ReclaimTarget` 分开：那边只收整段搬得走的 `safe`，是环形那道亮沿的输入；
/// 这本账要连 `warn` 一起数，不然「不可逆」永远是零，四类就名不副实。
public struct CostItem: Equatable, Sendable {
    public let path: String
    public let bytes: Int64
    public let tier: VerdictTier

    public init(path: String, bytes: Int64, tier: VerdictTier) {
        self.path = path
        self.bytes = bytes
        self.tier = tier
    }
}

/// 前三类的合计。「不碰」不在这里：它是整盘减掉这三类之后的补集，
/// 只有拿到整盘容量（见 `CostLedger`）才算得出来。
public struct CostSums: Equatable, Sendable {
    public private(set) var free: Int64
    public private(set) var redo: Int64
    public private(set) var irreversible: Int64

    public init(free: Int64 = 0, redo: Int64 = 0, irreversible: Int64 = 0) {
        self.free = free
        self.redo = redo
        self.irreversible = irreversible
    }

    /// 本工具能动的那部分字节。恒等于候选路径的并集体积。
    public var actionable: Int64 { free + redo + irreversible }

    /// 某一档的字节。`off` 在前三类里没有存量，取它得走 `CostLedger.bytes(_:)`。
    public func bytes(_ tier: CostTier) -> Int64 {
        switch tier {
        case .free: return free
        case .redo: return redo
        case .irreversible: return irreversible
        case .off: return 0
        }
    }

    mutating func add(_ tier: CostTier, _ bytes: Int64) {
        switch tier {
        case .free: free += bytes
        case .redo: redo += bytes
        case .irreversible: irreversible += bytes
        case .off: break
        }
    }
}

/// 四类的完整账：前三类来自知识库，`off` 是补集，`total` 是整盘容量。
///
/// 恒等式 `free + redo + irreversible + off == total` 是这本账唯一的验收条件。
/// 判词认得的字节比整盘还多时（用量与扫描快照不同步才会出现），`off` 压到 0，
/// 多出来的那截记进 `overdrawn`——界面得说「多了多少」，不许印一个负的「不碰」。
public struct CostLedger: Equatable, Sendable {
    public let sums: CostSums
    public let total: Int64
    public let off: Int64
    public let overdrawn: Int64

    public init(sums: CostSums, total: Int64) {
        self.sums = sums
        self.total = max(0, total)
        let rest = self.total - sums.actionable
        off = max(0, rest)
        overdrawn = max(0, -rest)
    }

    public func bytes(_ tier: CostTier) -> Int64 {
        tier == .off ? off : sums.bytes(tier)
    }

    /// 四类之和。没超账时恒等于整盘。
    public var accounted: Int64 { sums.actionable + off }
    public var balanced: Bool { overdrawn == 0 }
}

/// 把一堆候选字节归成前三类。
///
/// 两条规矩，缺一条四类就和候选池对不上：
/// 1. 同一个路径被两条知识库命中时取**最轻**的判词（池子也是 safe 优先）。
/// 2. 嵌套路径逐层拆：父项的体积减去直接子项的，剩下的才算父项自己那一档；
///    子项按覆盖它的最轻那一档算。父项是 `redo`、底下有一块 `safe` 时，
///    那一块就是零代价——候选池也只会搬那一块，不会把整条 `Caches` 端走。
public func costSums(of items: [CostItem]) -> CostSums {
    var byPath: [String: (bytes: Int64, tier: VerdictTier)] = [:]
    for it in items {
        guard it.bytes > 0, it.path.hasPrefix("/") else { continue }
        let p = URL(fileURLWithPath: it.path).standardizedFileURL.path
        if let prev = byPath[p] {
            if it.tier.cost.weight < prev.tier.cost.weight {
                byPath[p] = (prev.bytes, it.tier)
            }
        } else {
            byPath[p] = (it.bytes, it.tier)
        }
    }
    let keys = Set(byPath.keys)
    var parent: [String: String] = [:]
    for p in keys {
        if let a = nearestAncestor(of: p, in: keys) { parent[p] = a }
    }
    // 每个直接子项只从它的父项里减一次：兄弟目录互不相交，逐层减下来，
    // 各节点「自己那一段」加起来正好是路径并集，不多不少。
    var childBytes: [String: Int64] = [:]
    for (p, v) in byPath {
        if let a = parent[p] { childBytes[a, default: 0] += v.bytes }
    }
    // 祖先一定比后代短，按长度排就是拓扑序。
    var inherited: [String: CostTier] = [:]
    var sums = CostSums()
    for p in keys.sorted(by: { $0.count < $1.count }) {
        let own = byPath[p]!.tier.cost
        let up = parent[p].flatMap { inherited[$0] } ?? own
        let cls = up.weight <= own.weight ? up : own
        inherited[p] = cls
        sums.add(cls, max(0, byPath[p]!.bytes - (childBytes[p] ?? 0)))
    }
    return sums
}

/// 这串路径在集合里最近的祖先（最深的那一层已经存在的顶层路径）。
///
/// 逐级往上找、撞到第一个就停——不能拿「截到第一个通配」那一套去拼，
/// 那会造出一个比真正路径宽得多的前缀。
private func nearestAncestor(of path: String, in set: Set<String>) -> String? {
    var cut = path
    while let i = cut.lastIndex(of: "/"), i > cut.startIndex {
        cut = String(cut[..<i])
        if set.contains(cut) { return cut }
    }
    return nil
}
