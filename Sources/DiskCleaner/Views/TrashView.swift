import SwiftUI
import DiskCleanerCore

// ── 废纸篓面板：体积 + 撤销 + 交给访达清空 ──
// 清空这一步永远由访达执行（系统再拦一次），本工具不自己删。

struct TrashView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @State private var size: Int64? = nil
    @State private var confirmEmpty = false
    @State private var message: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(symbol: "trash", title: L("最后一道门"),
                           subtitle: L("东西都在这躺着，后悔药管够——清空才真没"),
                           variant: .display)

                HStack(alignment: .top, spacing: 14) {
                    ThemedCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("废纸篓现在"))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkSecondary)
                            Text(size.map { human($0) } ?? L("统计中…"))
                                .font(theme.numeric(.largeTitle))
                                .monospacedDigit()
                                .foregroundStyle(theme.palette.ink)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ThemedCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("本次移入"))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkSecondary)
                            Text(human(store.trashedBytes))
                                .font(theme.numeric(.largeTitle))
                                .monospacedDigit()
                                .foregroundStyle(theme.palette.ink)
                            Text(LF("%@可撤销", cnt(store.trashHistory.count, "项")))
                                .font(theme.bodyFont(.caption2))
                                .foregroundStyle(theme.palette.inkTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                ThemedCard {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "shield.checkerboard")
                            .font(.system(size: 14))
                            .foregroundStyle(theme.palette.tint)
                        Text(L("本工具所有的“删除”都只是移入废纸篓。真正释放空间要清空——那一步交给访达，系统会再拦你一次。"))
                            .font(theme.bodyFont(.callout))
                            .foregroundStyle(theme.palette.inkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 10) {
                    ThemeButton(kind: .secondary, symbol: "folder",
                                title: L("访达中打开")) { openTrashInFinder() }
                    ThemeButton(kind: .secondary, symbol: "arrow.clockwise",
                                title: L("重新统计")) { refresh() }
                    ThemeButton(kind: .secondary, symbol: "arrow.uturn.backward",
                                title: L("撤销上次"),
                                isDisabled: store.trashHistory.isEmpty) {
                        message = store.undoLast()
                        refresh()
                    }
                    Spacer()
                    ThemeButton(kind: .danger, symbol: "flame",
                                title: L("清空废纸篓"),
                                isDisabled: (size ?? 0) == 0) { confirmEmpty = true }
                }

                if let m = message {
                    Text(m)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.inkSecondary)
                }

                if !store.trashHistory.isEmpty {
                    SectionLabel(text: L("本次操作记录"), detail: L("从新到旧"))
                    historyList
                }
            }
            .pagePadding()
            .padding(.top, 18)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L("废纸篓"))
        .onAppear { refresh() }
        .alert(L("清空废纸篓？"), isPresented: $confirmEmpty) {
            Button(L("取消"), role: .cancel) {}
            Button(L("交给访达清空"), role: .destructive) { empty() }
        } message: {
            Text(L("这一步由访达执行，清空后不可恢复。系统层面会再确认一次。"))
        }
    }

    private var historyList: some View {
        LazyVStack(spacing: 8) {
            ForEach(Array(store.trashHistory.reversed().enumerated()), id: \.offset) { _, rec in
                HStack(spacing: 11) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.inkTertiary)
                    Text(rec.displayName)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 10)
                    Text(human(rec.size))
                        .font(theme.numeric(.callout))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.inkSecondary)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background(theme.cardShape().fill(theme.palette.surface))
                .overlay(theme.cardShape().stroke(theme.palette.separator,
                                                 lineWidth: theme.metric.stroke))
            }
        }
    }

    private func refresh() {
        size = nil
        Task {
            let s = trashSize()
            await MainActor.run { size = s }
        }
    }

    private func empty() {
        do {
            let before = volumeUsage()?.free ?? 0
            try emptyTrashViaFinder()
            // 访达是异步清空的，等 2 秒再读，报告真实释放量
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let after = volumeUsage()?.free ?? before
                await MainActor.run {
                    message = LF("已请访达清空，真实释放约 %@（以访达完成为准）。", human(max(0, after - before)))
                    store.clearHistory()
                    refresh()
                }
            }
        } catch {
            message = LF("清空失败：%@。去「系统设置 → 隐私与安全性 → 自动化」里允许本工具控制访达，然后重试。",
                         error.localizedDescription)
        }
    }
}
