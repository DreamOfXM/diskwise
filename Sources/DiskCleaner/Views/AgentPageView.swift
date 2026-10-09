import SwiftUI
import AppKit
import DiskCleanerCore

// ── AI Agent 页：把已经做好的 CLI/MCP 通道透出来 ───────────────────────────
//
// 这一页自己不干任何活。干活的是包里的 `diskwise` 和它挂出来的 stdio MCP server，
// 页面只回答三件事：**怎么接**、**接上之后长什么样**、**它替我动过什么、怎么整单撤回**。
// 方案与五屏样稿：`plans/plan_2026-10-09_agent-page-in-app.md`、
// `design/agent-page-2026-10-09.html`（换肤那一整套 v7 已作废，这里只穿现有皮肤）。
//
// 三条口径上的规矩，都是复核时定下的，改之前先读懂为什么：
// 1. 「本包已带 CLI」按**运行时实测** `<bundlePath>/Contents/MacOS/diskwise` 在不在，
//    不按 `Channel.isAppStore` 猜——渠道标志和实际包内容一旦不一致，这页就在撒谎，
//    而 v1.7 及更早的直装包本来就没带 CLI；
// 2. 累计那一行只说「移入废纸篓」，永远不说「已释放」——东西还在盘上，
//    清空之前一个字节都没腾出来；已放回的那部分单独一档，不从合计里减；
// 3. 账本没有「被拦住的尝试」这一类事件（全拒的一次运行连一行都不留），
//    所以这一页不列它——那是安全模型核心的改动，不是页面里的活。
//
// 商店版整组入口都不渲染：沙盒包里压根没有那个二进制，跟「实测到缺」是两回事。
// 算账的纯函数一律在 Core（`AgentLedger.swift`），那边才连得到自检。

/// 记录卡一次列几行。日志可以很长，这一屏只摆最近这几笔，累计仍按整本账算。
private let agentRowsShown = 20

struct AgentPageView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme

    /// 整本操作日志（磁盘上的真相）。视图随导航销毁，所以每次进来都重读一次。
    @State private var ops: [AgentOperation] = []
    /// 摊开逐项的那些行
    @State private var expanded: Set<String> = []
    /// 正在放回的那一行（一次只允许按一颗）
    @State private var undoing: String? = nil
    /// 本次会话里按过的撤销回执 → 三档各多少。
    /// 日志里只有「撤过」这一个事实，「回来几项、几项撤不回」只有当场数得出来。
    @State private var tallies: [String: AgentUndoTally] = [:]

    private var cli: AgentCLILocation { agentCLILocation(bundlePath: Bundle.main.bundlePath) }
    private var totals: AgentLedgerTotals { agentLedgerTotals(ops) }
    /// 最近几笔，新→旧
    private var rows: [AgentOperation] { Array(ops.suffix(agentRowsShown)).reversed() }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(symbol: AppPanel.agent.symbol, title: AppPanel.agent.title,
                           subtitle: L("让 AI 帮你清 Mac —— 它不能 rm -rf，只能把认得的东西移进废纸篓"),
                           variant: .display) {
                    ThemeBadge(text: cli.badgeText, tone: cli.badgeTone)
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        connectCard
                        recordCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                    // 这是一页说明加一张账，不是列表页：行长不封顶会读成横幅
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .themedList()
            }
            .pagePadding()
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            reload()
            // 截图这一路没有键鼠点不到那颗箭头：`DISKWISE_EXPAND=1` 时代相机按一次，
            // 置位的还是这颗 `expanded` 本身，不另画一份假展开（列表页
            // `ItemRow(preopen:)` 是同一条口径）。
            if SnapshotMode.expandFirstRow, let first = rows.first { expanded.insert(first.id) }
            // 「新」角标看过即收：第一次走到这一页就永久收起，不做「几天后自己消失」
            Prefs.shared.markAgentPageSeen()
        }
    }

    private func reload() { ops = agentAllOperations() }

    // MARK: 怎么接

    @ViewBuilder private var connectCard: some View {
        AgentCard(title: L("怎么接"), hint: L("把 diskwise 挂进你的 AI 工具，它就能读你的磁盘账")) {
            switch cli {
            case .present(let path, let stable):
                commandRow(path: path, stable: stable)
                if !stable {
                    AgentFlag(text: L("这个路径随当前这份副本失效：它一旦被搬走、改名或删掉，你的 AI 工具就再也起不来 diskwise。先把 App 拖进「应用程序」再从那儿打开一次，这行命令才会换成稳定路径。"))
                }
                demoBlock
                AgentNote(text: L("上面那行里的路径是按 App 实际安装位置拼出来的；用 Homebrew 装的话，把它换成 /opt/homebrew/bin/diskwise。"),
                          top: true)
            case .missing:
                AgentInertCommand(text: L("这一版包里没有 diskwise —— 升级后这行才会出现"))
                AgentNote(text: L("装 v1.8 的直装包，或用 Homebrew：brew install --cask dreamofxm/diskwise/diskwise。1.8 起 cask 带 binary，装完才有 /opt/homebrew/bin/diskwise。"),
                          top: true)
            }
            AgentNote(text: L("Cursor、Codex 这类工具填的是同一个 diskwise：命令填上面那个路径，参数填 mcp。两步确认跑在前面——没有 plan_id 一步都动不了，执行前逐项重跑判定。"),
                      top: true)
        }
    }

    /// 那一行可复制的命令。路径带空格时必须加引号，否则粘进终端就是一句断掉的话。
    private func commandRow(path: String, stable: Bool) -> some View {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return AgentCommand(text: "claude mcp add diskwise -- \(quoted) mcp",
                           warn: !stable) {
            ThemeButton(kind: .compact, symbol: "doc.on.doc", title: L("复制")) {
                copy("claude mcp add diskwise -- \(quoted) mcp")
            }
        }
    }

    /// 一段真跑过的对话（数字与 `docs/AGENTS-CLI.md` 里那次实录一致）。
    /// 顶上明写「示例」：这些数是他人的机器上的，不是眼前这台盘的账。
    private var demoBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("示例对话 · 接上之后就是这个样子"))
                .font(theme.bodyFont(.caption2).weight(.semibold))
                .foregroundStyle(theme.palette.inkTertiary)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) {
                termLine(L("看看我的 Mac 哪里能清"))
                termTool("diskwise · scan_disk", tail: "(category: \"all\")")
                termDim(L("总共 30 处 · agent 能动 23 处，合计约 57.7 GB"))
                termNo(L("iOS 模拟器运行时 16.6 GB 在系统区，outside_allowed，我不会动"))
                termLine(L("把 Ollama 和 oMLX 的模型清了吧"))
                termTool("plan_cleanup", tail: L("计划已生成，2 项合计 31.4 GB，进废纸篓。确认执行吗？"))
                termLine(L("可以"))
                termTool("execute_cleanup")
                termOk(L("31.4 GB 已移入废纸篓，可整单撤销"))
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            // 撑宽必须排在铺色**前面**：反过来写时 `background` 只盖到内容的理想宽度，
            // 多出来的那一段是透明的，实拍出来那块「终端」就只包到最后一行字的尾巴。
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.cardShape().fill(agentTerminalInk))
            // 深色皮肤上 #17191F 和卡片底色差不到一档，那块「终端」会化进卡里看不见边界；
            // 描一道和卡片同款的 separator，浅皮上等于没有，暗皮上才有那一框。
            .overlay(theme.cardShape().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
        }
        .padding(.top, 10)
    }

    /// 终端那一块的底色：深色画面压在浅色皮肤上也得是深色，字色才配得对。
    private var agentTerminalInk: Color { Color(red: 23 / 255, green: 25 / 255, blue: 31 / 255) }

    /// 这一块的字号**不借皮肤的 face**，整页只有这一处例外。
    ///
    /// 样稿 `.term{font-family:var(--m)}` 排的是等宽：这是一幅终端画面，
    /// 圆体/衬体一上去，「接上之后长这样」这句话就只剩文字没有样子了。
    /// 中文本来就没有 SF Mono 字形，系统自动回落 PingFang，落点仍然对齐。
    private var agentTermFont: Font { .system(size: 10.5, design: .monospaced) }

    /// 终端里的一条对话。
    ///
    /// 三个零件对齐靠一颗**定宽的记号列**（`agentTermMark`，14 pt）＋ 6 pt 间距，
    /// 没有记号的那两行就缩进 20 pt。缩进一律用 `padding`，不写前导空格：
    /// `Text` 会把连续空格压成一个，「  」这种前缀在屏幕上压根不存在，
    /// 整块会塌成齐平的一列。
    private func termLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            agentTermMark(Text("›").foregroundStyle(Color(red: 127 / 255, green: 178 / 255, blue: 1.0)))
            Text(text).foregroundStyle(Color(red: 214 / 255, green: 218 / 255, blue: 227))
        }
        .font(agentTermFont)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 工具调用那一行。只有**工具名**是紫的，参数与后面的回答回到正文色——
    /// 整行涂紫会把「它调了什么」和「它说了什么」压成同一种东西（样稿同一条口径）。
    /// `tail` 是它后面跟的回答，没有就只印工具名。
    private func termTool(_ tool: String, tail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 6) {
            agentTermMark(Text("⏺").foregroundStyle(Color(red: 123 / 255, green: 130 / 255, blue: 143)))
            Text(tool).foregroundStyle(Color(red: 201 / 255, green: 166 / 255, blue: 1.0))
            if let tail {
                Text(tail).foregroundStyle(Color(red: 214 / 255, green: 218 / 255, blue: 227))
            }
        }
        .font(agentTermFont)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 工具吐出来的读账结果：没有落点，收成灰色缩进。
    private func termDim(_ text: String) -> some View {
        Text(text)
            .font(agentTermFont)
            .foregroundStyle(Color(red: 123 / 255, green: 130 / 255, blue: 143))
            .padding(.leading, 20)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「这一处我不碰」——拒绝那一行是珊瑚色（样稿 `.no` #FF9E8A），
    /// 和「办成了」那枚绿分开两档，免得两种结论读成一种。
    private func termNo(_ text: String) -> some View {
        Text(text)
            .font(agentTermFont)
            .foregroundStyle(Color(red: 1.0, green: 158 / 255, blue: 138 / 255))
            .padding(.leading, 20)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func termOk(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            agentTermMark(
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(red: 95 / 255, green: 208 / 255, blue: 138 / 255)))
            Text(text)
                .font(agentTermFont)
                .foregroundStyle(Color(red: 95 / 255, green: 208 / 255, blue: 138 / 255))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(agentTermFont)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 记号列：「›」「⏺」和对勾都钉在同一个 14 pt 宽的槽里，
    /// 右边留 6 pt 间距，正文才会在三行、五种记号下对齐成一条竖线。
    private func agentTermMark<V: View>(_ mark: V) -> some View {
        mark.frame(width: 14, alignment: .leading)
    }

    // MARK: Agent 操作记录

    @ViewBuilder private var recordCard: some View {
        AgentCard(title: L("Agent 操作记录")) {
            if rows.isEmpty {
                // 空账只留空态那两句：「撤销按整单」「被拦下的不记账」都是在讲一行
                // 不存在的账怎么办，摊在一块空白底下，卡片下半截全是政策说明。
                // 只有「这一页读的是哪本账」在零行时仍然要回答——那正是人会问的一句。
                emptyBlock
                AgentNote(text: L("这一页只读 agent 留下的操作日志，你在 App 里手动清掉的东西不记在这儿。"),
                          top: true)
            } else {
                // 空账不渲染这一行：写「0 次操作」是给一个没发生过的事占一格
                if !totals.isEmpty { aggregateRow }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, op in
                    if index > 0 { Divider().overlay(theme.palette.separator) }
                    operationRow(op)
                }
                AgentNote(text: L("撤销按整单：一次执行的所有项一起放回，没有单项恢复，界面上也就不给单项按钮。这和终端里 diskwise undo 是同一条实现——日志只追加、不涂改，所以放回过的行还留在账上，只是再也点不动。"),
                          top: true)
                AgentNote(text: L("这一页只读 agent 留下的操作日志，你在 App 里手动清掉的东西不记在这儿；被拦下的尝试也不记账，一次都没搬成的操作不留行。清空废纸篓之后日志仍在，那时撤销会逐项告诉你哪几项已经撤不回来，不会静默跳过。"),
                          top: false)
            }
        }
    }

    private var aggregateRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(cnt(totals.operations, "次操作"))
                + Text(" · ") + Text(cnt(totals.items, "项"))
                + Text(" · ") + Text(LF("共 %@ 移入废纸篓", human(totals.bytes)))
            if totals.restoredBytes > 0 {
                Text("|").foregroundStyle(theme.palette.separator)
                Text(LF("其中 %@ 已放回", human(totals.restoredBytes)))
            }
            Spacer(minLength: 8)
            ThemeButton(kind: .ghost, symbol: "arrow.clockwise", title: L("刷新")) { reload() }
        }
        .font(theme.bodyFont(.caption))
        .foregroundStyle(theme.palette.inkSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func operationRow(_ op: AgentOperation) -> some View {
        let open = expanded.contains(op.id)
        let name = agentClientLabel(op.client) ?? L("未知来源")
        let tally = tallies[op.id]
        let presence = agentTrashPresence(op) { FileManager.default.fileExists(atPath: $0) }
        let undone = op.undoneAt != nil || tally != nil
        let hopeless = !undone && presence.present == 0 && presence.missing > 0

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                Button { toggle(op.id) } label: {
                    ThemeChevron(expanded: open)
                        .frame(width: 13, height: 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? L("收起") : L("展开"))

                AgentClientTile(name: name)

                Button { toggle(op.id) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 5) {
                            Text(name)
                                .font(theme.bodyFont(.caption).weight(.semibold))
                                .foregroundStyle(theme.palette.ink)
                            Text("· " + cnt(op.items.count, "项"))
                                .font(theme.bodyFont(.caption))
                                .foregroundStyle(theme.palette.inkSecondary)
                            undoPills(op, tally: tally, hopeless: hopeless, undone: undone)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        summaryLine(op, open: open)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .trailing, spacing: 5) {
                    Text(human(agentOperationBytes(op)))
                        .font(theme.bodyFont(.body).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(undone || hopeless ? theme.palette.inkTertiary
                                                            : theme.palette.ink)
                    undoButton(op, undone: undone, hopeless: hopeless)
                    if hopeless || (tally?.gone ?? 0) > 0 {
                        ThemeButton(kind: .ghost, symbol: "trash", title: L("打开废纸篓")) {
                            openTrashInFinder()
                        }
                    }
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if open {
                Divider().overlay(theme.palette.separator)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(op.items, id: \.original) { item in
                        HStack(alignment: .center, spacing: 8) {
                            // 给全路径、不给 ~：这一行的点击落点就是它显示的那串字，
                            // 缩写了就点不动（各页展开行同一个口径）
                            PathLine(path: item.original)
                            Spacer(minLength: 6)
                            Text(human(item.bytes))
                                .font(theme.bodyFont(.caption2).monospacedDigit())
                                .foregroundStyle(theme.palette.inkTertiary)
                                .fixedSize()
                        }
                    }
                }
                .padding(.leading, 52)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
                .background(theme.palette.surfaceAlt.opacity(0.45))
            }
        }
    }

    @ViewBuilder private func undoPills(_ op: AgentOperation, tally: AgentUndoTally?,
                                        hopeless: Bool, undone: Bool) -> some View {
        if let tally {
            // 三档同一个形状「N 项 + 结论」，别一行一个语序：译文里数词的位置
            // 要能对齐，混着写九门语言各要绕一遍。
            if tally.restored > 0 {
                ThemeBadge(text: LF("%@ 已放回", cnt(tally.restored, "项")), tone: .safe)
            }
            if tally.gone > 0 {
                ThemeBadge(text: LF("%@ 撤不回", cnt(tally.gone, "项")), tone: .danger)
            }
            if tally.failed > 0 {
                ThemeBadge(text: LF("%@ 放回失败", cnt(tally.failed, "项")), tone: .warn)
            }
        } else if undone {
            ThemeBadge(text: L("已撤销"), tone: .neutral)
        } else if hopeless {
            ThemeBadge(text: L("撤不回来"), tone: .danger)
        }
    }

    @ViewBuilder private func undoButton(_ op: AgentOperation, undone: Bool, hopeless: Bool) -> some View {
        if undone {
            ThemeButton(kind: .ghost, title: L("已放回"), isDisabled: true) {}
        } else if hopeless {
            ThemeButton(kind: .ghost, title: L("撤销"), isDisabled: true) {}
        } else {
            ThemeButton(kind: .compact, title: undoing == op.id ? L("撤销中…") : L("整单撤销"),
                        isDisabled: undoing != nil) {
                undo(op)
            }
        }
    }

    /// 收起那一行的摘要：最多两个路径，多的折成「等 N 项」。展开才摊全，
    /// 且每个路径各一个落点——行尾一颗笼统的「显示」在五个路径面前没人知道指向哪个。
    @ViewBuilder private func summaryLine(_ op: AgentOperation, open: Bool) -> some View {
        let shown = op.items.prefix(2).map { displayPath(URL(fileURLWithPath: $0.original)) }
        let hidden = op.items.count - shown.count
        HStack(alignment: .top, spacing: 5) {
            Text(agentWhen(op.at))
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.inkTertiary)
                .fixedSize()
            agentDot()
            if open {
                Text(L("展开中"))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize()
            } else {
                Text(shown.joined(separator: " · "))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if hidden > 0 {
                    // 「等 N 项」单列一颗，不拼进路径串：那一串是要被中间省略的。
                    // 但它**也不许吃满剩余宽度**——早先这里挂了 `maxWidth:.infinity`，
                    // 实拍出来「等 3 项」被推到行尾，正落在「16.2 GB」下面，
                    // 读起来像体积的一列而不是路径的尾巴。现在让路径按内容收，
                    // 剩的宽度全给末尾那颗 Spacer，两颗附属信息就贴在路径后面。
                    Text(LF("等 %@", cnt(hidden, "项")))
                        .font(theme.bodyFont(.caption2))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .fixedSize()
                }
            }
            if let when = op.undoneAt {
                Text(LF("放回时间 %@", agentWhen(when)))
                    .font(theme.bodyFont(.caption2))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 段与段之间那颗点。写成独立视图是因为它得跟着皮肤的字色走，
    /// 不能混进译文里——「 · 」进了词表就成了各语言都得照抄的一个符号。
    private func agentDot() -> some View {
        Text("·")
            .font(theme.bodyFont(.caption2))
            .foregroundStyle(theme.palette.inkTertiary.opacity(0.6))
            .fixedSize()
    }

    private var emptyBlock: some View {
        VStack(spacing: 5) {
            IconTile(symbol: AppPanel.agent.symbol, side: 44,
                     fill: theme.palette.inkTertiary, muted: true)
                .padding(.bottom, 7)
            Text(L("还没有 agent 操作过"))
                .font(theme.bodyFont(.headline))
                .foregroundStyle(theme.palette.ink)
            Text(L("接上之后每次执行都会在这里留一行，能整单撤销。"))
                .font(theme.bodyFont(.caption))
                .foregroundStyle(theme.palette.inkSecondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 430)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: 动作

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func undo(_ op: AgentOperation) {
        guard undoing == nil else { return }
        undoing = op.id
        let id = op.id
        let items = op.items
        Task.detached(priority: .userInitiated) {
            let result = Result { try agentUndo(operationId: id) }
            await MainActor.run {
                undoing = nil
                switch result {
                case .success(let statuses):
                    let tally = agentUndoTally(statuses: statuses, items: items)
                    tallies[id] = tally
                    reload()
                    store.notice = undoNotice(tally)
                case .failure(let error):
                    store.notice = undoFailText(error)
                }
            }
        }
    }

    /// 失败原因不原样吐机器码：`AgentAPIError` 的 description 是 `no_undoable_operation`
    /// 这种给 CLI 看的码，摆到人眼前必须翻成人话；系统那边抛的（TrashError）走
    /// `failReason` 那条既有口径，不在这儿另编一套原因。
    private func undoFailText(_ error: Error) -> String {
        if let e = error as? AgentAPIError {
            switch e {
            case .noUndoableOperation: return L("这一行已经放回过了，不能重复撤")
            case .planExpired: return L("计划已过期，回终端重新 plan 一次")
            case .planNotFound: return L("找不到那次执行的计划")
            case .planTooLarge: return L("那一次动得太多，回终端逐段撤")
            case .invalidPath: return L("记录里的路径已经不能照着放回")
            }
        }
        return failReason(error)
    }

    /// 三种结果三种读法，不合并成一句「好了」。
    private func undoNotice(_ t: AgentUndoTally) -> String {
        if t.restored == 0 {
            if t.gone > 0 { return LF("%@ 不在废纸篓里了，撤不回来", cnt(t.gone, "项")) }
            return L("什么都没放回")
        }
        if t.gone + t.failed == 0 {
            return LF("%@ 已放回原处 · %@", human(t.restoredBytes), cnt(t.restored, "项"))
        }
        return LF("%@ 已放回 · %@ 撤不回来",
                  cnt(t.restored, "项"), cnt(t.gone + t.failed, "项"))
    }

    private func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        store.notice = pb.setString(text, forType: .string)
            ? LF("已复制到剪贴板：%@", text)
            : L("复制失败，请手动选中复制")
    }

    /// 同一台机器上「今天 / 昨天 / 本月」这套读法交给系统，不自己拼中文日期：
    /// 九门语言里日期的长短和语序全不一样，而 `doesRelativeDateFormatting`
    /// 在每一门里都给当地那句「昨天 09:10」。
    private func agentWhen(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L10n.active.code)
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }
}

// MARK: - 包里到底有没有那个 CLI

private extension AgentCLILocation {
    /// 徽章说的是「这个包里带了什么」，不是「有没有人真接上了」——后者 App 不可能知道。
    var badgeText: String {
        switch self {
        case .present: return L("本包已带 CLI")
        case .missing: return L("本包不含 CLI")
        }
    }
    var badgeTone: ThemeBadge.Tone {
        switch self {
        case .present: return .tint
        case .missing: return .neutral
        }
    }
}

// MARK: - 这张页自己的版式件
//
// 沿用废纸篓/反馈那两页的口径：卡是 `cardShape` + `surface` + 一道 separator 描边，
// 说明文字是卡外 11pt 灰字，命令与终端块用等宽。不为这一页新造一套形状语言。

struct AgentCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var title: String
    var hint: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(theme.display(.subheadline))
                    .tracking(theme.titleTracking + 0.2)
                    .foregroundStyle(theme.palette.ink)
                if let hint {
                    Text(hint)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 13)
            .padding(.bottom, 9)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardShape().fill(theme.palette.surface))
        .overlay(theme.cardShape().stroke(theme.palette.separator, lineWidth: theme.metric.stroke))
    }
}

/// 一行命令：底是 `surfaceAlt`，左边等宽正文，右边那颗按钮才是能按的东西。
struct AgentCommand<Trailing: View>: View {
    @Environment(\.theme) private var theme
    var text: String
    var warn: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(text)
                .font(theme.bodyFont(.caption).monospacedDigit())
                .foregroundStyle(warn ? theme.palette.warnFG : theme.palette.ink)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing().fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(theme.controlShape().fill(warn ? theme.palette.warnBG
                                                  : theme.palette.surfaceAlt.opacity(0.7)))
        .overlay(theme.controlShape().stroke(warn ? theme.palette.warnFG.opacity(0.35)
                                                  : theme.palette.separator,
                                             lineWidth: theme.metric.stroke))
        .padding(.horizontal, 14)
    }
}

/// 「这一版没带 CLI」那一格：虚线边、灰字，看着就不是能复制的东西
struct AgentInertCommand: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(theme.bodyFont(.caption))
            .foregroundStyle(theme.palette.inkTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(theme.controlShape().strokeBorder(theme.palette.separator,
                                                          style: StrokeStyle(lineWidth: theme.metric.stroke,
                                                                             dash: [4, 3])))
            .padding(.horizontal, 14)
    }
}

/// 那句必须出现的警示（路径不稳定那一档）。
///
/// **不铺底色**：App 别处的警示条（`SharedViews` 那条错误带）是实心 amber，因为它是
/// 一屏上唯一的 amber。这一档上面那行命令已经是警示态了，再压一块同色实心板，
/// 两句不同的话就糊成一片背景。样稿 `.flag` 因此只留 warnFG 字色＋一颗圆点，
/// 这里照抄。
struct AgentFlag: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            ZStack {
                Circle().fill(theme.palette.warnFG)
                Image(systemName: "exclamationmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(theme.palette.surface)
            }
            .frame(width: 13, height: 13)
            .padding(.top, 1.5)
            Text(text)
                .font(theme.bodyFont(.caption2))
                .foregroundStyle(theme.palette.warnFG)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.top, 9)
    }
}

/// 卡里的灰字说明。字号、颜色、留白只有这一处口径（同 `ListNote`，但住在卡内）。
struct AgentNote: View {
    @Environment(\.theme) private var theme
    var text: String
    var top: Bool = false

    var body: some View {
        Text(text)
            .font(theme.bodyFont(.caption2))
            .foregroundStyle(theme.palette.inkTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.top, top ? 10 : 4)
            .padding(.bottom, 10)
    }
}

/// 行首那一格：客户端名字的第一个字符。
///
/// 铺法沿用 `IconTile(muted: true)` 与 `BrandTile` 那条已定的规矩——浅底同色，
/// 不铺实心彩块。认不认得来靠名字那一列，这一格只负责让行首有个落点。
/// 认不出来源的那一行（旧日志没有 client 字段）走中性档。
struct AgentClientTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var name: String

    var body: some View {
        let isDark = (theme.scheme ?? colorScheme) == .dark
        let color = name == L("未知来源") ? theme.palette.inkTertiary : theme.palette.tint
        ZStack {
            theme.tileShape(26).fill(color.opacity(theme.tileWash(dark: isDark)))
            Text(String(name.prefix(1)).uppercased())
                .font(theme.prose(size: 12, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 26, height: 26)
        .accessibilityHidden(true)
    }
}
