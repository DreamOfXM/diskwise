import Foundation

// ── 导航历史（返回那一步靠的就是它）────────────────────────────────────────
//
// 「返回」这件事里唯一会算错的地方是**去重**。
//
// 用户在下钻页按「上一级」往回走时，父目录本来就在历史里。要是把这一步当成
// 新的一站追加，历史会变成「…父、子、父」——按返回又跳回子目录，来回打转出不去。
// 所以规则是：要去的这一站已经记过，就回到它、把它后面那段全丢掉；没记过才追加。
//
// 这条规则跟界面无关，所以放在 Core 里由自检逐条钉住，不靠界面那边自觉。
//
// 元素是泛型的：这里只管顺序和去重，不认「页」或「目录」是什么——那是 UI 的事。
// 栈里**恒有至少一站**，`current` 就是此刻这一屏；少了这个不变量，
// 第一跳之后栈底是空的，返回会退到没有页面的地方。

public struct NavStack<Stop: Equatable> {
    public private(set) var stops: [Stop]

    public init(first stop: Stop) {
        stops = [stop]
    }

    /// 还能不能往回退。只剩一站时不能。
    public var canGoBack: Bool { stops.count > 1 }

    /// 此刻这一站。
    public var current: Stop { stops[stops.count - 1] }

    /// 上一站。返回按钮那行说明写的就是它的名字；没有上一站时为 nil。
    public var previous: Stop? { canGoBack ? stops[stops.count - 2] : nil }

    /// 落一站。
    ///
    /// 返回「位置是否真的动了」：已经在栈顶就是 false。视图据此决定要不要重新
    /// 去量那一层——同一处点两次不该重扫。
    @discardableResult
    public mutating func arrive(_ stop: Stop) -> Bool {
        if let i = stops.lastIndex(of: stop) {
            guard i < stops.count - 1 else { return false }
            stops.removeSubrange((i + 1)...)
        } else {
            stops.append(stop)
        }
        return true
    }

    /// 退一步，返回退到哪一站。只剩一站时什么都不做、返回 nil。
    @discardableResult
    public mutating func pop() -> Stop? {
        guard canGoBack else { return nil }
        stops.removeLast()
        return stops[stops.count - 1]
    }

    /// 「根」入口：历史压成只有这一站，返回随即失效。
    ///
    /// 点侧栏、点面包屑首格都是在**重新挑目的地**，不是往下走一步。
    /// 把这些也记进历史的话，人会在缓存页按返回跳到大文件页，谁都不想要这个。
    public mutating func reset(to stop: Stop) {
        stops = [stop]
    }
}
