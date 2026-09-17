import SwiftUI
import AppKit
import DiskCleanerCore

// ── 沙盒授权 ───────────────────────────────────────────────────────────────
//
// 沙盒版拿不到「直接读 ~/Library」这种能力：Foundation 的 homeDirectoryForCurrentUser
// 会被改写成 App 自己的容器目录，拿它当扫描根不会报错，只会安静地扫一个空壳，
// 然后告诉用户「你机器上几乎没东西」。所以授权必须先于任何扫描发生，
// 没授权时界面停在这一页，一屏数字都不给。
//
// 走的是 Apple 认可的那条路：NSOpenPanel 让用户亲手选家目录 → security-scoped
// bookmark 存下来 → 之后每次启动 restore() 续上，不再打扰。

@MainActor
final class HomeGrant: ObservableObject {
    static let shared = HomeGrant()

    @Published private(set) var needsGrant = HomeAccess.needsGrant
    @Published var failure: String?

    func refresh() { needsGrant = HomeAccess.needsGrant }

    func request() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = false
        panel.treatsFilePackagesAsDirectories = false
        panel.prompt = L("授权访问")
        panel.message = L("已经帮你定位到家目录了，直接点「授权访问」就行。DiskWise 只读你选中的这一个目录。")
        panel.directoryURL = realHomeDir()

        guard panel.runModal() == .OK, let picked = panel.url else { return }
        if HomeAccess.grant(picked) {
            failure = nil
            refresh()
        } else {
            failure = L("授权没生效，再试一次。")
        }
    }

    /// 选错了目录（比如选了移动硬盘）时的出口。
    func revoke() {
        HomeAccess.revoke()
        refresh()
    }
}

struct HomeGrantView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var grant = HomeGrant.shared

    var body: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 40)
            ZStack {
                Circle().fill(theme.palette.tintSoft)
                    .frame(width: 76, height: 76)
                Image(systemName: "lock.badge.clock")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(theme.palette.tint)
            }
            .accessibilityHidden(true)

            Text(L("还没拿到访问授权"))
                .font(theme.display(.headline))
                .foregroundStyle(theme.palette.ink)

            Text(L("沙盒版不能自己翻你的硬盘。选一次家目录，DiskWise 才知道空间去了哪；之后不会再问。"))
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)

            ThemeButton(kind: .primary, symbol: "folder.badge.gearshape",
                        title: L("授权家目录")) { grant.request() }

            if let failure = grant.failure {
                Text(failure)
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkSecondary)
            }

            Text(L("它只读你选中的这一个目录：不联网、不上传，删除一律进废纸篓。"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }
}
