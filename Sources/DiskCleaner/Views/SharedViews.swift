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

// MARK: - 徽章数据

struct ItemBadge {
    var text: String
    var tone: ThemeBadge.Tone
}

// MARK: - 可清理条目行

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
                        Image(systemName: expanded ? "chevron-down" : "chevron-right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(theme.palette.inkTertiary)
                            .frame(width: 10)
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

            ProportionBar(fraction: fraction, color: barColor, height: 3)
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

struct CleanBar: View {
    @Environment(\.theme) private var theme
    var count: Int
    var bytes: Int64
    var errorText: String? = nil
    var actionTitle: String = L("移入废纸篓")
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

// MARK: - 工具条（筛选/参数）

struct ControlStrip<Content: View>: View {
    @Environment(\.theme) private var theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 10) {
            content()
            Spacer(minLength: 0)
        }
        .font(theme.bodyFont(.callout))
        .foregroundStyle(theme.palette.inkSecondary)
    }
}

/// 皮肤化的数值步进器（系统 Stepper 的标签排版跟皮肤打架）
struct ThemeStepper: View {
    @Environment(\.theme) private var theme
    var label: String
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
