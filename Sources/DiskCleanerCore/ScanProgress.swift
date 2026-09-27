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

    public let counted: Counted
    private let lock = NSLock()
    private var _files = 0
    private var _bytes: Int64 = 0
    private var _current = ""
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
}
