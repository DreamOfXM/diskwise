// 测试台：把某个程序窗口里每个可点元素的「命中框」和标题打出来。
// 用系统辅助功能接口，不依赖被测程序里的任何埋点——已安装的正式版也能量。
import AppKit
import ApplicationServices

let pid = Int32(CommandLine.arguments[1]) ?? 0
let onlyColumn = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) : nil  // 只看 x 小于此值的（侧栏）
let top = CGFloat(NSScreen.screens.first?.frame.height ?? 0)
func attr(_ e: AXUIElement, _ k: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func kids(_ e: AXUIElement) -> [AXUIElement] {
    (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}
func describe(_ e: AXUIElement) -> String {
    let role = (attr(e, kAXRoleAttribute) as? String) ?? "?"
    var label = (attr(e, kAXTitleAttribute) as? String) ?? ""
    if label.isEmpty { label = (attr(e, kAXDescriptionAttribute) as? String) ?? "" }
    if label.isEmpty { label = (attr(e, kAXValueAttribute) as? String) ?? "" }
    var frame = "无框"
    if let av = attr(e, kAXPositionAttribute), let sv = attr(e, kAXSizeAttribute),
       CFGetTypeID(av) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID() {
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(av as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &s)
        frame = String(format: "屏顶向下 y %.0f..%.0f 中心 %.0f｜x %.0f 宽 %.0f", p.y, p.y + s.height, p.y + s.height / 2, p.x, s.width)
    }
    return "\(role) 「\(label.prefix(18))」 \(frame)"
}
var buttons: [String] = []
func walk(_ e: AXUIElement, depth: Int) {
    let role = (attr(e, kAXRoleAttribute) as? String) ?? "?"
    if role == "AXButton" || role == "AXCell" || role == "AXRow" {
        let d = describe(e)
        if let lim = onlyColumn, d.contains("x ") {
            // 只保留侧栏那一列（x 落在给定阈值左侧）
            let parts = d.components(separatedBy: "｜x ")
            if parts.count > 1, let x = Double(parts[1].split(separator: " ").first.map(String.init) ?? "") , x > lim { return }
        }
        buttons.append(String(repeating: "  ", count: min(depth, 6)) + d)
    }
    if depth < 24 { for c in kids(e) { walk(c, depth: depth + 1) } }
}
let app = AXUIElementCreateApplication(pid)
for w in kids(app) { walk(w, depth: 0) }
print("共 \(buttons.count) 个可点元素（角色 AXButton/AXCell/AXRow）")
for b in buttons.prefix(60) { print(b) }
