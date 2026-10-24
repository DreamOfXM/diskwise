import SwiftUI
import AppKit
import ServiceManagement

// ── 偏好：三格状态 ──────────────────────────────────────────────────────────
//
// 稿子①「这一版不做什么」写着不抽 Preferences 模型，所以这里就是几个
// 由 UserDefaults 背书的 published 值，谁要读谁自己拿 `Prefs.shared`。
// 盘上存的一共八个：菜单栏开关、「Agent 页进过没有」、「Agent 页选了哪家」、
// 「首次运行看完了没有」、总览读法、声音开关、「清理说明看到哪一版」、上一整轮量完的时刻。
// 中间那三个「进过没有 / 看完了没有 / 看到哪一版」不是开关——一次性事件只能被抹掉、
// 不能被点回来，所以它们没有对应的 setter（复看走 `reopenGuide`，那是重开一次，
// 不是把旧的那一次翻回来）。
//
// 开机启动那一格不存自己的布尔：系统那份登记（SMAppService）才是真相，
// 界面显示的必须是回读到的状态。自己记一份就会出现「开关显示开着、
// 系统里其实没登记」这种两边对不上账的显示。

/// 总览那一圈怎么读。两本账说的是同一块盘：
/// `space` 按位置分（前三名 + 其他 + 没量到 + 可清除 + 空闲），
/// `cost` 按删掉之后要付什么分（零代价 / 需重下 / 不可逆 / 不碰）。
enum OverviewRead: String, CaseIterable {
    case space, cost
}

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()

    /// 菜单栏那颗容量读数。没存过 = 开（稿子①定的是「默认开着」）。
    @Published private(set) var menuBarEnabled: Bool
    /// 开机启动：登记请求是否已经交出去
    @Published private(set) var loginItemEnabled: Bool
    /// 已登记但系统还没放行——用户得自己去「系统设置 ▸ 通用 ▸ 登录项」里勾
    @Published private(set) var loginItemNeedsApproval: Bool
    /// AI Agent 页那枚「新」角标：没进过这一页时为 true，进去一次就永久收起。
    /// 盘上存的是「进过没有」（`seen`），界面读的是「还新不新」（`!seen`）——
    /// 没写过键的机器上 `bool(forKey:)` 回来 false，正好就是「没进过、还新」。
    @Published private(set) var agentPageIsNew: Bool
    /// 「怎么接」那张卡上选中的是哪一家客户端。
    ///
    /// 存的是 `AgentClient.rawValue` 这一层字符串，不是枚举本身：这一层不引 Core，
    /// 而认回来的串在界面里用 `AgentClient(rawValue:)` 解。解不出来（比如以后收了
    /// 某一家）就回默认那家——留一个假名字在盘上，比让页面崩或画一颗选中却无内容的
    /// 胶囊都体面。第二次进来还记得自己上次看的是哪家，是因为这页的说明很长，
    /// 而对长说明唯一有用的读法就是「直接翻到我家那一段」。
    @Published private(set) var agentClientRaw: String
    /// 首次运行那一屏还没看完。**盘上存的是「看完了没有」**，界面读的是它的反面——
    /// 没写过键的机器上 `bool(forKey:)` 回来 false，正好就是「没看过，给它看引导」。
    ///
    /// 只有一条路能收起来：`finishFirstRun()`。刻意不给 setter、也不给「重看引导」的入口，
    /// 理由同 `agentPageIsNew` 那句——一次性事件被点回来之后就不是一次性事件了，
    /// 而这一屏讲的东西在总览页上处处都在重讲。要重拍它取证走 `DISKWISE_FIRST_RUN=1`，
    /// 那是截图链路的覆盖，不是用户能按到的开关。
    @Published private(set) var showsFirstRun: Bool
    /// 总览这一圈按哪种口径读。默认按空间——那是这一页原来的读法，
    /// 按代价是新开的一副面孔，不该在升级之后自己跳过去。
    @Published private(set) var overviewRead: OverviewRead
    /// 界面上的那几声。没存过 = 开：样稿里它就是默认开着的
    /// （`localStorage.dw_sound !== '0'`），声音是这一版体验的一部分，不是附加项。
    @Published private(set) var soundEnabled: Bool
    /// 「清理说明」那四页还没看。存的是**看过哪一版**（`guideEdition`），不是布尔：
    /// 这四页讲的是这一版改掉的两个口径，文案改了就得让看过旧版的人再读一次新账。
    /// 抬 `guideEdition` 等于给所有人复看一遍，所以只在内容真变了的时候抬。
    @Published private(set) var showsGuide: Bool
    /// 上一**整轮**量完的时刻。nil = 这台机器上还没走完过一轮，顶栏那句新鲜度就不画。
    ///
    /// 只由 `noteGaugeFinished()` 写，而它只在扫描协程跑到结尾时调用——中途按停
    /// （`OverviewModel.stop()`）不盖戳：那一趟是半截账，给它一个「量完」的时刻，
    /// 顶栏就是在替没走完的活儿签字。
    @Published private(set) var lastGaugeAt: Date?
    /// 这一轮在不在跑。**不落盘**，也不新增真源：写的三处与 `OverviewModel.scanning`
    /// 一一对应（开跑、走完、按停），所以它不可能和页头那句「正在扫描」打架。
    ///
    /// 为什么要它：顶栏那句落款说的是「画面这一圈数是什么时候定稿的」，而重扫途中
    /// 画面正在被重写——把上一轮的钟点挂在「正在扫描」旁边，等于替没定稿的账签字。
    /// 所以跑的时候整格收起来，跟右栏「这本账」小节头同一条判据（那边看 `scanning`）。
    @Published private(set) var gaugeRunning = false

    /// 盘上存过这一版就不再自动挡道；右上角那颗「?」随时能复看。
    static let guideEdition = "1"

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let menuBar = "diskcleaner.menubar.enabled"
        static let agentSeen = "diskcleaner.agent.seen"
        static let agentClient = "diskcleaner.agent.client"
        static let firstRunDone = "diskcleaner.firstRun.done"
        static let overviewRead = "diskcleaner.overview.read"
        static let sound = "diskcleaner.sound.enabled"
        static let guideSeen = "diskcleaner.guide.seenEdition"
        static let lastGauge = "diskcleaner.gauge.lastFinished"
    }

    private init() {
        menuBarEnabled = defaults.object(forKey: Keys.menuBar) == nil
            ? true
            : defaults.bool(forKey: Keys.menuBar)
        agentPageIsNew = !defaults.bool(forKey: Keys.agentSeen)
        agentClientRaw = defaults.string(forKey: Keys.agentClient) ?? ""
        // 截图那一趟默认**不画**这一屏：`SnapshotMode.run` 是循环换页拍一整套图的，
        // 引导盖在上面的话，那一趟拍回来的十几张图全是同一张引导页，而真正要取证的
        // 每一页一张都拍不到——这是新同学第一次跑截图链路时最容易踩的坑，而且报错只
        // 表现为「图都是白拍的」。`DISKWISE_FIRST_RUN=1` 是唯一把它顶出来的开关。
        showsFirstRun = SnapshotMode.active
            ? SnapshotMode.forceFirstRun
            : (!defaults.bool(forKey: Keys.firstRunDone) || SnapshotMode.forceFirstRun)
        // 认不出来的串回默认那一档：以后要是收了某一档，旧机器上那条值不该把页面画空。
        // 截图那一趟的 `DISKWISE_READ` 只覆盖**这一次**读到哪档，不写盘（见 setter）。
        overviewRead = OverviewRead(
            rawValue: SnapshotMode.readMode
                ?? defaults.string(forKey: Keys.overviewRead)
                ?? "") ?? .space
        soundEnabled = defaults.object(forKey: Keys.sound) == nil
            ? true
            : defaults.bool(forKey: Keys.sound)
        // 截图那一趟默认不画：`SnapshotMode.run` 换页连拍十几张，挡一道四页的模态
        // 会把那一整套全拍成引导页。`DISKWISE_GUIDE=<1~4>` 是唯一的例外，
        // 它同时决定钉在第几页（见 `SnapshotMode.guidePage`）。
        showsGuide = SnapshotMode.guidePage != nil
            || (defaults.string(forKey: Keys.guideSeen) != Self.guideEdition
                && !SnapshotMode.active)
        let status = Self.loginStatus
        loginItemEnabled = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
        lastGaugeAt = defaults.object(forKey: Keys.lastGauge) as? Date
    }

    static var loginStatus: SMAppService.Status { SMAppService.mainApp.status }

    /// 登记了但还没生效：这一格要给一句「去系统设置里放行」的出口，
    /// 不能只留一个看起来像坏了的开关。
    var loginItemBlocked: Bool { loginItemEnabled && Self.loginStatus != .enabled }

    func setMenuBar(_ on: Bool) {
        guard on != menuBarEnabled else { return }
        menuBarEnabled = on
        defaults.set(on, forKey: Keys.menuBar)
        MenuBar.readout.apply(shows: on)
    }

    /// 进过 AI Agent 页：角标从此不再画。只在真的落到那一屏时调一次，
    /// 侧栏划过、悬停都不算——否则角标会在用户还没看见它时就自己收起来。
    func markAgentPageSeen() {
        guard agentPageIsNew else { return }
        agentPageIsNew = false
        defaults.set(true, forKey: Keys.agentSeen)
    }

    /// 「怎么接」上选了哪家。存的是 rawValue，界面回读时解不出来才回默认那家。
    func setAgentClient(_ raw: String) {
        guard raw != agentClientRaw else { return }
        agentClientRaw = raw
        defaults.set(raw, forKey: Keys.agentClient)
    }

    /// 总览那一圈换成另一种读法。截图那一趟的覆盖不写盘：
    /// 拍一张「按代价」的图不该把用户自己的默认读法改掉。
    func setOverviewRead(_ mode: OverviewRead) {
        guard mode != overviewRead else { return }
        overviewRead = mode
        guard SnapshotMode.readMode == nil else { return }
        defaults.set(mode.rawValue, forKey: Keys.overviewRead)
    }

    /// 声音开关。写盘与引擎同步两件事一起做：只改盘子不告诉引擎，
    /// 界面上的图标会跟耳朵听到的对不上。
    func setSound(_ on: Bool) {
        guard on != soundEnabled else { return }
        soundEnabled = on
        defaults.set(on, forKey: Keys.sound)
        Sound.shared.setEnabled(on)
    }

    /// 首次运行那一屏看完了：从此不再画。
    ///
    /// 只在用户**自己做出选择**那两下（「开始看这块盘」/「以后再说」）里调，
    /// 悬停、换皮肤、换语言都不算——那些都在这一屏上操作，不代表他看完了。
    ///
    /// 收画面与写盘是两件事，这里分开判：`DISKWISE_FIRST_RUN=1` 那一趟照旧收画面
    /// （截图链路要拍「按下去落到哪儿」，见 `SnapshotMode` 里 `-after-guide` 那一张），
    /// 但**不写盘**——拍一张图不该把真用户的引导吃掉（见上面 init 里那句 `||`）。
    /// 所以同一台机器上已经看完过的人，也能反复把这一屏拍出来取证。
    func finishFirstRun() {
        guard showsFirstRun else { return }
        showsFirstRun = false
        guard !SnapshotMode.forceFirstRun else { return }
        defaults.set(true, forKey: Keys.firstRunDone)
    }

    /// 「清理说明」看完了：记下看过哪一版。
    ///
    /// 与 `finishFirstRun` 同一道分岔——截图那一趟（`DISKWISE_GUIDE`）收画面但不写盘，
    /// 拍一张取证图不该把真用户那一版挡掉的说明吃掉。
    func finishGuide() {
        guard showsGuide else { return }
        showsGuide = false
        guard !SnapshotMode.active else { return }
        defaults.set(Self.guideEdition, forKey: Keys.guideSeen)
    }

    /// 右上角那颗「?」：把这一套再摆出来。复看也算看过，收起来时仍记当前这一版。
    func reopenGuide() { showsGuide = true }

    /// 一整轮量完了，盖个时间戳。顶栏那句「量完 · 今天 09:41」读的就是它。
    ///
    /// 截图那一趟**只改内存不写盘**：那一趟量的是 `/tmp` 下造的演示树，把它的收尾时刻
    /// 记进真用户的偏好里，下次开机顶栏就报一个从没发生过的「量完」。
    /// 画面照旧要它——不然取证的那一张里这一格是空的，等于没拍到。
    func noteGaugeFinished(at date: Date = Date()) {
        gaugeRunning = false
        lastGaugeAt = date
        guard !SnapshotMode.active else { return }
        defaults.set(date, forKey: Keys.lastGauge)
    }

    /// 开跑 / 中途按停时翻那一格「在不在跑」。走完那条路不用调这里，
    /// `noteGaugeFinished` 自己会把它落回 false。
    func setGaugeRunning(_ on: Bool) {
        guard on != gaugeRunning else { return }
        gaugeRunning = on
    }

    func setLoginItem(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            // 不自己编失败原因：写回去读到的状态就是最终答案，读回来没变，开关就弹回原位。
        }
        let status = Self.loginStatus
        loginItemEnabled = (status == .enabled || status == .requiresApproval)
        loginItemNeedsApproval = (status == .requiresApproval)
    }

    /// 系统设置里管登录项那一大页。深链是公开写法，不是内部接口。
    static func openLoginItemsSettings() {
        guard let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(u)
    }
}
