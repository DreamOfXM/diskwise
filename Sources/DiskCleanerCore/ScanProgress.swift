import Foundation

// ── 扫描中的实时读数 ──
//
// 只有「正在扫描…」那句话的扫描，读起来和卡死没有区别：整盘范围要走几分钟，
// 而这段时间里界面上唯一在动的是骨架行那五道灰——它证明不了任何东西。
// 竞品在那一刻报的是「正在看哪个目录 + 已经检查了多少个文件」，
// 那是「它真的在干活、而且知道自己在干什么」的唯一现场证据。
//
// 刻意不做成 ObservableObject：一趟整盘遍历要碰几十万个条目，每个都发一次
// objectWillChange 会把 UI 淹掉，而读数本身不需要每个条目都刷新。
// 所以这里只是一只上了锁的计数器，由界面按自己的节拍去取快照（见 `LoadingRow`）。

public final class ScanProgress: @unchecked Sendable {
    /// 那个计数数的是什么。大文件页数的是文件，node_modules 页在找目录的过程中数的是
    /// 目录项——两种都真的被看过，但只有前者能叫「文件」。界面按这个选名词，
    /// 宁可写「条目」也不把「个文件」套到数目录的那趟上。
    public enum Counted { case files, entries }

    public struct Reading {
        public var files: Int
        public var bytes: Int64
        /// 最后走过的那个目录（不是文件）：界面上按它做中段截断，
        /// 文件名比目录名长得多，报文件会把整行占满。
        public var current: String
        public var elapsed: TimeInterval
    }

    /// 清单上的一格：这一趟要走的一处地方。
    ///
    /// 「预列」是这张清单的立身之本——这些格子在**第一步之前**就摆出来（见 `plan`），
    /// 所以「走到哪儿了」才有分母。走到哪亮到哪，见界面上的 `ScanChecklist`。
    ///
    /// 它跟「已检查 N 个条目」那句读数是两回事：那句回答「它还在动吗」，
    /// 这张清单回答「它打算走哪几处、走到第几处了、每一处量出来多少」。
    public struct Station: Identifiable {
        public enum State { case pending, active, done }

        /// 预列时的序号，一路不变。`enter` / `finish` 按它认人，**不按名字找**——
        /// 同名的两处（两个 `Cache`、两处 `node_modules`）按名字找必然错一处。
        public let index: Int
        /// 直接印在清单上的短名：家目录收成 `~`，其余取尾段。
        public var label: String
        /// 完整位置（或本来就是短名的目录名）。鼠标停上去看，不占行的宽度。
        public var detail: String
        public var state: State
        /// 这一处占了多少。走完才有意义；没走完的一律 0，界面也就不印。
        public var bytes: Int64

        public var id: Int { index }
    }

    public let counted: Counted
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _current = ""
    private var _stations: [Station] = []
    private let started = Date()

    public init(counted: Counted = .files) { self.counted = counted }

    /// 走过一批条目。按目录批量调，别按文件调——锁的开销是次要的，
    /// 而「正在看哪儿」这个问题本来就是以目录为单位的。
    public func walk(files: Int, bytes: Int64, in dir: String) {
        guard files > 0 || !dir.isEmpty else { return }
        lock.lock()
        _files += files
        _bytes += bytes
        if !dir.isEmpty { _current = dir }
        lock.unlock()
    }

    public func snapshot() -> Reading {
        lock.lock(); defer { lock.unlock() }
        return Reading(files: _files, bytes: _bytes, current: _current,
                       elapsed: Date().timeIntervalSince(started))
    }

    // ── 清单：这一趟要走的地方 ─────────────────────────────────────────────

    /// 预列这一趟要走的地方。**先列后走**：清单在第一步之前就摆出来。
    ///
    /// 各扫描函数自己调，一趟里后面的阶段可以再追加一批（node_modules 先「翻目录」
    /// 再「逐个量」）：追加的排在已有的后面，于是清单读起来正好是这一趟实际走的顺序。
    /// 传进来的是**位置**——大多是路径（`shortName` 取尾段当短名，家目录收成 `~`），
    /// 也有本来就只有名字的（卸载残留那几处按 `~/Library` 下的目录名走）。
    ///
    /// 返回每一格的序号，调用方拿着它 `enter` / `finish`。
    @discardableResult
    public func plan(_ places: [String]) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        let base = _stations.count
        let names = Self.labels(for: places)
        for (i, p) in places.enumerated() {
            _stations.append(Station(index: base + i, label: names[i], detail: p,
                                     state: .pending, bytes: 0))
        }
        return Array(base..<(base + places.count))
    }

    /// 走到某一处。
    public func enter(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard _stations.indices.contains(index) else { return }
        _stations[index].state = .active
    }

    /// 这一处走完了，顺手记下它占了多少。
    public func finish(_ index: Int, bytes: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard _stations.indices.contains(index) else { return }
        _stations[index].state = .done
        _stations[index].bytes = bytes
    }

    /// 清单快照。跟 `snapshot()` 一个路数：由界面按自己的节拍取，不走 `objectWillChange`。
    public func stations() -> [Station] {
        lock.lock(); defer { lock.unlock() }
        return _stations
    }

    /// 一批格子的短名。同一批里重名就**一起加长**，直到分得开为止。
    ///
    /// `/Applications`、`/System/Applications`、`~/Applications` 各占一格时，
    /// 只写尾段是三个一模一样的「Applications」——清单要答的「现在走到哪一处」就没答。
    /// 加长只发生在真的重名时，所以 `Application Support` 这种本来就长的名字不会被无谓地拖长。
    public static func labels(for places: [String]) -> [String] {
        var depth = 1
        var out = places.map { shortName($0, depth: depth) }
        while Set(out).count != out.count && depth < 4 {
            depth += 1
            out = places.map { shortName($0, depth: depth) }
        }
        return out
    }

    /// 清单上一格的短名。
    ///
    /// - 家目录就是 `~`。
    /// - 家目录里的一处只写尾段（进这一页时面包屑已经说了在哪一层），重名才补成 `~/两段`。
    /// - 家目录之外的**至少留两段**：`/usr/local` 只写 `local`、`/System/Volumes/Data/System`
    ///   只写 `System`，都会跟别处混成同一件事——而这两个正是整盘范围里的真根。
    /// - 本来就没有路径分隔符的（Docker 的运行时名、卸载残留按目录名走的那几处）原样留着。
    public static func shortName(_ place: String, depth: Int = 1) -> String {
        let home = homePath()
        if place == home { return "~" }
        let underHome = place.hasPrefix(home + "/")
        var comps = place.split(separator: "/").map(String.init)
        if underHome {
            comps = Array(comps.dropFirst(home.split(separator: "/").count))
        }
        guard let last = comps.last else { return place }
        if !underHome { return comps.suffix(max(depth, 2)).joined(separator: "/") }
        return depth <= 1 ? last : "~/" + comps.suffix(max(depth, 2)).joined(separator: "/")
    }
}
