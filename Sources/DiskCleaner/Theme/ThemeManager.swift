import SwiftUI

// ── 皮肤持有者：选择 / 持久化 / 解锁 / 试穿 ────────────────────────────────
//
// 「这套皮肤能不能用」只有 `usable(_:unlocked:)` 一个判定入口（编译期开关 + 解锁记录），
// `canUse(_:)` 只是拿当前解锁集喂它。要改判定只动这两处，视图一行不动：
//   canUse(_:)  —— 能不能用
//   unlock(_:)  —— 怎么记为可用

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var current: Theme
    /// 已解锁的进阶皮肤 id（`Channel.showsPricing` 为真时才参与判定）
    @Published var unlockedPremiumIDs: Set<String> = []
    /// 试穿中的皮肤 id：能看能摸，不写入偏好，切走即还原
    @Published private(set) var tryingID: String?
    /// 明暗模式：nil = 跟随系统，否则强制
    @Published var forcedScheme: ColorScheme? {
        didSet {
            switch forcedScheme {
            case .some(.dark): defaults.set("dark", forKey: Keys.forcedScheme)
            case .some(.light): defaults.set("light", forKey: Keys.forcedScheme)
            default: defaults.removeObject(forKey: Keys.forcedScheme)
            }
        }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let selected = "diskcleaner.theme.id"
        /// v0.2 及以前用的键，升级时要搬家
        static let legacySelected = "diskcleaner.skin.id"
        static let unlocked = "diskcleaner.theme.premium.unlocked"
        static let forcedScheme = "diskcleaner.theme.forcedScheme"
    }

    init() {
        let stored = defaults.string(forKey: Keys.selected)
        let saved = stored ?? defaults.string(forKey: Keys.legacySelected) ?? Theme.dawn.id
        let migrated = Theme.migrateLegacyID(saved)
        let candidate = Theme.byID(migrated) ?? .dawn
        let unlocked = Set(defaults.stringArray(forKey: Keys.unlocked) ?? [])
        unlockedPremiumIDs = unlocked
        current = Self.usable(candidate, unlocked: unlocked) ? candidate : .dawn
        // 逐屏实拍要用深色/玻璃皮验外框，但偏好里存的是浅皮：给个环境变量入口，
        // 只在正常启动时生效（截图模式自己注入 Theme，走不到这里）。
        if let forced = SnapshotMode.requestedSkinID, let skin = Theme.byID(forced) {
            current = skin
        }
        if let raw = defaults.string(forKey: Keys.forcedScheme) {
            forcedScheme = raw == "dark" ? .dark : (raw == "light" ? .light : nil)
        }
        if migrated != saved || stored == nil { defaults.set(migrated, forKey: Keys.selected) }
    }

    /// 实际生效的皮肤：试穿优先于已选
    var effective: Theme {
        (tryingID.flatMap { Theme.byID($0) }) ?? current
    }

    /// 实际生效的明暗：App 级开关优先于皮肤自带
    var effectiveScheme: ColorScheme? {
        forcedScheme ?? effective.scheme
    }

    /// 能不能用：开关关闭时全部放行；开关打开时按 tier + 解锁记录。
    static func usable(_ theme: Theme, unlocked: Set<String>) -> Bool {
        !Channel.showsPricing || theme.tier == .free || unlocked.contains(theme.id)
    }

    func canUse(_ theme: Theme) -> Bool {
        Self.usable(theme, unlocked: unlockedPremiumIDs)
    }

    @discardableResult
    func select(_ theme: Theme) -> Bool {
        guard canUse(theme) else { return false }
        tryingID = nil
        current = theme
        defaults.set(theme.id, forKey: Keys.selected)
        return true
    }

    /// 试穿：先穿上身再决定留不留。锁定态不许直接 select，只能试。
    func startTrying(_ theme: Theme) {
        guard theme.isPaid, !canUse(theme) else { return }
        tryingID = theme.id
    }

    func stopTrying() {
        tryingID = nil
    }

    /// 截图模式专用：把皮肤直接穿上身，但不碰偏好。
    /// 皮肤页那张「使用中」徽章读的是 `current`，只往渲染器注入 Theme 的话，
    /// 图里画着晨雾、徽章却指着作者上次选的那套——徽章会撒谎。
    func useForSnapshot(_ theme: Theme) {
        tryingID = nil
        current = theme
    }

    /// 记为已解锁：当前实现是直接放行
    func unlock(_ theme: Theme) {
        unlockedPremiumIDs.insert(theme.id)
        defaults.set(Array(unlockedPremiumIDs), forKey: Keys.unlocked)
        tryingID = nil
        select(theme)
    }
}
