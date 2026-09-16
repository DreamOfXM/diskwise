#!/usr/bin/env swift
// ── 双语覆盖率闸门 ──────────────────────────────────────────────────────────
//
// 这个项目的本地化不靠 NSLocalizedString 的隐式查找：中文原文就是 key。
// 好处是漏译不会崩，退回显示中文；坏处是「漏了」这件事本身看不见。
// 所以出包前跑一遍：把源码 + 知识库 + 皮肤里所有该有英文的中文全数出来，
// 跟 en.lproj/Localizable.strings 对账。少一条就退出码 1，build.sh 直接挂。
//
//   swift build_app/l10n_tool.swift check   [包根目录]
//   swift build_app/l10n_tool.swift keys    [包根目录]   # 打印缺的 key，照着补
//
// 不参与对账的中文：注释、Swift 插值拼接（那些本来就不该进词表）、
// 以及 L10n.swift 里 `// l10n-scan: off` 圈住的量词表（英文在代码里，不在词表里）。

import Foundation

// MARK: - 配置

/// 扫这些目录下的 .swift（跳过注释与标记关闭的区间）
let swiftDirs = ["Sources/DiskCleaner", "Sources/DiskCleanerCore"]
/// 知识库：这四个字段是给人读的文案，必须条条有译文
let dbFields = ["name", "what", "whatif", "rec"]
let dbPath = "Sources/DiskCleaner/Resources/safety_db.json"
/// 皮肤名与标语同样是展示文案
let skinsPath = "Sources/DiskCleaner/Theme/Skins.swift"
let skinsFields = ["name", "tagline"]

let tablePath = "Sources/DiskCleaner/Resources/en.lproj/Localizable.strings"
let scanOff = "// l10n-scan: off"
let scanOn = "// l10n-scan: on"

// MARK: - 中文判定

func hasHan(_ s: String) -> Bool {
    for scalar in s.unicodeScalars {
        if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
            return true
        }
    }
    return false
}

// MARK: - Swift 字符串字面量切分
//
// 不用正则：字符串里可以有 \" 和 \( ) 嵌套的括号，正则迟早漏。
// 逐字符扫，遇到未转义的 " 开始，扫到下一个未转义的 " 结束。

func stringLiterals(in line: String) -> [String] {
    var out: [String] = []
    let chars = Array(line)
    var i = 0
    while i < chars.count {
        guard chars[i] == "\"" else { i += 1; continue }
        var body = ""
        var j = i + 1
        var closed = false
        var interpDepth = 0
        while j < chars.count {
            let c = chars[j]
            if c == "\\", j + 1 < chars.count {
                let n = chars[j + 1]
                if n == "(" { interpDepth += 1; body += "\\("; j += 2; continue }
                if n == "\"" { body += "\"" ; j += 2; continue }
                if n == "\\" { body += "\\" ; j += 2; continue }
                if n == "n" { body += "\n"; j += 2; continue }
                body.append(c); body.append(n); j += 2; continue
            }
            if interpDepth > 0 {
                if c == "(" { interpDepth += 1 }
                if c == ")" { interpDepth -= 1 }
                j += 1
                continue
            }
            if c == "\"" { closed = true; break }
            body.append(c)
            j += 1
        }
        if closed {
            // 带插值的字面量不是纯 key，跳过（单独在 --interp 里列出来看）
            out.append(body)
        }
        i = j + 1
    }
    return out
}

/// 这些调用的参数是量词表的查表入参（"个文件"、"项"……），不是词条。
/// 不能整行跳过——`Text(LF("%@ 项可查", cnt(n, "项")))` 这种一行里两个都有。
private let lookupCalls = ["cnt", "trashedNotice"]

func strippingLookupCalls(_ line: String) -> String {
    guard lookupCalls.contains(where: { line.contains("\($0)(") }) else { return line }
    let chars = Array(line)
    var out = ""
    var i = 0
    while i < chars.count {
        if let hit = lookupCalls.first(where: {
            chars.count - i >= $0.count + 1
                && String(chars[i..<(i + $0.count + 1)]) == "\($0)("
        }) {
            var depth = 0
            var j = i + hit.count             // 停在 "(" 上
            while j < chars.count {
                if chars[j] == "(" { depth += 1 }
                if chars[j] == ")" { depth -= 1; if depth == 0 { j += 1; break } }
                j += 1
            }
            i = j
            continue
        }
        out.append(chars[i])
        i += 1
    }
    return out
}

// MARK: - 收集

func swiftFiles(_ root: String) -> [String] {
    let fm = FileManager.default
    var out: [String] = []
    for dir in swiftDirs {
        guard let en = fm.enumerator(atPath: "\(root)/\(dir)") else { continue }
        for case let p as String in en where p.hasSuffix(".swift") {
            out.append("\(root)/\(dir)/\(p)")
        }
    }
    return out.sorted()
}

/// 返回 (纯 key 集合, 带插值的中文拼接)
func collectFromSwift(_ root: String) -> (Set<String>, [String]) {
    var keys = Set<String>()
    var interp: [String] = []
    for file in swiftFiles(root) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        var off = false
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(scanOff) { off = true; continue }
            if line.hasPrefix(scanOn) { off = false; continue }
            if line.hasPrefix("//") { continue }
            if raw.contains("// l10n-scan: skip") { continue }
            if line.hasPrefix("///") || line.hasPrefix("/*") || line.hasPrefix("*") {
                continue
            }
            if off { continue }
            for lit in stringLiterals(in: strippingLookupCalls(raw)) where hasHan(lit) {
                if lit.contains("\\(") {
                    interp.append("\(file): \(lit)")
                } else {
                    keys.insert(lit.replacingOccurrences(of: "\n", with: " "))
                }
            }
        }
    }
    return (keys, interp)
}

/// Skins.swift 里的 name:/tagline: 值——它们是展示文案，但写在数据里
func collectFromSkins(_ root: String) -> Set<String> {
    var keys = Set<String>()
    guard let text = try? String(contentsOfFile: "\(root)/\(skinsPath)", encoding: .utf8) else { return keys }
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("//") { continue }
        for f in skinsFields {
            guard line.hasPrefix("\(f):") else { continue }
            for lit in stringLiterals(in: line) where hasHan(lit) { keys.insert(lit) }
        }
    }
    return keys
}

/// 知识库里的中文说明
func collectFromDB(_ root: String) throws -> Set<String> {
    let url = URL(fileURLWithPath: "\(root)/\(dbPath)")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = obj["entries"] as? [[String: Any]] else {
        throw NSError(domain: "l10n", code: 1, userInfo: [NSLocalizedDescriptionKey: "读不了 \(dbPath)"])
    }
    var keys = Set<String>()
    for e in entries {
        for f in dbFields {
            if let s = e[f] as? String, hasHan(s) { keys.insert(s) }
        }
    }
    return keys
}

// MARK: - 读译文表
//
// 一行一条 "key" = "value"; ——我们自己维护的表就这个格式，不引第三方解析。

func readTable(_ root: String) throws -> [String: String] {
    let path = "\(root)/\(tablePath)"
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw NSError(domain: "l10n", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "找不到译文表：\(path)"])
    }
    var out: [String: String] = [:]
    for raw in text.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("/*") { continue }
        let lits = stringLiterals(in: line)
        if lits.count >= 2 { out[lits[0]] = lits[1] }
    }
    return out
}

// MARK: - 格式串体检
//
// key 和译文的位置参数必须一一对应：%1$@ 用错成 %@ 会让界面显示 "%1$@"，
// 少个参数直接是运行时崩溃。所以这条也当编译期检查用。

func specifiers(_ s: String) -> [String] {
    var out: [String] = []
    var i = s.startIndex
    while i < s.endIndex {
        guard s[i] == "%" else { i = s.index(after: i); continue }
        var j = s.index(after: i)
        var body = "%"
        while j < s.endIndex {
            let c = s[j]
            if c == "$" || c == "-" || c == "0" || c == "." || (c >= "1" && c <= "9") {
                body.append(c); j = s.index(after: j); continue
            }
            if "@dDuFfSxXc%".contains(c) { body.append(c); break }
            body.append(c); break
        }
        out.append(body)
        i = body.hasSuffix("%") ? s.index(after: j) : j
    }
    return out.filter { $0 != "%%" }
}

func checkSpecs(_ keys: Set<String>, _ table: [String: String]) -> [String] {
    var bad: [String] = []
    for k in keys.sorted() {
        let want = specifiers(k).sorted()
        guard let v = table[k] else { continue }
        let got = specifiers(v).sorted()
        if want != got {
            bad.append("  参数对不上：\(k)\n    key \(want) vs 译文 \(got)")
        }
    }
    return bad
}

// MARK: - %@ 喂整数 = 闪退
//
// String(format:) 的 %@ 只认对象，传 Swift Int 直接 EXC_BAD_ACCESS，
// 而且只在特定分支上炸（比如「有清理失败」那条提示），测试很容易漏过去。
// 这里静态扫一遍：LF 的 key 里有 %@，实参却是裸的 .count / 整数变量名，就报。

private let intLikeNames: Set<String> = ["failed", "ok", "count", "n", "index", "size"]

/// 按顶层逗号切参数（括号内与字符串内的逗号不算）
func splitArgs(_ s: String) -> [String] {
    var out: [String] = []
    var depth = 0, inStr = false, esc = false, cur = ""
    for c in s {
        if inStr {
            cur.append(c)
            if esc { esc = false }
            else if c == "\\" { esc = true }
            else if c == "\"" { inStr = false }
            continue
        }
        switch c {
        case "\"": inStr = true; cur.append(c)
        case "(", "[": depth += 1; cur.append(c)
        case ")", "]": depth -= 1; cur.append(c)
        case "," where depth == 0: out.append(cur); cur = ""
        default: cur.append(c)
        }
    }
    if !cur.trimmingCharacters(in: .whitespaces).isEmpty { out.append(cur) }
    return out
}

func checkIntFormat(_ root: String) -> [String] {
    var bad: [String] = []
    for file in swiftFiles(root) {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        for (no, raw) in text.components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            guard let start = line.range(of: "LF(") else { continue }
            // 从 LF( 的左括号起，取到配对的右括号
            let chars = Array(line[start.lowerBound...])
            guard let lparen = chars.firstIndex(of: "(") else { continue }
            var depth = 0, end = -1
            for (i, c) in chars.enumerated() {
                if c == "(" { depth += 1 }
                if c == ")" { depth -= 1; if depth == 0 { end = i; break } }
            }
            if end < 0 || end <= lparen + 1 { continue }
            let inner = String(chars[(lparen + 1)..<end])
            let args = splitArgs(inner)
            guard args.count >= 2, let key = stringLiterals(in: args[0]).first,
                  specifiers(key).contains(where: { $0.hasSuffix("@") }) else { continue }
            for arg in args.dropFirst() {
                let a = arg.trimmingCharacters(in: .whitespaces)
                let looksInt = a.hasSuffix(".count") || intLikeNames.contains(a)
                if looksInt && !a.hasPrefix("String(") {
                    let name = (file as NSString).lastPathComponent
                    bad.append("  \(name):\(no + 1)  \(a) 是整数，喂给 %@ 会闪退，包一层 String(…)")
                }
            }
        }
    }
    return bad
}

// MARK: - main

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "check"
let root = args.count > 2 ? args[2] : FileManager.default.currentDirectoryPath

let (swiftKeys, interpKeys) = collectFromSwift(root)
var need = swiftKeys.union(collectFromSkins(root))
do { try need.formUnion(collectFromDB(root)) }
catch { FileHandle.standardError.write("读取失败：\((error as NSError).description)\n".data(using: .utf8)!) ; exit(2) }

let table = (try? readTable(root)) ?? [:]
let tableKeys = Set(table.keys)
let missing = need.subtracting(tableKeys).sorted()
let unused = tableKeys.subtracting(need).sorted()

switch mode {
case "keys":
    for k in missing { print("\"\(k)\"\n    = \"\";") }

case "interp":
    for k in interpKeys.sorted() { print(k) }

default:
    print("词条：需要 \(need.count)，已有 \(table.count)，缺 \(missing.count)，冗余 \(unused.count)")
    if !missing.isEmpty {
        print("\n缺译文（\(missing.count) 条）：")
        for k in missing.prefix(400) { print("  \(k)") }
    }
    let specBad = checkSpecs(need, table)
    if !specBad.isEmpty {
        print("\n位置参数不匹配（\(specBad.count) 条）：")
        for m in specBad { print(m) }
    }
    let intBad = checkIntFormat(root)
    if !intBad.isEmpty {
        print("\n%@ 收到整数，运行时会闪退（\(intBad.count) 条）：")
        for m in intBad { print(m) }
    }
    if !unused.isEmpty {
        print("\n表里有、源码已不用的 key（\(unused.count) 条，删掉即可）：")
        for k in unused.prefix(60) { print("  \(k)") }
    }
    if missing.isEmpty && specBad.isEmpty && intBad.isEmpty {
        print("双语覆盖完整 ✓")
        exit(0)
    }
    exit(1)
}
