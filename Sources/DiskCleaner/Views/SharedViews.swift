import SwiftUI
import AppKit
import DiskCleanerCore

// ── 页面共享件 ──────────────────────────────────────────────────────────────
//
// 六个列表页（大文件/很久没动/重复/残留/node_modules/缓存）以前各写一遍行布局，
// 结果每页的字号、右对齐、留白都微妙地不一样。这里收成一个 ItemRow，
// 页面只喂数据。
//
// 文案一律过 L()/LF()：中英混排时固定宽度那些坑见 §布局，见 MASTER.md。

// MARK: - 失败原因与提示（各页共用，措辞只这一处）

extension ScanScope {
    /// 界面上的范围名。总览的范围开关和各扫描页的范围标签共用这一份叫法，
    /// 两处不一致的话用户就不知道「整盘」和「全盘」是不是同一件事。
    var uiName: String {
        switch self {
        case .user: return L("用户区")
        case .disk: return L("整盘")
        }
    }
}

extension View {
    /// 内容区列表：拿掉 List 的默认底和分隔线，皮肤背景才透得出来
    func themedList() -> some View {
        listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
    }

    /// 一行 = 账本里的一道横格。行自己不带盒子，格与格之间靠 `ItemRow` 顶上那条 1px 分段线分开，
    /// 所以这里上下不留缝——留了缝就等于把 27 行重新拆回 27 张卡。
    func themedRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    /// 页面内容通用内边距
    func pagePadding() -> some View {
        padding(.horizontal, 20)
    }
}

/// 一条失败原因：为什么（含系统原话）。TrashError 只给原因码，句子在这拼
func failReason(_ error: Error) -> String {
    guard let t = error as? TrashError else { return error.localizedDescription }
    return t.detail.isEmpty ? L(t.reasonKey) : LF("%@：%@", L(t.reasonKey), t.detail)
}

/// 一条失败原因：「条目名：为什么」
func failLine(_ name: String, _ error: Error) -> String {
    LF("%@：%@", name, failReason(error))
}

/// 清理完成后的顶部提示：成功多少、失败多少
func trashedNotice(_ ok: Int, _ unit: String, failed: Int) -> String {
    var s = LF("已移入废纸篓 %@", cnt(ok, unit))
    if failed > 0 { s += LF("，%@ 项失败", String(failed)) }
    return s
}

/// 行内路径：家目录缩成 ~。整条 /Users/名字/… 又长又把人用户名印在每行上，
/// 而认一个条目靠的从来是尾段（~/Library/Caches/Google）。展开行里仍给全路径。
func displayPath(_ url: URL) -> String {
    let p = url.path
    let home = homePath()
    return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
}

// MARK: - 徽章数据

struct ItemBadge {
    var text: String
    var tone: ThemeBadge.Tone
}

/// 行首图形那一格的边长。
///
/// 26 不是拍的：侧栏那些浅底图标块是 22，页头是 46，列表行的名字已经占到 12pt，
/// 图形再大就压过文字。取一个「一眼认出是什么、又不抢读数那一列」的档。
let rowIconSide: CGFloat = 26

/// 比例条和展开明细的左缩进：一路让到名字那一列的左缘。
///
/// 勾选框 16 + 间距 10 + 图形 26 + 间距 10 + 箭头 12 = 74。加图形之前这个数是 38，
/// 三处 padding 一起动才成立——只动行的话，条子和明细会比名字缩进去一格。
let rowLeadInset: CGFloat = 16 + 10 + rowIconSide + 10 + 12

// MARK: - 可清理条目行

/// 整盘扫描会扫到我们删不动的位置。行照样列出来（那是账），但勾选框锁死，
/// 而且得说清为什么锁——不然用户只会以为工具坏了。
/// 做成计算属性而不是常量：语言切换后要跟着换。
var outsideScopeHint: String {
    L("这个位置我们不动：要么只有管理员写得动，要么归 Homebrew / Xcode 自己管，用它们各自的清理命令更安全。")
}

/// 扫描中、一行都还没出来时画在账本里的那几道灰格。
///
/// 列表是扫完才一次性回填的，整盘范围能走几分钟。原先这一段时间里有的页面画的是
/// **一张有边没内容的空卡**（2026-09-27 实拍 node_modules）：卡片都给了，里面是零行，
/// 读起来就是「扫完了，结果一项没有」——恰好是最不该说的那句话。
/// 骨架行占的是真行的槽位（勾选位、名字、明细、比例条、数），所以数出来那一刻
/// 每一行往哪儿长是定的，整列不会在回填时跳一下。
///
/// `scope` 只给那些「慢有慢的理由」的页面（大文件 / 落灰 / 重复）：那三页换范围之后
/// 要重走整盘，等几分钟得说清在等什么。其余四页页头那颗 `LoadingRow` 已经在说本页在干什么。
struct ScanSkeleton: View {
    @Environment(\.theme) private var theme
    var scope: String? = nil

    // 五条、名字长短不一、比例条一次比一次短：这七页的列表都按字节从大到小排，
    // 骨架先按那个顺序占位。等长的五行会被读成「五件一样大的东西」，那是假数。
    private static let slots: [(name: CGFloat, sub: CGFloat, bar: CGFloat)] = [
        (212, 296, 204), (168, 244, 152), (240, 192, 116), (148, 268, 78), (196, 156, 48)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(Self.slots.enumerated()), id: \.offset) { idx, s in
                    SkeletonRow(showRule: idx > 0, nameW: s.name, subW: s.sub, barW: s.bar,
                                phase: Double(idx) * 0.14)
                }
            }
            .ledgerCard()
            // 整块都是「还没有数」的图形，读屏念不出任何真信息；页头那句话才是它的话。
            .accessibilityHidden(true)

            if let scope {
                ListNote(text: LF("范围「%@」，要把每个目录走一遍才出列表。", scope))
            }
        }
    }
}

private struct SkeletonRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var showRule: Bool
    var nameW: CGFloat
    var subW: CGFloat
    var barW: CGFloat
    /// 各行错开半个节拍：五道灰同时明灭会像一排指示灯，看不出「数据正在陆续回来」。
    var phase: Double

    @State private var lit = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                dash(16, 16, corner: 5)                        // 勾选位
                dash(rowIconSide, rowIconSide, corner: 7)      // 行首图形位
                dash(10, 10, corner: 3)                        // 展开记号位
                VStack(alignment: .leading, spacing: 5) {
                    dash(nameW, 13)
                    dash(subW, 9)
                }
                Spacer(minLength: 10)
                dash(64, 20)
                    .frame(width: 104, alignment: .trailing)   // 那列数的位
            }
            .padding(.top, 11)
            .padding(.bottom, 9)

            // 只画有内容的那一截，不画轨道：轨道是「100%」，而此刻连分母都还没量出来。
            dash(barW, 3).padding(.leading, rowLeadInset).padding(.bottom, 11)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showRule {
                Rectangle().fill(theme.palette.separator.opacity(0.7))
                    .frame(height: 1).padding(.horizontal, 8)
            }
        }
        .onAppear {
            if reduceMotion { lit = true; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)
                .delay(phase)) { lit = true }
        }
        .onDisappear { lit = false }
    }

    /// 一格灰。底色用 `inkTertiary` 压到 42%，不用 `separator`：分隔线本身就只有 1.9:1，
    /// 骨架要是跟线一个重量，浅皮下整块看着还是一片空卡——那正是这次要修的缺陷。
    /// 明灭只在 0.6↔1.0 之间走，最暗那一档也比行里的分隔线重，眼睛才追得到「在动」。
    private func dash(_ w: CGFloat, _ h: CGFloat, corner: CGFloat? = nil) -> some View {
        RoundedRectangle(cornerRadius: corner ?? h / 2)
            .fill(theme.palette.inkTertiary.opacity(0.42))
            .frame(width: max(12, w), height: h)
            .opacity(lit ? 1 : 0.6)
    }
}

/// 列表页的一行，解剖与总览英雄卡那几行同一副（`docs/DESIGN.md` §6）：
/// 一块容器 + 一道 1px 分段线 + 两档数字 + 彩色只给动得了的。
///
/// 原先这里是每页一张带描边的白卡：27 行缓存就是 27 个盒子，读出来是「27 件不相干的
/// 东西」而不是「一张表」；数字单档 13pt、单位跟数字一样大，一整列扫下来比不出大小；
/// 比例条按页面配色（重复页粉、Docker 页橙），颜色在说「你在哪一页」，
/// 而这一屏唯一需要一眼分清的轴是「这行能不能删」。
struct ItemRow<Detail: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selected: Bool
    /// 行首那一格。每个页面都得明说这一行背后是什么：真实路径、一个类别，还是
    /// 什么都取不到——因为「认不出这条缓存是谁的」正是这一格要解决的问题。
    var icon: RowIcon
    /// 条目自己声明的归属 App 包名，只有缓存页用得上（safety_db 的 `app` 字段）。
    var appID: String? = nil
    /// 没有 .app 可查的工具挂哪家官方品牌标（safety_db 的 `icon` 字段）。
    var brand: String? = nil
    var name: String
    var sub: String? = nil
    /// 这一行的展示级数字。整列由页面过一次 `addableHumanColumn`（或 `unifiedHuman`）
    /// 再传进来，不在这里 `human()`：各行独立四舍五入会各自往上飘，那一列就加不起来了。
    var sizeText: String
    /// 0...1，相对本页最大项的比例——磁盘工具不画比例就等于没画
    var fraction: Double = 1
    var badge: ItemBadge? = nil
    var selectable: Bool = true
    /// 「动得了」这一档：灯色、21pt、条子只给它。默认跟着 `selectable`；
    /// 缓存页和残留页要再收紧一层——标「留意」的行得用户自己判，不给它灯的暗示。
    var lit: Bool? = nil
    /// 首行不画分段线（样稿 `.ledger>.mrow:first-child::before{display:none}`）
    var showRule: Bool = true
    var lockedHint: String? = nil
    /// 截图链路用：进这一页时把明细摊开，拍的就是「点开以后长什么样」。
    /// 批量拍图这一路没有键鼠，只能让视图自己展开，走的仍是那颗箭头改的同一个状态。
    var preopen: Bool = false
    @ViewBuilder var detail: () -> Detail

    @State private var expanded = false
    @State private var hovering = false

    private var act: Bool { lit ?? selectable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // 动不了的行：位置留着、框不画。画一个灰掉的勾选框是在说「这里有个开关」，
                // 而这一行根本没有开关——勾选列因此还能对齐成一条竖线。
                Toggle("", isOn: $selected)
                    .toggleStyle(ThemeCheckStyle(side: 16))
                    .disabled(!selectable)
                    .labelsHidden()
                    .opacity(selectable ? 1 : 0)

                // 图形定宽一格：取不取得到图标都不能让名字那一列左右跳。
                // 挂在勾选框后面而不是最左，是因为勾选才是这一行唯一可操作的东西，
                // 它必须继续对齐成一条竖线。
                RowIconView(icon: icon, appID: appID, brand: brand)
                    .frame(width: rowIconSide, height: rowIconSide)

                Button {
                    withAnimation(reduceMotion ? nil : theme.animation) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 10) {
                        ThemeChevron(expanded: expanded, color: chevronColor)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(name)
                                .font(theme.bodyFont(.callout))
                                .foregroundStyle(theme.palette.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let sub {
                                Text(sub)
                                    .font(theme.bodyFont(.caption2))
                                    .foregroundStyle(theme.palette.inkTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 10)

                if let badge {
                    ThemeBadge(text: badge.text, tone: badge.tone)
                }

                SizeNumber(shown: sizeText, size: act ? 21 : 17, color: numberColor)
                    .frame(minWidth: 104, alignment: .trailing)
            }
            .padding(.top, 11)
            .padding(.bottom, 8)

            // 条子定宽 232 不铺满：贴到行尾的长条会被读成分隔线，而且各页行宽不同
            // 就没了可比性。窗口窄到装不下时宁可让 List 截这一列的右边，不缩短条子。
            ProportionBar(fraction: fraction,
                          color: act ? SweepRing.lamp(theme.palette.tint) : theme.palette.inkTertiary,
                          track: theme.palette.surfaceAlt,
                          height: 3, trackWidth: 232)
                .padding(.leading, rowLeadInset)
                .padding(.bottom, 11)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    detail()
                    if let hint = lockedHint {
                        Text(hint)
                            .font(theme.bodyFont(.caption))
                            .foregroundStyle(theme.palette.warnFG)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, rowLeadInset)
                .padding(.bottom, 11)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showRule {
                Rectangle().fill(theme.palette.separator.opacity(0.7))
                    .frame(height: 1).padding(.horizontal, 8)
            }
        }
        .background(rowBG, in: theme.controlShape())
        // 截图那一趟不认悬停：鼠标停在谁身上是拍图这一刻的偶然，而没人碰它时这一行没有高亮。
        // 与关掉常驻动效同一条理由（`SnapshotMode.active`）——拍出去的得是静止态那张脸。
        .onHover { if !SnapshotMode.active { hovering = $0 } }
        .onAppear { if preopen { expanded = true } }
        .themedRow()
    }

    /// 数和单位的颜色，三档：已勾 > 动得了 > 只能看。
    ///
    /// 已勾那一档必须是灯色：底部那条清理条只报「已选 X 项」，哪几项被选了得在
    /// 列表里当场看得见（样稿 `.val.sel`）。
    private var numberColor: Color {
        if selected { return SweepRing.lamp(theme.palette.tint) }
        return act ? theme.palette.ink : theme.palette.inkSecondary
    }

    private var chevronColor: Color {
        act ? SweepRing.lamp(theme.palette.tint).opacity(0.72) : theme.palette.inkTertiary
    }

    /// 勾选那一行从左缘打进来一道光，不是描边：整列都是格子的时候再多两个矩形框，
    /// 用户就分不清哪个框是「能按的东西」了。样稿这道光在行宽 72% 处已经灭掉。
    private var rowBG: some ShapeStyle {
        let glow = selected ? 0.13 : (hovering ? 0.07 : 0)
        if glow == 0 { return AnyShapeStyle(Color.clear) }
        return AnyShapeStyle(LinearGradient(stops: [
            .init(color: SweepRing.lamp(theme.palette.tint).opacity(glow), location: 0),
            .init(color: .clear, location: 0.72)
        ], startPoint: .leading, endPoint: .trailing))
    }
}

// MARK: - 一块账本

extension View {
    /// 整列装进同一张卡：底、边、投影三样由这里给，行自己不给。
    ///
    /// 上一版每行一张卡，27 行就是 27 个盒子；样稿把这一页画成**一块表**，
    /// 行与行之间只有一道 1px 分段线（线在 `ItemRow` 自己头上画）。
    /// 卡片只留一层投影、12 磅圆角，压在页头和底部清理条之间。
    func ledgerCard() -> some View { modifier(LedgerCardChrome()) }
}

private struct LedgerCardChrome: ViewModifier {
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        let shape = theme.cardShape()
        content
            .themedList()
            .background(shape.fill(theme.palette.surface))
            .clipShape(shape)
            .overlay(shape.stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
            .shadow(color: theme.palette.shadow, radius: 3, x: 0, y: 1)
            .padding(.horizontal, 20)
    }
}

/// 账本下面那句对账话：这一屏列出的数**和页头那个数是什么关系**。
///
/// 只做一件小事：不给它卡、也不给它在卡外面再画一道边，11pt 灰字坐在卡下面。
/// 句子由各页拼（每页的账不一样），但字号、颜色、留白只有这一处。
struct ListNote: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(theme.bodyFont(.caption))
            .foregroundStyle(theme.palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .pagePadding()
            .padding(.top, 11)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 这一页的账（列表页顶部那块读数）

/// 账上的一个分档：这一屏列出的行里，归这一档的那部分字节。
///
/// 分档由**各页自己**给，不是一套三档模板：只有缓存页真的同时有
/// 「动得了 / 留意 / 只能看」三堆；重复项、node_modules 整页都动得了；
/// Docker 整页一个字节的决定都不替用户做。硬套三档就得编出「只能看 0 B」。
struct LedgerTier {
    enum Tone { case hot, warn, cold }
    var label: String
    var bytes: Int64
    var tone: Tone
}

/// 列表页顶上的「这一页的账」：合计数、分档条、图例。
///
/// 这笔账原来只有一句 11pt 灰字，压在二十行列表**底下**（`ListNote`）：
/// 「列出的 18 项合计 29.2 GB：本工具动得了 15.4 GB，其余只能看不能删」。
/// 话是对的，位置不对——一屏最先要回答的是「这一页值多少、其中多少动得了」，
/// 却排在下面二十个数字之后，等用户自己把那一列加出来。这里把同一笔账搬到
/// 列表上方，字换成行里那套两档数字，分档用一条整页宽的条子说。
///
/// 不新增数字：合计与每一档都从**同一批行**里加出来（`listedSplitOf` 那本账），
/// 各档字符串走 `addableHumanColumn`，所以图例相加正好等于头上那个合计。
/// 空的那一档不画、那句「其中动得了的」在只有一个档时也不写（它跟合计是同一个数）。
struct PageLedger: View {
    @Environment(\.theme) private var theme
    var tiers: [LedgerTier]
    var rows: Int
    var note: String? = nil

    /// 只留真有字节的那些档。
    private var drawn: [LedgerTier] { tiers.filter { $0.bytes > 0 } }
    private var total: Int64 { drawn.reduce(Int64(0)) { $0 + $1.bytes } }
    /// 各档那串字：统一到合计那个单位、按最大余数法补位，图例相加 = 合计。
    private var shown: [String] { addableHumanColumn(drawn.map(\.bytes), total: total) }
    private var totalShown: String { human(total) }

    /// 「其中动得了的」那一格：只有当动得了的确实少于合计数才写。
    private var hotCell: Int? {
        guard let i = drawn.firstIndex(where: { $0.tone == .hot }) else { return nil }
        return drawn[i].bytes < total ? i : nil
    }

    var body: some View {
        Group {
            if drawn.isEmpty {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: drawn.count > 1 ? 9 : 8) {
                    numbers
                    // 条子永远画：只有一个档时它是这一页唯一的图形信息——整条亮色＝
                    // 「这一页全动得了」，整条灰＝「一个字节的决定都不替你做」。
                    // 这也是这块卡片的横向重心：少了一条通宽的条，卡片右半截是空的。
                    stack
                    // 图例只在两档以上才出现：单档时它会把头上那个合计数一字不差
                    // 再说一遍，同屏两遍同样的数就是两本账。
                    if drawn.count > 1 { legend }
                    if let note {
                        Text(note)
                            .font(theme.bodyFont(.caption))
                            .foregroundStyle(theme.palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.cardShape().fill(theme.palette.surface))
                .clipShape(theme.cardShape())
                .overlay(theme.cardShape().stroke(theme.palette.separator,
                                                 lineWidth: theme.metric.stroke))
                .shadow(color: theme.palette.shadow, radius: 3, x: 0, y: 1)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
    }

    private var numbers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(L("这一页量到"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
            SizeNumber(shown: totalShown, size: 22)
            Text("· " + cnt(rows, "项"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkTertiary)
                .layoutPriority(1)
            Spacer(minLength: 10)
            if let i = hotCell {
                Text(L("其中动得了的"))
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                SizeNumber(shown: shown[i], size: 22, color: theme.palette.tint)
            }
        }
    }

    /// 整页宽的分档条。
    ///
    /// 段与段之间留 2pt 缝、缝里透出卡底：三档挨着涂时 tint 和洗淡的 tint 会在
    /// 交界处糊成一块，看不出是两笔账。**最小给 4pt**：0.1 GB 那一档在这盘上
    /// 占不到千分之一，算出来不到一个像素就等于从条子上消失，而图例里明明写着它。
    private var stack: some View {
        GeometryReader { geo in
            let gap: CGFloat = 2
            let usable = max(1, geo.size.width - gap * CGFloat(drawn.count - 1))
            HStack(spacing: gap) {
                ForEach(Array(drawn.enumerated()), id: \.offset) { _, t in
                    let f = min(1, max(0, Double(t.bytes) / Double(max(1, total))))
                    Capsule().fill(color(t.tone))
                        .frame(width: min(usable, max(4, usable * f)))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            ForEach(Array(drawn.enumerated()), id: \.offset) { i, t in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(t.tone))
                        .frame(width: 8, height: 8)
                    Text("\(t.label) \(shown[i])")
                        .font(theme.bodyFont(.caption))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.inkSecondary)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// 一档一色，跟环形图那条规矩同一套：**彩色只给动得了的**，留意用徽章那支墨色，
    /// 只能看不上色。灰那一档走 `inkTertiary` 而不是 `separator`：实拍过分隔线那个
    /// 灰在白卡上几乎看不见，整条读成一道分隔线而不是一段账。
    private func color(_ tone: LedgerTier.Tone) -> Color {
        switch tone {
        case .hot:  return theme.palette.tint
        case .warn: return theme.palette.warnFG
        case .cold: return theme.palette.inkTertiary.opacity(0.75)
        }
    }
}

/// 列出的这些行按「动得了 / 只能看」分两堆的字节账，给 `PageLedger` 当输入。
///
/// 两堆从**同一批行**里加出来，所以两者之和就是那一列的合计——对账句里
/// 「合计 X：动得了 Y」的 X 与 Y 必须同源，否则那句本身就加不回来。
func listedSplitOf<T>(_ rows: [T], bytes: (T) -> Int64,
                      lit: (T) -> Bool) -> (reclaimable: Int64, viewOnly: Int64) {
    var r = Int64(0), v = Int64(0)
    for row in rows { if lit(row) { r += bytes(row) } else { v += bytes(row) } }
    return (r, v)
}

/// 一整列尺寸，按行的 key 查自己那串字。
///
/// 整列过一遍 `addableHumanColumn`（统一到页头那个总数的单位 + 最大余数法补位），
/// 于是屏幕上这一列**印出来的那几串字**相加正好等于对账句里那个合计。
/// 各行自己 `human()` 会各自往上飘，实拍过「12.0 + 6.3 + 4.2 = 22.5」而总数写 22.4。
/// 用字典而不是下标：`List($rows)` 拿不到下标，而下标一错位整列就说谎。
func sizeColumn<Key: Hashable>(_ rows: [(key: Key, bytes: Int64)]) -> [Key: String] {
    let bytes = rows.map(\.bytes)
    let shown = addableHumanColumn(bytes, total: bytes.reduce(Int64(0), +))
    var out: [Key: String] = [:]
    for (k, s) in zip(rows.map(\.key), shown) { out[k] = s }
    return out
}

/// 展开行里那句「这一处到底装着什么」：文件个数 + 最近一次改动。
///
/// 只有字节数的那一版，13 GB 的一堆碎缓存和 13 GB 的单个磁盘镜像在界面上长一样，
/// 而前者能一条条判、后者不能。个数和日期才是「敢不敢勾」的依据。
/// 一个都没量到就返回 nil——那一行不画，不写「0 个文件」。
func contentsLine(_ files: Int, _ newest: Date?) -> String? {
    var parts: [String] = []
    if files > 0 { parts.append(cnt(files, "个文件")) }
    if let newest { parts.append(LF("最近改动 %@", shortDate(newest))) }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

/// 说明行：「这是什么 / 删了会怎样」这类键值对
struct ExplainLine: View {
    @Environment(\.theme) private var theme
    var key: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(theme.bodyFont(.caption).weight(.semibold))
                .foregroundStyle(theme.palette.inkTertiary)
                // 「这是什么」4 字 vs "What is this" 11 字——宽度按内容走，别钉死
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 66, alignment: .leading)
            Text(value)
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 路径行。整行就是「在访达里把这个文件选中」那颗按钮。
///
/// 为什么不用 `Button` 包：Button 的 label 会吃掉 `.textSelection`，
/// 那样就只剩「打开」没有了「复制路径」。点一下和拖选一段得同时成立。
struct PathLine: View {
    @Environment(\.theme) private var theme
    var path: String

    @State private var hovering = false
    @State private var hand = false

    private var fg: Color {
        hovering ? SweepRing.lamp(theme.palette.tint) : theme.palette.inkTertiary
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(fg)
            Text(path)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(fg)
                .underline(hovering, color: fg)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture(perform: reveal)
        }
        .padding(.leading, 2)
        .contentShape(Rectangle())
        .onTapGesture(perform: reveal)
        .onHover {
            hovering = $0
            // 同 SweepRing：光标只在翻转时动，拆掉这层时要把箭头还回去
            guard hand != $0 else { return }
            hand = $0
            ($0 ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help(LF("在访达里打开 %@", path))
        .accessibilityAddTraits(.isLink)
    }
}

// MARK: - 底部清理条

/// CleanBar 上那颗「全选」要知道的三件事。
struct SelectAll {
    var allSelected: Bool
    /// 这颗按钮不碰的行数（勾不了的、或刻意不批量碰的）。不报这个数，列表 30 行、
    /// 按完只选上 20 项，用户只会以为漏了 10 项。
    var unselectable: Int
    var toggle: (Bool) -> Void
}

/// 列表页的底部收口：一条通栏带子，顶上那道 1px 线就是它和账本的分界。
///
/// 原先它是一张浮在内容上的卡（12 磅投影 + 四周留白），于是每一页都有两个「盒子」在
/// 抢同一块地方——上面那张账本卡和它下面这张浮卡。样稿把它压成一条带子：
/// 通栏、只有一道上边线、不投影。它说的是「这一页的合计与动手的地方」，
/// 不是一个飘在画面上的通知。
struct CleanBar: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: AppStore
    var count: Int
    var bytes: Int64
    /// `bytes` 印成哪串字。由页面按整列那个单位给（`unifiedHuman` / `addableHumanColumn`），
    /// 不给就现算——现算的会和上面那一列不同单位，同一屏两把尺。
    var bytesText: String = ""
    var errorText: String? = nil
    /// 清理条右侧那句口径话：这一页的合计是怎么算出来的（并集、每组留一份、留意项不批量勾）
    var hint: String? = nil
    var selection: SelectAll? = nil
    var onClean: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let e = errorText {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.warnFG)
                    Text(e)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.warnFG)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.controlShape().fill(theme.palette.warnBG))
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 8)
            }

            HStack(spacing: 13) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 0 ? L("还没勾选任何东西") : LF("已选 %1$d 项", count))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                    SizeNumber(shown: shownBytes, size: 21)
                }
                if let s = selection {
                    ThemeButton(kind: .compact, symbol: s.allSelected ? "circle.dashed" : "checklist",
                                title: s.allSelected ? L("取消全选") : L("全选")) {
                        s.toggle(!s.allSelected)
                    }
                    .help(s.unselectable == 0
                          ? L("选中本页列出的全部")
                          : LF("选中本页列出的全部，另有 %d 项不在全选范围内", s.unselectable))
                }
                Spacer(minLength: 10)
                if let h = hint {
                    Text(h)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(L("只进废纸篓，可撤销"))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                }
                ThemeButton(kind: .primary, symbol: "trash",
                            title: ctaTitle, isDisabled: count == 0, action: onClean)
                    .accessibilityLabel(LF("把选中的 %1$d 项移入废纸篓，随时可撤销", count))
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 13)
            .frame(maxWidth: .infinity)
            .background(theme.palette.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(theme.palette.separator).frame(height: 1)
            }
        }
        // 截图链路要「真按一次」才照得见这颗按钮的两态（见 AppStore.selectAllPulse）。
        // 同一时刻画面上只有一页在渲染，所以这一按落的就是当前页那条清理条。
        .onChange(of: store.selectAllPulse) { _ in
            guard let s = selection else { return }
            s.toggle(!s.allSelected)
        }
    }

    private var shownBytes: String { bytesText.isEmpty ? human(bytes) : bytesText }

    /// 那颗按钮自己把「要带走多少」说出来：这一页底下那一串数字可以被划出视野，
    /// 而按下按钮的那一刻，眼睛只在按钮上。没勾任何东西时不拍数，拍一个 0 是假数。
    private var ctaTitle: String {
        bytes > 0 ? LF("把选中的 %@ 移进废纸篓", shownBytes) : L("把选中的移进废纸篓")
    }
}

// MARK: - 确认对话框

extension View {
    /// 扫描页通用 confirm：措辞统一，不许各页自己发挥
    func confirmTrash(isPresented: Binding<Bool>, text: String,
                      action: @escaping () -> Void) -> some View {
        alert(L("确认清理？"), isPresented: isPresented) {
            Button(L("取消"), role: .cancel) {}
            Button(L("移入废纸篓"), role: .destructive, action: action)
        } message: {
            Text(text + L("删除只进废纸篓，随时可撤销；真正释放空间需要之后清空废纸篓。"))
        }
    }
}

// MARK: - 工具条（筛选/参数 + 右侧动作）

struct ControlStrip<Content: View, Trailing: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        // 一行装得下就一行；装不下让状态文字换到上一行，而不是把英文句子截成
        // 「Found 5 duplicate gro…」。状态文字必须 fixedSize 才能报出真实宽度，
        // 否则 HStack 永远「装得下」（Text 会自己截断），第二档永远轮不到。
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                content().fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                trailing()
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) { content() }
                HStack(spacing: 10) { Spacer(minLength: 0); trailing() }
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(theme.bodyFont(.callout))
        .foregroundStyle(theme.palette.inkSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension ControlStrip where Trailing == EmptyView {
    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
        self.trailing = { EmptyView() }
    }
}

/// 扫描页的共用动作：扫描中给「停止」，扫完给「重新扫描」。
/// 结果跨 tab 复用之后，进页面不再自动重扫，这颗按钮就是用户唯一的重扫入口。
struct ScanControl: View {
    @Environment(\.theme) private var theme
    var scanning: Bool
    var kind: ThemeButton.Kind = .secondary
    var rescan: () -> Void
    var stop: () -> Void

    var body: some View {
        if scanning {
            ThemeButton(kind: .secondary, symbol: "stop.fill",
                        title: L("停止"), action: stop)
        } else {
            ThemeButton(kind: kind, symbol: "arrow.clockwise",
                        title: L("重新扫描"), action: rescan)
        }
    }
}

/// 皮肤化的数值步进器（系统 Stepper 的标签排版跟皮肤打架）
struct ThemeStepper: View {
    @Environment(\.theme) private var theme
    var label: String
    var unit: String? = nil
    var value: Binding<Int>
    var range: ClosedRange<Int>
    var step: Int = 1
    var onCommit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            Text(label)
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
                .padding(.horizontal, 10)
            hairline
            stepButton("minus", enabled: value.wrappedValue > range.lowerBound) {
                value.wrappedValue = max(range.lowerBound, value.wrappedValue - step)
                onCommit?()
            }
            hairline
            Text("\(value.wrappedValue)")
                .font(theme.numeric(.callout))
                .monospacedDigit()
                .foregroundStyle(theme.palette.ink)
                .frame(minWidth: 34)
            hairline
            stepButton("plus", enabled: value.wrappedValue < range.upperBound) {
                value.wrappedValue = min(range.upperBound, value.wrappedValue + step)
                onCommit?()
            }
            // 单位放进框里：挂在框外面的「天 / MB」小胶囊会被读成另一个控件，
            // 而且它是文案不是徽章，英文下还会把整行顶到窗口边。
            if let unit {
                hairline
                Text(unit)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.inkSecondary)
                    .padding(.horizontal, 10)
                    .fixedSize()
            }
        }
        .frame(height: 30)
        .fixedSize()
        .background(theme.controlShape().fill(theme.palette.surface))
        .overlay(theme.controlShape().stroke(theme.palette.separator,
                                            lineWidth: theme.metric.stroke))
        .clipShape(theme.controlShape())
    }

    /// HStack 里的 Divider 会吃满父级给的高度，这里自己画一根
    private var hairline: some View {
        Rectangle().fill(theme.palette.separator)
            .frame(width: theme.metric.stroke, height: 16)
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(enabled ? theme.palette.ink : theme.palette.inkTertiary.opacity(0.5))
                .frame(width: 24, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(symbol == "plus" ? L("增加") : L("减少"))
    }
}

/// 皮肤化开关
struct ThemeSwitch: View {
    @Environment(\.theme) private var theme
    var label: String
    var isOn: Binding<Bool>
    var onCommit: (() -> Void)? = nil

    var body: some View {
        Button {
            withAnimation(theme.animation) { isOn.wrappedValue.toggle() }
            onCommit?()
        } label: {
            HStack(spacing: 7) {
                ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Capsule().fill(isOn.wrappedValue ? theme.palette.tint : theme.palette.surfaceAlt)
                        .frame(width: 28, height: 16)
                        .overlay(Capsule().stroke(theme.palette.separator, lineWidth: 1))
                    Circle().fill(.white)
                        .frame(width: 12, height: 12)
                        .shadow(color: theme.palette.shadow, radius: 1, x: 0, y: 1)
                        .padding(.horizontal, 2)
                }
                Text(label)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.inkSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOn.wrappedValue ? L("开") : L("关"))
    }
}
