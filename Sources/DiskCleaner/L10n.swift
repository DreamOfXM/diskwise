import AppKit
import Foundation

// ── 本地化：中文原文当 key，英文表是唯一需要维护的译文 ──
//
// 为什么不用 SPM 的 .process(.strings) + Bundle.module：见 docs/ARCHITECTURE.md §4.1，
// Bundle.module 在手工拼的 .app 里会 fatalError 并把构建机绝对路径烧进二进制。
// 这里走 Apple 的正路：Contents/Resources/en.lproj/Localizable.strings +
// CFBundleDevelopmentRegion，运行时自己挑 .lproj 目录，`swift run` 也能用。
//
// 三条规矩：
// 1. 界面里所有中文一律包进 L("…")，带变量的写成 L("已选 %d 项") + String(format:)；
// 2. 英文表里数量词写成 "item(s)"，由 cnt() 按数字挑单复数（中文没这烦恼）；
// 3. 漏译不会崩，退回显示中文——所以 build.sh 有覆盖率断言，漏一条就构建失败。

enum AppLanguage: String, CaseIterable {
    case system
    case en
    case zhHans

    /// 写进 AppleLanguages 的语言码
    var code: String {
        switch self {
        case .system: return ""
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        }
    }

    /// 分段控件上的短标签。语言名用自称，不查词表；只有「自动」是界面文案。
    var menuLabel: String {
        switch self {
        case .system: return L("自动")
        case .en: return "English"
        case .zhHans: return "中文"   // l10n-scan: skip 语言自称，两种界面都写作「中文」
        }
    }
}

enum L10n {
    /// 用户选择：nil = 跟随系统
    static let choiceKey = "diskcleaner.language"

    static var choice: AppLanguage {
        get {
            guard let raw = UserDefaults.standard.string(forKey: choiceKey),
                  let v = AppLanguage(rawValue: raw) else { return .system }
            return v
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: choiceKey) }
    }

    /// 启动时系统给的语言。选「自动」时一直用它——本会话写进 AppleLanguages 的
    /// 覆盖不该反过来让「自动」在运行中变卦。
    private static let systemResolved: AppLanguage = {
        let pref = Locale.preferredLanguages.first ?? "en"
        return pref.hasPrefix("zh") ? .zhHans : .en
    }()

    private static func resolve(_ c: AppLanguage) -> AppLanguage {
        switch c {
        case .en: return .en
        case .zhHans: return .zhHans
        case .system: return systemResolved
        }
    }

    /// 当前实际生效的语言。切换由 AppStore.setLanguage 走 apply，
    /// 改完还要发布一次状态让界面重画——所以它不是常量。
    static var active: AppLanguage = resolve(SnapshotMode.requestedLang ?? choice)

    /// 换词表：下一次取文案就生效
    static func apply(_ lang: AppLanguage) { active = resolve(lang) }

    private static var tableCode: String?
    private static var table: Bundle = .main

    private static var resolved: Bundle {
        let code = active.code
        if code != tableCode {
            tableCode = code
            table = bundle(for: code)
        }
        return table
    }

    private static func bundle(for code: String) -> Bundle {
        if let u = Bundle.main.url(forResource: code, withExtension: "lproj"),
           let b = Bundle(url: u) {
            return b
        }
        // `swift run`：Bundle.main 是 .build/release 里的裸二进制，去源码树里找
        let dev = FileManager.default.currentDirectoryPath
        let candidate = (dev as NSString).appendingPathComponent("Sources/DiskCleaner/Resources/\(code).lproj")
        if FileManager.default.fileExists(atPath: candidate), let b = Bundle(url: URL(fileURLWithPath: candidate)) {
            return b
        }
        return .main
    }

    static var isChinese: Bool { active == .zhHans }

    static func string(_ zh: String) -> String {
        guard isChinese else {
            return resolved.localizedString(forKey: zh, value: zh, table: nil)
        }
        return zh
    }

    /// 切语言：记住选择，并写 AppleLanguages 让下次启动时系统级一致。
    /// 本次会话的生效走 apply，不靠重启。
    static func setChoice(_ lang: AppLanguage) {
        choice = lang
        switch lang {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .en, .zhHans: UserDefaults.standard.set([lang.code], forKey: "AppleLanguages")
        }
    }
}

/// 界面文案。中文原文即 key，所以源码里看见的中文就是兜底文案。
@inline(__always)
func L(_ zh: String) -> String { L10n.string(zh) }

@inline(__always)
func LF(_ zh: String, _ args: CVarArg...) -> String {
    String(format: L(zh), arguments: args)
}

/// 中文量词 → 带数量的文案。中文直接拼；英文查单复数表（不规则复数也在这张表里）。
func cnt(_ n: Int, _ zhUnit: String) -> String {
    if L10n.isChinese { return "\(n) \(zhUnit)" }
    // l10n-scan: off —— 这些中文是查表入参，英文就写在下面，不进 Localizable.strings
    let one: [String: String] = [
        "项": "item", "个文件": "file", "个副本": "copy", "处残留": "leftover",
        "个项目": "project", "组": "group", "份": "copy", "天": "day",
        "组重复": "duplicate group",
        "个应用": "app", "个包": "package", "个 node_modules": "node_modules folder",
        "个可清理项": "cleanable item", "处可疑": "suspicious spot", "次": "time",
        "套": "skin", "个多余副本": "extra copy",
    ]
    let many: [String: String] = [
        "项": "items", "个文件": "files", "个副本": "copies", "处残留": "leftovers",
        "个项目": "projects", "组": "groups", "份": "copies", "天": "days",
        "组重复": "duplicate groups",
        "个应用": "apps", "个包": "packages", "个 node_modules": "node_modules folders",
        "个可清理项": "cleanable items", "处可疑": "suspicious spots", "次": "times",
        "套": "skins", "个多余副本": "extra copies",
    ]
    // l10n-scan: on
    guard let unit = one[zhUnit] else { return "\(n) \(zhUnit)" }
    return n == 1 ? "1 \(unit)" : "\(n) \(many[zhUnit] ?? unit + "s")"
}

/// 拼接多条失败原因。中文用全角分号，英文照英文的来。
func errList(_ msgs: [String]) -> String {
    msgs.joined(separator: L10n.isChinese ? "；" : "; ")
}
