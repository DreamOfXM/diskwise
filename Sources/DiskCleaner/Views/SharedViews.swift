import SwiftUI
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

    /// 一行 = 一张卡
    func themedRow() -> some View {
        listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
    }

    /// 页面内容通用内边距
    func pagePadding() -> some View {
        padding(.horizontal, 20)
    }
}

/// 一条失败原因：「条目名：为什么」。TrashError 只给原因码，句子在这拼
func failLine(_ name: String, _ error: Error) -> String {
    let reason: String
    if let t = error as? TrashError {
        reason = t.detail.isEmpty ? L(t.reasonKey) : LF("%@：%@", L(t.reasonKey), t.detail)
    } else {
        reason = error.localizedDescription
    }
    return LF("%@：%@", name, reason)
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

// MARK: - 可清理条目行

/// 整盘扫描会扫到我们删不动的位置。行照样列出来（那是账），但勾选框锁死，
/// 而且得说清为什么锁——不然用户只会以为工具坏了。
/// 做成计算属性而不是常量：语言切换后要跟着换。
var outsideScopeHint: String {
    L("这个位置我们不动：要么只有管理员写得动，要么归 Homebrew / Xcode 自己管，用它们各自的清理命令更安全。")
}

/// 扫描中、一行都还没出来时画什么。
///
/// 列表是扫完才一次性回填的，整盘范围能走几分钟；这段时间留着空白页，用户只能
/// 猜程序是不是死了。范围写在文案里，等起来才有理由。
func scanningState(scope: ScanScope) -> some View {
    ScanningState(title: L("正在扫描"),
                  hint: LF("范围「%@」，要把每个目录走一遍才出列表。", scope.uiName))
}

struct ItemRow<Detail: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Binding var selected: Bool
    var name: String
    var sub: String? = nil
    var sizeText: String
    /// 0...1，相对本页最大项的比例——磁盘工具不画比例就等于没画
    var fraction: Double = 1
    var barColor: Color? = nil
    var badge: ItemBadge? = nil
    var selectable: Bool = true
    var lockedHint: String? = nil
    @ViewBuilder var detail: () -> Detail

    @State private var expanded = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 11) {
                Toggle("", isOn: $selected)
                    .toggleStyle(ThemeCheckStyle())
                    .disabled(!selectable)
                    .labelsHidden()

                Button {
                    withAnimation(reduceMotion ? nil : theme.animation) {
                        expanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        ThemeChevron(expanded: expanded)
                        VStack(alignment: .leading, spacing: 2) {
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

                Text(sizeText)
                    .font(theme.numeric(.callout))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.ink)
                    .fixedSize()
            }

            ProportionBar(fraction: fraction, color: barColor)
                .padding(.leading, 29)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    theme.palette.separator
                        .frame(height: 1)
                        .padding(.bottom, 2)
                    detail()
                    if let hint = lockedHint {
                        Text(hint)
                            .font(theme.bodyFont(.caption))
                            .foregroundStyle(theme.palette.warnFG)
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(
            theme.cardShape().fill(hovering ? theme.palette.surfaceAlt.opacity(0.5)
                                           : theme.palette.surface)
        )
        .overlay(
            theme.cardShape().stroke(
                selected ? theme.palette.tint.opacity(0.5) : theme.palette.separator,
                lineWidth: theme.metric.stroke
            )
        )
        .themedRow()
    }
}

extension ItemRow where Detail == EmptyView {
    init(selected: Binding<Bool>, name: String, sub: String? = nil,
         sizeText: String, fraction: Double = 1, barColor: Color? = nil,
         badge: ItemBadge? = nil, selectable: Bool = true, lockedHint: String? = nil) {
        self._selected = selected
        self.name = name
        self.sub = sub
        self.sizeText = sizeText
        self.fraction = fraction
        self.barColor = barColor
        self.badge = badge
        self.selectable = selectable
        self.lockedHint = lockedHint
        self.detail = { EmptyView() }
    }
}

// MARK: - 说明行

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

struct PathLine: View {
    @Environment(\.theme) private var theme
    var path: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 9))
                .foregroundStyle(theme.palette.inkTertiary)
            Text(path)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 2)
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

struct CleanBar: View {
    @Environment(\.theme) private var theme
    @EnvironmentObject private var store: AppStore
    var count: Int
    var bytes: Int64
    var errorText: String? = nil
    var actionTitle: String = L("移入废纸篓")
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
                .padding(.bottom, 8)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 0 ? L("还没勾选任何东西") : LF("已选 %1$d 项", count))
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Text(human(bytes))
                        .font(theme.numeric(.title3))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.ink)
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
                Spacer()
                Text(L("只进废纸篓，可撤销"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                ThemeButton(kind: .primary, symbol: "trash",
                            title: actionTitle, isDisabled: count == 0, action: onClean)
                    .accessibilityLabel(LF("把选中的 %1$d 项移入废纸篓，随时可撤销", count))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(theme.cardShape().fill(theme.palette.surface))
            .overlay(theme.cardShape().stroke(theme.palette.separator,
                                             lineWidth: theme.metric.stroke))
            .shadow(color: theme.palette.shadow, radius: 12, x: 0, y: -2)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        // 截图链路要「真按一次」才照得见这颗按钮的两态（见 AppStore.selectAllPulse）。
        // 同一时刻画面上只有一页在渲染，所以这一按落的就是当前页那条清理条。
        .onChange(of: store.selectAllPulse) { _ in
            guard let s = selection else { return }
            s.toggle(!s.allSelected)
        }
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
