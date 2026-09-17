import Foundation

// ── 品牌：一个名字，两种语言都一样 ──
//
// 品牌名不进词表——「DiskWise」在中文界面里也写作 DiskWise。
// bundle id 保持 com.dreamofxm.diskcleaner 不动：它是钥匙串、自动化授权和 UserDefaults 的锚点，
// 改它等于让已有用户的偏好与授权作废。

enum Product {
    /// 界面上的显示名
    static let name = "DiskWise"
    /// 产物文件名：纯 ASCII，GitHub Release / DMG / 下载链路都省事
    static let fileName = "DiskWise"
    static let bundleID = "com.dreamofxm.diskcleaner"
}

// ── 反馈渠道：地址只这一处 ──
//
// 全是公开地址（README 里同样这几个），所以不进词表、不本地化。
// App 不联网，这些渠道都得用户主动发起；页面只负责把地址摆清楚并保证可复制。

enum Contact {
    static let email = "hnyxgxm2009@163.com"
    /// 交给系统打开邮件客户端要用带 scheme 的 URL，光一个地址没有 scheme
    static let mailto = "mailto:\(email)"
    static let qqGroup = "913022339"
    /// GitHub 上的 owner/repo，界面里展示的就是这一串
    static let repoSlug = "DreamOfXM/diskwise"
    static let repo = "https://github.com/\(repoSlug)"
    static let issues = "https://github.com/\(repoSlug)/issues"
}

// ── 编译期开关：皮肤是否按可用性分组展示 ──
//
// 判定在编译期完成（`CHANNEL=appstore bash build_app/build.sh` → `-DAPPSTORE`）：
// 默认 false，六套皮肤一律可用，`Theme.tier` 不参与判定，分区标题与 `PaywallSheet` 不渲染；
// 为 true 时可用性只由 `ThemeManager.canUse` / `unlock` 决定，视图不感知这个开关。

enum Channel {
    #if APPSTORE
    static let showsPricing = true
    #else
    static let showsPricing = false
    #endif
}
