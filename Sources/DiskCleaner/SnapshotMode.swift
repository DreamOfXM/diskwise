import AppKit
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
// 皮肤页那种长页要一次装下六张卡：再加 DISKWISE_WIN=1280x920（默认 1280x820）。
// 注意走合成路径时窗口必须放得下屏幕，超出屏幕的那一截拍不到。
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

    /// (页面, 文件名, 最少先等, 最多等到扫描静下来)
    ///
    /// 哈希大文件的那几页要给足预算：一趟 640 MB 的全量哈希能安静好几秒，
    /// 画面在这段时间里一动不动，光靠「连续 N 帧一致」会在扫描中途收工。
    /// 实测过一张少算一份副本的重复文件页（3 份报成 2 份）。
    private static let pages: [(AppPanel, String, Double, Double)] = [
        (.overview, "01-overview", 12, 60),
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        let host = NSHostingView(rootView: content)
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
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
            waitSettled(window, paper: paper, canvas: canvas, minSeconds: minWait, maxSeconds: maxWait)
            shoot(name)
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
