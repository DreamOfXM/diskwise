import SwiftUI
import AppKit

// ── 按住空格：预演「全部清空之后」────────────────────────────────────────────
//
// 设计稿③那一整块（稿上标的 6/10/11/12）说的是同一件事：**按住**空格，这一屏从
// 「现在能收走多少」换成「全收走之后有多少」，松手就回去。它不是又一个按钮，
// 而是一档只在你按着的时候存在的读法——所以它要的是一只**能收到 keyUp** 的接收器。
//
// 为什么用 `NSEvent.addLocalMonitorForEvents` 而不是 `.keyboardShortcut(.space)`：
// 快捷键只有 keyDown，没有「松手」这一说；SwiftUI 到 macOS 14 才有 `.onKeyPress`，
// 而这一层要同时接住按下与松开。同一条理由见 `EscapeTap.swift`（Esc 那只）。
//
// **这一只吞事件，与 `EscapeTap` 相反**。Esc 不能吞，因为同一扇窗里还有
// `.onExitCommand` 在等同一个键；空格不一样——它落下去本来会去**按下当前聚焦的那颗
// 按钮**（AppKit 的规矩：空格 = 按下默认按钮/被聚焦的按钮），而这一屏上那些按钮是
// 「移进废纸篓」。一边预演「全部清空之后」，一边真把东西搬进废纸篓，是这一层最不能
// 放过去的一件事。所以命中空格的那一发 keyDown 返回 nil。
//
// 让出去的那两种情形，都在让之前先看过：
// 1. 焦点在文本框里（反馈页、路径输入）——空格是内容，不是命令；
// 2. 带着 ⌘//⌃/⇧ ——那是别人的组合键（⌥空格要打不换行空格），不是这一档。
//
// **量到与没量到的**：预演这一档的**画面**有静图（`DISKWISE_RING=preview` 落进真那条
// 入口 `holdPreview()`，再发 `previewoff` 走 `endPreview()` 拍退干净那一张，
// 见 `01-overview-preview.png` / `01-overview-previewback.png`）；它的**代价**也有配对
// 测量（`DISKWISE_PREVIEW=on` 把这一档钉住整趟）。没量到的只有一跳：「按下空格之后
// 监视器收不收得到」——截图链路没有键鼠，这台机器上也没有辅助功能授权去合成按键
// （同 `EscapeTap` 记着的限制）。所以键本身在这一环境里证不了，只能由人自己按一次。

/// 挂在窗口背景上的一枚隐形空格接收器：按住 = 进预演，松开 = 回档。
struct SpaceHoldTap: View {
    let onHold: () -> Void
    let onRelease: () -> Void

    var body: some View {
        Host(onHold: onHold, onRelease: onRelease)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Host: NSViewRepresentable {
        let onHold: () -> Void
        let onRelease: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            context.coordinator.install(onHold: onHold, onRelease: onRelease)
            return NSView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            context.coordinator.box.swap(onHold: onHold, onRelease: onRelease)
        }

        /// 动作放在外面这一层，理由同 `EscapeTap`：回调直接抓 `Coordinator` 会成环，
        /// `deinit` 不触发，拆窗之后那只监视器会留在系统里继续响。
        final class Box {
            var hold: (() -> Void)?
            var release: (() -> Void)?
            func swap(onHold: @escaping () -> Void, onRelease: @escaping () -> Void) {
                hold = onHold
                release = onRelease
            }
        }

        final class Coordinator {
            let box = Box()
            private var token: Any?

            func install(onHold: @escaping () -> Void, onRelease: @escaping () -> Void) {
                let box = self.box
                box.swap(onHold: onHold, onRelease: onRelease)
                guard token == nil else { return }
                token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { ev in
                    guard ev.keyCode == 49, Self.freeSpace(ev) else { return ev }
                    if ev.type == .keyDown {
                        // 按住不放会来连发：每一发都进一次预演等于每 30 ms 发一轮整页变更。
                        // 连发只当第一发，其余吞掉。
                        if !ev.isARepeat, let f = box.hold { f() }
                        return nil
                    }
                    box.release?()
                    return ev
                }
            }

            /// 这一发空格归不归这一档：不带修饰键，且焦点不在文本框里。
            private static func freeSpace(_ ev: NSEvent) -> Bool {
                if ev.modifierFlags.intersection([.command, .option, .control, .shift]) != [] {
                    return false
                }
                // 判据读类名而不是 `r is NSTextView`：AppKit 的字段编辑器（打字的时候
                // 真正接住键盘的那一枚）不总是响应链上被叫作 NSTextView 的那一个，
                // 而它和 SwiftUI `TextField` 的宿主控件类名里都带着这两个字串之一。
                // 认名字比认继承多覆盖一种，且写在这里看得见、错了看得穿。
                if let r = ev.window?.firstResponder {
                    let name = NSStringFromClass(type(of: r))
                    if name.contains("TextView") || name.contains("FieldEditor") { return false }
                }
                return true
            }

            deinit { if let token { NSEvent.removeMonitor(token) } }
        }
    }
}
