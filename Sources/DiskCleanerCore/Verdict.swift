import Foundation
import Darwin

// ── 知识库判词：给任意一个路径，回答「这是什么东西、能不能放心删」──
//
// 缓存两页是从**条目**出发找路径（`globExpand` 把知识库那几十条展开成具体位置）；
// 总览与文件夹详情正相反，是从**一个已经量出来的目录**出发反问「它是什么」。
//
// 后者不能跑 glob：一层九十多个目录，每个都去展开一遍通配是白烧，而且展开的结果是
// 「现在存在的位置」，反查一个已经不存在的路径就没答案了。
//
// 所以这里**逐段比对**：把条目路径和候选路径都按 `/` 切开，字面段要求相等，
// 含通配的段走 `fnmatch`。逐段而不是「截到第一个通配为止」，是因为后者会造出
// 一个比条目宽得多的前缀——`~/Library/Application Support/*[Dd]ing[Tt]alk*/log`
// 截出来是 `~/Library/Application Support`，那会把整个 Application Support
// 判成「安全」，而那一层住着几十个 App 的真实数据。
//
// 三档：安全（有可靠的再生成路径）/ 留意（能删，但要知道代价）/ 不认识。
//
// **第三档必须存在。** 没命中不等于安全：`~/Library` 本身就不是知识库里的任何一处，
// 而它显然不是「可以删」的。界面上明说「不认识」比默认说「安全」诚实。

/// 一个路径落在知识库里的三档之一。
public enum VerdictTier: String {
    /// 知识库认得它，而且有可靠的再生成路径。
    case safe
    /// 知识库认得它，但删了有代价——重下几十 G、环境要重建、或者只有用户知道里面是什么。
    case caution
    /// 知识库里没有它。**不是**「安全」的同义词。
    case unknown
}

public struct Verdict {
    public let tier: VerdictTier
    /// 命中的那一条。`nil` = 知识库不认得这个路径。
    public let entry: SafetyEntry?
    /// 命中的就是路径本身，而不是它上面的某一层。
    ///
    /// 界面要这个区别：`~/Library/Developer/CoreSimulator/Devices/XXXX` 底下某一台
    /// 模拟器，和 `~/Library/Developer/CoreSimulator/Devices` 本身，说的不是同一句话。
    public let exact: Bool
    /// 这条路径**底下**还有几处是知识库认得的。
    ///
    /// 用来把「不认识」说清楚：`~/Library` 本身不在库里，但它下面躺着 Caches、
    /// DerivedData 这些认得的。没有这个数，「不认识」就成了一句死话。
    public let knownBelow: Int

    public var known: Bool { entry != nil }
}

/// 路径 → 判词的索引。构建一次（几十条），之后每次查询是几十次短字符串比对。
public struct VerdictIndex {
    private struct Item {
        let segs: [String]
        let entry: SafetyEntry
    }

    /// 按段数降序，深的先匹配。
    private let items: [Item]

    public init(entries: [SafetyEntry]) {
        items = entries
            .compactMap { e -> Item? in
                let s = Self.segments(expandHome(e.path))
                return s.isEmpty ? nil : Item(segs: s, entry: e)
            }
            .sorted { $0.segs.count > $1.segs.count }
    }

    /// 打包版 / `swift run` 都走这一份。
    public static let shared = VerdictIndex(entries: loadSafetyEntries(from: safetyDBFileURL()))

    public func verdict(for path: String) -> Verdict {
        let ps = Self.segments(path)
        guard !ps.isEmpty else {
            return Verdict(tier: .unknown, entry: nil, exact: false, knownBelow: 0)
        }
        var best: Item? = nil
        var below = 0
        for it in items {
            // 条目比候选路径**更深**：那不是命中它，是它躺在候选路径底下。
            // 方向要跟下面那条反过来——`covers` 比的是「前缀」，同一个参数顺序
            // 在这里恒为 false，`knownBelow` 就会永远报 0。
            if it.segs.count > ps.count {
                if Self.covers(ps, it.segs) { below += 1 }
                continue
            }
            guard Self.covers(it.segs, ps) else { continue }
            if best == nil || it.segs.count > best!.segs.count { best = it }
        }
        guard let h = best else {
            return Verdict(tier: .unknown, entry: nil, exact: false, knownBelow: below)
        }
        return Verdict(tier: h.entry.level == "warn" ? .caution : .safe,
                       entry: h.entry,
                       exact: h.segs.count == ps.count,
                       knownBelow: below)
    }

    /// 绝对路径按 `/` 切段。相对路径（知识库里不该有，但也不排除写错）一律不认——
    /// 认了就会把判词挂到想不到的地方去。
    static func segments(_ p: String) -> [String] {
        guard p.hasPrefix("/") else { return [] }
        return p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// 这一串段能不能盖住那串段：字面段要求相等，含通配的段走 `fnmatch`。
    static func covers(_ pat: [String], _ path: [String]) -> Bool {
        guard pat.count <= path.count else { return false }
        for i in 0..<pat.count where !segmentMatch(pat[i], path[i]) { return false }
        return true
    }

    static func segmentMatch(_ pat: String, _ s: String) -> Bool {
        if pat.contains("*") || pat.contains("?") || pat.contains("[") {
            return fnmatch(pat, s, 0) == 0
        }
        return pat == s
    }
}

/// 知识库文件位置：打包版在 `Contents/Resources`，`swift run` 时在包根目录的源码树里。
///
/// 刻意不用 `Bundle.module`——它的生成代码找不到 `.bundle` 就 `fatalError`，
/// 且回退路径是构建机的绝对路径，等于只有开发者自己的机器能打开这一页。
public func safetyDBFileURL() -> URL? {
    if let u = Bundle.main.url(forResource: "safety_db", withExtension: "json") { return u }
    let dev = "Sources/DiskCleaner/Resources/safety_db.json"
    return FileManager.default.fileExists(atPath: dev) ? URL(fileURLWithPath: dev) : nil
}
