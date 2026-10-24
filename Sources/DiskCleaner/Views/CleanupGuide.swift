import SwiftUI
import DiskCleanerCore

// ── 「清理说明」那四页 ────────────────────────────────────────────────────────
//
// **为什么要有这一套**：这一版把 1.9 的两处口径都改了——环心从「还能腾出多少」换成
// 「现在能用多少」，动手从「勾上再按主钮」换成「同一段点两下」。两处都是好改动，
// 但都会让一个用惯了 1.9 的人第一眼读错。读错的代价不是看不懂，是**按错**：
// 他以为还要先勾选，于是去点账本行，点完什么也没发生，就以为软件坏了。
// 引导页（`FirstRunView`）管不到这件事：它站在授权之前，那会儿盘上一个数都没有，
// 能讲的只有「一圈就是这块盘」。这一套讲的是**怎么动手**，必须落在有数之后。
//
// **为什么是四页而不是一屏说明文**：每页只回答一个会被误解的动作。合成一屏就变成
// 「一段产品更新公告」，没人读，读完也记不住哪一条跟自己接下来那一下有关。
// 页眉的 01/04 与页脚那四颗点就是这条约束的产物：它明说「只有四下就能走完」。
//
// **页脚只有前后两钮**（样稿同）：中间再放一颗「继续」，读起来像「继续看」，
// 干的却是关掉——一个动作两个名字。退出这一套的路子已经有三条：页眉的「跳过」、
// 点背面、Esc。最后一张那颗换成「开始用这块盘」，正向走完和就地收口合成同一下。
//
// **为什么盖在窗口上而不是 sheet**：同 `FirstRunView` 头注——截图链路只拍自己这一扇窗，
// sheet 是另一扇子窗，用 sheet 这一套一张图都拍不到。取证走
// `DISKWISE_GUIDE=1~4`（见 `SnapshotMode.guidePage`）。
//
// **右边那一栏的数全是示意的**，页内明写「示意数字，不是你这台盘的数」。这四页要讲的
// 是关系（上膛→移入、移入≠腾出），关系用假数讲最清楚；拿真盘数讲反而会把人钉在
// 自己那 6.3 GB 上，忘了这一页说的是所有段。示意的三个数自己加得起来：
// 整块盘 96.0 = 已用 80.0 + 可用 16.0；清空 6.3 之后可用 16.0 + 6.3 = 22.3。
//
// **不做逐页动画**：这一套只在第一次出现，四页加起来读十几秒。为它挂一条常驻
// 时间线，是把「说明一个交互」花成「和交互抢帧」——本项目的红线（见 `PerfProbe`）
// 不允许。页与页之间只有 SwiftUI 那一下转场。

/// 四页的内容。`kicker` 是页码那一行，`notes` 是编号那几条。
struct GuidePage: Identifiable {
    let id: Int
    let kicker: String
    let headline: String
    let lede: String
    let notes: [(String, String)]
}

/// 「清理说明」那一屏。由 `ContentView` 盖在两列之上。
struct CleanupGuide: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemScheme

    /// 截图链路用 `DISKWISE_GUIDE=<1~4>` 钉页；平时是用户自己翻。
    @State private var page: Int
    let onClose: () -> Void

    init(startPage: Int? = nil, onClose: @escaping () -> Void) {
        _page = State(initialValue: max(1, min(Self.pages.count, startPage ?? 1)))
        self.onClose = onClose
    }

    static let pages: [GuidePage] = [
        GuidePage(
            id: 1,
            kicker: L("01 / 环心的那个数"),
            headline: L("最大的数，不再是「还能腾出」"),
            lede: L("上一版的环心写一笔预期——「还能腾出 12.9」。这一版换成这块盘此刻真实的可用量；预期收得走多少，退到账上那一行。"),
            notes: [
                (L("环心 = 现在就能用的"), L("不是清完以后能到多少。那个数只会在废纸篓真的清空后变。")),
                (L("收得走多少，写在账上"), L("每段各占多少，条子长度就是它；环心不替它们相加。")),
                (L("没量到的另算"), L("不混进「共用了多少」——那一笔随时会缩，混进来就会骗人。")),
            ]),
        GuidePage(
            id: 2,
            kicker: L("02 / 动手"),
            headline: L("点两下才真的动，3 秒不点就撤"),
            lede: L("第一下只上膛，第二下才把这一段移进废纸篓。中间这三秒，点别处、换一段或按 Esc，都能撤。"),
            notes: [
                (L("第一下：只是上膛"), L("环心报这一段的量，主钮写明要做什么；还没动任何文件。")),
                (L("第二下：才移进废纸篓"), L("同一段再点一次。不点，3 秒后自己回到原样。")),
                (L("点别的段，就是改主意"), L("上膛挪到新的一段，原来那段撤下；按 Esc 也一样。")),
            ]),
        GuidePage(
            id: 3,
            kicker: L("03 / 字节去哪了"),
            headline: L("进了废纸篓，空间还没回来"),
            lede: L("本工具只做「移进废纸篓」这一步：字节还在盘上，可用数不会立刻涨。清空那一下归访达——你去访达按，或从废纸篓页请访达动手，让出空间的都是那一下。"),
            notes: [
                (L("移入后：可用数不动"), L("环上那一段只是换了颜色——它还在占地方。")),
                (L("清空后：可用数才涨"), L("这一步交给访达。本工具不替你倒垃圾，也不偷偷清。")),
                (L("还想找回来"), L("废纸篓页能打开访达；清空之前，整批都能原样放回去。")),
            ]),
        GuidePage(
            id: 4,
            kicker: L("04 / 点不动的时候"),
            headline: L("不给清的，会当场说为什么"),
            lede: L("不是所有段都能动。点不动的段不会假装在忙，会直接给一句原因；已经移进去的，都能还原。"),
            notes: [
                (L("受系统保护"), L("比如系统数据那一段：整块根目录不许整个搬走。里面的东西能清，去别的清理页挑。")),
                (L("不在这次范围"), L("比如其他用户和盘顶那些系统区：量得到、报得出数，但删除那一步只认家目录、应用程序与两个临时区。")),
                (L("只是一笔汇总"), L("「没量到的」这类合账背后不是一个目录，整个搬不走；要逐块看，点开右边账上那一行。")),
                (L("移错了：还原"), L("废纸篓页把这一批原样放回去；清空之前都还在。")),
            ]),
    ]

    private var current: GuidePage { Self.pages[max(0, min(page - 1, Self.pages.count - 1))] }
    private var isLast: Bool { page == Self.pages.count }

    var body: some View {
        ZStack {
            theme.palette.shadow
                .opacity(isDark ? 0.68 : 0.34)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            sheet
                .frame(maxWidth: 860)
                .padding(.horizontal, 28)
        }
        .accessibilityAddTraits(.isModal)
        .onExitCommand(perform: onClose)
    }

    private var sheet: some View {
        VStack(spacing: 0) {
            header
            Divider().background(theme.palette.separator)
            HStack(alignment: .top, spacing: 26) {
                copy.frame(maxWidth: .infinity, alignment: .leading)
                visual.frame(width: 268)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            Divider().background(theme.palette.separator)
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: theme.metric.radiusCard, style: .continuous)
                .fill(theme.palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.metric.radiusCard, style: .continuous)
                .stroke(theme.palette.separator, lineWidth: theme.metric.stroke)
        )
        .shadow(color: theme.palette.shadow.opacity(isDark ? 0.62 : 0.20),
                radius: 26, y: 12)
    }

    // MARK: 页眉

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("升级后的第一次 · 清理说明"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
            Spacer(minLength: 8)
            Text(String(format: "%02d / %02d", page, Self.pages.count))
                .font(theme.bodyFont(.caption))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkTertiary)
                .accessibilityLabel(LF("第 %1$@ 页，共 %2$@ 页",
                                       String(page), String(Self.pages.count)))
            Button(action: onClose) {
                Text(L("跳过"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("跳过清理说明"))
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
    }

    // MARK: 左栏：这一页讲什么

    private var copy: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(current.kicker)
                .font(theme.bodyFont(.caption))
                .tracking(0.6)
                .foregroundStyle(theme.palette.tint)
            Text(current.headline)
                .font(theme.display(.title))
                .tracking(theme.titleTracking)
                .foregroundStyle(theme.palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(current.lede)
                .font(theme.prose(size: 14))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(current.notes.enumerated()), id: \.offset) { idx, note in
                    noteRow(idx + 1, note.0, note.1)
                }
            }
            .padding(.top, 4)
        }
    }

    private func noteRow(_ n: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(String(n))
                .font(theme.bodyFont(.caption2)).monospacedDigit()
                .foregroundStyle(theme.palette.inkTertiary)
                .frame(width: 16, height: 16)
                .background(Circle().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(theme.bodyFont(.footnote)).fontWeight(.medium)
                    .foregroundStyle(theme.palette.ink)
                Text(detail)
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 右栏：这一页那笔账

    private var visual: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch current.id {
            case 1: visualOne
            case 2: visualTwo
            case 3: visualThree
            default: visualFour
            }
            Text(L("示意数字，不是你这台盘的数"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: theme.metric.radiusCard - 2, style: .continuous)
                .fill(theme.palette.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: theme.metric.radiusCard - 2, style: .continuous)
                .stroke(theme.palette.separator, lineWidth: theme.metric.stroke)
        )
    }

    /// 第 1 页：环心那一个大数，和它「不再是」的那句旧话。
    ///
    /// 那行小字复用总览页的同一对键（`整块盘 %1$@ · 已用 %2$@`），不另造一句：
    /// 同一屏上「整块盘 / 已用 / 可用」若两处措辞不一样，人就当成两本账——
    /// 这条规矩是 `FirstRunView.hero` 先立下的，这里照办。
    private var visualOne: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("可用"))
                .font(theme.bodyFont(.caption2))
                .tracking(2.2)
                .foregroundStyle(theme.palette.tint)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("16.0")
                    .font(theme.display(.largeTitle))
                    .foregroundStyle(theme.palette.ink)
                Text("GB")
                    .font(theme.bodyFont(.footnote))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
            Text(LF("整块盘 %1$@ · 已用 %2$@", "96.0 GB", "80.0 GB"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkSecondary)
            Text(L("还能腾出 12.9"))
                .font(theme.bodyFont(.caption2))
                .strikethrough()
                .foregroundStyle(theme.palette.inkTertiary.opacity(0.7))
        }
        .accessibilityElement(children: .combine)
    }

    /// 第 2 页：同一段的两下，中间那三秒。
    private var visualTwo: some View {
        VStack(alignment: .leading, spacing: 9) {
            stepRow(L("第一下"), L("上膛 · 应用缓存 6.3 GB"), lit: true)
            HStack(spacing: 7) {
                Rectangle().fill(theme.palette.separator).frame(height: 1)
                Text(L("3 秒不点就撤"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                Rectangle().fill(theme.palette.separator).frame(height: 1)
            }
            stepRow(L("第二下"), L("移入废纸篓 +6.3 GB"), lit: false)
        }
        .accessibilityElement(children: .combine)
    }

    /// 第 3 页：移入与清空是两件事，可用数只认后者。
    private var visualThree: some View {
        VStack(alignment: .leading, spacing: 9) {
            stepRow(L("移入后"), L("可用 16.0 GB · 没变"), lit: false)
            HStack(spacing: 7) {
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.palette.inkTertiary)
                Text(L("在访达里清空"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                Spacer(minLength: 0)
            }
            stepRow(L("清空后"), L("可用 22.3 GB"), lit: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 第 4 页：四种「动不了」，每一种都给原因。
    private var visualFour: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(current.notes.enumerated()), id: \.offset) { _, note in
                HStack(spacing: 7) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 9, weight: .regular))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Text(note.0)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func stepRow(_ tag: String, _ body: String, lit: Bool) -> some View {
        HStack(spacing: 8) {
            Text(tag)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(lit ? theme.palette.onTint : theme.palette.inkTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(lit ? theme.palette.tint : theme.palette.surface))
            Text(body)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(lit ? theme.palette.ink : theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: 页脚：四颗点 + 前后

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(Self.pages) { p in
                    Button {
                        withAnimation(theme.animation) { page = p.id }
                    } label: {
                        Circle()
                            .fill(p.id == page ? theme.palette.tint : theme.palette.separator)
                            .frame(width: 6, height: 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LF("第 %1$@ 页", String(p.id)))
                }
            }
            Spacer(minLength: 0)
            Text(L("升级后只出现一次 · 之后从右上角 ? 复看"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .layoutPriority(1)
            Spacer(minLength: 0)
            ThemeButton(kind: .ghost, title: L("上一页")) {
                guard page > 1 else { return }
                withAnimation(theme.animation) { page -= 1 }
            }
            .disabled(page == 1)
            // 走完最后一张与中途关掉是同一件事：都回到这块盘。所以最后一张
            // 不另起一颗钮，把「下一页」那颗改名字、换主色、改成收口。
            ThemeButton(kind: isLast ? .primary : .secondary,
                        title: isLast ? L("开始用这块盘") : L("下一页")) {
                if isLast { onClose() } else { withAnimation(theme.animation) { page += 1 } }
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 54)
    }

    private var isDark: Bool { (theme.scheme ?? systemScheme) == .dark }
}

// MARK: - 右上角那颗「?」

/// 工具条上的「?」。复看这一套四页——样稿里它就是顶栏最右那一颗，
/// 和「声音」「重新扫描」并排，不藏进设置页：需要它的时刻是**正卡在主画面上**，
/// 而不是已经退到设置里翻的时候。
struct GuideButton: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            Prefs.shared.reopenGuide()
        } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.palette.inkTertiary)
                .frame(width: 22, height: 22)
                .background(Circle().stroke(theme.palette.separator, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("清理说明：这一版哪几处和上一版不一样"))
        .accessibilityLabel(L("清理说明"))
    }
}
