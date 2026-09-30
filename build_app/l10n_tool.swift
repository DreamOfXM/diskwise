#!/usr/bin/env swift
// ── 多语言覆盖率闸门 ────────────────────────────────────────────────────────
//
// 这个项目的本地化不靠 NSLocalizedString 的隐式查找：中文原文就是 key。
// 好处是漏译不会崩，退回显示中文；坏处是「漏了」这件事本身看不见。
// 所以出包前跑一遍：把源码 + 知识库 + 皮肤里所有该有译文的中文全数出来，
// 跟 Resources 下每一张 <语言>.lproj/Localizable.strings 逐一对账。
// 任何一门语言少一条、或位置参数对不上，退出码就是 1，build.sh 直接挂。
//
// 语言清单来自目录本身（见 availableLanguages）——没有第二份需要同步的名单。
//
//   swift build_app/l10n_tool.swift check   [包根目录]
//   swift build_app/l10n_tool.swift keys    [包根目录] [语言]   # 打印这门语言缺的 key
//   swift build_app/l10n_tool.swift interp  [包根目录]          # 列出带插值的中文拼接
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
/// 皮肤名与标语同样是展示文案，现在住在 skins.json 里
let skinsPath = "Sources/DiskCleaner/Resources/skins.json"
let skinsFields = ["name", "tagline"]

/// 词表根目录。下面每一个 *.lproj 都是一门已接入的语言，逐张对账。
let resourcesDir = "Sources/DiskCleaner/Resources"
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

/// skins.json 里的 name / tagline。跟知识库一个道理：写在数据里，但也是给人读的文案。
func collectFromSkins(_ root: String) -> Set<String> {
    var keys = Set<String>()
    let url = URL(fileURLWithPath: "\(root)/\(skinsPath)")
    guard let data = try? Data(contentsOf: url),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = obj["skins"] as? [[String: Any]] else { return keys }
    for skin in list {
        for f in skinsFields {
            if let s = skin[f] as? String, hasHan(s) { keys.insert(s) }
        }
    }
    return keys
}

/// Sources/DiskCleaner/Resources 下的 *.lproj，就是这份 App 会加载的全部语言。
/// 目录本身就是登记表：加一门语言 = 建一个 <语言>.lproj，这里自动发现，
/// 不必再维护第二份清单——两份清单迟早对不上。
///
/// 只认带 Localizable.strings 的目录：zh-Hans.lproj 只有 InfoPlist.strings
/// （中文是源码原文，不需要一份自己译自己的词表），它不是一门「要翻译的语言」。
func availableLanguages(_ root: String) -> [String] {
    let dir = "\(root)/\(resourcesDir)"
    let items = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    return items.filter { $0.hasSuffix(".lproj") }
        .filter { FileManager.default.fileExists(atPath: "\(dir)/\($0)/Localizable.strings") }
        .map { String($0.dropLast(".lproj".count)) }
        .sorted()
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

func err(_ msg: String) -> NSError {
    NSError(domain: "l10n", code: 3, userInfo: [NSLocalizedDescriptionKey: msg])
}

func readTable(_ path: String) throws -> [String: String] {
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
    // 行扫描器不看分号：漏一个分号，运行时整张表都读不出来，界面全体退回中文，
    // 而覆盖率照样报「完整」。所以再用 App 同款解析器过一遍，条数必须对得上。
    let strict = (try? PropertyListSerialization.propertyList(
        from: Data(text.utf8), options: [], format: nil)) as? [String: String]
    if strict == nil {
        throw err("译文表解析失败：\(path)——多半是某行漏了分号或引号")
    }
    if strict!.count != out.count {
        throw err("译文表只解析出 \(strict!.count) 条，行扫描看到 \(out.count) 条——某行漏了结尾的分号")
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
        if mixedSpecs(k) {
            bad.append("  带序号和普通参数混用：\(k)\n    一条串里只要有一个 %1$@，其余参数也必须带序号")
            continue
        }
        guard let v = table[k] else { continue }
        let got = specifiers(v).sorted()
        if want != got {
            bad.append("  参数对不上：\(k)\n    key \(want) vs 译文 \(got)")
        }
        if mixedSpecs(v) {
            bad.append("  译文混用带序号与普通参数：\(k)\n    \(v)")
        }
    }
    return bad
}

/// 带序号的参数（`%1$d`）和普通的（`%d`、`%@`）不能出现在同一条串里：
/// CFString 解析时会直接崩（实测 EXC_BAD_ACCESS，且只在走到那条分支时崩，
/// 演示数据常常凑不齐触发条件——总览页「展开其余 N 处」就是这么漏过去的）。
func mixedSpecs(_ s: String) -> Bool {
    let specs = specifiers(s)
    return specs.contains { $0.contains("$") } && specs.contains { !$0.contains("$") }
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

/// 把格式串里的占位符按 C 的规则对上实参：带序号的（`%2$@`）直接数序号，
/// 不带的按出现顺序吃下一个。只有对上 `%@` 的那一个实参是裸整数才算闪退。
/// 以前这里不看位置，`("第 4 到 %1$d 行 %2$@", count, human(x))` 被误报成会炸——
/// 误报攒多了，这道闸门就没人信了。
func boundArgs(key: String, args: [String]) -> [(spec: String, arg: String)] {
    let params = Array(args.dropFirst())
    var out: [(spec: String, arg: String)] = []
    var next = 0
    for spec in specifiers(key) {
        let idx: Int
        if let dollar = spec.firstIndex(of: "$") {
            idx = (Int(spec[spec.index(after: spec.startIndex)..<dollar]) ?? 1) - 1
        } else {
            idx = next
        }
        next = idx + 1
        if idx >= 0, idx < params.count { out.append((spec, params[idx])) }
    }
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
            for (spec, arg) in boundArgs(key: key, args: args) {
                guard spec.hasSuffix("@") else { continue }
                let a = arg.trimmingCharacters(in: .whitespaces)
                let looksInt = a.hasSuffix(".count") || intLikeNames.contains(a)
                if looksInt && !a.hasPrefix("String(") {
                    let name = (file as NSString).lastPathComponent
                    bad.append("  \(name):\(no + 1)  \(a) 是整数，喂给 \(spec) 会闪退，包一层 String(…)")
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

let langs = availableLanguages(root)
guard !langs.isEmpty else {
    FileHandle.standardError.write("在 \(root)/\(resourcesDir) 下找不到任何 *.lproj\n".data(using: .utf8)!)
    exit(2)
}

// 逐门语言读表。读不出来直接退出：一张坏表比一张缺表更危险——运行时它整张静默失效，
// 界面全体退回中文，而覆盖率照样报「完整」。
var tables: [(lang: String, dict: [String: String])] = []
for lang in langs {
    do {
        tables.append((lang, try readTable("\(root)/\(resourcesDir)/\(lang).lproj/Localizable.strings")))
    } catch {
        FileHandle.standardError.write("\((error as NSError).localizedDescription)\n".data(using: .utf8)!)
        exit(2)
    }
}

switch mode {
case "keys":
    // 给翻译用：swift build_app/l10n_tool.swift keys . zh-Hant > 待译.txt
    let lang = args.count > 3 ? args[3] : "en"
    guard let t = tables.first(where: { $0.lang == lang })?.dict else {
        FileHandle.standardError.write(
            "没有 \(lang) 这张表。现有：\(langs.joined(separator: " "))\n".data(using: .utf8)!)
        exit(2)
    }
    for k in need.subtracting(Set(t.keys)).sorted() { print("\"\(k)\"\n    = \"\";") }

case "interp":
    for k in interpKeys.sorted() { print(k) }

default:
    var failed = false
    for (lang, dict) in tables {
        let keys = Set(dict.keys)
        let missing = need.subtracting(keys).sorted()
        let unused = keys.subtracting(need).sorted()
        print("[\(lang)] 需要 \(need.count)，已有 \(dict.count)，缺 \(missing.count)，冗余 \(unused.count)")
        if !missing.isEmpty {
            failed = true
            print("  缺译文（\(missing.count) 条）：")
            for k in missing.prefix(400) { print("    \(k)") }
        }
        let specBad = checkSpecs(need, dict)
        if !specBad.isEmpty {
            failed = true
            print("  位置参数不匹配（\(specBad.count) 条）：")
            for m in specBad { print(m) }
        }
        // 冗余只对 en 报：en 是覆盖率的基准表，多出来的就是死词条。
        // 其它语言的冗余多半是翻译时顺手留的注记，一律报出来只会淹掉真问题。
        if lang == "en" && !unused.isEmpty {
            print("  表里有、源码已不用的 key（\(unused.count) 条，删掉即可）：")
            for k in unused.prefix(60) { print("    \(k)") }
        }
    }
    let intBad = checkIntFormat(root)
    if !intBad.isEmpty {
        failed = true
        print("\n%@ 收到整数，运行时会闪退（\(intBad.count) 条）：")
        for m in intBad { print(m) }
    }
    if failed { exit(1) }
    print("\n\(tables.count) 种语言覆盖完整 ✓")
    exit(0)
}
