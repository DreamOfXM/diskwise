import SwiftUI
import DiskCleanerCore

// ── 废纸篓面板：体积 + 撤销 + 交给访达清空 ──
// 清空这一步永远由访达执行（系统再拦一次），本工具不自己删。

struct TrashView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @State private var info: (items: Int, bytes: Int64)? = nil
    @State private var measuring = false
    @State private var measureTask: Task<Void, Never>? = nil
    @State private var confirmEmpty = false
    @State private var message: String? = nil
    /// 上一次失败到底是不是「系统没放行自动化」——只有是的时候才摆授权入口
    @State private var automationGate = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "trash", title: L("废纸篓"),
                       subtitle: L("东西都在这躺着，后悔药管够——清空才真没"),
                       variant: .display)
                .pagePadding()
                .padding(.top, 14)
                .padding(.bottom, 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 14) {
                        ThemedCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(L("废纸篓现在"))
                                    .font(theme.bodyFont(.caption))
                                    .foregroundStyle(theme.palette.inkSecondary)
                                Text(sizeText)
                                    .font(theme.numeric(.largeTitle))
                                    .monospacedDigit()
                                    .foregroundStyle(theme.palette.ink)
                                if measuring {
                                    Text(L("正在数过每一个条目…"))
                                        .font(theme.bodyFont(.caption2))
                                        .foregroundStyle(theme.palette.inkTertiary)
                                } else if let info {
                                    Text(cnt(info.items, "项"))
                                        .font(theme.bodyFont(.caption2))
                                        .foregroundStyle(theme.palette.inkTertiary)
                                } else {
                                    Text(L("这里读不到，以访达为准"))
                                        .font(theme.bodyFont(.caption2))
                                        .foregroundStyle(theme.palette.inkTertiary)
                                }
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
                                    isDisabled: info?.items == 0) { confirmEmpty = true }
                    }

                    if let m = message {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(m)
                                .font(theme.bodyFont(.callout))
                                .foregroundStyle(theme.palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if automationGate {
                                ThemeButton(kind: .compact, symbol: "lock.open",
                                            title: L("打开自动化设置")) {
                                    openAutomationPane()
                                }
                            }
                        }
                    }

                    if !store.trashHistory.isEmpty {
                        SectionLabel(text: L("本次操作记录"), detail: L("从新到旧"))
                        historyList
                    }
                }
                .pagePadding()
                .padding(.top, 16)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refresh() }
        .onDisappear { measureTask?.cancel() }
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

    private var sizeText: String {
        if measuring { return L("统计中…") }
        guard let info else { return L("未知") }
        return human(info.bytes)
    }

    private func refresh() {
        measureTask?.cancel()
        measuring = true
        info = nil
        measureTask = Task {
            let r = await trashInfo()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                info = r
                measuring = false
            }
        }
    }

    private func empty() {
        automationGate = false
        message = L("正在请访达清空…")
        // 清空这一步要同步等访达的事件回执：它可能先弹自己的确认框，清空一个大
        // 废纸篓也能持续好几秒。搁主线程上点完就冻住，看着就是「按了没反应」。
        Task {
            let job: (free: Int64?, result: Result<Void, Error>) = await Task.detached(priority: .userInitiated) {
                let before = volumeUsage()?.free
                return (before, Result { try emptyTrashViaFinder() })
            }.value
            await MainActor.run { finishEmpty(job) }
        }
    }

    private func finishEmpty(_ job: (free: Int64?, result: Result<Void, Error>)) {
        switch job.result {
        case .success:
            // 访达是异步清空的，等 2 秒再读，报告真实释放量
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let before = job.free ?? 0
                let after = volumeUsage()?.free ?? before
                await MainActor.run {
                    message = LF("已请访达清空，真实释放约 %@（以访达完成为准）。", human(max(0, after - before)))
                    store.clearHistory()
                    refresh()
                }
            }
        case .failure(let error):
            // 报访达的原话 + 错误号，而不是 Swift 自动生成的「错误 N」——
            // 那个数字既不告诉用户下一步，也让我们远程排查时什么都问不出来。
            let why = failReason(error)
            if let t = error as? TrashError {
                switch t {
                case .automationDenied:
                    automationGate = true
                    message = LF("清空失败：%@。系统没放行本工具指挥访达——在「隐私与安全性 → 自动化」里勾上 Finder，勾完重启本工具再试。", why)
                case .finderCanceled:
                    message = LF("%@。废纸篓里的东西还在，没有清空。", why)
                default:
                    message = LF("清空失败：%@。也可以手动清空：点上面的「访达中打开」，在访达窗口里按 ⌘⇧⌫。", why)
                }
            } else {
                message = LF("清空失败：%@。", why)
            }
            refresh()
        }
    }

    private func openAutomationPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }
}
