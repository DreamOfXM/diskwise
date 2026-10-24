import SwiftUI
import DiskCleanerCore

// ── 首次运行那一屏 ──────────────────────────────────────────────────────────
//
// **为什么盖在窗口上，而不是侧栏里的一页**：这一屏要在任何数字出现之前把「一整圈＝整块盘」
// 这句话讲完。放进侧栏就会被绕过——第一次打开的人点的是「空间总览」，看到的是一圈还没量完的
// 弧加右边一排「统计中…」，那正是这一屏要避免的第一印象。
//
// **为什么不用 sheet**：截图链路只拍自己这一扇窗（`SnapshotMode.pngData(window…)`），
// 而 sheet 是另一扇子窗（见 `shootSheet` 那段：父窗的合成结果里没有它）。用 sheet 的话
// `DISKWISE_FIRST_RUN=1` 一张图都拍不到，这一屏就永远没有证据图。
//
// **为什么盖着的时候扫描已经在跑**：底下那一屏的 `onAppear` 照常起来，扫描在这一屏后面就开始了。
// 于是它同时是「等第一趟量完」的等待页——按下去直接有账，不用干等一圈光带走完。
//
// **环上为什么是示例数**：沙盒版在授权前压根量不到东西，而任何造出来的数都必须当场说明是造的
// （环底下那句「示例环，不是你这台盘的数」）。这一屏是全 App 第一句自我介绍，它不许撒谎。
// 示例那五段照旧要加得起来（`docs/DESIGN.md` 第 6 节第 7 条）：42.4 + 33.8 + 27.5 + 240.0
// + 168.3 = 512.0，圆心那句「整块盘 512.0 GB · 已用 343.7 GB」与「全部清空后可用
// 272.0 GB」都是拿这五个数算的，不是另外编的。
//
// **环是真环**：`SweepRing` 本体，材质由此刻生效的皮肤决定（`skins.json` 的 `ring` 字段 →
// `Theme.ring` → `RingStyle`）。所以下面那排皮肤点一下，环就换成那一套的画法。
// 说清楚现在换的是什么：六套内置皮肤**都选 `crystal`**，所以点下去变的是墨色、灯光、
// 字体和环的粗细，材质本身不变——材质这一档目前只有投放进来的 `skins.json` 能给出第二款。
// 因此这一屏讲的是「整张脸跟着这一排走」，不讲「这里能试两种材质」；那句假话以前写在这里，
// 2026-10-21 拍图时对不上，删了。示例段用的灰走 `SweepRing.blockedInk` / `freeInk`，
// 与总览页同一份配方，不是重抄一遍的近似色。

/// 首次运行那一屏。由 `ContentView` 盖在窗口上，看完或跳过之后 `Prefs.finishFirstRun()` 收起。
struct FirstRunView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemScheme
    @ObservedObject private var grant = HomeGrant.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    chrome
                    // 上面这一道 `Spacer` 不是留白，是把「标题 + 环」这一块**立到窗口中间去**。
                    // 少了它，窗口一高（截图那趟实测 852 磅），内容全贴在顶上、按钮孤零零站在
                    // 底下，中间空出一整屏——读者会以为这一屏还没画完。有了它，700 高的默认窗
                    // 和 850 高的大窗是同一张构图，只是上下各多一点呼吸。
                    Spacer(minLength: 8)
                    HStack(alignment: .top, spacing: 34) {
                        story.frame(width: storyWidth(in: geo.size))
                        hero(diameter: ringDiameter(in: geo.size))
                            .frame(maxWidth: .infinity, alignment: .top)
                    }
                    Spacer(minLength: 16)
                    actions
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 22)
                // 内容矮于一屏时也要占满整屏高度：上面那个 `Spacer` 靠这一行才有得撑，
                // 按钮才始终落在窗口下沿，而不是悬在半空。
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            // 容器尺寸钉在窗口上（同 `ContentView.detail` 那一手）：macOS 13 的 ScrollView
            // 会把内容的完整高度报成自己的理想尺寸，不钉就会把窗口越撑越高。
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(ThemedBackdrop().ignoresSafeArea())
    }

    // MARK: 让位与语言

    /// 顶部这一条只有一颗语言开关。红绿灯那 52pt 不归这里管：这一屏是 `ContentView` 的
    /// overlay，落在系统安全区内侧（和 `detail` 同一档），带子是系统让的——
    /// 拿 `Chrome.trafficLightInset` 再让一次，就是 `Chrome.topClearance` 那句注释
    /// 骂过的「叠成一条 58pt 的空档」。
    /// 语言挑在这一屏右上角：它必须在**看懂这句话之前**就能换，放到页脚等于让不懂中文的人
    /// 先读一整屏中文再去找开关。
    private var chrome: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            LanguagePicker()
        }
        .padding(.top, 6)
    }

    // MARK: 左栏：怎么说清这块盘

    private var story: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("一整圈，就是这块盘"))
                    .font(theme.display(.largeTitle))
                    .tracking(theme.titleTracking)
                    .foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("每条弧是盘上一块真实的字节，长短就是它占多少。"))
                    .font(theme.prose(size: 15))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 9) {
                promise(symbol: "wifi.slash", text: L("不联网、不上传"))
                promise(symbol: "trash", text: L("删除先进废纸篓，随时可撤"))
                promise(symbol: "checkmark.shield", text: L("系统文件一律不碰"))
            }

            skins
        }
    }

    /// 三句承诺。字号压到 12、只用 `inkSecondary`：它们要在第一屏就被扫到，
    /// 但不能比「一整圈就是这块盘」这句话更抢眼。
    private func promise(symbol: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.inkTertiary)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 皮肤那一排

    /// 六套皮肤排成 2 列 3 行。为什么不是 3 列 2 行：这一栏定宽 420（`storyWidth` 在
    /// 1000 宽的窗口上就已经顶到 420 了），三列分下来每颗只有 ~100 磅能放字，
    /// 俄语那句「Стекло северного сияния」两行都装不下，只能截成「северного си…」。
    /// 两列给到 ~170 磅，最长的那两个名字（俄语、德语）刚好两行收完。
    private var skins: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: L("外观皮肤"), detail: cnt(SkinCatalog.all.count, "套"))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                      alignment: .leading, spacing: 8) {
                ForEach(SkinCatalog.all) { skin in
                    skinChip(skin)
                }
            }
            Text(L("这一排换的是整张脸：颜色、字体、环怎么画都跟着走。不满意随时能换，设置 › 外观皮肤里还有每一套的缩略图。"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func skinChip(_ skin: Theme) -> some View {
        let chosen = themeManager.effective.id == skin.id
        let usable = themeManager.canUse(skin)
        return Button {
            // 走的是皮肤页同一颗按钮的路：`select` 自己判能不能用，用不了就什么都不发生
            // （这一屏不该弹付费墙，第一屏谈钱是最糟的开场）。
            themeManager.select(skin)
        } label: {
            HStack(spacing: 6) {
                swatch(skin)
                Text(L(skin.name))
                    .font(theme.bodyFont(.caption))
                    // 两行，不是一行截断：这一屏的名字就是控件本身，点的人得看清自己挑的是哪一套。
                    // 皮肤页那张卡可以截（卡上有缩略图、tagline 和整页可滚，截掉的只是尾巴），
                    // 这里截了就只剩「Тушь и рисовая б…」——2026-10-21 俄语实拍，六个名字截了两个。
                    // 中文和英文一行就够，多出来的那一行只在长名字的语言里出现。
                    // 两行是上限：再放宽一颗名字三行的话，六颗胶囊就长成六张卡，
                    // 这一栏会从「一排可选的脸」退化成「一列要读的文案」。列数改窄之后两行够用
                    // （见 `skins` 那段）。
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !usable {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 8, weight: .semibold))
                } else if chosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
            .foregroundStyle(chosen ? theme.palette.onTint : theme.palette.inkSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.controlShape()
                .fill(chosen ? theme.palette.tint : theme.palette.surface))
            .overlay(theme.controlShape().stroke(theme.palette.separator,
                                                 lineWidth: theme.metric.stroke))
            .contentShape(theme.controlShape())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityLabel(LF("%1$@，%2$@", L(skin.name), chosen ? L("使用中") : L("使用")))
    }

    /// 一颗小色卡：纸色当底、主色当点。缩略图那一套（真迷你界面）留在皮肤页——
    /// 这一屏要的是「点一下换一套」的密度，132 磅高的卡在 560 高的窗口里放不下。
    private func swatch(_ skin: Theme) -> some View {
        ZStack {
            Circle().fill(skin.palette.paper)
            Circle().strokeBorder(skin.palette.separator, lineWidth: 1)
            Circle().fill(skin.palette.tint).frame(width: 6, height: 6)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }

    // MARK: 右栏：那枚环

    private func hero(diameter: CGFloat) -> some View {
        VStack(spacing: 14) {
            SweepRing(segments: sampleSegments,
                      centerTop: L("可用"),
                      centerValue: human(sampleFree),
                      // 盘心那两行用的是总览页同一对键，不另造一句：同一屏上「整块盘 /
                      // 已用 / 全部清空后可用」若两处措辞不一样，人就当成两本账。
                      centerCap: LF("整块盘 %1$@ · 已用 %2$@", human(sampleTotal), human(sampleUsed))
                          + "\n" + LF("全部清空后可用 %1$@", human(sampleAfterClear)),
                      diameter: diameter)
                .frame(width: diameter, height: diameter)

            Text(L("示例环，不是你这台盘的数"))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)

            legend
        }
    }

    /// 两条颜色规矩。放在环底下而不是左栏里：它解释的是眼前这一圈，
    /// 挪到三句承诺旁边就得让人自己把「灰」这个字和图上那一块对上。
    ///
    /// 第三条「虚线 = 已进废纸篓」原来在这里，2026-10-21 实拍删了：示例给这一档是撒谎
    /// （第一次开机的人压根还没清过东西，废纸篓那一档不可能有数），而它画出来也不像虚线
    /// ——6% 那一档的宽度上，虚线描边被切成一叠同心细条，读起来是「渲染坏了」而不是「已搬走」。
    /// 那一档留给它真正出现的那一刻：清完一轮，总览页上自己会长出来。
    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            legendRow(tone: .hot, text: L("彩色 = 收得走"))
            legendRow(tone: .grey, text: L("灰 = 动不了"))
        }
        .padding(.top, 2)
    }

    private enum LegendTone { case hot, grey }

    private func legendRow(tone: LegendTone, text: String) -> some View {
        HStack(spacing: 8) {
            swatchBar(tone)
            Text(text)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 图例那一小段带子：吃的是环上同一份配方，所以「灰」这一条在图上和在这里是同一个灰。
    private func swatchBar(_ tone: LegendTone) -> some View {
        let ink: Color = {
            switch tone {
            case .hot: return SweepRing.lamp(theme.palette.tint)
            case .grey: return SweepRing.blockedInk(theme: theme, dark: isDark)
            }
        }()
        return Capsule()
            .fill(ink)
            .frame(width: 20, height: 8)
            .accessibilityHidden(true)
    }

    private var isDark: Bool { (theme.scheme ?? systemScheme) == .dark }

    // MARK: 示例那五段

    /// 整块盘：一块常见容量的 SSD。
    private var sampleTotal: Int64 { 512 * GB }
    /// 空闲那一档＝系统口径的可用（示例里没有「系统可清除」那一段，所以可用就是空闲）。
    private var sampleFree: Int64 { 168_300_000_000 }
    /// 已用＝整块盘减空闲。圆心那两行和环上那五段必须是同一本账，所以这个数只能算出来，
    /// 不能另外挑一个「看起来合理」的——挑了就会出现五段加起来不等于那行字的图。
    private var sampleUsed: Int64 { sampleTotal - sampleFree }
    /// 走完这一步之后：空闲 + 三段收得走的。示例里没有废纸篓那一段（见下面 `sampleSegments`），
    /// 所以「全部清空后可用」就是 168.3 + 42.4 + 33.8 + 27.5 = 272.0。
    private var sampleAfterClear: Int64 { sampleFree + 42_400_000_000 + 33_800_000_000 + 27_500_000_000 }

    /// 五段示例账。名字全用产品里真会出现的那几个（`应用缓存`/`开发缓存`/`大文件`/
    /// `其他已统计`/`空闲`），为的是这一屏教会的那套名字，点进总览页之后一个都不用重新学。
    ///
    /// `reclaim` 一律留 0：这几段收不走任何东西，给了可回收量，环上就会画出那道「点我」的
    /// 内侧暖沿、光标也会变手型（见 `SweepRing.ringHitLayer`）——示例环邀请人来点是骗人。
    /// 上色照旧走 `.hot`，颜色说的是「这类东西在真盘上动得了」，不是「点这里」。
    ///
    /// 没有「本次移入废纸篓」那一段：第一次开机的人还没清过任何东西，这一档在真盘上必然是 0，
    /// 摆在示例里就是编一个不可能存在的状态。它在清完第一轮之后自己会出现在总览页上。
    private var sampleSegments: [GaugeSegment] {
        let lamp = SweepRing.lamp(theme.palette.tint)
        return [
            GaugeSegment(label: L("应用缓存"), value: 42_400_000_000, color: lamp, tone: .hot),
            GaugeSegment(label: L("开发缓存"), value: 33_800_000_000, color: lamp, tone: .hot),
            GaugeSegment(label: L("大文件"), value: 27_500_000_000, color: lamp, tone: .hot),
            GaugeSegment(label: L("其他已统计"), value: 240_000_000_000,
                         color: SweepRing.blockedInk(theme: theme, dark: isDark),
                         tone: .neutral),
            GaugeSegment(label: L("空闲"), value: sampleFree,
                         color: SweepRing.freeInk(theme: theme, dark: isDark),
                         tone: .neutral),
        ]
    }

    // MARK: 尺寸

    /// 左栏给到 420，窗口再窄就按比例让。窄窗里右边那一圈跟着缩，不会挤出滚动条。
    private func storyWidth(in size: CGSize) -> CGFloat {
        min(420, max(280, size.width * 0.42))
    }

    /// 环的直径。地板 260 不是凑的：那是弧上印不印数的那道闸（`RingStyle.labelMinDiameter`），
    /// 低于它这一屏就退化成「一枚没数的小饼」——上一版最小窗实拍到的正是这个样子。
    /// 天花板 320：再大就把右边这一栏顶到窗口边上，而左栏的字要开始折第三行。
    private func ringDiameter(in size: CGSize) -> CGFloat {
        let room = size.height - 200
        let roomW = size.width - storyWidth(in: size) - 120
        return min(320, max(260, min(room, roomW)))
    }

    // MARK: 底部动作

    /// 两个出口：按下去开始（沙盒版还没授权时，那颗就是「授权家目录」），或者以后再说。
    /// 顺序照 macOS：默认动作在最右，回车就是它。
    private var actions: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            ThemeButton(kind: .ghost, title: L("以后再说")) { prefs.finishFirstRun() }
            ThemeButton(kind: .primary,
                        symbol: grant.needsGrant ? "folder.badge.gearshape" : "magnifyingglass",
                        title: grant.needsGrant ? L("授权家目录") : L("开始看这块盘"),
                        shortcut: KeyboardShortcut(.return, modifiers: []),
                        action: start)
        }
    }

    /// 开始用这块盘。
    ///
    /// 沙盒版还没授权时，这颗直接走授权那一趟（同一套 `NSOpenPanel`，与总览页被拦住时
    /// 画的那一屏共用一个 `HomeGrant`）。**没授权成功就不收这一屏**：引导消失、界面却
    /// 还一屏数字都不给，那是把两屏都不见了。
    private func start() {
        if grant.needsGrant {
            grant.request()
            guard !grant.needsGrant else { return }
        }
        prefs.finishFirstRun()
    }
}
