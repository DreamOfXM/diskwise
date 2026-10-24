import AppKit
import DiskCleanerCore

// ── 性能探针：DISKWISE_PERF=<秒> 时启用，跑完把逐段帧间隔打到 stderr ──────────
//
// 为什么要有它：这台机器是 Intel 核显，环上那几层材质、往后还要往上叠的动效，
// 卡不卡只能量，不能靠「我看着挺顺」。第一次拿它试跑总览，常驻 25.9% CPU，
// 而这一屏一个用户动作都没做——没有量具的话，这句话根本不会被说出来。
//
// 量的是**主线程相邻两次被调度的空档**：一个 1/120 s、加在 `.common` 模式上的定时器，
// 每次 fire 记一次与上一次的差。差值就是「这段时间主线程被谁占走了」——点下去没反应、
// hover 慢半拍、切页那一瞬的顿挫，全是它。用 `.common` 是为了滚动、按下拖拽期间
// 也照样记（那正是用户最挑的时候）。
//
// 它看不见的那一半：GPU 合成侧丢帧。那种卡是窗口服务器丢的，主线程可以完全空闲，
// 探针一声不响。所以每一格同时记两个 CPU 时间：本线程的（`thread_info`）和整条进程的
// （`clock_gettime(CLOCK_PROCESS_CPUTIME_ID)`）。三个数一起看才敢下结论：
// 空档大、**主线程**也高 = 我们自己在主线程上算东西；空档大、主线程低 = 没排上队或者
// 在等一个同步调用（卷查询、磁盘遍历），那时候要修的是机器负载，不是代码；
// 空档小、进程高主线程低 = 合成侧或扫描线程的账，该去减层。
// 早先只记进程时间，误判过一次：扫描线程正忙时「主线程在睡觉」读起来跟「主线程在算」
// 一模一样，差点去修一个不存在的问题。
//
// 走查（`DISKWISE_PERF_WALK=1`）切页走的是 `store.jumpTo`——就是页面上那些
// 「去废纸篓页」「看这一格摊开」的链接按下去的同一条路，不是另开一条测试专用通道。
// 探针自己不做任何渲染，所以它测的是真 App 的那扇窗，不是截图模式那扇手搓的窗。
//
// 用法（这台机器上唯一能开窗的跑法，命令行尾巴同理）：
//   BIN=/tmp/dw-v19/build_app/DiskWise.app/Contents/MacOS/DiskCleaner
//   APP=/tmp/dw-v19/build_app/DiskWise.app
//   DISKWISE_PERF=30 DISKWISE_PERF_WALK=1 "$BIN" -diskcleaner.firstRun.done YES &
//   sleep 3; open "$APP"
//   DISKWISE_PERF=20 DISKWISE_PERF_HOLD=overview DISKWISE_PERF_SKIP=8 \
//     DISKWISE_PERF_NOTE=环在转 "$BIN" -diskcleaner.firstRun.done YES &
//   sleep 3; open "$APP"
//   DISKWISE_PERF=24 DISKWISE_PERF_HOLD=overview DISKWISE_PERF_SKIP=6 \
//     DISKWISE_PERF_HOVER=0.5 "$BIN" -diskcleaner.firstRun.done YES &
//   sleep 3; open "$APP"          # 每 0.5 秒在账本各行间「进—出」一次
//   DISKWISE_COST=1 "$BIN" -diskcleaner.firstRun.done YES &
//   sleep 3; open "$APP"          # 只打四类代价账（口径验收），不测帧、不退出
//   DISKWISE_PERF=24 DISKWISE_PERF_HOLD=overview DISKWISE_PERF_SKIP=6 \
//     DISKWISE_PERF_FX=1.6 "$BIN" -diskcleaner.firstRun.done YES &
//   sleep 3; open "$APP"          # 每 1.6 s 自演一趟「点第二下」的回收（含声音，不动真账）
//
// ⚠ 两道门槛，缺一个探针一声不响地跑完（踩过三次）：
//   1. 必须跑在 `DiskWise.app/Contents/MacOS/DiskCleaner` 里。光秃秃那个二进制不开窗，
//      `onAppear` 不触发，探针压根挂不上。
//   2. 但从这条 shell 直接 exec 那个包内二进制**仍然不开窗**——它没有会话归属，
//      AppKit 不起来那扇主窗。先起来、等 3 秒、再 `open` 同一个 bundle，
//      由 LaunchServices 补一发 reopen 事件把窗建出来，探针这才挂得上。
//      `DISKWISE_PERF` 只决定「要不要挂」，窗口才是「有没有得挂」。
//   3. `-diskcleaner.firstRun.done YES` 压掉首屏那层引导遮罩；不压的话第一段量到的是遮罩。
//      它是临时参数，不写进正式 defaults（`defaults read com.dreamofxm.diskcleaner` 里没有它）。
//
// ── 红线（2026-10-21 本机 Intel i7-9750H 量的底数，演示树、单实例）──────────
//
// 认的是**尾段**那一行（`DISKWISE_PERF_SKIP=8`：跳过扫盘，只看扫完之后环还在转的常驻态）：
//   空间总览 30 s 尾段：p50 8.3  p95 11.6  p99 13.4  最大 74.2  >16.7 一次  >100 零次  主线程 20.3%
//   卸载残留 26 s 尾段：p50 8.3  p95  9.2  p99  9.4  最大 13.5  一帧没丢                主线程  1.7%
// 这两行是**环还在 SwiftUI 里每秒重画 60 帧**时的历史底数。总览的主线程底数已经变了
// （2026-10-22 降到 1.7%，见下面「20% 的账结了」）；卸载残留没有常驻循环，不受影响。
// 往环上、账本上、页面上加动效层之前，先量同样这两行，判据是：
//   1. 尾段 p99 不超过 16.7 ms（两帧），>33.4 每 30 秒不超过 1 次，>100 零次；
//   2. 尾段**主线程%** 比**同一次配对的静置**涨不超过 3 个点——不要拿别的日子、别的
//      底数来比：这台机器的静置在负载高时会整体抬 6 个点以上，跨跑比较读不出真信号；
//   3. 扫盘那一段另算，别拿它给常驻态辩护。
// 超了就把那一层改成 Core Animation 驱动、延后、或者砍掉，不许用「看起来还行」结案。
//
// 「总览那 20% 是谁在常驻态里一直算」的账结了（2026-10-22）：不是我们在主线程上算盘，
// 是 `withAnimation(...repeatForever)` 让 SwiftUI 每秒把视图树重算 60 次。`sample` 归因
// 见 `RingLayers.swift` 顶上 `CALoopView` 那段。余晖呼吸和环上反光搬进 CABasicAnimation
// 之后常驻从 17–20% 掉到 1.7%，两条都摘掉的对照也是 1.7%——1.7 就是这页本身的地板。
//
// 首屏和扫描期的两笔账（都不在常驻尾段）：
// 1. 还没结：首屏那一下 1.0-1.3 秒主线程一直在算：环形 + 整本账 + 列表第一次铺开。
// 2. 结了（2026-10-22）：扫描回填原先**每量完一处就发一轮变更**（`done`/`covered`/
//    `hotspots`/`measuring` 那一串 `@Published`），几百处就是几百轮整页重绘。现在攒进
//    `OverviewModel` 的 0.2 s 窗口统一发。同一棵合成家目录（200 个一级目录 / 6 万个文件）
//    配对量：
//      每处当场发   15 s 里 >33.4 207 次、p99 89.7 ms、主线程 79.5%
//      0.2 s 窗口   >33.4   9 次、p99 14.9/17.7 ms、主线程 11.4/11.7%（两次跑）
//    还剩下的 4 次 >100 ms 全在起跑后 1.3 s 内，属于上面第 1 笔（首屏），不在回填途中。
//
// 已经结掉的一笔（别再写回去）：缓存页一趟扫描连发上百条 `objectWillChange`，
// 旧代码每条都在主线程上重归一次全量缓存账（每个路径 stat 一次 + 判可删/受保），
// 实测能把主线程一口气压住 1.4 秒。现在攒进 `cachesSettleWindow` 结算，一趟最多算一遍：
// 同一页同一台机器 >33.4 从 23 次降到 5 次、>100 从 9 次降到 2 次、CPU 16.2% 降到 7.7%。
//
// 这台机器的底价（2026-10-22 重量的，加改动之前先认这条线）：
//   下面这一组是**环还在 SwiftUI 里画**时量的，留作交互账的原始读数；
//   环搬去 Core Animation 之后的底价在后面「两条永续循环搬走之后」那一段。
//   同一启动配方、停在总览、`DISKWISE_PERF=24 SKIP=6`。
//   一次「整页变更」在这台机器上值 60–100 ms（`noop` 1 s 一次那一跑：主线程 23.9%，
//   最大 105.6 ms）；静置本身 ±6 个点是噪声，所以每次都要配对跑。
//   `sample` 归因：自研 Swift 帧的 self time 接近 0，占满的是
//   SwiftUI `AttributeGraph` 那一轮 + `NSWindow layoutIfNeeded → _layoutSubtreeWithOldSize`。
//   悬停那一层（`DISKWISE_PERF_HOVER=0.5`，配对夹两次静置，2026-10-22，同样是尾段）：
//     整页订阅（等价于旧的 `hovKey` @State）  主线程 32.0–33.6%，p99 44–49 ms，>33.4 约 100 次/24 s
//     收窄到环 + 账本行里的叶子                主线程 25.6–26.0%，p99 25–27 ms，>33.4 8 次/24 s
//     把 `SweepRing` 的 body、命中层、盘心副读也摘出去（搬去 CA 之前的那一版）：
//       静置 17.3 / 17.6，悬停 19.6 / 19.9（**+2.0/+2.6 个点**）；
//       p99 静置 10.1/10.4、悬停 11.7/10.8；>33.4 各 1 次；>100 零次。红线四条全过。
//     `sample` 归因（停在 25 ms 那一版）：悬停那 8 s 的主线程有 670 个样本在
//     `SweepRing.dial`、401 个在 `SweepRing.frame.getter`、278 个在 `RingStyle.selected`
//     —— 每次换段都在重算整帧环，连 `ProcessInfo.environment` 的整表重建都跟着走。
//     修法同翻勾那条：`hovered` 不进 `RingFrame`，只从两组带子的绘制函数门口进来；
//     命中层的手型/当前段搬进自己的 `RingHitLayer`；`RingStyle` 的 env 覆盖表缓存成一次读取。
//
//   —— 两条永续循环搬走之后（`CALoopView`，2026-10-22，同一配方、同样是尾段）——
//   静置三次：主线程 1.7 / 1.7 / 1.7，p99 9.6–10.2，>33.4 各 1 次，>100 零次。
//   两条循环都摘掉的对照：1.7 / 2.0——和开着几乎一样，剩下的 1.7 就是这页的地板。
//   悬停的第一版（环已经不在 SwiftUI 里画）反而更贵：
//     静置 1.6 / 1.9，悬停 6.6 / 6.8，p99 17.9 / 17.7，>33.4 23 / 27 次每 24 s。
//   `sample`：每一下悬停都走到 `NSWindow layoutIfNeeded → _layoutSubtreeWithOldSize`。
//   圆心那行「现在是哪一段」当时排在 VStack 末尾，出现/消失把整摞顶动半个行高，
//   带着整扇窗重跑 Auto Layout。环每秒画 60 帧那会儿这轮布局本来就在发生，免费搭了车；
//   环搬走之后它才现形。把那一行挂到布局之外的 overlay 上（对齐修完之前的二进制）：
//     静置 2.1 / 2.1，悬停 4.8 / 4.9；静置 1.7 / 1.7，悬停 4.9 / 5.0（**+2.7/+3.2 个点**）；
//     p99 悬停 14.7 / 14.1，>33.4 零次、>100 零次，最大 25.1 / 28.5。
//   终版（overlay 的 `alignmentGuide` 挂到 `Group` 上、重新签名之后）复测两对：
//     静置 1.5 / 1.7，悬停 4.3 / 4.4（**+2.8/+2.7 个点**），p99 悬停 14.0，最大 19.8；
//     静置 1.5 / 1.6，悬停 4.4 / 4.5（**+2.9/+2.9 个点**），p99 悬停 13.5，最大 28.2；
//     >33.4 两对都是零次、>100 零次。红线四条全过。
//   （同一晚另有一对被负载污染：静置最大 248.9 ms、>33.4 16 次；作废重跑，别引用。）
//
//   —— 回收动效 + 声音（`DISKWISE_PERF_FX=1.6`，2026-10-22，已签名的发布包，同一配方、同样是尾段）——
//   这一档自演的是「点第二下扇形」那条路：每 1.6 s 放一趟水珠搬运（Core Animation 图层）
//   并带上 `snap` / `gather` / `dawn` 三声，**不动真账**（不写盘、不清东西）。
//     静置          p50 8.3  p95 8.9  p99  9.0  最大 36.5  >16.7 1 次  >33.4 1 次  >100 0  主线程 1.7%
//     动效+声音     p50 8.3  p95 9.9  p99 11.7  最大 32.8  >16.7 1 次  >33.4 0 次  >100 0  主线程 2.5%
//   两跑尾段节拍数一模一样（2158），所以是同一时间窗的配对。涨幅 +0.8 个点，
//   红线四条全过（p99 11.7 ≪ 16.7；>33.4 反而归零；>100 零次；+0.8 ≪ +3）。
//   为什么这么便宜：水珠是普通 `CALayer` 上的关键帧动画（position / opacity / scale），
//   最多三趟并发（`ReclaimFXHost.active`），建在 SwiftUI 布局之外的一块 `hitTest → nil`
//   的 `NSView` 上；声音的 PCM 在 `diskwise.sound.synth` 这条后台队列算好，
//   点击那一下只是往一条空闲轨递现成的缓冲区。
//   这两条就是「一次交互不许为了好看再算一遍」的落点，见 `ReclaimFX` 与 `Sound` 的头注。
//
//   —— 上面那对之后，工具条多了一颗「?」、窗口背景多了一枚 0×0 的按键接收器
//   （`CleanupGuide` / `EscapeTap`），同一配方在同一个签名包上重跑两对（2026-10-22，尾段）：
//     静置 1      p50 8.3  p95 9.1  p99  9.3  最大 12.5  >16.7 0  >33.4 0  >100 0  主线程 1.7%
//     动效+声音   p50 8.3  p95 9.1  p99 10.3  最大 21.8  >16.7 3  >33.4 0  >100 0  主线程 2.9%
//     静置 2      p50 8.3  p95 9.6  p99 10.2  最大 10.4  >16.7 0  >33.4 0  >100 0  主线程 1.8%
//     动效+声音   p50 8.3  p95 10.0 p99 12.6  最大 25.5  >16.7 3  >33.4 0  >100 0  主线程 3.0%
//   红线四条照旧全过（两对动效跑的 p99 是 10.3 与 12.6，都 ≪ 16.7；>33.4 与 >100 全零；
//   主线程差 +1.1/+1.2 个点，离 +3 那条还远）。与上一对的差在噪声量级里，
//   但这一对里 >16.7 各出现 3 次而上一次只有 1 次——不拿一次跑的话说明不了任何事，
//   所以这两对都留着，别只引用好看的那一对。
//
//   四层结论，前两层是被第三层证伪之后剩下的，第四层是搬走常驻循环之后才看见的：
//   1. 一次「整页变更」在这台 Intel 机器上值 60–100 ms，与改了什么无关；
//      所以修法不是把算的改成更快的算，是**缩小一次变更能作废多少视图**。
//   2. `AppStore` 是一整块 `ObservableObject`：它上任何一个 `@Published` 一写，每一页都重绘。
//      拿它当一次性交互的通道，量到的是这笔全 App 的账——这个错判过一次，代价是一轮白做的优化。
//      要窄作废就单独挂一条通知（`OverviewModel.hoverSignal` 就是这种线），别图省事往 store 上写。
//   3. **作废范围收窄之后仍不动，凶手是隐式动画。** 一颗只画 16 pt、位置很浅的叶子挂着
//      `.animation(theme.animation, value:)`，一被触发就把整扇窗的 Auto Layout 重跑
//      一整个动画时长（实测 ~1 s 的补间 × 每次触发）。以后往这页加动画之前，
//      先想清楚它的 value 挂在哪一层——挂在深层叶子上的隐式动画，价钱是按整页付的。
//      回收动效因此走 Core Animation 图层（见 `ReclaimFX`），不进 SwiftUI 的布局。
//   4. **常驻循环搬走，不等于交互账也结了。** 它以前一直在替交互付一笔布局钱：
//      环的 60 Hz 更新让整扇窗每帧都在重排，一行字插进/抽走根本看不出来。常驻降到 1.7%
//      之后，同一段悬停的主线程涨了 5 个点、p99 17.9。往布局里加减任何东西——哪怕只是一行
//      `Text`——都要按「整扇窗重排」记账；出现/消失的元素挂到 overlay，别改 VStack 的高度。
//
// ── 逐页底数（2026-10-22，6 s 一页的走查；「稳态」= 丢掉每页头 2 s 的建造）──────
//
// 配方：`DISKWISE_PERF=90 WALK=1 EVERY=6`，演示树、dawn、zh；同一分钟另跑一条
// `HOLD=overview SKIP=6` 当同负载对照，尾段 1.5% / p99 10.3 / >33.4 零次 / 最大 10.5 ms。
// 跑的时候整机负载 4.8–5.8（这台机器上别的进程占满一个核），但对照的最大空档只有 10.5 ms，
// 说明主线程没被排挤——下面这些数直接跟 1.5 这条地板比，别跟旧的 17–20% 比。
//
// 十二页的稳态落在同一个量级：大文件 1.7、很久没动 1.6、node_modules 1.6、
// Docker 2.0、开发缓存 2.0、应用缓存 1.7、卸载残留 1.7、废纸篓 1.5、AI Agent 1.6、
// 外观皮肤 1.7、问题反馈 1.6、菜单栏与启动 1.6（单位 %）；p99 全在 10.0–10.3，
// 最大 10.3–15.4，>33.4 和 >100 都是零次。没有常驻循环的页，地板就是 1.5–1.6。
//
// 带后台扫描的几页（稳态段里扫描还没跑完）：
//   重复文件   主线程 8.3，进程 102.6；p99 11.6，最大 26.7，>33.4 零次
//   node_modules / Docker / 开发缓存   进程 92.4–98.5，主线程 1.6–2.0
// 扫描线程的账基本不落在主线程上；重复文件是这里唯一主线程跟着涨的（+6.8 个点），
// 进程那一栏也满着。它要再涨，先去看它把什么搬回了主线程，别先动别的页。
//
// 切页那一下（每页头 2 s）另记：要起一轮扫描的页 p99 被抬到 31.8–42.1 ms；其余页的 p99
// 仍贴着 10 ms，但每页都有 1–3 次 >100 ms 的建造空档，最大 123–541 ms（总览首屏 467 ms）。
// 这是「建造」那笔账，不是常驻底数——拿走查的全段数去定常驻红线，量到的其实是切页有多贵
// （第一版就这么错过一次，见 `line(_:name:after:)` 上面那行「稳态」的注释）。
//
// 总览单独说：它在走查里排第一，2–6 s 那段还在首屏建造 + 扫描里，稳态行读到 18.6%、
// 最大 125.8、>100 一次，**不能当常驻底数**；同一分钟的 SKIP=6 静置才落到 1.5%。
// 给总览定红线只用 SKIP≥6 的静置跑；逐页走查只用来比「这一页比地板多花多少」。

@MainActor
final class PerfProbe {
    static let shared = PerfProbe()

    private static let env = ProcessInfo.processInfo.environment
    private static var uptime: Double { ProcessInfo.processInfo.systemUptime }

    /// DISKWISE_PERF=<秒>：跑这么久然后退出。没设就是完全不开探针。
    static var seconds: Double? {
        guard let raw = env["DISKWISE_PERF"], let v = Double(raw), v > 0 else { return nil }
        return v
    }

    private static var walk: Bool { env["DISKWISE_PERF_WALK"] == "1" }
    private static var every: Double { Double(env["DISKWISE_PERF_EVERY"] ?? "") ?? 2.5 }
    private static var note: String { env["DISKWISE_PERF_NOTE"] ?? "" }

    /// `DISKWISE_PERF_SKIP=<秒>`：整段照记，但**额外**给每段再打一行「尾段」——
    /// 只算起跑 `SKIP` 秒之后的那些格子。
    ///
    /// 要分开是因为「扫盘期间」和「扫完之后」是两条不同的承诺：前者跟磁盘和别的进程
    /// 抢时间，后者才是环一直在转、手一直在页面上移动时用户摸到的那一段。
    /// 尾段那一行才是动效层的红线，全程序列会把两者混成一个数。
    private static var skip: Double { Double(env["DISKWISE_PERF_SKIP"] ?? "") ?? 0 }

    /// `DISKWISE_PERF_HOVER=<秒>`：每隔这么多秒把鼠标「挪」到账本的下一段上。
    ///
    /// 走的是 `OverviewModel.applyHoverToken` → `hoverSignal.set`，跟手指把鼠标
    /// 跨进一行（`onHover` → `setHover`）落的是同一个写入口。没有这条驱动，
    /// 悬停这一层只能靠人拿手扫，而那既不可重复也没法配对——而悬停是这一页
    /// 唯一一个「每秒能来好几发」的动作，它的价不量出来就等于没管过。
    private static var hoverEvery: Double? {
        guard let raw = env["DISKWISE_PERF_HOVER"], let v = Double(raw), v > 0 else { return nil }
        return v
    }

    /// `DISKWISE_PERF_PREVIEW=<秒>`：每隔这么多秒把「按住空格」压下去再松开，一轮一遍。
    ///
    /// 为什么要有这一支：预演的账不在静帧上，在**进入那一秒**——绿色亮弧从零长到
    /// 该到的角度，同时六颗 `+N` 角标和盘心那三行读数一起换。静帧配对（按住不动 30 s）
    /// 量出来跟不预演一模一样，那既证不了过渡便宜，也证不了它不贵。
    /// 而过渡只有 1.05 s，把它圈进起跑那几秒又会被扫盘本身淹掉（实测两趟 35 / 39 格
    /// 的差异全在启动噪声里），所以要在**扫完之后的常驻窗口**里反复触发。
    ///
    /// 覆盖到哪、没覆盖到哪：这里直达 `OverviewModel.beginPreview/endPreview`，
    /// 也就是手指那条路最终落笔的两个写入口——画面重算的部分一字不差。没走的是
    /// `OverviewView.holdPreview` 前面那几道闸门（在扫盘/代价读法/没账时拒绝进入）
    /// 和那一声 `Sound.preview`：闸门是一次 `Bool` 判断，声音在后台线程合成，
    /// 两者都不进这一层的账。要量「整条手指路」得连拒绝路径一起量，那是另一件事。
    private static var previewEvery: Double? {
        guard let raw = env["DISKWISE_PERF_PREVIEW"], let v = Double(raw), v > 0 else { return nil }
        return v
    }

    /// `DISKWISE_PERF_ARM=<秒>`：每隔这么多秒上一发膛再自己解除，一轮一遍。
    ///
    /// 这一支是**参照系**，不是新承诺：预演过渡测出来很难看（见 `previewEvery`），
    /// 但要紧的问题不是「它贵」而是「它比已经上线的那一发上膛贵在哪」。上膛改的是
    /// 同一个模型上的另一个 `@Published`（`armedPath`），动的也是环 + 六行 + 盘心，
    /// 两边一减才分得清：贵的是预演自己那几层（亮弧、六颗角标、决策条），
    /// 还是这一页「模型一动就整页重算」的老账。
    /// 走 `arm(_:)`/`disarm()`，与手指点弧落在同一对写入口上。
    private static var armEvery: Double? {
        guard let raw = env["DISKWISE_PERF_ARM"], let v = Double(raw), v > 0 else { return nil }
        return v
    }

    /// 侧栏上真存在、真点得到的那些页，顺序照 `ContentView.sidebar` 的四组。
    /// `folderDrill` 不在里面：它不是一栏常驻的目的地，是从某一行进去的。
    private static let walkPanels: [AppPanel] = [
        .overview, .big, .old, .dup,
        .nodemodules, .docker, .devcache,
        .caches, .orphans, .trash,
        .agent,
        .appearance, .feedback, .menuLaunch,
    ]

    /// 一次节拍：空档多长、这期间**主线程**算掉了多少 CPU 时间。
    ///
    /// 为什么两样都要记：一台正在别处满载的机器（另一个实例在扫盘、mds 在重建索引）
    /// 会让主线程长时间排不上队，那在「空档」一列里跟我们自己在主线程上算东西长得
    /// 一模一样。只看空档就会去修一个不存在的问题。
    ///
    /// 这里必须问**线程**的 CPU 时间而不是进程的：进程时间把所有扫描线程都算进去，
    /// 后台正扫盘时会把「主线程在睡觉」误判成「主线程在忙」——总览页实测错过一次。
    private struct Gap {
        let at: Double      // 这次 fire 的时刻（systemUptime）
        let ms: Double      // 距上一次 fire
        let mt: Double      // 这期间主线程算掉的毫秒
        let p: Double       // 这期间整条进程算掉的毫秒（含扫描线程）
    }

    private struct Segment {
        let name: String
        let t0: Double
        var t1: Double
        var from: Int       // 这一段在 `gaps` 里从哪一格开始
    }

    private var segments: [Segment] = []
    /// 平铺一格一条，不塞进 `Segment` 里：塞进去每次 append 都要把整段（几千格）
    /// 复制一遍才写回数组，实测探针自己就烧掉 1.6% CPU——量具不该扰动被量的东西。
    private var gaps: [Gap] = []
    private var last = 0.0
    private var lastCpu = 0.0
    private var lastMt = 0.0
    private var timer: Timer?
    private var walkTimer: Timer?
    private var hoverTimer: Timer?
    private var previewTimer: Timer?
    private var armTimer: Timer?
    /// 现在这一拍是「按着」还是「松了」（见 `flipPreview`）。
    private var previewOn = false
    /// 现在这一拍膛上没上（见 `flipArm`）。
    private var armOn = false
    private var walkIndex = 0
    private var store: AppStore?
    /// 翻勾那一发要直达总览模型，不能绕 `store` 上的 token（见 `flipPick`）。
    private var overview: OverviewModel?
    /// 代价账那支表等到第几下「没在扫盘」了（见 `watchCostLedger`）。
    private var costIdle = 0
    /// 这支表有没有真见过「在扫」。少了它，App 刚起来那一秒
    /// `scanning`/`cleanScanning` 都还是 false，表会对着一个空账打「全是 0」。
    private var costSeen = false
    private var running = false

    private static func cpuSeconds() -> Double {
        var ts = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts) == 0 else { return -1 }
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
    }

    /// 本线程（挂了节拍的那条 = 主线程）累计占用的 CPU 秒。
    private static func threadSeconds() -> Double {
        let tid = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, tid) }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(tid, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        func sec(_ t: time_value) -> Double { Double(t.seconds) + Double(t.microseconds) / 1_000_000 }
        return sec(info.user_time) + sec(info.system_time)
    }

    /// 由 `ContentView.onAppear` 叫一次。没设 `DISKWISE_PERF` 时这里什么都不做。
    ///
    /// `overview` 那一站是必须的：悬停那一项要按**手指走的那条路**去按，而 `AppStore`
    /// 上没有直达总览模型的口子（模型住在 `ScanStore`）。
    func start(store: AppStore, overview: OverviewModel, on panel: AppPanel) {
        guard let seconds = Self.seconds, !running else { return }
        running = true
        self.store = store
        self.overview = overview
        let now = Self.uptime
        last = now
        lastCpu = Self.cpuSeconds()
        lastMt = Self.threadSeconds()
        var name = panel.title
        if let hold = Self.holdPanel {
            name = hold.title
            if hold != panel { store.jumpTo = hold }   // 停在指定那一页，别在总览上白测
        }
        openSegment(name: name, at: now)

        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { PerfProbe.shared.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if Self.walk, Self.holdPanel == nil {
            let w = Timer(timeInterval: Self.every, repeats: true) { _ in
                MainActor.assumeIsolated { PerfProbe.shared.advance() }
            }
            RunLoop.main.add(w, forMode: .common)
            walkTimer = w
        }

        if let h = Self.hoverEvery {
            let t = Timer(timeInterval: h, repeats: true) { _ in
                MainActor.assumeIsolated { PerfProbe.shared.moveHover() }
            }
            RunLoop.main.add(t, forMode: .common)
            hoverTimer = t
        }

        if let p = Self.previewEvery {
            let t = Timer(timeInterval: p, repeats: true) { _ in
                MainActor.assumeIsolated { PerfProbe.shared.flipPreview() }
            }
            RunLoop.main.add(t, forMode: .common)
            previewTimer = t
        }

        if let a = Self.armEvery {
            let t = Timer(timeInterval: a, repeats: true) { _ in
                MainActor.assumeIsolated { PerfProbe.shared.flipArm() }
            }
            RunLoop.main.add(t, forMode: .common)
            armTimer = t
        }

        let end = Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { PerfProbe.shared.report(runsFor: seconds) }
        }
        RunLoop.main.add(end, forMode: .common)
        log("探针已挂上：跑 \(String(format: "%.0f", seconds)) s"
            + (Self.walk && Self.holdPanel == nil ? "，逐页走查每 \(Self.every) s 一跳" : "，停在 \(name)")
            + (Self.hoverEvery.map { "，每 \(String(format: "%g", $0)) s 指一段" } ?? "")
            + (Self.previewEvery.map { "，每 \(String(format: "%g", $0)) s 压一次空格" } ?? "")
            + (Self.armEvery.map { "，每 \(String(format: "%g", $0)) s 上一次膛" } ?? "")
            + (Self.note.isEmpty ? "" : "（\(Self.note)）"))
    }

    /// 压一下、松一下（见 `previewEvery`）。落点与 `SpaceHoldTap` 那两个回调同一对。
    private func flipPreview() {
        guard let overview else { return }
        previewOn.toggle()
        if previewOn { overview.beginPreview() } else { overview.endPreview() }
    }

    /// 上一发膛、再自己解除（见 `armEvery`）。挑哪条弧不写死名字：
    /// 从 `cacheTargets`（真带着可回收目标的那些弧）里取第一条，演示树改了也跟着动。
    /// 只上膛不按下第二下，所以这一支一趟也不搬文件。
    private func flipArm() {
        guard let overview else { return }
        armOn.toggle()
        if armOn {
            guard let path = overview.cacheTargets.keys.sorted().first else { return }
            overview.arm(path)
        } else {
            overview.disarm()
        }
    }

    /// 把悬停挪到下一段（或挪开）。落点跟行/弧的 `onHover` 是同一条写入口，
    /// 见 `OverviewModel.applyHoverToken`。
    private func moveHover() {
        overview?.applyHoverToken(Self.env["DISKWISE_PERF_HOVER_CMD"] ?? "cycle")
    }

    /// `DISKWISE_COST=1`：扫盘收尾后把四类代价账打一遍（口径验收用），不测帧、不退出。
    ///
    /// 跟 `DISKWISE_PERF` 分开是一件真事：这个只要模型跑完，不要 1/120 s 的节拍，
    /// 也不该为了取一个数把「量帧」那套配方（跳段、hold、`open` 补窗）全背上。
    ///
    /// 「跑完」要两段都看见：总览自己那趟扫盘（`scanning`）和缓存体积（`cleanScanning`）。
    /// 只看后者会打在扫盘还没开始的那一秒上——账是空的，四类全 0，看着像口径错了。
    /// 再停两拍：缓存账在 `cachesSettleWindow`（0.12 s）里结算，`scanning` 变 false
    /// 那一瞬账可能还差最后一笔。
    ///
    /// 演示树（96 G 假盘）实测：零代价 20.4 G / 需重下 3.4 G / 不可逆 9.6 G / 不碰 62.6 G，
    /// 四类之和 96.0 G 正好是整盘，零代价与环上亮沿（`cacheTargets`）是同一个数。
    static func watchCostLedger(_ overview: OverviewModel) {
        guard env["DISKWISE_COST"] == "1" else { return }
        let started = uptime
        let t = Timer(timeInterval: 0.5, repeats: true) { timer in
            MainActor.assumeIsolated {
                let p = PerfProbe.shared
                if overview.scanning || overview.cleanScanning {
                    p.costSeen = true
                    p.costIdle = 0
                } else {
                    p.costIdle += 1
                }
                if p.costSeen, p.costIdle >= 2, let ledger = overview.costLedger {
                    timer.invalidate()
                    p.reportCost(ledger, overview: overview)
                } else if uptime - started > 180 {
                    timer.invalidate()
                    p.log("四类代价账：等了 180 s 还没等到扫盘收尾，放弃")   // l10n-scan: skip
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        PerfProbe.shared.log("四类代价账：等扫盘收尾后打一遍")   // l10n-scan: skip
    }

    /// 四类账的读数 + 两条对账：四类之和 = 整盘；零代价 = 环上亮沿认的可回收量。
    ///
    /// 后一条不是把同一个数念两遍：亮沿读 `cacheTargets`（只收 safe、父项吞子项），
    /// 代价账读 `costSums`（连 warn 一起、按最轻那档拆）。两套归账各写一遍，
    /// 能对上是它们真的在数同一块盘；对不上就是其中一处漏了或重了。
    private func reportCost(_ ledger: CostLedger, overview: OverviewModel) {
        let s = ledger.sums
        // l10n-scan: off
        func g(_ b: Int64) -> String { "\(human(b))（\(b) B）" }
        func name(_ t: CostTier) -> String {
            switch t {
            case .free: return "零代价"
            case .redo: return "需重下"
            case .irreversible: return "不可逆"
            case .off: return "不碰"
            }
        }
        let reclaim = overview.cacheTargets.values.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.size }
        let poolSafe = overview.cleanPool.filter { $0.tier == .safe }.count
        var out = "\n    ── 四类代价账（DISKWISE_COST）\n"
        out += "      整盘 \(g(ledger.total))\n"
        out += "      " + CostTier.allCases
            .map { "\(name($0)) \(g(ledger.bytes($0)))" }
            .joined(separator: "   ") + "\n"
        out += "      四类之和 \(g(ledger.accounted)) / 整盘 \(g(ledger.total))"
        out += ledger.balanced ? " —— 对账 OK\n" : " —— 超账 \(ledger.overdrawn) B\n"
        out += "      零代价 vs 环上亮沿（cacheTargets）\(g(reclaim))"
        out += s.free == reclaim ? " —— 一致\n" : " —— 不一致\n"
        out += "      候选池 \(overview.cleanPool.count) 处（safe \(poolSafe) / "
        out += "redo \(overview.cleanPool.count - poolSafe)）\n"
        // l10n-scan: on
        FileHandle.standardError.write(out.data(using: .utf8)!)
    }

    /// 一律走 stderr，跟截图模式那套 `✓ / !` 同一条道，方便 `2>&1 | tee`。
    private func log(_ s: String) {
        FileHandle.standardError.write("    perf: \(s)\n".data(using: .utf8)!)
    }

    private static var holdPanel: AppPanel? {
        guard let raw = env["DISKWISE_PERF_HOLD"], !raw.isEmpty else { return nil }
        return AppPanel.allCases.first { String(describing: $0).lowercased() == raw.lowercased() }
    }

    private func openSegment(name: String, at t: Double) {
        segments.append(Segment(name: name, t0: t, t1: t, from: gaps.count))
    }

    private func tick() {
        let now = Self.uptime
        let cpu = Self.cpuSeconds()
        let mt = Self.threadSeconds()
        let gap = (now - last) * 1000
        let worked = (mt - lastMt) * 1000
        let proc = (cpu - lastCpu) * 1000
        last = now
        lastCpu = cpu
        lastMt = mt
        guard gap > 0, !segments.isEmpty else { return }
        gaps.append(Gap(at: now, ms: gap, mt: worked, p: proc))
        segments[segments.count - 1].t1 = now
    }

    private func advance() {
        guard let store else { return }
        walkIndex += 1
        guard walkIndex < Self.walkPanels.count else { walkTimer?.invalidate(); return }
        let panel = Self.walkPanels[walkIndex]
        store.jumpTo = panel          // 与页面上那些跳转链接同一条路
        openSegment(name: panel.title, at: Self.uptime)
    }

    private func report(runsFor seconds: Double) {
        timer?.invalidate()
        walkTimer?.invalidate()
        /// 第 `i` 段的那些格子：下一段的起点就是这一段的终点。
        func slice(_ i: Int) -> ArraySlice<Gap> {
            let end = i + 1 < segments.count ? segments[i + 1].from : gaps.count
            return gaps[segments[i].from..<max(segments[i].from, end)]
        }
        func line(_ i: Int, name tag: String? = nil, after: Double = 0) -> String {
            let s = segments[i]
            let all = slice(i).filter { $0.at - s.t0 >= after }
            let g = all.map { $0.ms }.sorted()
            func q(_ p: Double) -> Double {
                guard !g.isEmpty else { return 0 }
                return g[min(g.count - 1, max(0, Int((p * Double(g.count)).rounded())))]
            }
            let over16 = g.filter { $0 > 16.7 }.count
            let over33 = g.filter { $0 > 33.4 }.count
            let over100 = g.filter { $0 > 100 }.count
            // `wall` 用毫秒：`mt`/`p` 存的就是毫秒，混成秒会把占用率吹高一千倍
            // （第一版真吹出来了：常驻页面上印出 33783.8%）。
            let wall = max(1.0, ((all.last?.at ?? s.t1) - (all.first?.at ?? s.t0)) * 1000)
            let mt = all.reduce(0.0) { $0 + $1.mt } / wall * 100
            let cpu = all.reduce(0.0) { $0 + $1.p } / wall * 100
            // 名字留 12 个汉字宽：中文页名各语言长度不一，用固定字符数对齐比用字节数稳。
            let name = (tag ?? s.name).padding(toLength: 14, withPad: " ", startingAt: 0)
            return String(format: "      %@ %6d  %5.1f  %5.1f  %5.1f  %6.1f  %5d  %4d  %4d  %5.1f  %5.1f",
                          name, g.count, q(0.50), q(0.95), q(0.99), g.last ?? 0,
                          over16, over33, over100, mt, cpu)
        }
        // l10n-scan: off —— 这一段全是打到 stderr 的判读文字，不是界面词条
        var out = "\n    ── DISKWISE_PERF 探针：\(String(format: "%.1f", seconds)) s"
        if !Self.note.isEmpty { out += "（\(Self.note)）" }
        out += """
        ，主线程 1/120 s 节拍
          段落               节拍数   p50    p95    p99     最大   >16.7 >33.4 >100   主线程%  进程%
        """
        out += "\n"
        for i in segments.indices {
            out += line(i) + "\n"
            if Self.skip > 0 { out += line(i, name: sfx(i), after: Self.skip) + "\n" }
            // 走查里每一段的头两秒是这一页的**建造**（首屏那笔账），不是常驻底数。
            // 不给这条，拿 2.5 s 一段的数去定红线，量到的其实是「切页有多贵」。
            if Self.walk && Self.holdPanel == nil {
                out += line(i, name: segments[i].name + " 稳态", after: 2) + "\n"
            }
        }
        out += "      判读：p50 应贴着 8.3 ms（节拍本身）；>33.4 那一列是「丢了两帧以上」，\n"
        out += "            用户手感的门槛在它，不在 p50。「主线程%」是我们自己的账，\n"
        out += "            「进程%」高而主线程不涨，是合成侧或扫描线程的账。\n"
        // 长空档逐条摊开，并带上「这期间到底算了多少」。不摊开就会去修机器而不是修代码：
        // 另一个实例在扫盘、mds 在重建索引时，主线程排不上队的空档跟我们算出来的空档
        // 在这一列里长得一模一样。
        /// 尾段那一行的标签。
        func sfx(_ i: Int) -> String { segments[i].name + " 尾段" }
        var long = gaps.filter { $0.ms > 100 }
        if !long.isEmpty {
            long.sort { $0.ms > $1.ms }
            let t0 = segments.first?.t0 ?? 0
            out += "      长空档（>100 ms）逐条，按长度：\n"
            for g in long.prefix(8) {
                let kind = g.mt > g.ms * 0.3 ? "主线程在算东西" : "没排上队 / 主线程在等"
                out += String(format: "        @ %5.1f s  空档 %7.1f ms  主线程算了 %6.1f ms（同期进程 %6.1f ms）→ %@\n",
                              g.at - t0, g.ms, g.mt, g.p, kind)
            }
            if long.count > 8 { out += "        …… 另有 \(long.count - 8) 条\n" }
        }
        // >100 那一列里两类空档长得一模一样：我们自己在主线程上算出来的，和整台机器忙到
        // 主线程排不上队的。红线要罚的是前者，而上面逐条只摊前 8 条——配对跑的时候数不全，
        // 就会去修机器而不是修代码。这里按段直接给一个拆分（只数尾段窗口内那些格子）：
        // 「算」是我们自己的账，「等」是 mds、另一个实例、别的进程的账，不该记到这一层上。
        if Self.skip > 0 {
            for i in segments.indices {
                let l = slice(i).filter { $0.ms > 100 && $0.at - segments[i].t0 >= Self.skip }
                guard !l.isEmpty else { continue }
                let calc = l.filter { $0.mt > $0.ms * 0.3 }.count
                out += "      \(sfx(i)) 大空档拆分：主线程在算 \(calc) / 没排上队 \(l.count - calc)\n"
            }
        }
        // l10n-scan: on
        FileHandle.standardError.write(out.data(using: .utf8)!)
        exit(0)
    }
}
