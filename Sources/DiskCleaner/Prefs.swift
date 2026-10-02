import SwiftUI
import AppKit
import ServiceManagement

// ── 偏好：两格开关 ──────────────────────────────────────────────────────────
//
// 稿子①「这一版不做什么」写着不抽 Preferences 模型，所以这里就是两个
// 由 UserDefaults 背书的 published 值，谁要读谁自己拿 `Prefs.shared`。
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

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let menuBar = "diskcleaner.menubar.enabled"
    }

    private init() {
        menuBarEnabled = defaults.object(forKey: Keys.menuBar) == nil
            ? true
            : defaults.bool(forKey: Keys.menuBar)
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
