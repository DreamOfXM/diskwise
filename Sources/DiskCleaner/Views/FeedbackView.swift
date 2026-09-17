import SwiftUI
import AppKit
import DiskCleanerCore

// ── 问题反馈页 ─────────────────────────────────────────────────────────────
//
// 这个 App 不联网，所以"发送反馈"这个按钮天生不存在。页面能做的是把三条
// 公开渠道摆清楚、保证一眼可读、一键可复制，再告诉用户怎么提才有用。
//
// 地址全部来自 Product.swift 的 Contact——README 用的是同一批值，两处不会漂。
// 二维码是仓库里的 docs/contact/qq-group.png：打包版进 Contents/Resources，
// `swift run` 走源码树兜底，与 safety_db.json 同一套路子（Bundle.module 禁用，
// 理由见 docs/ARCHITECTURE.md §4.1）。

/// 二维码位置：打包版在 bundle 里，开发态在仓库的 docs/contact 下
private func qqQRURL() -> URL? {
    if let u = Bundle.main.url(forResource: "qq-group", withExtension: "png") { return u }
    let dev = "docs/contact/qq-group.png"
    return FileManager.default.fileExists(atPath: dev) ? URL(fileURLWithPath: dev) : nil
}

/// 加载一次就够：这是张静态图，没必要跟着皮肤重画
private let qqQRImage: NSImage? = qqQRURL().flatMap { NSImage(contentsOf: $0) }

struct FeedbackView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(symbol: "text.bubble", title: L("问题反馈"),
                           subtitle: L("App 不联网，反馈得由你亲手发出来"),
                           variant: .display)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        emailCard
                        qqCard
                        githubCard
                        hints
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    // 这一页是文字页不是列表页：行长不封顶会读成横幅，靠左是为了跟页头对齐
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .themedList()
            }
            .pagePadding()
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(L("问题反馈"))
    }

    // MARK: 三条渠道

    private var emailCard: some View {
        FeedbackCard(symbol: "envelope", title: L("邮箱"),
                     subtitle: Contact.email,
                     extra: { EmptyView() }) {
            ThemeButton(kind: .secondary, symbol: "doc.on.doc",
                        title: L("复制地址")) { copy(Contact.email) }
            ThemeButton(kind: .primary, symbol: "paperplane",
                        title: L("写邮件")) { open(Contact.mailto) }
        }
    }

    private var qqCard: some View {
        FeedbackCard(symbol: "qrcode", title: L("QQ 群"),
                     subtitle: LF("群号 %@", Contact.qqGroup),
                     extra: { qqBody }) {
            EmptyView()
        }
    }

    private var githubCard: some View {
        FeedbackCard(symbol: "chevron.left.forwardslash.chevron.right",
                     title: L("GitHub Issue"),
                     subtitle: LF("仓库 %@", Contact.repoSlug),
                     extra: { EmptyView() }) {
            ThemeButton(kind: .secondary, symbol: "doc.on.doc",
                        title: L("复制仓库")) { copy(Contact.repo) }
            ThemeButton(kind: .primary, symbol: "arrow.up.right.square",
                        title: L("提 Issue")) { open(Contact.issues) }
        }
    }

    /// 二维码 + 用法。图没打进来时不能空着：群号还在，给一句能照着做的兜底。
    private var qqBody: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 9) {
                Text(L("手机打开 QQ，扫这个码进群"))
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("加不上就按群号搜索，或直接把问题发到邮箱"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("群里聊什么：清理求助、缓存知识库补条目、使用技巧"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ThemeButton(kind: .secondary, symbol: "doc.on.doc",
                            title: L("复制群号")) { copy(Contact.qqGroup) }
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let image = qqQRImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 200)
                    .clipShape(theme.cardShape())
                    .overlay(theme.cardShape().stroke(theme.palette.separator,
                                                     lineWidth: theme.metric.stroke))
                    .accessibilityLabel(L("QQ 群二维码"))
            } else {
                Text(LF("二维码没能加载出来。在 QQ 里按群号 %@ 搜索也能加。", Contact.qqGroup))
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .frame(width: 200, height: 200, alignment: .center)
                    .background(theme.cardShape().fill(theme.palette.surfaceAlt))
            }
        }
        .padding(.top, 4)
    }

    // MARK: 怎么提才有用

    private var hints: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: L("怎么提才有用"))
            VStack(alignment: .leading, spacing: 8) {
                ExplainLine(key: L("你在哪一步"),
                            value: L("哪一页、点了哪个按钮、扫的是哪个目录"))
                ExplainLine(key: L("看到了什么"),
                            value: L("报错原文整段贴过来，截图也行"))
                ExplainLine(key: L("你的机器"),
                            value: L("macOS 版本、Apple Silicon 还是 Intel"))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardShape().fill(theme.palette.surface))
            .overlay(theme.cardShape().stroke(theme.palette.separator,
                                             lineWidth: theme.metric.stroke))

            Text(L("这个 App 不联网，也没有任何遥测：以上信息只有你主动发出来时才存在。"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    // MARK: 动作

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        store.notice = pb.setString(text, forType: .string)
            ? LF("已复制到剪贴板：%@", text)
            : L("复制失败，请手动选中复制")
    }

    private func open(_ target: String) {
        guard let url = URL(string: target) else { return }
        if !NSWorkspace.shared.open(url) {
            store.notice = LF("打不开 %@，可能被系统拦了", target)
        }
    }
}

// MARK: - 渠道卡

/// 一张卡 = 一个渠道：图标块 + 名称 + 地址 + 右侧动作。
/// 地址永远用正文字色，不做彩色链接——设计铁律见 docs/DESIGN.md §2。
private struct FeedbackCard<Actions: View, Extra: View>: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var title: String
    var subtitle: String
    @ViewBuilder var extra: () -> Extra
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                IconTile(symbol: symbol, side: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(theme.display(.subheadline))
                        .tracking(theme.titleTracking)
                        .foregroundStyle(theme.palette.ink)
                    Text(subtitle)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                actions()
            }
            extra()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardShape().fill(theme.palette.surface))
        .overlay(theme.cardShape().stroke(theme.palette.separator,
                                         lineWidth: theme.metric.stroke))
    }
}

extension FeedbackCard where Extra == EmptyView {
    init(symbol: String, title: String, subtitle: String,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.extra = { EmptyView() }
        self.actions = actions
    }
}
