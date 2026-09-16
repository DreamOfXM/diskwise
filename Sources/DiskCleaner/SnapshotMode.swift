import AppKit
import SwiftUI

// ── 截图模式：DISKWISE_SHOTS=<目录> 时启用，渲染完就退出 ─────────────────────
//
// 为什么不用系统截图：README 的图要能复现，而录屏权限一掉就只拍到黑屏。
// 这里自己画——开一个真窗口，把每一页的 layer 树拍成 PNG。
//
// 必须配 DISKWISE_HOME_SHIM（见 build_app/make_demo_home.sh）：
// 总览页会把 ~/Desktop、~/Documents 连同体积原样晒出去，那是隐私不是演示。
//
// DISKWISE_SKIN=<皮肤 id> 指定用哪套皮肤拍。注意这只是给渲染器注入 Theme，
// 不碰购买状态——付费皮肤在正常启动路径里依然要解锁才能穿上。
//
// 用法（两语言 × 多皮肤，逐页出图）：
//   defaults write com.dreamofxm.diskcleaner diskcleaner.language en
//   DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome DISKWISE_SHOTS=/tmp/shots/en-dawn \
//     DISKWISE_SKIN=dawn ./build_app/DiskWise.app/Contents/MacOS/DiskCleaner
// 只拍某几页（定位问题不必重跑全套）：再加 DISKWISE_ONLY=overview,dup

enum SnapshotMode {
    static var requestedDir: String? {
        let raw = ProcessInfo.processInfo.environment["DISKWISE_SHOTS"] ?? ""
        guard !raw.isEmpty else { return nil }
        return (raw as NSString).expandingTildeInPath
    }

    /// (页面, 文件名, 最少先等, 最多等到扫描静下来)
    private static let pages: [(AppPanel, String, Double, Double)] = [
        (.overview, "01-overview", 12, 40),
        (.big, "02-big-files", 10, 40),
        (.old, "03-old-files", 10, 40),
        (.dup, "04-duplicates", 12, 60),
        (.nodemodules, "05-node-modules", 12, 60),
        (.docker, "06-docker", 8, 30),
        (.caches, "07-caches", 12, 60),
        (.orphans, "08-leftovers", 12, 60),
        (.trash, "09-trash", 6, 20),
        (.appearance, "10-skins", 4, 15),
    ]

    @MainActor
    static func run(outDir: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let store = AppStore()
        let manager = ThemeManager.shared
        let skinID = ProcessInfo.processInfo.environment["DISKWISE_SKIN"] ?? ""
        let skin = Theme.byID(skinID) ?? manager.effective
        let paper = NSColor(skin.palette.paper)

        let root = ContentView()
            .environmentObject(store)
            .environmentObject(manager)
            .themed(skin)
            .preferredColorScheme(skin.scheme)
            .tint(skin.palette.tint)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        pump(3)
        hideWindowServerLayers(in: window.contentView)
        let only = Set((ProcessInfo.processInfo.environment["DISKWISE_ONLY"] ?? "")
            .split(separator: ",").map { $0.lowercased() })
        for (panel, name, minWait, maxWait) in pages where only.isEmpty || only.contains(String(describing: panel)) {
            store.jumpTo = panel
            waitSettled(window, paper: paper, minSeconds: minWait, maxSeconds: maxWait)
            let path = (outDir as NSString).appendingPathComponent(name + ".png")
            var ok = false
            if let data = pngData(window, paper: paper) {
                ok = (try? data.write(to: URL(fileURLWithPath: path))) != nil
            }
            FileHandle.standardError.write(ok
                ? "    ✓ \(name).png\n".data(using: .utf8)!
                : "    ✗ \(name).png render failed\n".data(using: .utf8)!)
        }
        exit(0)
    }

    /// 窗口服务器专属的那几层：材质背景离屏渲染就是一条黑带，拍之前摘掉。
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
    private static func waitSettled(_ window: NSWindow, paper: NSColor, minSeconds: Double, maxSeconds: Double) {
        pump(minSeconds)
        var previous = pngData(window, paper: paper)
        var stable = 0
        let deadline = Date().addingTimeInterval(maxSeconds)
        while Date() < deadline {
            pump(1.5)
            let current = pngData(window, paper: paper)
            if current != nil && current == previous {
                stable += 1
                if stable >= 3 { return }
            } else {
                stable = 0
            }
            previous = current
        }
    }

    /// 只拍内容区：窗口边框视图会在圆角外留一圈黑。
    /// 走 layer 树——SwiftUI 的内容层是 Core Animation 画的，
    /// 视图自己的 drawRect 路径里什么都没有。
    private static func pngData(_ window: NSWindow, paper: NSColor) -> Data? {
        guard let view = window.contentView, view.bounds.width > 1 else { return nil }
        view.layoutSubtreeIfNeeded()
        let scale = window.backingScaleFactor
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
        guard rep.pixelsWide > 0 else { return nil }
        return rep.representation(using: .png, properties: [:])
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
