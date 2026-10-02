import SwiftUI
import DiskCleanerCore

// ── 菜单栏与启动页（稿子①新加的那一屏）──────────────────────────────────────
//
// 这一屏只有两格开关，是 ⌘, 该落的地方。稿子①写着：扫描范围、单位口径、语言这些
// 等有真实需要再进来，不预先摆空位——所以这里不铺一屏系统设置的仿制品。
//
// 两行下面那两句注解走 inkTertiary 灰小字，不给灯色也不给警示色：
// 跨皮肤铁律第 1 条，正文不染色；而且这两格都不是「动得了的东西」。

struct MenuBarLaunchView: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(symbol: "gearshape.2",
                           title: L("菜单栏与启动"),
                           subtitle: L("App 没开窗的时候，你从哪里找到它"),
                           variant: .display)

                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switches
                        footnote
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    // 与反馈页同宽：两格开关加一句注解，铺开成横幅就读成设置了整个 macOS
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .themedList()
            }
            .pagePadding()
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 两格开关

    private var switches: some View {
        VStack(spacing: 0) {
            SwitchLine(title: L("在菜单栏显示可用容量"),
                       note: L("只看卷的剩余空间，不扫盘、不读你的文件 · 默认开着"),
                       isOn: Binding(get: { prefs.menuBarEnabled },
                                     set: { prefs.setMenuBar($0) }))
            Divider().overlay(theme.palette.separator)
            SwitchLine(title: L("开机时启动 DiskWise"),
                       note: L("不随机启动时，菜单栏只在 App 开着时出现 · 系统设置里允许后才生效"),
                       isOn: Binding(get: { prefs.loginItemEnabled },
                                     set: { prefs.setLoginItem($0) })) {
                if prefs.loginItemBlocked { openSettingsButton }
            }
        }
        .padding(.vertical, 4)
        .background(theme.cardShape().fill(theme.palette.surface))
        .overlay(theme.cardShape().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
    }

    private var openSettingsButton: some View {
        ThemeButton(kind: .compact, symbol: "arrow.up.right.square",
                    title: L("打开系统设置")) { Prefs.openLoginItemsSettings() }
            .fixedSize()
    }

    private var footnote: some View {
        Text(L("这一屏只有上面两行。扫描范围、单位口径、语言这些等有真实需要再进来。"))
            .font(theme.bodyFont(.caption))
            .foregroundStyle(theme.palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 一行 = 一句会说人话的开关名 + 一句口径注解 + 系统那颗开关。
/// 开关尺寸不自己画：`.switch` 就是系统设置里那一只，稿子①量到的 38×22 pt 是它的实测值。
private struct SwitchLine<Trailing: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var note: String
    var isOn: Binding<Bool>
    var trailing: Trailing

    init(title: String, note: String, isOn: Binding<Bool>,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.note = note
        self.isOn = isOn
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(note)
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
