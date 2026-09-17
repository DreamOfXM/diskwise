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

// ── 发行渠道 ──
//
// `CHANNEL=appstore bash build_app/build.sh` 会带上 `-DAPPSTORE`：Mac App Store 必须进沙盒，
// 证书和产物格式也跟直链分发不同（两张证书不能互换，见 docs/RELEASE.md）。
//
// `showsPricing` 是另一回事，它只决定「皮肤按可用性分组 + 付费墙」是否渲染：为 false 时六套
// 皮肤一律可用，`Theme.tier` 不参与判定，付费墙不会渲染。两个渠道当前都是 false
// ——挂着「解锁」按钮却直接放行是审核指南 2.1 的明确拒点，所以要等内购真的接上才能翻。

enum Channel {
    #if APPSTORE
    static let isAppStore = true
    #else
    static let isAppStore = false
    #endif

    static let showsPricing = false
}
