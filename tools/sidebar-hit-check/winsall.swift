// 测试台：列出所有窗口（含不在屏上的），按进程 id 过滤。
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) ?? 0 : 0)
if let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid else { continue }
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        print("win \(w[kCGWindowNumber as String] as? Int ?? -1) 层\(w[kCGWindowLayer as String] as? Int ?? -999) x \(Int(b["X"] ?? 0)) y \(Int(b["Y"] ?? 0)) 宽 \(Int(b["Width"] ?? 0)) 高 \(Int(b["Height"] ?? 0)) 「\(w[kCGWindowName as String] as? String ?? "")」")
    }
}
