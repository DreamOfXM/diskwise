import AppKit
import Combine
import SwiftUI

// ── 截图模式：DISKWISE_SHOTS=<目录> 时启用，渲染完就退出 ─────────────────────
//
// 为什么不用系统截图：README 的图要能复现，而整屏截图会把别的窗口拍进来。
// 这里只拍自己这一扇窗：先问窗口服务器要它的合成像素（侧边栏的列表只有服务器端
// 那份，离线画 layer 树会拍成一片空白），问不到再退回自己画。
//
// 必须配 DISKWISE_HOME_SHIM（见 build_app/make_demo_home.sh）：
// 总览页会把 ~/Desktop、~/Documents 连同体积原样晒出去，那是隐私不是演示。
//
// DISKWISE_SKIN=<皮肤 id> 指定用哪套皮肤拍。注意这只是给渲染器注入 Theme，
// 不写解锁记录——`Channel.showsPricing` 为真时进阶皮肤在正常启动路径里依然要解锁才能穿上，
// 默认（false）则全部可用。
//
// 用法（两语言 × 多皮肤，逐页出图）：
//   DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome DISKWISE_SHOTS=/tmp/shots/en-dawn \
//     DISKWISE_DEMO_USAGE=96:16 DISKWISE_SKIN=dawn DISKWISE_LANG=en \
//     ./build_app/DiskWise.app/Contents/MacOS/DiskCleaner
// 只拍某几页（定位问题不必重跑全套）：再加 DISKWISE_ONLY=overview,dup
// 要拍「底部那颗全选按下去 / 再按回来」：再加 DISKWISE_PICK=dup 或 dup,caches，
//   命中的页各补两张 -selected / -deselected。
// 要拍「列表页刚进去、一行都还没出来」那张加载态：再加 DISKWISE_MIDSCAN=overview,nodemodules
//   （页名同 DISKWISE_ONLY），命中的页各补一张 -midscan。
// 要拍「总览某一行的下一级摊开」：再加 DISKWISE_DRILL='~/Library'，总览那张之后会补一张
// 01-overview-drill.png（列表里没有这个名字时就不补，只拍普通那张）。
// 环形那道绕环的反光在静止帧里默认钉在正上方；要取证「它在走」：
//   DISKWISE_RING_GLINT=110 / 230 各跑一趟，三张并排看亮斑落点。
// 要取证余晖「在呼吸」：DISKWISE_RING_BREATH=0 与 =1 各一张，两档求差。
// 要拍「从总览深挖进某目录后的大文件页」（带返回入口那一屏）：
//   DISKWISE_ONLY=big DISKWISE_BIGDRILL='<某个目录>' → 02-big-files-drilled.png。
// 要拍「总览某一格摊开之后长什么样」：再加 DISKWISE_JUMP=rest|gap|<某行完整路径>，rest 摊开
// 「其他已统计」那一格（它名下的那些行，加上尾巴那句逐段对账），gap 摊开「没量到」那一格（卷账逐块点名），
// 给完整路径就摊开那个目录的下一级，补 01-overview-jump.png。`restnote` 是 rest 的旧名，仍然认。
// 皮肤页那种长页要一次装下六张卡：再加 DISKWISE_WIN=1280x920（默认 1280x820）。
// 长列表页（大文件深挖那种）可以把画幅拉到 2600：超出屏幕的那一截**拍得到**，
// 前提是别让用户钳制生效，见 `SnapshotWindow`。
// 要验「切语言当次生效」：再加 DISKWISE_LANG_FLIP=en|zhHans，整套拍完会在同一进程里
// 当场换一次语言，把皮肤页再拍成 90-skins-after-flip-<码>.png。

enum SnapshotMode {
    static var requestedDir: String? {
        let raw = ProcessInfo.processInfo.environment["DISKWISE_SHOTS"] ?? ""
        guard !raw.isEmpty else { return nil }
        return (raw as NSString).expandingTildeInPath
    }

    /// DISKWISE_PANEL=<页名>：正常启动（不是截图模式）时直接落在某一页。
    /// 验窗口外框必须走这个——截图模式自己开窗口只拍 contentView，
    /// 红绿灯压住导航、标题栏重影这类缺陷在截图里结构性地看不见。
    static var requestedPanel: AppPanel? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_PANEL"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty else { return nil }
        return AppPanel.allCases.first { String(describing: $0).lowercased() == raw }
    }

    /// DISKWISE_SKIN=<皮肤 id>：正常启动时也用这套皮肤。
    /// 同 DISKWISE_PANEL：验外框/对比度要真窗口，而浅皮看不出「内容有没有顶到窗口边」。
    static var requestedSkinID: String? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_SKIN"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !raw.isEmpty, requestedDir == nil else { return nil }
        return raw
    }

    /// DISKWISE_LANG=en|zh|auto：覆盖已存的语言选择，截图模式和正常启动都认。
    /// 不走 `defaults write`：沙盒包里 App 读的是容器里那份 plist，命令行写进去的那份
    /// 它看不见——批量截双语图时这条才是确定的。
    static var requestedLang: AppLanguage? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_LANG"] ?? "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch raw {
        case "en", "english": return .en
        case "zh", "zh-hans", "chinese": return .zhHans
        case "auto", "system": return .system
        default: return nil
        }
    }

    /// DISKWISE_DRILL=<行名>：拍完总览之后，把列表里那一行就地摊开再补一张
    /// （`01-overview-drill.png`）。摊开出来的下级只有点下去才看得见，
    /// 而截图这一路没有键鼠，所以直接调行上那颗箭头走的同一个方法——不另画一份假界面。
    private static var drillRow: String? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_DRILL"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    /// DISKWISE_JUMP=rest|restnote|gap|<某行的完整路径>：拍完总览再把那一格就地摊开，补一张
    /// `01-overview-jump.png`。走的是行首那颗 `▸` 调的同一条路径（`openDrill`），摊开的同时环
    /// 收成参照盘——所以这一张拍的就是「下钻态」本身，不是滚到某处看满幅的环。
    /// 为什么需要它：明细只在点开之后存在，而截图这一路没有键鼠；「其他已统计」那块弧到底
    /// 回答没回答「能不能删」，恰恰就看摊开后的那几行。
    /// `restnote` 与 `rest` 现在指同一处：那句对账不再躺在列表尾巴，它就是摊开后的最后一段。
    private static var jumpToken: String? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_JUMP"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    /// DISKWISE_RING=arm,refuse：拍完总览再往环上真点几下，各补一张。
    /// `arm` 出两张——`01-overview-armed.png`（第一下，上膛）和
    /// `01-overview-taken.png`（同一条弧第二下，真搬进废纸篓）；
    /// `refuse` 出一张 `01-overview-refused.png`（点一条动不了的弧，看它当场怎么解释）。
    /// `scan` 出一张 `01-overview-scanning.png`：重跑一趟扫描，趁量到一半时拍——
    /// 「光束钉在量到的边界上」这件事只有这一帧能证明，静下来的图里那道光永远停在起点。
    /// `arm` 拍完会自己把搬走的那棵树放回原处，不用人在外面补一条 `mv`。
    ///
    /// 走的是弧上 `onTapGesture` 那个 `tapArc`（经 `store.overviewRing`），
    /// 两段式确认、3.2 秒自动解除、真 `trashItem`、真挪账全在链路上。
    ///
    /// 上膛那一张**不能**用 `waitSettled`：它一泡就是九秒，而膛只保 3.2 秒——
    /// 等到画面静下来时那句「再点一次」早就自己收回去了，拍出来永远是没上膛的环。
    /// 扫描那一张同理，而且更紧：整趟只有几十秒，`pump` 到点就得拍。
    private static var ringHooks: Set<String> {
        Set((ProcessInfo.processInfo.environment["DISKWISE_RING"] ?? "")
            .split(separator: ",").map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0 == "arm" || $0 == "refuse" || $0 == "scan" })
    }

    /// DISKWISE_RING_GLINT=<度>：静止帧里把那道绕环走的反光钉在指定相位上。
    /// 「流动」这件事一张图证明不了——同一版连拍两三张不同相位，才看得出它真的在走
    /// 而不是环上刮了一道白痕。不给这个变量就停在 0°（一圈量完的边界，正上方），
    /// 那正是扫描结束后第一帧真机上看到的样子。
    static var ringGlintPhase: Double? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_RING_GLINT"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(raw) else { return nil }
        return v.truncatingRemainder(dividingBy: 360)
    }

    /// DISKWISE_RING_BREATH=<0~1>：把呼吸余晖钉在指定档（0 = 最暗 .34，1 = 最亮 .9）。
    /// 同 `ringGlintPhase`：一伏一起是**动**出来的，静止帧默认取中位，
    /// 要证明它真的在呼吸就两档各拍一张求差。
    static var ringBreath: Double? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_RING_BREATH"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard let v = Double(raw) else { return nil }
        return min(1, max(0, v))
    }

    /// DISKWISE_HOVER=<第几段>：把「鼠标停在某条弧上」这件事钉住拍照（序号对着环旁边
    /// 那列账目从上往下数，0 起）。悬停响应是这一屏最容易「代码写了、图上看不见」的一处，
    /// 没有旋钮就只能靠嘴说它存在。
    static var ringHover: Int? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_HOVER"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return Int(raw)
    }

    /// DISKWISE_BIGDRILL=<目录>：拍 02 那一张时，走的正是总览点「深挖」那条路
    /// （塞 bigScanDir 再切页，由大文件页的 onAppear 消费一次），出来的图就叫
    /// `02-big-files-drilled.png`。配 `DISKWISE_ONLY=big` 用：这趟只出深挖那一张，
    /// 不带这个变量再跑一趟才拿到默认范围的 02。
    private static var bigDrillDir: URL? {
        let raw = (ProcessInfo.processInfo.environment["DISKWISE_BIGDRILL"] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }

    /// DISKWISE_EXPAND=1：进列表页时把**第一行**的明细摊开。
    ///
    /// 展开态是行自己的状态，批量拍图这一路没有键鼠点不到那颗箭头，
    /// 所以由视图自己置位——改的是同一个 `expanded`，不是另画一张展开样。
    /// 只摊第一行：整列都摊开的话这一屏只剩明细，拍不到列表本身长什么样。
    static var expandFirstRow: Bool {
        (ProcessInfo.processInfo.environment["DISKWISE_EXPAND"] ?? "") == "1"
    }

    /// (页面, 文件名, 最少先等, 最多等到扫描静下来)
    ///
    /// 哈希大文件的那几页要给足预算：一趟 640 MB 的全量哈希能安静好几秒，
    /// 画面在这段时间里一动不动，光靠「连续 N 帧一致」会在扫描中途收工。
    /// 实测过一张少算一份副本的重复文件页（3 份报成 2 份）。
    private static let pages: [(AppPanel, String, Double, Double)] = [
        // 总览的上限给到 5 分钟：演示树十几秒就静了，真机整盘要走过几百 G，
        // 60 秒会在扫描中途收工——那张图的账是半截的，拿去对账反而误导。
        (.overview, "01-overview", 12, 300),
        (.big, "02-big-files", 10, 45),
        (.old, "03-old-files", 10, 45),
        (.dup, "04-duplicates", 20, 120),
        (.nodemodules, "05-node-modules", 15, 90),
        (.docker, "06-docker", 8, 30),
        (.caches, "07-caches", 15, 90),
        (.orphans, "08-leftovers", 15, 90),
        (.trash, "09-trash", 6, 20),
        (.appearance, "10-skins", 4, 15),
        (.feedback, "13-feedback", 2, 8),
    ]

    /// DISKWISE_PICK=dup,caches：这些页各补两张——按一次底部清理条的「全选」，再按一次
    /// 「取消全选」（`04-duplicates-selected.png` / `-deselected.png`）。勾选列表动辄几百项，
    /// 「勾上去撤不回」是用户报过的缺陷，只有真按一次才照得出来；按的就是那颗按钮的 action。
    private static var pickPanels: Set<String> {
        Set((ProcessInfo.processInfo.environment["DISKWISE_PICK"] ?? "")
            .split(separator: ",").map { $0.lowercased() })
    }

    /// DISKWISE_MIDSCAN=nm,caches：这些页在「刚换过去、一行都还没回填」的那一刻先拍一张
    /// （`<页名>-midscan.png`）。列表是扫完才一次性回来的，`waitSettled` 会一直等到数据落地
    /// 才收工，所以加载那几分钟画的是什么，没有这一钩子就只能靠嘴说它存在。
    private static var midscanPanels: Set<String> {
        Set((ProcessInfo.processInfo.environment["DISKWISE_MIDSCAN"] ?? "")
            .split(separator: ",").map { $0.lowercased() })
    }

    /// DISKWISE_MIDSCAN_AT=8：那张 -midscan 在换页后几秒拍，默认 0.35。
    ///
    /// 为什么要有这个数：0.35 秒是按「真机整盘」调的，可演示树不到 0.35 秒就扫完了，
    /// 于是拍出来是一张结果页；反过来在真机上 0.35 秒时读数还全是 0，拍出来的是兜底文案。
    /// 两种都证明不了「扫描中那行读数在动」，而只有拍的人知道这次挂的是哪套数据。
    private static var midscanDelay: Double {
        let raw = Double(ProcessInfo.processInfo.environment["DISKWISE_MIDSCAN_AT"] ?? "") ?? 0.35
        return min(max(raw, 0.2), 120)
    }

    /// DISKWISE_LANG_FLIP=<en|zhHans>：整套拍完后在同一个进程里当场切一次语言，
    /// 把皮肤页再拍一张。切语言不重启就得当场生效，这件事用户报过两回，
    /// 而「重启后再截图」验的是另一条路径，照不出重画有没有跟上。
    private static var languageFlip: AppLanguage? {
        AppLanguage(rawValue: ProcessInfo.processInfo.environment["DISKWISE_LANG_FLIP"] ?? "")
    }

    /// DISKWISE_WIN=1280x820：正常启动时也用这个尺寸开窗。真窗口截图要固定画幅，
    /// 而皮肤页那种长页一屏装不下。数值不合理就当没写，别打错一个字符拍出一张没用的图。
    static var requestedWindowSize: NSSize? {
        let raw = ProcessInfo.processInfo.environment["DISKWISE_WIN"] ?? ""
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, (900...2400).contains(parts[0]), (500...2600).contains(parts[1])
        else { return nil }
        return NSSize(width: parts[0], height: parts[1])
    }

    /// 截图窗口尺寸：默认 1280x820，DISKWISE_WIN 覆盖。
    private static var windowSize: NSSize {
        requestedWindowSize ?? NSSize(width: 1280, height: 820)
    }

    /// 系统那套「窗口不许高过屏幕」的钳制在这里必须关掉。
    ///
    /// 为什么是这里：`NSWindow.orderFront` 会调 `constrainFrameRect(_:to:)`，把整扇窗压回
    /// `visibleFrame`——本机 1920x1080 那屏就是 985pt，实测 `DISKWISE_WIN=1280x2600` 建出来的窗
    /// 一显示就掉回 985，长列表尾巴那几行连布局都没有，谈不上拍不拍。
    /// 关掉之后窗口保住 2600，而窗口服务器的合成图是 2560x5264（整扇窗，离屏那截有像素）——
    /// 所以「超出屏幕拍不到」从来不是合成路径的极限，是这道钳制的副作用。
    private final class SnapshotWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
            frameRect
        }
    }

    @MainActor
    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let store = AppStore()
        let manager = ThemeManager.shared
        let skinID = ProcessInfo.processInfo.environment["DISKWISE_SKIN"] ?? ""
        let skin = Theme.byID(skinID) ?? manager.effective
        // 连 `current` 一起换掉：皮肤页的「使用中」徽章读的是它，只注入渲染器会拍出一张
        // 画着晨雾、徽章却指着作者上次那套的图。不写偏好，退出后一切照旧。
        manager.useForSnapshot(skin)
        let paper = NSColor(skin.palette.paper)

        let content = ContentView()
            .environmentObject(store)
            .environmentObject(manager)
            .themed(skin)
            .preferredColorScheme(skin.scheme)
            .tint(skin.palette.tint)

        let size = windowSize
        let window = SnapshotWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        // 真窗口是 `.windowStyle(.hiddenTitleBar)`：标题带里一个字都不画。
        // 这扇手搓的 NSWindow 没那个 style，SwiftUI 每次换页写 `navigationTitle`
        // 都会把标题文字带回来——列表页于是比真机多一行页名，而且容量读数被标题
        // 挤到最右边（总览页没有标题时它在最左）。同一套界面在九张图里长出两种版面，
        // 拿去当 README 就是撒谎。这里把它钉回隐藏。
        window.titleVisibility = .hidden
        titleBarObserver = window.publisher(for: \.titleVisibility).sink { visible in
            if visible != .hidden { window.titleVisibility = .hidden }
        }

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        store.bigScanDir = bigDrillDir
        pump(3)
        // 换页之前量一次，这就是整套图的画幅。之后窗口会被内容的理想尺寸撑高（SwiftUI 的
        // ScrollView 把自己的理想高度报成内容高度），但每张图都只从内容顶部截这一块——
        // 否则一趟跑完就是五张不同尺寸的图，README 的表格直接散架。
        // 皮肤页一屏装不下，用 DISKWISE_WIN 把画幅拉高，别硬截。
        let canvas = host.bounds.size
        // 先探一次窗口服务器有没有这张窗的像素：有就走合成路径，那就没必要再摘材质层了
        // ——那些层是窗口自己合成进去的，摘掉就是真洞。问不到才退回离线画 layer 树。
        compositedCapture = windowServerImage(window) != nil
        if !compositedCapture { hideWindowServerLayers(in: window.contentView) }
        let only = Set((ProcessInfo.processInfo.environment["DISKWISE_ONLY"] ?? "")
            .split(separator: ",").map { $0.lowercased() })
        func shoot(_ name: String) {
            let path = (outDir as NSString).appendingPathComponent(name + ".png")
            var ok = false
            if let data = pngData(window, paper: paper, canvas: canvas) {
                ok = (try? data.write(to: URL(fileURLWithPath: path))) != nil
            }
            FileHandle.standardError.write(ok
                ? "    ✓ \(name).png\n".data(using: .utf8)!
                : "    ✗ \(name).png render failed\n".data(using: .utf8)!)
        }
        for (panel, name, minWait, maxWait) in pages where only.isEmpty || only.contains(String(describing: panel)) {
            store.jumpTo = panel
            if midscanPanels.contains(String(describing: panel)) {
                pump(midscanDelay)   // 只等布局，不等数据
                shoot(name + "-midscan")
            }
            waitSettled(window, paper: paper, canvas: canvas, minSeconds: minWait, maxSeconds: maxWait)
            shoot(panel == .big && bigDrillDir != nil ? name + "-drilled" : name)
            if pickPanels.contains(String(describing: panel)) {
                store.selectAllPulse += 1
                waitSettled(window, paper: paper, canvas: canvas, minSeconds: 2, maxSeconds: 12)
                shoot(name + "-selected")
                store.selectAllPulse += 1
                waitSettled(window, paper: paper, canvas: canvas, minSeconds: 2, maxSeconds: 12)
                shoot(name + "-deselected")
            }
            if panel == .overview, let drill = drillRow {
                store.overviewDrill = drill
                // 下一级是真去量的：一趟几十 G 的子树，等它静下来再拍。
                waitSettled(window, paper: paper, canvas: canvas, minSeconds: 3, maxSeconds: 180)
                shoot(name + "-drill")
            }
            if panel == .overview, let token = jumpToken {
                store.overviewJump = token
                waitSettled(window, paper: paper, canvas: canvas, minSeconds: 3, maxSeconds: 120)
                shoot(name + "-jump")
            }
            if panel == .overview, ringHooks.contains("scan") {
                slowScanFill = true
                store.overviewRing = "rescan"
                // 先等画面真的动起来（旧账清空、弧开始重新长），再让它长 1.2 秒——
                // 那时几条大弧已经落地、剩下的还在路上，圆心那句「正在量 x/y」也还在。
                var previous = pngData(window, paper: paper, canvas: canvas)
                let startBy = Date().addingTimeInterval(5)
                while Date() < startBy {
                    pump(0.15)
                    let current = pngData(window, paper: paper, canvas: canvas)
                    if current != nil && current != previous { break }
                    previous = current
                }
                pump(1.2)
                shoot(name + "-scanning")
                slowScanFill = false
                // 后面几张要在静下来的账上拍，别把半截扫描留给它们。
                waitSettled(window, paper: paper, canvas: canvas, minSeconds: 12, maxSeconds: 300)
            }
            if panel == .overview, ringHooks.contains("refuse") {
                store.overviewRing = "refuse"
                pump(1.4)
                shoot(name + "-refused")
                store.overviewRing = nil      // 那句解释跟着收，别糊到下一张上
                pump(0.4)
            }
            if panel == .overview, ringHooks.contains("arm") {
                store.overviewRing = "arm"
                pump(1.0)
                shoot(name + "-armed")
                store.overviewRing = "arm"    // 同一条弧的第二下：这才真搬
                waitSettled(window, paper: paper, canvas: canvas, minSeconds: 3, maxSeconds: 90)
                shoot(name + "-taken")
                // 拍完把演示树放回原处。这一钩子搬的是真文件，而 HOME 假目录并不接管废纸篓，
                // 于是它落在真的 ~/.Trash 里：不放回，下一趟的账会凭空少一块，
                // 而环形恒等式照样自洽——只有图会悄悄变，没人看得出来。
                // 走的是废纸篓页「撤销」那颗按钮的同一条 untrash，不是另写一遍搬文件。
                let restored = store.undoLast()
                FileHandle.standardError.write("    ↺ \(restored)\n".data(using: .utf8)!)
                // 放回之后那句「已移入废纸篓」就成了过期话，而提示条会一路挂到后面几页。
                // 撤销时界面本来也是这么换掉它的（废纸篓页那颗按钮），这里直接收掉。
                store.notice = nil
            }
        }
        if let flip = languageFlip {
            store.jumpTo = .appearance
            store.setLanguage(flip)
            waitSettled(window, paper: paper, canvas: canvas, minSeconds: 2, maxSeconds: 10)
            shoot("90-skins-after-flip-\(flip.rawValue)")
        }
        exit(0)
    }

    /// 走不走窗口服务器的合成路径，由 `run` 开头探一次决定。
    private static var compositedCapture = false

    /// 标题带「保持隐藏」的观察者。必须有个长命的东西持有它，否则观察当场就断。
    private static var titleBarObserver: AnyCancellable?

    /// 兜底路径专用：材质背景离线画就是一条黑带，拍之前摘掉。
    /// 走合成路径时不能摘——那些层是窗口自己合成进去的，摘了就是真洞。
    /// 侧边栏背景由主题自己铺，不靠这层。
    private static func hideWindowServerLayers(in view: NSView?) {
        guard let view = view else { return }
        for sub in view.subviews {
            let name = String(describing: type(of: sub))
            if name.contains("Alleyway") || name.contains("Backdrop") || name.contains("CoreHostingView") {
                sub.isHidden = true
            } else {
                hideWindowServerLayers(in: sub)
            }
        }
    }

    /// 只给 `DISKWISE_RING=scan` 那一帧用：把扫描结果回填的节拍放慢到快门跟得上。
    /// 推迟的是**什么时候显示**，不是显示什么——每个数照旧是真的量出来的。
    /// 由 scan 钩子自己开、拍完立刻关，所以别的截图和真机运行都不受影响。
    static var slowScanFill = false

    /// 截图模式是否开着（`DISKWISE_SHOTS` 有值）。
    /// 界面用它来关掉**常驻**动效：环形那两道光永续转时，`waitSettled` 永远等不到静帧，
    /// 每一张总览图都会拖到上限。关的是「一直转」，不是「有没有这道光」——
    /// 静止态该长什么样，真机和截图看到的是同一张脸。
    static var active: Bool { requestedDir != nil }

    /// 扫描是后台 Task + @MainActor 回填，拍到一半就是「Counting…」。
    /// 光看「两帧一样」不够——进度条隔几秒才动一下，静帧会骗人，所以先泡够
    /// 最短时间，再要求连续三帧完全一致；一直动的页面就泡到上限为止。
    private static func waitSettled(_ window: NSWindow, paper: NSColor, canvas: NSSize,
                                    minSeconds: Double, maxSeconds: Double) {
        pump(minSeconds)
        var previous = pngData(window, paper: paper, canvas: canvas)
        var stable = 0
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            pump(1.5)
            let current = pngData(window, paper: paper, canvas: canvas)
            if current != nil && current == previous {
                stable += 1
                // 九秒一动不动才算静下来：三帧（4.5 秒）正好落在一趟大文件哈希的中间。
                if stable >= 6 { return }
            } else {
                stable = 0
            }
            previous = current
        }
    }

    /// 优先问窗口服务器要这张窗口的合成像素，拿不到才退回离线画 layer 树。
    ///
    /// 为什么不能只用 layer.render：侧边栏的列表由 `_NSCoreHostingView` 画，
    /// 内容只存在于服务器端的合成层里，离线渲染拍出来是一片纯白（导航项全丢）。
    /// 这条路径只要自己这一扇窗，不碰别的 App，所以录屏权限掉不掉都拍得到。
    private static func pngData(_ window: NSWindow, paper: NSColor, canvas: NSSize) -> Data? {
        guard let view = window.contentView, view.bounds.width > 1 else { return nil }
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
        let full = (compositedCapture ? windowServerImage(window) : nil)
            ?? offscreenImage(view: view, paper: paper, scale: scale)
        guard let full, full.width > 0 else { return nil }
        // 整张拍完再按画幅裁顶。窗口只会因为内容变高、不会变矮，所以整张永远是页面顶部对齐的，
        // 多出来的是底部那段空白或滚出画面的行——裁掉它就等于用户把窗口缩到画幅大小时看到的样子。
        let cropH = Int(canvas.height * scale)
        let out = full.height > cropH
            ? full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: cropH)) ?? full
            : full
        let cropped = NSBitmapImageRep(cgImage: out)
        cropped.size = NSSize(width: CGFloat(out.width) / scale, height: CGFloat(out.height) / scale)
        return cropped.representation(using: .png, properties: [:])
    }

    /// 窗口服务器里这一扇窗的合成结果。`optionIncludingWindow` 只取自己这一张，
    /// 别的窗口压在上方也不会混进来。
    private static func windowServerImage(_ window: NSWindow) -> CGImage? {
        CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(window.windowNumber),
                                [.boundsIgnoreFraming, .bestResolution])
    }

    /// 兜底：自己把 layer 树画进位图。SwiftUI 的内容层由 Core Animation 画，
    /// 视图自己的 drawRect 路径里什么都没有，所以走 layer 树而不是 draw。
    private static func offscreenImage(view: NSView, paper: NSColor, scale: CGFloat) -> CGImage? {
        let px = NSSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
        guard let (ctx, rep) = bitmapContext(for: view, pixels: px) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        // 窗口圆角外、侧边栏顶到标题栏那一条本来就没像素，不铺底就是白缺口
        // ——深色皮肤下尤其难看，先按皮肤底色铺一层。
        paper.setFill()
        ctx.cgContext.fill(CGRect(origin: .zero, size: view.bounds.size))
        // layer.render 走 CG 坐标系（原点左下），不翻过来拍出来是倒的
        ctx.cgContext.translateBy(x: 0, y: view.bounds.height)
        ctx.cgContext.scaleBy(x: 1, y: -1)
        if let layer = view.layer {
            layer.render(in: ctx.cgContext)
        } else {
            view.displayIgnoringOpacity(view.bounds, in: ctx)
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }

    private static func bitmapContext(for view: NSView, pixels: NSSize)
        -> (NSGraphicsContext, NSBitmapImageRep)? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixels.width), pixelsHigh: Int(pixels.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = view.bounds.size      // 点尺寸 ↔ 像素尺寸的比例就是 Retina 倍率
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        return (ctx, rep)
    }

    /// 主循环得转起来，后台回填的结果才看得到
    private static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: min(end, Date().addingTimeInterval(0.05)))
        }
    }
}
