import SwiftUI

// ── 六套皮肤：三套基础 + 三套进阶（premium tier）──────────────────────────
//
// 进阶皮肤的存在理由不是"颜色不一样"，是"骨架不一样"：
//   极夜黑金 = 衬线 + 直角 + 零阴影 + 零动效   → 克制的贵
//   极光玻璃 = 圆体 + 大圆角 + 真材质 + 弹性   → 外放的炫
//   水墨宣纸 = 衬线 + 纸纹 + 方印章 + 静        → 有文化的慢
// tier 只在 Channel.showsPricing 为真时用作分组依据；默认构建下六套皮肤一律可用。
//
// 铁律（所有皮肤共用，用户实测反馈定的）：
//   正文只用 ink / inkSecondary，绝不染色；
//   彩色只给图标块、环形图、按钮、徽章；
//   页头禁止整块高饱和底色。

extension Theme {

    // MARK: 免费 · 晨雾（默认）

    static let dawn = Theme(
        id: "dawn", name: "晨雾", tagline: "像系统自带的那样自然",
        tier: .free, scheme: nil,
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
            chart: [Color(hex: 0x0072B2), Color(hex: 0xE69F00), Color(hex: 0x009E73),
                    Color(hex: 0xCC79A7), Color(hex: 0x9AA0AA), Color(hex: 0xD55E00)]
        ),
        face: .system, displayWeight: .semibold, displayTracking: -0.2,
        elevation: .soft,
        backdrop: .wash([Color(hex: 0xF8F9FB), Color(hex: 0xEEF1F5)]),
        metric: ThemeMetric(radiusCard: 12, radiusControl: 9, radiusTile: 8,
                            stroke: 1, rowHeight: 40, cardPadding: 16, sectionGap: 20),
        motion: .calm,
        tileShape: .squircle
    )

    // MARK: 免费 · 石墨（深色）

    static let graphite = Theme(
        id: "graphite", name: "石墨", tagline: "夜里干活不刺眼",
        tier: .free, scheme: .dark,
        palette: ThemePalette(
            paper: Color(hex: 0x0C0D10),
            surface: Color(hex: 0x16181D),
            surfaceAlt: Color(hex: 0x1D2026),
            ink: Color(hex: 0xF2F4F7),
            inkSecondary: Color(hex: 0xA3AAB6),
            inkTertiary: Color(hex: 0x6E7581),
            separator: Color(hex: 0x262A31),
            tint: Color(hex: 0x6C9BFF),
            onTint: Color(hex: 0x06080C),
            tintSoft: Color(hex: 0x1B2434),
            danger: Color(hex: 0xFF6B60),
            onDanger: Color(hex: 0x0C0D10),
            safeBG: Color(hex: 0x14261C), safeFG: Color(hex: 0x6EE7A7),
            warnBG: Color(hex: 0x2A2113), warnFG: Color(hex: 0xF0B860),
            shadow: Color(hex: 0x000000, alpha: 0.5),
            chart: [Color(hex: 0x4FA3E3), Color(hex: 0xF2B441), Color(hex: 0x35C795),
                    Color(hex: 0xE58FC0), Color(hex: 0x6E7581), Color(hex: 0xF07850)]
        ),
        face: .system, displayWeight: .semibold, displayTracking: -0.2,
        elevation: .flat,
        backdrop: .solid,
        metric: ThemeMetric(radiusCard: 12, radiusControl: 9, radiusTile: 8,
                            stroke: 1, rowHeight: 40, cardPadding: 16, sectionGap: 20),
        motion: .calm,
        tileShape: .squircle
    )

    // MARK: 免费 · 薄荷

    static let mint = Theme(
        id: "mint", name: "薄荷", tagline: "刚擦过的桌子",
        tier: .free, scheme: nil,
        palette: ThemePalette(
            paper: Color(hex: 0xF4F8F6),
            surface: .white,
            surfaceAlt: Color(hex: 0xEDF4F1),
            ink: Color(hex: 0x131A17),
            inkSecondary: Color(hex: 0x5B6B64),
            inkTertiary: Color(hex: 0x8A9892),
            separator: Color(hex: 0xDCE7E2),
            tint: Color(hex: 0x0E8F79),
            onTint: .white,
            tintSoft: Color(hex: 0xDFF1EC),
            danger: Color(hex: 0xC8372D),
            onDanger: .white,
            safeBG: Color(hex: 0xD9F2E7), safeFG: Color(hex: 0x0B6B52),
            warnBG: Color(hex: 0xFBEFD8), warnFG: Color(hex: 0x8A5108),
            shadow: Color(hex: 0x0E3B32, alpha: 0.07),
            chart: [Color(hex: 0x0E8F79), Color(hex: 0xE69F00), Color(hex: 0x4B7FBF),
                    Color(hex: 0xCC79A7), Color(hex: 0x9FB5AC), Color(hex: 0xD55E00)]
        ),
        face: .rounded, displayWeight: .bold, displayTracking: -0.3,
        elevation: .soft,
        backdrop: .wash([Color(hex: 0xF7FAF8), Color(hex: 0xE7F2ED)]),
        metric: ThemeMetric(radiusCard: 14, radiusControl: 10, radiusTile: 10,
                            stroke: 1, rowHeight: 40, cardPadding: 16, sectionGap: 20),
        motion: .calm,
        tileShape: .circle
    )

    // MARK: 进阶 · 极夜黑金

    static let midnight = Theme(
        id: "midnight", name: "极夜黑金", tagline: "直角、细线、不解释",
        tier: .premium, scheme: .dark,
        palette: ThemePalette(
            paper: Color(hex: 0x0A0908),
            surface: Color(hex: 0x14120E),
            surfaceAlt: Color(hex: 0x1C1914),
            ink: Color(hex: 0xF4EFE6),
            inkSecondary: Color(hex: 0xA79C8A),
            inkTertiary: Color(hex: 0x6E6558),
            separator: Color(hex: 0x2C2720),
            tint: Color(hex: 0xC9A227),
            onTint: Color(hex: 0x14120E),
            tintSoft: Color(hex: 0x241E12),
            danger: Color(hex: 0xE0553F),
            onDanger: Color(hex: 0x14120E),
            safeBG: Color(hex: 0x16211A), safeFG: Color(hex: 0x8FBF9F),
            warnBG: Color(hex: 0x26200F), warnFG: Color(hex: 0xD9B45B),
            shadow: Color(hex: 0x000000, alpha: 0.6),
            chart: [Color(hex: 0xC9A227), Color(hex: 0x7FA8C9), Color(hex: 0x9CAF88),
                    Color(hex: 0xE0553F), Color(hex: 0x5C5340), Color(hex: 0x6E85A0)]
        ),
        face: .serif, displayWeight: .semibold, displayTracking: 0.8,
        elevation: .flat,
        backdrop: .wash([Color(hex: 0x12100B), Color(hex: 0x060505)]),
        metric: ThemeMetric(radiusCard: 4, radiusControl: 3, radiusTile: 2,
                            stroke: 1, rowHeight: 44, cardPadding: 20, sectionGap: 26),
        motion: .still,
        tileShape: .rounded,
        tileStrategy: .duotone
    )

    // MARK: 进阶 · 极光玻璃

    static let aurora = Theme(
        id: "aurora", name: "极光玻璃", tagline: "会呼吸的那一层",
        tier: .premium, scheme: nil,
        palette: ThemePalette(
            paper: Color(hex: 0xEEF1FB),
            surface: Color(hex: 0xFFFFFF, alpha: 0.66),
            surfaceAlt: Color(hex: 0xFFFFFF, alpha: 0.45),
            ink: Color(hex: 0x171A2A),
            inkSecondary: Color(hex: 0x4E5470),
            inkTertiary: Color(hex: 0x858BA6),
            separator: Color(hex: 0xFFFFFF, alpha: 0.7),
            tint: Color(hex: 0x6B4CE0),
            onTint: .white,
            tintSoft: Color(hex: 0xE4DEFC),
            danger: Color(hex: 0xE0447C),
            onDanger: .white,
            safeBG: Color(hex: 0xD5F5E8), safeFG: Color(hex: 0x0E7256),
            warnBG: Color(hex: 0xFFE9D0), warnFG: Color(hex: 0x93500C),
            shadow: Color(hex: 0x6B4CE0, alpha: 0.16),
            chart: [Color(hex: 0x6B4CE0), Color(hex: 0x00B8A9), Color(hex: 0xFF7A59),
                    Color(hex: 0x3AA0FF), Color(hex: 0x9AA0C8), Color(hex: 0xE84B8A)]
        ),
        face: .rounded, displayWeight: .bold, displayTracking: -0.4,
        elevation: .glass,
        backdrop: .aurora([Color(hex: 0x8E7BFF), Color(hex: 0x4FD1C5),
                           Color(hex: 0xFF8FC7), Color(hex: 0xFFD36E)]),
        metric: ThemeMetric(radiusCard: 22, radiusControl: 14, radiusTile: 12,
                            stroke: 1, rowHeight: 44, cardPadding: 18, sectionGap: 22),
        motion: .springy,
        tileShape: .squircle
    )

    // MARK: 进阶 · 水墨宣纸

    static let inkwash = Theme(
        id: "inkwash", name: "水墨宣纸", tagline: "一纸一印，墨分五色",
        tier: .premium, scheme: nil,
        palette: ThemePalette(
            paper: Color(hex: 0xF4F0E6),
            surface: Color(hex: 0xFBF8F0),
            surfaceAlt: Color(hex: 0xEFE9DB),
            ink: Color(hex: 0x1C1A17),
            inkSecondary: Color(hex: 0x6A6357),
            inkTertiary: Color(hex: 0x9A9282),
            separator: Color(hex: 0xD8CFBB),
            tint: Color(hex: 0xB03A2E),
            onTint: Color(hex: 0xFBF8F0),
            tintSoft: Color(hex: 0xEFE0DA),
            danger: Color(hex: 0xB03A2E),
            onDanger: Color(hex: 0xFBF8F0),
            safeBG: Color(hex: 0xE4E6DA), safeFG: Color(hex: 0x3E5138),
            warnBG: Color(hex: 0xF0E2D2), warnFG: Color(hex: 0x7A4A1E),
            shadow: Color(hex: 0x1C1A17, alpha: 0),
            chart: [Color(hex: 0x1C1A17), Color(hex: 0xB03A2E), Color(hex: 0x5C7A6B),
                    Color(hex: 0x8C7A4B), Color(hex: 0xCFC7B4), Color(hex: 0x4A5D75)]
        ),
        face: .serif, displayWeight: .semibold, displayTracking: 1.2,
        elevation: .flat,
        backdrop: .fiber(tint: Color(hex: 0x8A7A5C), strength: 0.055),
        metric: ThemeMetric(radiusCard: 6, radiusControl: 4, radiusTile: 4,
                            stroke: 1, rowHeight: 46, cardPadding: 20, sectionGap: 26),
        motion: .still,
        tileShape: .rounded,
        tileStrategy: .duotone
    )

    static let all: [Theme] = [.dawn, .graphite, .mint, .midnight, .aurora, .inkwash]

    static func byID(_ id: String) -> Theme? { all.first { $0.id == id } }

    /// v0.2 老用户的皮肤偏好搬家：奶油橙→晨雾，水墨→水墨宣纸
    static func migrateLegacyID(_ id: String) -> String {
        switch id {
        case "cream": return "dawn"
        case "inkwash": return "inkwash"
        default: return id
        }
    }
}
