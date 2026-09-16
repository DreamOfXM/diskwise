import SwiftUI

// ── 皮肤持有者：选择 / 持久化 / 解锁 / 试穿 ────────────────────────────────
//
// 商业化只有两个接缝，接 StoreKit 时改这两处就够，视图一行不动：
//   canUse(_:)  —— 能不能用（改成查交易收据）
//   unlock(_:)  —— 怎么解锁（改成走 Product.purchase）

final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var current: Theme
    /// 已购买的付费皮肤 id
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
        current = unlocked.contains(candidate.id) || candidate.tier == .free
            ? candidate : .dawn
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

    func canUse(_ theme: Theme) -> Bool {
        theme.tier == .free || unlockedPremiumIDs.contains(theme.id)
    }

    @discardableResult
    func select(_ theme: Theme) -> Bool {
        guard canUse(theme) else { return false }
        tryingID = nil
        current = theme
        defaults.set(theme.id, forKey: Keys.selected)
        return true
    }

    /// 试穿：付费皮肤先穿上身再决定买不买。锁定态下不许直接 select，只能试。
    func startTrying(_ theme: Theme) {
        guard theme.tier == .premium else { return }
        tryingID = theme.id
    }

    func stopTrying() {
        tryingID = nil
    }

    /// StoreKit 桩：购买成功后由交易回调调用
    func unlock(_ theme: Theme) {
        unlockedPremiumIDs.insert(theme.id)
        defaults.set(Array(unlockedPremiumIDs), forKey: Keys.unlocked)
        tryingID = nil
        select(theme)
    }
}
