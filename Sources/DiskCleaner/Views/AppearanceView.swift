import SwiftUI
import DiskCleanerCore

// ── 外观皮肤页 ─────────────────────────────────────────────────────────────
//
// v0.2 的皮肤卡是三个色块，看不出彼此之间的骨架差异。
// v0.3 直接渲染"那套皮肤下的真实界面缩略图"：迷你侧边栏 + 环形图 + 列表行，
// 材质、字体、圆角、图表配色全都看得见——骨架差异只有在这种小图里才读得出来。
//
// 分区标题、解锁按钮、付费墙这一层全部由 Channel.showsPricing 控制：
// 默认这一页就是普通的皮肤选择器，六套随便穿。
// 开关为真时可用性判定只落在 ThemeManager.canUse / unlock 两处，视图不动。
//
// 这一页同时是「个性化」的总入口：明暗、语言都在右上角那两个分段控件里。

struct AppearanceView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @State private var paywallSkin: Theme? = nil

    private var freeSkins: [Theme] { Theme.all.filter { $0.tier == .free } }
    private var premiumSkins: [Theme] { Theme.all.filter { $0.tier == .premium } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(symbol: "paintpalette", title: L("外观皮肤"),
                           subtitle: Channel.showsPricing
                             ? L("免费三套随便穿；付费三套连骨架都不一样")
                             : L("六套皮肤，连骨架都不一样"),
                           variant: .display) {
                    SchemePicker()
                    LanguagePicker()
                }

                if let trying = themeManager.tryingID.flatMap({ Theme.byID($0) }) {
                    tryOnBar(trying)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        if Channel.showsPricing {
                            skinSection(L("免费"), themes: freeSkins)
                            skinSection(L("付费精选"), themes: premiumSkins)
                            footnote
                        } else {
                            skinSection(L("全部皮肤"), themes: Theme.all)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .themedList()
            }
            .pagePadding()
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .sheet(item: $paywallSkin) { skin in
            PaywallSheet(skin: skin)
                .themed(theme)   // 付费墙跟随当前皮肤，别在切过去那一刻跳色
        }
    }

    // MARK: 试穿横幅

    private func tryOnBar(_ skin: Theme) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 13))
                .foregroundStyle(theme.palette.tint)
            Text(skin.isPaid
                 ? LF("正在试穿「%@」——不满意随时还原，不会自动扣费", L(skin.name))
                 : LF("正在试穿「%@」——不满意随时还原", L(skin.name)))
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.ink)
            Spacer()
            ThemeButton(kind: .compact, title: L("还原")) { themeManager.stopTrying() }
            if skin.isPaid {
                ThemeButton(kind: .primary, symbol: "lock.open",
                            title: L("解锁")) { paywallSkin = skin }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(theme.controlShape().fill(theme.palette.tintSoft))
        .overlay(theme.controlShape().stroke(theme.palette.tint.opacity(0.3),
                                            lineWidth: theme.metric.stroke))
    }

    // MARK: 分区

    private func skinSection(_ titleKey: String, themes: [Theme]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(text: L(titleKey), detail: cnt(themes.count, "套"))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 268, maximum: 360), spacing: 16)],
                      alignment: .leading, spacing: 16) {
                ForEach(themes, id: \.id) { skin in
                    SkinCard(skin: skin,
                             isSelected: themeManager.current.id == skin.id,
                             isTrying: themeManager.tryingID == skin.id,
                             isUnlocked: themeManager.canUse(skin)) {
                        handleTap(skin)
                    } onTry: {
                        themeManager.startTrying(skin)
                    }
                }
            }
        }
    }

    private func handleTap(_ skin: Theme) {
        if themeManager.select(skin) { return }
        paywallSkin = skin
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("付费皮肤是买断制，一次解锁永久可用。"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
            Text(L("内购尚未接入：现在点「解锁」会直接放行，方便先看效果；接上 StoreKit 后这里换成真实交易。"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
        }
        .padding(.top, 4)
    }
}

// MARK: - 皮肤卡

private struct SkinCard: View {
    @Environment(\.theme) private var theme
    var skin: Theme
    var isSelected: Bool
    var isTrying: Bool
    var isUnlocked: Bool
    var onTap: () -> Void
    var onTry: () -> Void

    @State private var hovering = false

    private var locked: Bool { skin.isPaid && !isUnlocked }

    /// 商品状态标签；开关关闭时不贴任何状态
    private var statusText: String? {
        if isSelected { return L("使用中") }
        if isTrying { return L("试穿中") }
        if locked { return L("付费皮肤") }
        guard Channel.showsPricing else { return nil }
        if skin.tier == .premium && isUnlocked { return L("已解锁") }
        return L("免费")
    }

    private var a11yLabel: String {
        if let status = statusText {
            return LF("%1$@，%2$@，%3$@", L(skin.name), L(skin.tagline), status)
        }
        return LF("%1$@，%2$@", L(skin.name), L(skin.tagline))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SkinThumb(skin: skin)
                .frame(height: 132)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: max(theme.metric.radiusCard - 4, 4),
                        style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: max(theme.metric.radiusCard - 4, 4),
                                     style: .continuous)
                        .stroke(theme.palette.separator, lineWidth: 1)
                )
                .overlay(alignment: .topTrailing) {
                    if locked {
                        ThemeBadge(text: L("付费"), tone: .neutral, symbol: "lock.fill")
                            .padding(7)
                    }
                }
                .opacity(locked && !hovering ? 0.82 : 1)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L(skin.name))
                    .font(theme.display(.headline))
                    .tracking(theme.titleTracking)
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                if isSelected {
                    ThemeBadge(text: L("使用中"), tone: .safe)
                } else if isTrying {
                    ThemeBadge(text: L("试穿中"), tone: .tint)
                } else if locked {
                    ThemeBadge(text: L("付费"), tone: .warn)
                } else if Channel.showsPricing {
                    ThemeBadge(text: (skin.tier == .premium && isUnlocked) ? L("已解锁") : L("免费"),
                               tone: .neutral)
                }
            }
            .padding(.top, 11)

            Text(L(skin.tagline))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Spacer()
                if locked {
                    ThemeButton(kind: .compact, symbol: "wand.and.stars",
                                title: L("试穿"), action: onTry)
                    ThemeButton(kind: .primary, symbol: "lock.open",
                                title: L("解锁"), action: onTap)
                } else if !isSelected {
                    // 正在用的那张卡不给按钮：上一屏同时挂着「使用中」徽章和一颗禁用的「当前」，
                    // 同一个状态说两遍，而禁用按钮看起来像坏了。状态归徽章，动作归按钮。
                    ThemeButton(kind: .compact, title: L("使用"), action: onTap)
                }
            }
            .padding(.top, 10)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardShape().fill(theme.palette.surface))
        .overlay(
            theme.cardShape().stroke(
                isSelected ? theme.palette.tint : theme.palette.separator,
                lineWidth: isSelected ? 2 : theme.metric.stroke
            )
        )
        .shadow(color: theme.palette.shadow, radius: hovering ? 14 : 8, x: 0, y: hovering ? 6 : 3)
        .scaleEffect(hovering ? 1.008 : 1)
        .animation(theme.animation, value: hovering)
        .onHover { hovering = $0 }
        // contain，不是 combine：combine 会把卡里的「使用/试穿/解锁」并成一个元素，
        // 旁白就只剩一张读得出来、点不动的卡。
        .accessibilityElement(children: .contain)
        .accessibilityLabel(a11yLabel)
    }
}

// MARK: - 迷你界面预览
//
// 不是色板，是那套皮肤下的真实界面缩影：侧边栏 + 环形图 + 列表行。
// 用户只有在这张小图里看出"材质和字体真的不一样"，皮肤列表才不只是换个配色。

private struct SkinThumb: View {
    var skin: Theme

    var body: some View {
        ThumbBody()
            .environment(\.theme, skin)
            .environment(\.colorScheme, skin.scheme ?? .light)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}

private struct ThumbBody: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ThemedBackdrop()
                HStack(spacing: 0) {
                    sidebar.frame(width: geo.size.width * 0.24)
                    Rectangle().fill(theme.palette.separator)
                        .frame(width: theme.elevation == .glass ? 0.5 : 1)
                    detail
                }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(0..<5, id: \.self) { i in
                HStack(spacing: 5) {
                    theme.tileShape(9).fill(theme.tileColor(index: i, dark: theme.scheme == .dark))
                        .frame(width: 9, height: 9)
                    Capsule()
                        .fill(i == 1 ? theme.palette.ink : theme.palette.inkTertiary.opacity(0.55))
                        .frame(height: 3.5)
                }
            }
            Spacer()
        }
        .padding(9)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.paper.opacity(theme.elevation == .glass ? 0.3 : 0.55))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                MiniRing(diameter: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Capsule().fill(theme.palette.ink)
                        .frame(width: 46, height: 7)
                    Capsule().fill(theme.palette.inkTertiary.opacity(0.6))
                        .frame(width: 30, height: 4)
                    Capsule().fill(theme.palette.inkTertiary.opacity(0.4))
                        .frame(width: 38, height: 4)
                }
                Spacer(minLength: 0)
            }
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(theme.palette.tint, lineWidth: 1)
                        .frame(width: 7, height: 7)
                    Capsule().fill(theme.palette.inkSecondary.opacity(0.75))
                        .frame(width: [64, 48, 56][i], height: 4)
                    Spacer(minLength: 0)
                    Capsule().fill(theme.palette.tint.opacity(0.5))
                        .frame(width: [26, 18, 22][i], height: 4)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 6)
                .background(theme.cardShape(4).fill(theme.palette.surface))
                .overlay(theme.cardShape(4).stroke(theme.palette.separator,
                                                  lineWidth: theme.metric.stroke))
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MiniRing: View {
    @Environment(\.theme) private var theme
    var diameter: CGFloat

    var body: some View {
        let lw = diameter * 0.17
        ZStack {
            Circle().stroke(theme.palette.separator, lineWidth: lw)
            Circle()
                .trim(from: 0, to: 0.42)
                .stroke(theme.palette.chart[0], style: StrokeStyle(lineWidth: lw))
            Circle()
                .trim(from: 0.44, to: 0.68)
                .stroke(theme.palette.chart[1], style: StrokeStyle(lineWidth: lw))
            Circle()
                .trim(from: 0.70, to: 0.83)
                .stroke(theme.palette.chart[2], style: StrokeStyle(lineWidth: lw))
        }
        .rotationEffect(.degrees(-90))
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

// MARK: - 明暗模式

private struct SchemePicker: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme

    private let symbols = ["circle.lefthalf", "sun.max", "moon"]
    // 存成 let 就等于在初始化那一刻把词表冻住：切语言后这一排还是旧文案
    private var labels: [String] { [L("跟随"), L("浅色"), L("深色")] }
    private let schemes: [ColorScheme?] = [nil, .light, .dark]

    var body: some View {
        SegmentedStrip(symbols: symbols, labels: labels,
                       isOn: { themeManager.forcedScheme == schemes[$0] },
                       select: { i in
                           withAnimation(theme.animation) {
                               themeManager.forcedScheme = schemes[i]
                           }
                       },
                       a11yPrefix: L("明暗模式"))
    }
}

// MARK: - 语言

private struct LanguagePicker: View {
    @EnvironmentObject private var store: AppStore

    private let symbols = ["globe", "a.square", "character"]
    private var labels: [String] { AppLanguage.allCases.map(\.menuLabel) }

    var body: some View {
        SegmentedStrip(symbols: symbols, labels: labels,
                       isOn: { store.languageChoice == AppLanguage.allCases[$0] },
                       select: { store.setLanguage(AppLanguage.allCases[$0]) },
                       a11yPrefix: L("界面语言"))
    }
}

/// 图标 + 文字的分段选择条（明暗和语言共用一个长相）
private struct SegmentedStrip: View {
    @Environment(\.theme) private var theme
    var symbols: [String]
    var labels: [String]
    var isOn: (Int) -> Bool
    var select: (Int) -> Void
    var a11yPrefix: String

    var body: some View {
        HStack(spacing: 0) {
            ForEach(symbols.indices, id: \.self) { i in
                Button {
                    select(i)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: symbols[i])
                            .font(.system(size: 10, weight: .semibold))
                        Text(labels[i]).font(theme.bodyFont(.caption))
                    }
                    .foregroundStyle(isOn(i) ? theme.palette.onTint : theme.palette.inkSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(isOn(i) ? theme.palette.tint : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LF("%1$@：%2$@", a11yPrefix, labels[i]))
            }
        }
        .fixedSize()
        .background(theme.controlShape().fill(theme.palette.surface))
        .overlay(theme.controlShape().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
        .clipShape(theme.controlShape())
    }
}

// MARK: - 付费墙

private struct PaywallSheet: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var skin: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                SkinThumb(skin: skin)
                    .frame(width: 190, height: 116)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(theme.palette.separator, lineWidth: 1))
                VStack(alignment: .leading, spacing: 5) {
                    Text(L(skin.name))
                        .font(theme.display(.title3))
                        .tracking(theme.titleTracking)
                        .foregroundStyle(theme.palette.ink)
                    Text(L(skin.tagline))
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.inkSecondary)
                    Spacer()
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                feature(L("材质与分层"),
                        skin.elevation == .glass ? L("真实玻璃材质 + 高光描边")
                                                 : L("独立分层语言，不是换个色"))
                feature(L("字体"),
                        skin.face == .serif ? L("衬线标题，字距单独调过") : L("独立字体设计与字重"))
                feature(L("图表"), L("环形图配色单独配过，深色下同样清楚"))
                feature(L("动效"),
                        skin.motion == .still ? L("静：几乎不动，越克制越贵") : L("独立动效签名"))
                feature(L("明暗"),
                        skin.scheme == .dark ? L("自带深色，不受系统拉扯") : L("浅色优先，深色可控"))
                feature(L("语言"), L("中英文各调过一版字距，换语言不串味"))
            }

            Divider().overlay(theme.palette.separator)

            HStack(spacing: 12) {
                ThemeButton(kind: .primary, symbol: "lock.open",
                            title: L("解锁")) {
                    themeManager.unlock(skin)
                    dismiss()
                }
                ThemeButton(kind: .secondary, title: L("再试穿一下")) {
                    themeManager.startTrying(skin)
                    dismiss()
                }
                Spacer(minLength: 8)
                ThemeButton(kind: .ghost, title: L("恢复购买")) {
                    themeManager.unlock(skin)
                    dismiss()
                }
            }
            .fixedSize()

            Text(L("买断制，一次解锁永久可用。价格以内购面板为准；StoreKit 尚未接入，点解锁会直接放行。"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
        .background(theme.palette.paper)
    }

    private func feature(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.tint)
                .padding(.top, 1)
            Text(title)
                .font(theme.bodyFont(.callout).weight(.semibold))
                .foregroundStyle(theme.palette.ink)
            Text(detail)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
