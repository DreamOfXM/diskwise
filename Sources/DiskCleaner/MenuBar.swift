import AppKit
import DiskCleanerCore

// ── 菜单栏那颗容量读数（稿子③）──────────────────────────────────────────────
//
// 取数沿用窗口标题栏那颗 `VolumeChip` 走的同一条路：`volumeUsage()` 问一次、
// 每 5 秒问一次，不另开口径——稿子的判据是「菜单栏与窗口在同一秒读出来一致」，
// 两条取数路迟早对不齐，而这类工具卖的就是数字可信。
//
// 不做常驻：状态项跟着进程活，App 没开就没有这一条。稿子①那一屏的第二格
// （开机时启动）才是把它带到开机之后的唯一途径。
// 量不到时只留图标不留数：写 0 是谎报「这盘空了」，写「未知」是给一桩还没发生的
// 事占一格——与侧栏那列容量同一套口径。

@MainActor
final class MenuBar: NSObject {
    static let readout = MenuBar()

    private var item: NSStatusItem?
    private var timer: Timer?

    override init() {}

    func apply(shows: Bool) {
        shows ? install() : remove()
    }

    private func install() {
        guard item == nil else { refresh(); return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = status.button {
            button.image = NSImage(systemSymbolName: "internaldrive",
                                   accessibilityDescription: L("可用"))
            button.imagePosition = .imageLeading
            button.font = NSFont.menuFont(ofSize: 0)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        status.menu = menu
        item = status
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { _ in
            Task { @MainActor in MenuBar.readout.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func remove() {
        timer?.invalidate()
        timer = nil
        if let item { NSStatusBar.system.removeStatusItem(item) }
        self.item = nil
    }

    private func refresh() {
        guard let item, let menu = item.menu else { return }
        let usage = volumeUsage()
        item.button?.title = usage.map { " " + human($0.available) } ?? ""
        menu.removeAllItems()
        if let u = usage {
            menu.addItem(Self.info(LF("整块盘 %1$@ · 已用 %2$@", human(u.total), human(u.used))))
            menu.addItem(Self.info(LF("可用 %@", human(u.available))))
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: Product.name, action: #selector(focusMain), keyEquivalent: "")
        open.target = self
        open.isEnabled = true
        menu.addItem(open)
    }

    private static func info(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// 已有窗口就带到前面；一个都没有时只把 App 激活，
    /// 剩下的交给系统在点击 Dock 图标时补——这里不自己造窗口，也不硬调私有选择器。
    @objc private func focusMain() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
