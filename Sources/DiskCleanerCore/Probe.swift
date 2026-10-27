import Foundation

// MARK: - 内容探针与归属（PR-3）
//
// 设计出处：plans/design-diagnostic-dumps-velocity-provenance-2026-10-27.md §5，
// 评审修订 §2.3：探针默认关闭、只读崩溃转储文件头 64KB、结果仅存本机、展示默认脱敏。
// 这是对 PRIVACY.md「不读文档内容」承诺的显式放宽，承诺文本已随本 PR 同步改写。

/// 内容探针。只读文件头，不做完整 minidump 解析——v1 要的只是
/// 「崩溃进程是谁」这一句旁证，不是事故报告。
public protocol ContentProbe {
    var maxReadBytes: Int { get }
    func probe(_ url: URL) -> ProbeResult
}

public struct ProbeResult: Equatable {
    /// false = 未探测（文件超限/格式不符/读不动），诚实展示，绝不装结论
    public let probed: Bool
    public let executablePath: String?
    /// 发起源指纹（键值原文，展示前统一脱敏）
    public let originHints: [String]

    public init(probed: Bool, executablePath: String? = nil, originHints: [String] = []) {
        self.probed = probed
        self.executablePath = executablePath
        self.originHints = originHints
    }
}

/// Crashpad minidump 探针：校验 MDMP 魔数，strings 扫描 executable_path 与环境指纹键。
public struct CrashpadProbe: ContentProbe {
    public let maxReadBytes = 64 * 1024
    /// 指纹键的后缀约定：撞上就当发起源线索收下，值展示前打码
    static let hintSuffixes = ["_SESSION_ID=", "_TOOL_CALL_ID="]
    static let bundleKey = "CFBundleIdentifier="

    public init() {}

    public func probe(_ url: URL) -> ProbeResult {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return ProbeResult(probed: false) }
        defer { try? fh.close() }
        let data = (try? fh.read(upToCount: maxReadBytes)) ?? Data()
        guard data.count >= 4 else { return ProbeResult(probed: false) }
        // 魔数校验防误伤：不是 minidump 的文件（哪怕是用户误放进来的）一律「未探测」
        guard data.prefix(4) == Data("MDMP".utf8) else { return ProbeResult(probed: false) }

        let bytes = [UInt8](data)
        var exe: String?
        if let r = find("executable_path=", in: bytes) {
            exe = readToken(in: bytes, from: r.end)
        }
        var hints: [String] = []
        for suffix in Self.hintSuffixes {
            if let r = find(suffix, in: bytes) {
                // 键名 = 从等号处往前回溯的大写段（如 CODEBUDDY）＋ 命中的后缀段（_SESSION_ID）
                let back = readKey(in: bytes, before: r.start) ?? ""
                if let val = readToken(in: bytes, from: r.end), !back.isEmpty {
                    hints.append("\(back)\(suffix)\(val)")
                }
            }
        }
        if let r = find(Self.bundleKey, in: bytes) {
            if let val = readToken(in: bytes, from: r.end) {
                hints.append("CFBundleIdentifier=\(val)")
            }
        }
        return ProbeResult(probed: true, executablePath: exe, originHints: hints)
    }

    private struct Range { let start: Int; let end: Int }

    private func find(_ needle: String, in bytes: [UInt8]) -> Range? {
        let n = Array(needle.utf8)
        guard !n.isEmpty, bytes.count >= n.count else { return nil }
        for i in 0...(bytes.count - n.count) {
            var ok = true
            for j in 0..<n.count where bytes[i + j] != n[j] { ok = false; break }
            if ok { return Range(start: i, end: i + n.count) }
        }
        return nil
    }

    /// 从某处读一个「路径/值」token：到 NUL、换行或控制字符为止
    private func readToken(in bytes: [UInt8], from start: Int) -> String? {
        var out: [UInt8] = []
        var i = start
        while i < bytes.count, bytes[i] >= 0x20, bytes[i] != 0x7F {
            out.append(bytes[i])
            i += 1
            if out.count > 512 { break }   // 路径没有半 KB 长的，超了就是扫进了垃圾
        }
        let s = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    /// 从键值等号处往回读全大写/数字/下划线组成的键名（CODEBUDDY_SESSION_ID 这种）
    private func readKey(in bytes: [UInt8], before end: Int) -> String? {
        var i = end
        while i > 0 {
            let c = bytes[i - 1]
            if (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 { i -= 1 } else { break }
        }
        let s = String(decoding: bytes[i..<end], as: UTF8.self)
        return s.isEmpty ? nil : s
    }
}

/// 一条目的归属结算：目录归属 × 内容归属。
public struct AttributionOutcome: Equatable {
    public let directoryOwner: String?
    public let contentOwner: String?
    public let mixed: Bool
    public let probed: Bool
    public let samples: Int
    /// 已脱敏的发起源指纹（KEY=d5•••3f 形态），仅本地展示
    public let redactedHints: [String]

    public var crossAttribution: Bool {
        guard let content = contentOwner, let dir = directoryOwner else { return false }
        return !content.isEmpty && !dir.isEmpty
            && !content.localizedCaseInsensitiveContains(dir)
    }
}

/// 抽样策略：最新 3 + 最旧 1 + 随机 1（设计稿屏③）。文件不足 5 个就全抽。
public func probeSampleFiles(under dirs: [URL], limit: Int = 5) -> [URL] {
    let fm = FileManager.default
    var files: [(url: URL, mtime: Date)] = []
    for d in dirs {
        guard let names = try? fm.contentsOfDirectory(atPath: d.path) else { continue }
        for n in names where (n as NSString).pathExtension.lowercased() == "dmp" {
            let u = d.appendingPathComponent(n)
            var st = stat()
            guard lstat(u.path, &st) == 0 else { continue }
            files.append((u, Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))))
        }
    }
    guard files.count > limit else { return files.map(\.url) }
    files.sort { $0.mtime > $1.mtime }
    var picked = Array(files.prefix(3).map(\.url))
    picked.append(files[files.count - 1].url)
    if let rand = files.dropFirst(3).dropLast().randomElement()?.url { picked.append(rand) }
    return picked
}

/// 结算归属：样本全一致才出「内容归属」；不一致标「混合来源」；一个都没探上就是未探测。
public func resolveAttribution(directoryOwner: String?, results: [ProbeResult]) -> AttributionOutcome {
    let probed = results.filter(\.probed)
    guard !probed.isEmpty else {
        return AttributionOutcome(directoryOwner: directoryOwner, contentOwner: nil, mixed: false,
                                  probed: false, samples: 0, redactedHints: [])
    }
    let owners = Set(probed.compactMap(\.executablePath).map { ownerName(of: $0) })
    let mixed = owners.count > 1
    let hints = Array(Set(probed.flatMap(\.originHints))).sorted()
    return AttributionOutcome(directoryOwner: directoryOwner,
                              contentOwner: owners.first,
                              mixed: mixed,
                              probed: true,
                              samples: probed.count,
                              redactedHints: hints.map(redactHint))
}

/// 路径 → 进程名：最后一段去掉 .app 外壳的话取包名，否则取可执行名
public func ownerName(of executablePath: String) -> String {
    let url = URL(fileURLWithPath: executablePath)
    var parts = url.pathComponents.filter { !$0.isEmpty && $0 != "/" }
    if let idx = parts.lastIndex(where: { $0.hasSuffix(".app") }) {
        return parts[idx].replacingOccurrences(of: ".app", with: "")
    }
    if let last = parts.popLast(), !last.isEmpty { return last }
    return executablePath
}

/// 指纹脱敏：值只留头 2 尾 2，中间打点。防的是截图外泄，不是防本机阅读。
public func redactHint(_ hint: String) -> String {
    guard let eq = hint.firstIndex(of: "=") else { return hint }
    let key = String(hint[hint.startIndex..<eq])
    let val = String(hint[hint.index(after: eq)...])
    guard val.count > 4 else { return "\(key)=••••" }
    let head = val.prefix(2)
    let tail = val.suffix(2)
    return "\(key)=\(head)••••\(tail)"
}

/// 探针总开关。默认关——隐私承诺的边界在这（PRIVACY.md「读什么」随本键同步改写）。
public func diagnosticProbeEnabled() -> Bool {
    UserDefaults.standard.object(forKey: "diagnosticProbeEnabled") as? Bool ?? false
}
