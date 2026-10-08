import Foundation

// 大小参数解析：500MB / 2GB / 1.5GB / 纯字节数。
// 十进制（1 GB = 10^9），与 App、访达「显示简介」同一口径——同一台机器上
// 两种进制会让「100MB 阈值」悄悄变成 104.9MB，没人对得出来。

enum SizeArgError: Error, CustomStringConvertible {
    case bad(String)

    var description: String {
        switch self {
        case .bad(let s): return "cannot parse size '\(s)' (examples: 500MB, 2GB, 1.5GB, 1048576)"
        }
    }
}

func parseSize(_ raw: String) throws -> Int64 {
    let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
    guard !s.isEmpty else { throw SizeArgError.bad(raw) }
    var digits = ""
    var unit = ""
    var seenDot = false
    for ch in s {
        if ch.isNumber {
            digits.append(ch)
        } else if ch == "." && !seenDot && !digits.isEmpty {
            seenDot = true
            digits.append(ch)
        } else {
            unit = String(s[s.firstIndex(of: ch)!...])
            break
        }
    }
    let scale: Double
    switch unit {
    case "", "b": scale = 1
    case "kb": scale = 1_000
    case "mb": scale = 1_000_000
    case "gb": scale = 1_000_000_000
    case "tb": scale = 1_000_000_000_000
    default: throw SizeArgError.bad(raw)
    }
    guard let v = Double(digits), v >= 0, v.isFinite else { throw SizeArgError.bad(raw) }
    return Int64((v * scale).rounded())
}
