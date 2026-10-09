import AppKit
import Foundation

// ── 本地化：中文原文当 key，其余每种语言各维护一份译文 ──
//
// 为什么不用 SPM 的 .process(.strings) + Bundle.module：见 docs/ARCHITECTURE.md §4.1，
// Bundle.module 在手工拼的 .app 里会 fatalError 并把构建机绝对路径烧进二进制。
// 这里走 Apple 的正路：Contents/Resources/<语言>.lproj/Localizable.strings +
// CFBundleDevelopmentRegion，运行时自己挑 .lproj 目录，`swift run` 也能用。
//
// 三条规矩：
// 1. 界面里所有中文一律包进 L("…")，带变量的写成 L("已选 %d 项") + String(format:)；
// 2. 拉丁语言的量词要分单复数，由 cnt() 按数字挑（中文与日韩没这烦恼）；
// 3. 漏译不会崩，退回显示中文——所以 build.sh 有覆盖率断言，漏一条就构建失败。
//
// 加一门语言 = 建一个 Sources/DiskCleaner/Resources/<语言>.lproj/Localizable.strings
// （简体中文除外，它的文案就是源码原文），再加下面一个 case。
// 闸门与构建脚本都按目录自动发现语言，不存在第二份需要同步的名单。
//
// 界面语言的清单按「这门语言有多少人真的会用这个 App」排，不按字母：
// 简繁中文、英、日、韩、德、西、法、俄、巴葡。

enum AppLanguage: String, CaseIterable {
    case system
    case en
    case zhHans
    case zhHant
    case ja
    case ko
    case de
    case es
    case fr
    case ru
    case ptBR

    /// 写进 AppleLanguages 的语言码，同时也是词表目录名（`<code>.lproj`）。
    var code: String {
        switch self {
        case .system: return ""
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        case .ja: return "ja"
        case .ko: return "ko"
        case .de: return "de"
        case .es: return "es"
        case .fr: return "fr"
        case .ru: return "ru"
        case .ptBR: return "pt-BR"
        }
    }

    /// 选择器上的短标签。语言名用自称，不查词表；只有「自动」是界面文案。
    ///
    /// 自称这几条必须挂 `l10n-scan: skip`：`hasHan` 认得出「繁體中文」「日本語」里的汉字，
    /// 不标就会被当成待译词条收进闸门，然后要求八种语言各译一遍「日本語」——
    /// 一种语言的名字不该被翻译。
    var menuLabel: String {
        switch self {
        case .system: return L("自动")
        case .en: return "English"
        case .zhHans: return "中文"        // l10n-scan: skip 语言自称
        case .zhHant: return "繁體中文"     // l10n-scan: skip 语言自称
        case .ja: return "日本語"           // l10n-scan: skip 语言自称
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .fr: return "Français"
        case .ru: return "Русский"
        case .ptBR: return "Português"
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
    private static let systemResolved: AppLanguage = match(Locale.preferredLanguages.first ?? "en")

    /// 系统语言标签 → 我们支持的哪一门。
    ///
    /// 按前缀认，因为同一门语言的标签长得五花八门（`zh-Hant-TW`、`pt-BR`、`es-419`）。
    /// 中文要先分简繁：`zh` 后面跟着 hant / tw / hk / mo 的都算繁体，其余（含光秃秃的
    /// `zh`）算简体。认不出来就退回英文——退回中文会让一门没有词表的语言显示成简体，
    /// 那比显示英文更不像话。
    static func match(_ tag: String) -> AppLanguage {
        let t = tag.lowercased().replacingOccurrences(of: "_", with: "-")
        if t.hasPrefix("zh") {
            for script in ["hant", "tw", "hk", "mo"] where t.contains(script) { return .zhHant }
            return .zhHans
        }
        if t.hasPrefix("ja") { return .ja }
        if t.hasPrefix("ko") { return .ko }
        if t.hasPrefix("de") { return .de }
        if t.hasPrefix("es") { return .es }
        if t.hasPrefix("fr") { return .fr }
        if t.hasPrefix("ru") { return .ru }
        if t.hasPrefix("pt") { return .ptBR }
        return .en
    }

    private static func resolve(_ c: AppLanguage) -> AppLanguage {
        c == .system ? systemResolved : c
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

    /// 简体中文：源码里的中文原文就是它的文案，压根不必查表。
    static var isChinese: Bool { active == .zhHans }

    /// 汉字排版（简繁都算）。
    ///
    /// 标题字距是照着汉字调的——方块字要透气，衬线皮肤得给到 0.8/1.2；同一套值套到拉丁
    /// 字母上会散成一排省略号。全角标点也按这条分，所以繁体不能只改 `isChinese`：
    /// 它的文案要走词表，但排版规矩跟简体一模一样。
    static var isHanScript: Bool { active == .zhHans || active == .zhHant }

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
        if lang == .system {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([lang.code], forKey: "AppleLanguages")
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

/// 中文量词 → 带数量的文案。简体直接拼；繁体换一张换算表；其余语言查单复数表。
func cnt(_ n: Int, _ zhUnit: String) -> String {
    // 千分位在这里统一加，而不是各页自己格式化：整盘扫描的读数动辄六位
    // （实测 306772 个目录项），有的写「306,772」有的写「306772」，
    // 同一屏两处长得不一样的数会被读成两个不同的量。
    let head = n.formatted(.number.grouping(.automatic))
    if L10n.isChinese { return "\(head) \(zhUnit)" }
    // l10n-scan: off —— 以下中文都是查表入参，译文写在代码里，不进 Localizable.strings
    //
    // 繁体不能直接把简体量词拼上去（「个文件」得写「個檔案」），所以它单独一张换算表：
    // 键仍是源码里那串简体，值换成繁体写法。这样调用点不必知道自己被谁调用。
    if L10n.active == .zhHant {
        let hant: [String: String] = [
            "项": "項", "个文件": "個檔案", "个文件夹": "個檔案夾", "个副本": "個副本", "处残留": "處殘留",
            "个项目": "個專案", "组": "組", "份": "份", "天": "天",
            "组重复": "組重複", "个应用": "個應用程式", "个包": "個套件",
            "个 node_modules": "個 node_modules", "个可清理项": "個可清理項",
            "处可疑": "處可疑", "次": "次", "套": "套", "个多余副本": "個多餘副本",
            "次操作": "次操作",
            "个条目": "個條目", "个环境": "個環境", "处": "處",
        ]
        return "\(head) \(hant[zhUnit] ?? zhUnit)"
    }
    // 其余语言各有一张量词表（见文件末尾 measureWords）：英德西法巴葡分单复数，
    // 俄语多一档「2–4」的少数形，日韩干脆不分。表里的 key 仍是源码里那串简体中文。
    // l10n-scan: on
    guard let forms = measureWords(L10n.active)[zhUnit] else { return "\(head) \(zhUnit)" }
    return "\(head)\(measureGap(L10n.active))\(forms.form(n, in: L10n.active))"
}

/// 数词与量词之间的间隔。拉丁与西里尔语系用空格（`6 files`），
/// 韩语的量词紧贴数词（`6개 파일`），中间插一个空格就是错字。
/// 日语维持空格，与本表里「6 つのスキン」那类写法一致。
private func measureGap(_ lang: AppLanguage) -> String {
    lang == .ko ? "" : " "
}

// MARK: - 非中文语言的量词表
//
// 中文（含繁体）不必查表：简体直接拼，繁体在 cnt() 里换一张换算表。
// 这门语言之外，量词要按各自的正字法变形——这正是 cnt() 存在的理由。
//
// 表里的 key 是源码里那串简体中文，值只是三种数形态的译文，所以整块圈在
// l10n-scan: off 里：这些中文是查表入参，不是界面词条，不该进 Localizable.strings。
// 加一门语言 = 在这里添一张表 + AppLanguage 里加一个 case，没有第三处要同步。
// l10n-scan: off

/// 一个量词在三种数形态下的写法。多数语言只用得上 one / many 两形，
/// 俄语还要 few（2–4 那档），日韩三形相同。
private struct MeasureForms {
    let one: String
    let few: String
    let many: String

    init(_ one: String, _ many: String) { self.init(one, many, many) }

    init(_ one: String, _ few: String, _ many: String) {
        self.one = one
        self.few = few
        self.many = many
    }

    /// 按数字挑形态。
    ///
    /// 俄语的规则看末位与末两位：末位 1 且末两位不是 11 用 one；末位 2–4 且末两位
    /// 不是 12–14 用 few；其余（含 0、5–20、25–30……）用 many。11–14 之所以要单独
    /// 排除，是因为它们末位是 1–4 却全归 many——「11 файлов」不是「11 файл」。
    func form(_ n: Int, in lang: AppLanguage) -> String {
        switch lang {
        case .ja, .ko:
            return one                      // 日韩不分单复数
        case .ru:
            let m10 = n % 10, m100 = n % 100
            if m10 == 1 && m100 != 11 { return one }
            if (2...4).contains(m10) && !(12...14).contains(m100) { return few }
            return many
        default:
            return n == 1 ? one : many
        }
    }
}

/// 取一门语言的量词表。zh-Hans / zh-Hant 走不到这里（cnt 里已经分流）。
private func measureWords(_ lang: AppLanguage) -> [String: MeasureForms] {
    switch lang {
    case .ja:
        return [
            "项": MeasureForms("件", "件"),
            "个文件": MeasureForms("ファイル", "ファイル"),
            "个文件夹": MeasureForms("フォルダ", "フォルダ"),
            "个副本": MeasureForms("コピー", "コピー"),
            "处残留": MeasureForms("件の残存データ", "件の残存データ"),
            "个项目": MeasureForms("プロジェクト", "プロジェクト"),
            "组": MeasureForms("グループ", "グループ"),
            "份": MeasureForms("コピー", "コピー"),
            "天": MeasureForms("日", "日"),
            "组重复": MeasureForms("件の重複グループ", "件の重複グループ"),
            "个应用": MeasureForms("アプリ", "アプリ"),
            "个包": MeasureForms("パッケージ", "パッケージ"),
            "个 node_modules": MeasureForms("node_modules", "node_modules"),
            "个可清理项": MeasureForms("件の削除候補", "件の削除候補"),
            "处可疑": MeasureForms("件の要注意", "件の要注意"),
            "次": MeasureForms("回", "回"),
            "次操作": MeasureForms("回の操作", "回の操作"),
            "套": MeasureForms("スキン", "スキン"),
            "个多余副本": MeasureForms("件の余分なコピー", "件の余分なコピー"),
            "个条目": MeasureForms("件", "件"),
            "个环境": MeasureForms("環境", "環境"),
            "处": MeasureForms("箇所", "箇所"),
        ]
    case .ko:
        return [
            "项": MeasureForms("개 항목", "개 항목"),
            "个文件": MeasureForms("개 파일", "개 파일"),
            "个文件夹": MeasureForms("개 폴더", "개 폴더"),
            "个副本": MeasureForms("개 사본", "개 사본"),
            "处残留": MeasureForms("개 잔여 항목", "개 잔여 항목"),
            "个项目": MeasureForms("개 프로젝트", "개 프로젝트"),
            "组": MeasureForms("개 그룹", "개 그룹"),
            "份": MeasureForms("개 사본", "개 사본"),
            "天": MeasureForms("일", "일"),
            "组重复": MeasureForms("개 중복 그룹", "개 중복 그룹"),
            "个应用": MeasureForms("개 앱", "개 앱"),
            "个包": MeasureForms("개 패키지", "개 패키지"),
            "个 node_modules": MeasureForms("개 node_modules", "개 node_modules"),
            "个可清理项": MeasureForms("개 정리 항목", "개 정리 항목"),
            "处可疑": MeasureForms("개 의심 항목", "개 의심 항목"),
            "次": MeasureForms("회", "회"),
            "次操作": MeasureForms("회 작업", "회 작업"),
            "套": MeasureForms("개 스킨", "개 스킨"),
            "个多余副本": MeasureForms("개 중복 사본", "개 중복 사본"),
            "个条目": MeasureForms("개 항목", "개 항목"),
            "个环境": MeasureForms("개 환경", "개 환경"),
            "处": MeasureForms("개 위치", "개 위치"),
        ]
    case .de:
        return [
            "项": MeasureForms("Eintrag", "Einträge"),
            "个文件": MeasureForms("Datei", "Dateien"),
            "个文件夹": MeasureForms("Ordner", "Ordner"),
            "个副本": MeasureForms("Kopie", "Kopien"),
            "处残留": MeasureForms("Überrest", "Überreste"),
            "个项目": MeasureForms("Projekt", "Projekte"),
            "组": MeasureForms("Gruppe", "Gruppen"),
            "份": MeasureForms("Kopie", "Kopien"),
            "天": MeasureForms("Tag", "Tage"),
            "组重复": MeasureForms("Duplikatgruppe", "Duplikatgruppen"),
            "个应用": MeasureForms("App", "Apps"),
            "个包": MeasureForms("Paket", "Pakete"),
            "个 node_modules": MeasureForms("node_modules-Ordner", "node_modules-Ordner"),
            "个可清理项": MeasureForms("löschbarer Eintrag", "löschbare Einträge"),
            "处可疑": MeasureForms("verdächtige Stelle", "verdächtige Stellen"),
            "次": MeasureForms("Mal", "Mal"),
            "次操作": MeasureForms("Aktion", "Aktionen"),
            "套": MeasureForms("Skin", "Skins"),
            "个多余副本": MeasureForms("überzählige Kopie", "überzählige Kopien"),
            "个条目": MeasureForms("Eintrag", "Einträge"),
            "个环境": MeasureForms("Umgebung", "Umgebungen"),
            "处": MeasureForms("Stelle", "Stellen"),
        ]
    case .es:
        return [
            "项": MeasureForms("elemento", "elementos"),
            "个文件": MeasureForms("archivo", "archivos"),
            "个文件夹": MeasureForms("carpeta", "carpetas"),
            "个副本": MeasureForms("copia", "copias"),
            "处残留": MeasureForms("residuo", "residuos"),
            "个项目": MeasureForms("proyecto", "proyectos"),
            "组": MeasureForms("grupo", "grupos"),
            "份": MeasureForms("copia", "copias"),
            "天": MeasureForms("día", "días"),
            "组重复": MeasureForms("grupo duplicado", "grupos duplicados"),
            "个应用": MeasureForms("app", "apps"),
            "个包": MeasureForms("paquete", "paquetes"),
            "个 node_modules": MeasureForms("carpeta node_modules", "carpetas node_modules"),
            "个可清理项": MeasureForms("elemento limpiable", "elementos limpiables"),
            "处可疑": MeasureForms("punto sospechoso", "puntos sospechosos"),
            "次": MeasureForms("vez", "veces"),
            "次操作": MeasureForms("operación", "operaciones"),
            "套": MeasureForms("aspecto", "aspectos"),
            "个多余副本": MeasureForms("copia extra", "copias extra"),
            "个条目": MeasureForms("entrada", "entradas"),
            "个环境": MeasureForms("entorno", "entornos"),
            "处": MeasureForms("punto", "puntos"),
        ]
    case .fr:
        return [
            "项": MeasureForms("élément", "éléments"),
            "个文件": MeasureForms("fichier", "fichiers"),
            "个文件夹": MeasureForms("dossier", "dossiers"),
            "个副本": MeasureForms("copie", "copies"),
            "处残留": MeasureForms("résidu", "résidus"),
            "个项目": MeasureForms("projet", "projets"),
            "组": MeasureForms("groupe", "groupes"),
            "份": MeasureForms("copie", "copies"),
            "天": MeasureForms("jour", "jours"),
            "组重复": MeasureForms("groupe de doublons", "groupes de doublons"),
            "个应用": MeasureForms("app", "apps"),
            "个包": MeasureForms("paquet", "paquets"),
            "个 node_modules": MeasureForms("dossier node_modules", "dossiers node_modules"),
            "个可清理项": MeasureForms("élément nettoyable", "éléments nettoyables"),
            "处可疑": MeasureForms("emplacement suspect", "emplacements suspects"),
            "次": MeasureForms("fois", "fois"),
            "次操作": MeasureForms("opération", "opérations"),
            "套": MeasureForms("apparence", "apparences"),
            "个多余副本": MeasureForms("copie en trop", "copies en trop"),
            "个条目": MeasureForms("entrée", "entrées"),
            "个环境": MeasureForms("environnement", "environnements"),
            "处": MeasureForms("emplacement", "emplacements"),
        ]
    case .ru:
        return [
            "项": MeasureForms("элемент", "элемента", "элементов"),
            "个文件": MeasureForms("файл", "файла", "файлов"),
            "个文件夹": MeasureForms("папка", "папки", "папок"),
            "个副本": MeasureForms("копия", "копии", "копий"),
            "处残留": MeasureForms("остаток", "остатка", "остатков"),
            "个项目": MeasureForms("проект", "проекта", "проектов"),
            "组": MeasureForms("группа", "группы", "групп"),
            "份": MeasureForms("копия", "копии", "копий"),
            "天": MeasureForms("день", "дня", "дней"),
            "组重复": MeasureForms("группа дубликатов", "группы дубликатов", "групп дубликатов"),
            "个应用": MeasureForms("приложение", "приложения", "приложений"),
            "个包": MeasureForms("пакет", "пакета", "пакетов"),
            "个 node_modules": MeasureForms("папка node_modules", "папки node_modules", "папок node_modules"),
            "个可清理项": MeasureForms("объект для очистки", "объекта для очистки", "объектов для очистки"),
            "处可疑": MeasureForms("подозрительное место", "подозрительных места", "подозрительных мест"),
            "次": MeasureForms("раз", "раза", "раз"),
            "次操作": MeasureForms("действие", "действия", "действий"),
            "套": MeasureForms("оформление", "оформления", "оформлений"),
            "个多余副本": MeasureForms("лишняя копия", "лишние копии", "лишних копий"),
            "个条目": MeasureForms("запись", "записи", "записей"),
            "个环境": MeasureForms("окружение", "окружения", "окружений"),
            "处": MeasureForms("место", "места", "мест"),
        ]
    case .ptBR:
        return [
            "项": MeasureForms("item", "itens"),
            "个文件": MeasureForms("arquivo", "arquivos"),
            "个文件夹": MeasureForms("pasta", "pastas"),
            "个副本": MeasureForms("cópia", "cópias"),
            "处残留": MeasureForms("resíduo", "resíduos"),
            "个项目": MeasureForms("projeto", "projetos"),
            "组": MeasureForms("grupo", "grupos"),
            "份": MeasureForms("cópia", "cópias"),
            "天": MeasureForms("dia", "dias"),
            "组重复": MeasureForms("grupo de duplicados", "grupos de duplicados"),
            "个应用": MeasureForms("app", "apps"),
            "个包": MeasureForms("pacote", "pacotes"),
            "个 node_modules": MeasureForms("pasta node_modules", "pastas node_modules"),
            "个可清理项": MeasureForms("item limpável", "itens limpáveis"),
            "处可疑": MeasureForms("ponto suspeito", "pontos suspeitos"),
            "次": MeasureForms("vez", "vezes"),
            "次操作": MeasureForms("operação", "operações"),
            "套": MeasureForms("tema", "temas"),
            "个多余副本": MeasureForms("cópia extra", "cópias extras"),
            "个条目": MeasureForms("entrada", "entradas"),
            "个环境": MeasureForms("ambiente", "ambientes"),
            "处": MeasureForms("ponto", "pontos"),
        ]
    default:
        // en，同时也是兜底：认不出的语言退回英文量词，总比拼中文强。
        return [
            "项": MeasureForms("item", "items"),
            "个文件": MeasureForms("file", "files"),
            "个文件夹": MeasureForms("folder", "folders"),
            "个副本": MeasureForms("copy", "copies"),
            "处残留": MeasureForms("leftover", "leftovers"),
            "个项目": MeasureForms("project", "projects"),
            "组": MeasureForms("group", "groups"),
            "份": MeasureForms("copy", "copies"),
            "天": MeasureForms("day", "days"),
            "组重复": MeasureForms("duplicate group", "duplicate groups"),
            "个应用": MeasureForms("app", "apps"),
            "个包": MeasureForms("package", "packages"),
            "个 node_modules": MeasureForms("node_modules folder", "node_modules folders"),
            "个可清理项": MeasureForms("cleanable item", "cleanable items"),
            "处可疑": MeasureForms("suspicious spot", "suspicious spots"),
            "次": MeasureForms("time", "times"),
            "次操作": MeasureForms("operation", "operations"),
            "套": MeasureForms("skin", "skins"),
            "个多余副本": MeasureForms("extra copy", "extra copies"),
            "个条目": MeasureForms("entry", "entries"),
            "个环境": MeasureForms("environment", "environments"),
            "处": MeasureForms("spot", "spots"),
        ]
    }
    // l10n-scan: on
}

/// 拼接多条失败原因。汉字用全角分号，其余语言照各自的正字法来。
func errList(_ msgs: [String]) -> String {
    msgs.joined(separator: L10n.isHanScript ? "；" : "; ")
}
