import SwiftUI
import AppKit

// ── Esc 撤下膛 ───────────────────────────────────────────────────────────────
//
// 总览那两下确认（第一下上膛、第二下才搬）对外承诺过三条退路：点别处、换一段、
// 按 Esc。前两条是鼠标的事，第三条得有人接。这一层就是接那一条的。
//
// **为什么用 `NSEvent.addLocalMonitorForEvents` 而不是 `.onExitCommand`**：
// 同一扇窗里此刻有两件事都想接 Esc——清理说明那四页（它用的是 `.onExitCommand`）
// 和刚上膛的那段弧。SwiftUI 那条走的是 first responder 链，谁先接住取决于焦点
// 当时停在哪颗按钮上，而翻页会挪焦点。判据不能建在「大概会先给模态那一层」上。
// 另一条硬约束：macOS 13 没有 `.onKeyPress`（那是 14 才有的），纯 SwiftUI 这一层
// 连方向键都递不进来，为一条 Esc 再引一套 AppKit 反而更省。
//
// **只旁听，不吞**：回调永远把事件原样还回去。吞掉的话，同一扇窗里那条
// `.onExitCommand`（关掉清理说明）会跟着一起断——两件事都要能发生。
// 于是「撤膛」和「关说明」不是二选一：Esc 按下去，两样各退一步。
//
// **量过的**：这一枚挂在窗口背景上，同一次构建里开/关各拍一张总览
// （1280×852、dawn、演示账），两张 `01-overview.png` md5 相同（`1f01a034…`）——
// 0×0 的接收器一个像素都不动，环形那套 md5 闸门照旧。
//
// **没量到的那一环**：截图链路没有键鼠，「按下 Esc 之后监视器收不收得到」这一跳
// 只能按 AppKit 的规矩认。被调到的那件事本身早有证据：`disarm()` 画的正是 3.2 秒
// 自动解除那一下（`01-overview-disarmed.png`），Esc 走的是同一个入口。

/// 挂在窗口背景上的一枚隐形按键接收器。
struct EscapeTap: View {
    /// 只在主线程被调（本地监视器的回调就在主运行循环上 fire）。
    let onEscape: () -> Void

    var body: some View {
        Host(onEscape: onEscape)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }

    private struct Host: NSViewRepresentable {
        let onEscape: () -> Void

        func makeCoordinator() -> Coordinator { Coordinator() }

        func makeNSView(context: Context) -> NSView {
            context.coordinator.install(onEscape)
            return NSView(frame: .zero)
        }

        func updateNSView(_ nsView: NSView, context: Context) {
            // 视图重建时闭包会换一份（它捕获的是 `scans`，那一层是 StateObject，
            // 实际上不会变），这里跟着换指针就够了：监视器只装一次，不重装。
            context.coordinator.box.action = onEscape
        }

        /// 动作放在外面这一层，而不是让监视器的回调去抓 `Coordinator`：
        /// 抓了就是「协调器 → 票据 → 回调 → 协调器」一个环，`deinit` 永不触发，
        /// 拆窗时那条监视器会留在系统里继续响。
        final class Box {
            var action: (() -> Void)?
        }

        final class Coordinator {
            let box = Box()
            private var token: Any?

            /// 本地监视器只在 App 在前台、事件进自己这条响应链时响——正是「人在这扇窗里
            /// 按 Esc」这一件事的定义。全局监视器要辅助功能授权，这里不需要，也不该要。
            func install(_ f: @escaping () -> Void) {
                // 先把它取成局部量再进闭包：闭包里直接写 `box.action` 会连 `self` 一起抓住，
                // 又绕回上面说的那个环。
                let box = self.box
                box.action = f
                guard token == nil else { return }
                token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { ev in
                    // 53 = esc。读键码不读字符：⌥Esc、⇧Esc 的字符会变，键码不变。
                    guard ev.keyCode == 53, let f = box.action else { return ev }
                    f()
                    return ev
                }
            }

            deinit { if let token { NSEvent.removeMonitor(token) } }
        }
    }
}
