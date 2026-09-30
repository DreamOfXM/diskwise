import SwiftUI

// ── 皮肤目录：皮肤的数据在 Resources/skins.json，这里是它的读取端 ─────────────
//
// 皮肤是一组值，不是一段逻辑。原先写成 Swift 的 static let，加一套皮肤要先会写 Swift、
// 再编译一次；搬进 JSON 之后，任何人在 GitHub 网页上点开 skins.json、照格式加一段、
// 提 PR 就够了——不用 clone，不用装工具链。
//
// 读取一律宽容：缺字段取默认值，认不出的枚举档退回默认档，单条解不出来就跳过那一条。
// 整份文件读不出来时退回 `Theme.builtIn`。这条兜底不是洁癖——Theme 是 Environment
// 的默认值，拿不到就是整屏空白，比「皮肤不好看」严重一个量级。

private func skinsJSONURL() -> URL? {
    if let u = Bundle.main.url(forResource: "skins", withExtension: "json") { return u }
    // `swift run`：Bundle.main 是 .build 里的裸二进制，去源码树里找
    let dev = "Sources/DiskCleaner/Resources/skins.json"
    return FileManager.default.fileExists(atPath: dev) ? URL(fileURLWithPath: dev) : nil
}

// MARK: - 取值助手
//
// 全部返回非可选值：解不出来就给 fallback，调用点不必到处写 ??。

private func str(_ any: Any?, _ fallback: String) -> String {
    guard let s = any as? String, !s.isEmpty else { return fallback }
    return s
}

private func num(_ any: Any?, _ fallback: Double) -> Double {
    guard let n = any as? NSNumber else { return fallback }
    return n.doubleValue
}

private func cg(_ any: Any?, _ fallback: CGFloat) -> CGFloat {
    CGFloat(num(any, Double(fallback)))
}

private func flag(_ any: Any?, _ fallback: Bool) -> Bool {
    (any as? NSNumber)?.boolValue ?? fallback
}

/// `#RRGGBB` 或 `#RRGGBB@透明度`。`@` 之后的透明度用 0–1。解析不了退回 fallback。
private func color(_ any: Any?, _ fallback: Color) -> Color {
    guard let raw = any as? String else { return fallback }
    var body = raw
    var alpha: Double = 1
    if let at = raw.firstIndex(of: "@") {
        body = String(raw[raw.startIndex..<at])
        alpha = Double(raw[raw.index(after: at)...]) ?? 1
    }
    if body.hasPrefix("#") { body.removeFirst() }
    guard body.count == 6, let v = UInt(body, radix: 16) else { return fallback }
    return Color(hex: v, alpha: alpha)
}

private func colors(_ any: Any?, _ fallback: [Color]) -> [Color] {
    guard let list = any as? [Any], !list.isEmpty else { return fallback }
    let base = fallback.first ?? .gray
    let out = list.map { color($0, base) }
    // 图表序列按 6 色取模使用，给太短也没意义：不足一位的当没填。
    return out.count >= 2 ? out : fallback
}

/// 枚举档：认得出就用，认不出退回默认——TYPO 不该让整套皮肤消失。
private func pick<T>(_ any: Any?, _ table: [String: T], _ fallback: T) -> T {
    guard let s = any as? String, let v = table[s] else { return fallback }
    return v
}

private let faces: [String: FaceDesign] = [
    "system": .system, "rounded": .rounded, "serif": .serif,
]
private let elevations: [String: Elevation] = [
    "flat": .flat, "soft": .soft, "hard": .hard, "glass": .glass,
]
private let motions: [String: MotionSignature] = [
    "still": .still, "calm": .calm, "springy": .springy,
]
private let tileShapes: [String: TileShape] = [
    "circle": .circle, "squircle": .squircle, "rounded": .rounded,
]
private let tileStrategies: [String: TileStrategy] = [
    "spectrum": .spectrum, "duotone": .duotone,
]
private let schemes: [String: ColorScheme] = [
    "light": .light, "dark": .dark,
]
/// Font.Weight 的可选档。少写几档是因为皮肤用不到的档位写进 JSON 只会变成噪音。
private let weights: [String: Font.Weight] = [
    "ultraLight": .ultraLight, "thin": .thin, "light": .light,
    "regular": .regular, "medium": .medium, "semibold": .semibold,
    "bold": .bold, "heavy": .heavy, "black": .black,
]

// MARK: - 兜底皮肤

extension Theme {
    /// 只有整份 skins.json 读不出来时才露面。长相刻意朴素：它一旦被看见，
    /// 说明资源没打进包里，这时候「好看」不是重点，「界面还画得出来」才是。
    static let builtIn = Theme(
        id: "builtin",
        name: "默认",
        tagline: "",
        tier: .free,
        scheme: nil,
        palette: ThemePalette(
            paper: Color(hex: 0xF6F7F9),
            surface: .white,
            surfaceAlt: Color(hex: 0xF1F3F6),
            ink: Color(hex: 0x14161A),
            inkSecondary: Color(hex: 0x5A616C),
            inkTertiary: Color(hex: 0x8A919E),
            separator: Color(hex: 0xE3E6EB),
            tint: Color(hex: 0x2A62D6),
            onTint: .white,
            tintSoft: Color(hex: 0xE8EFFC),
            danger: Color(hex: 0xD0342C),
            onDanger: .white,
            safeBG: Color(hex: 0xE4F5EA), safeFG: Color(hex: 0x1B6B3A),
            warnBG: Color(hex: 0xFDF0DC), warnFG: Color(hex: 0x8A4B08),
            shadow: Color(hex: 0x1A2233, alpha: 0.08),
            chart: Theme.spectrumLight
        ),
        face: .system, displayWeight: .semibold, displayTracking: -0.2,
        elevation: .soft,
        backdrop: .solid,
        metric: ThemeMetric(radiusCard: 12, radiusControl: 9, radiusTile: 8,
                            stroke: 1, rowHeight: 40, cardPadding: 16, sectionGap: 20),
        motion: .calm,
        tileShape: .squircle,
        tileStrategy: .spectrum
    )
}

// MARK: - 解析

private func parsePalette(_ any: Any?) -> ThemePalette {
    let d = Theme.builtIn.palette
    guard let m = any as? [String: Any] else { return d }
    return ThemePalette(
        paper: color(m["paper"], d.paper),
        surface: color(m["surface"], d.surface),
        surfaceAlt: color(m["surfaceAlt"], d.surfaceAlt),
        ink: color(m["ink"], d.ink),
        inkSecondary: color(m["inkSecondary"], d.inkSecondary),
        inkTertiary: color(m["inkTertiary"], d.inkTertiary),
        separator: color(m["separator"], d.separator),
        tint: color(m["tint"], d.tint),
        onTint: color(m["onTint"], d.onTint),
        tintSoft: color(m["tintSoft"], d.tintSoft),
        danger: color(m["danger"], d.danger),
        onDanger: color(m["onDanger"], d.onDanger),
        safeBG: color(m["safeBG"], d.safeBG),
        safeFG: color(m["safeFG"], d.safeFG),
        warnBG: color(m["warnBG"], d.warnBG),
        warnFG: color(m["warnFG"], d.warnFG),
        shadow: color(m["shadow"], d.shadow),
        chart: colors(m["chart"], d.chart)
    )
}

private func parseMetric(_ any: Any?) -> ThemeMetric {
    let d = Theme.builtIn.metric
    guard let m = any as? [String: Any] else { return d }
    return ThemeMetric(
        radiusCard: cg(m["radiusCard"], d.radiusCard),
        radiusControl: cg(m["radiusControl"], d.radiusControl),
        radiusTile: cg(m["radiusTile"], d.radiusTile),
        stroke: cg(m["stroke"], d.stroke),
        rowHeight: cg(m["rowHeight"], d.rowHeight),
        cardPadding: cg(m["cardPadding"], d.cardPadding),
        sectionGap: cg(m["sectionGap"], d.sectionGap)
    )
}

private func parseBackdrop(_ any: Any?) -> Backdrop {
    guard let m = any as? [String: Any] else { return .solid }
    let kind = str(m["kind"], "solid")
    let list = m["colors"]
    switch kind {
    case "wash":
        guard let c = list as? [Any], !c.isEmpty else { return .solid }
        return .wash(c.map { color($0, .gray) })
    case "aurora":
        guard let c = list as? [Any], !c.isEmpty else { return .solid }
        return .aurora(c.map { color($0, .gray) })
    case "fiber":
        return .fiber(tint: color(m["tint"], .gray), strength: num(m["strength"], 0.05))
    default:
        return .solid
    }
}

private func parseSkin(_ any: Any?) -> Theme? {
    guard let m = any as? [String: Any] else { return nil }
    let id = str(m["id"], "")
    // 没有 id 就进不了 byID、也存不进偏好，留着只会让皮肤页多一张点不动的卡
    guard !id.isEmpty else { return nil }

    let scheme: ColorScheme? = (m["scheme"] as? String).flatMap { schemes[$0] }

    return Theme(
        id: id,
        name: str(m["name"], id),
        tagline: str(m["tagline"], ""),
        tier: pick(m["tier"], ["free": ThemeTier.free, "premium": .premium], .free),
        scheme: scheme,
        palette: parsePalette(m["palette"]),
        face: pick(m["face"], faces, .system),
        displayWeight: pick(m["displayWeight"], weights, .semibold),
        displayTracking: num(m["displayTracking"], 0),
        elevation: pick(m["elevation"], elevations, .soft),
        backdrop: parseBackdrop(m["backdrop"]),
        metric: parseMetric(m["metric"]),
        motion: pick(m["motion"], motions, .calm),
        tileShape: pick(m["tileShape"], tileShapes, .squircle),
        tileStrategy: pick(m["tileStrategy"], tileStrategies, .spectrum)
    )
}

// MARK: - 目录

enum SkinCatalog {
    /// 顺序 = 皮肤页的展示顺序，第一条是默认皮肤。
    static let all: [Theme] = load()

    static func byID(_ id: String) -> Theme? { all.first { $0.id == id } }

    /// 默认皮肤：没标 id 的偏好、坏掉的偏好、试穿结束后回落都用它。
    static var defaultSkin: Theme { all.first ?? .builtIn }

    private static func load() -> [Theme] {
        guard let url = skinsJSONURL(),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["skins"] as? [Any] else { return [.builtIn] }
        let parsed = list.compactMap(parseSkin)
        // 一条都没解出来 = 文件被改坏了；退回兜底而不是给一个空皮肤页
        return parsed.isEmpty ? [.builtIn] : parsed
    }

    /// v0.2 老用户的皮肤偏好搬家：奶油橙→晨雾，水墨→水墨宣纸
    static func migrateLegacyID(_ id: String) -> String {
        switch id {
        case "cream": return "dawn"
        default: return id
        }
    }
}
