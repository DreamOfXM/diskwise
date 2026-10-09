import SwiftUI
import AppKit
import ServiceManagement

// ── 偏好：三格状态 ──────────────────────────────────────────────────────────
//
// 稿子①「这一版不做什么」写着不抽 Preferences 模型，所以这里就是几个
// 由 UserDefaults 背书的 published 值，谁要读谁自己拿 `Prefs.shared`。
// 盘上存的一共两个：菜单栏开关、「Agent 页进过没有」。后者不是开关——
// 「新」角标只能被抹掉、不能被点回来，所以它没有对应的 setter。
//
// 开机启动那一格不存自己的布尔：系统那份登记（SMAppService）才是真相，
// 界面显示的必须是回读到的状态。自己记一份就会出现「开关显示开着、
// 系统里其实没登记」这种两边对不上账的显示。

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    /// 菜单栏那颗容量读数。没存过 = 开（稿子①定的是「默认开着」）。
    @Published private(set) var menuBarEnabled: Bool
    /// 开机启动：登记请求是否已经交出去
    @Published private(set) var loginItemEnabled: Bool
    /// 已登记但系统还没放行——用户得自己去「系统设置 ▸ 通用 ▸ 登录项」里勾
    @Published private(set) var loginItemNeedsApproval: Bool
    /// AI Agent 页那枚「新」角标：没进过这一页时为 true，进去一次就永久收起。
    /// 盘上存的是「进过没有」（`seen`），界面读的是「还新不新」（`!seen`）——
    /// 没写过键的机器上 `bool(forKey:)` 回来 false，正好就是「没进过、还新」。
    @Published private(set) var agentPageIsNew: Bool

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let menuBar = "diskcleaner.menubar.enabled"
        static let agentSeen = "diskcleaner.agent.seen"
    }

    private init() {
        menuBarEnabled = defaults.object(forKey: Keys.menuBar) == nil
            ? true
            : defaults.bool(forKey: Keys.menuBar)
        agentPageIsNew = !defaults.bool(forKey: Keys.agentSeen)
        let status = Self.loginStatus
        loginItemEnabled = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    static var loginStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// 登记了但还没生效：这一格要给一句「去系统设置里放行」的出口，
    /// 不能只留一个看起来像坏了的开关。
    var loginItemBlocked: Bool { loginItemEnabled && Self.loginStatus != .enabled }

    func setMenuBar(_ on: Bool) {
        guard on != menuBarEnabled else { return }
        menuBarEnabled = on
        defaults.set(on, forKey: Keys.menuBar)
        MenuBar.readout.apply(shows: on)
    }

    /// 进过 AI Agent 页：角标从此不再画。只在真的落到那一屏时调一次，
    /// 侧栏划过、悬停都不算——否则角标会在用户还没看见它时就自己收起来。
    func markAgentPageSeen() {
        guard agentPageIsNew else { return }
        agentPageIsNew = false
        defaults.set(true, forKey: Keys.agentSeen)
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // 不自己编失败原因：写回去读到的状态就是最终答案，读回来没变，开关就弹回原位。
        }
        let status = Self.loginStatus
        loginItemEnabled = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    /// 系统设置里管登录项那一大页。深链是公开写法，不是内部接口。
    static func openLoginItemsSettings() {
        guard let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(u)
    }
}
