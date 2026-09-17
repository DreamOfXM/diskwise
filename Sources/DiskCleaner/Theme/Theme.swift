import SwiftUI

// ── 皮肤引擎 v2 ────────────────────────────────────────────────────────────
// 皮肤 = 一整套视觉骨架，不只是配色。
//
// v1 的致命伤：Skin 只带颜色，所以每套皮肤看起来是同一件衣服换了支口红。
// v2 把「结构」也纳入 token：字体设计、圆角、描边粗细、分层方式（材质）、背景做法、
// 密度、动效签名。两套皮肤要在骨架上就不一样，否则没有存在的必要。
//
// 加皮肤 = 在 Skins.swift 加一份数据，视图零改动。
// 视图只准读 @Environment(\.theme)，禁止硬编码色值。
// 铁律：正文永不染色（ink/inkSecondary 之外不许出现彩色文字），
//       彩色只给图标块、环形图、按钮、徽章。

// MARK: - 皮肤骨架维度

enum ThemeTier: String, Hashable {
    case free
    case premium
}

/// 字体设计——三套就有三种气质，零字体文件、零体积
enum FaceDesign: Hashable {
    case system      // SF Pro：原生、可信
    case rounded     // SF Rounded：亲和、年轻
    case serif       // New York：贵、慢、有文化
}

/// 分层方式：卡片靠什么从背景里浮出来
enum Elevation: Hashable {
    case flat        // 只靠描边（黑金/水墨：越克制越贵）
    case soft        // 柔和投影（原生高级感）
    case hard        // 实心偏移影（粗野、有冲击力）
    case glass       // 半透明材质 + 高光描边（极光）
}

/// 背景做法：窗口底不是纯色就有戏
enum Backdrop: Hashable {
    case solid
    case wash([Color])                 // 纵向渐层
    case aurora([Color])               // 多束径向光斑
    case fiber(tint: Color, strength: Double)   // 纸纹肌理
}

/// 动效签名：换皮肤连手感一起换
enum MotionSignature: Hashable {
    case still     // 几乎不动（水墨：静）
    case calm      // 标准缓动（原生）
    case springy   // 弹性（极光：活）
}

// MARK: - 调色板

struct ThemePalette {
    var paper: Color          // 窗口底
    var surface: Color        // 卡片
    var surfaceAlt: Color     // 卡片内嵌套层 / hover
    var ink: Color            // 正文（永不染色）
    var inkSecondary: Color   // 次要文字
    var inkTertiary: Color    // 占位/说明
    var separator: Color      // 分隔线、卡片描边
    var tint: Color           // 主强调色：按钮/环形图/图标块/选中
    var onTint: Color
    var tintSoft: Color       // 选中行底色
    var danger: Color
    var onDanger: Color
    var safeBG: Color
    var safeFG: Color
    var warnBG: Color
    var warnFG: Color
    var shadow: Color         // 投影色（深色皮肤要更黑更实）
    var chart: [Color]        // 6 色数据系列，色觉可分辨
}

// MARK: - 度量

struct ThemeMetric {
    var radiusCard: CGFloat
    var radiusControl: CGFloat
    var radiusTile: CGFloat
    var stroke: CGFloat       // 卡片描边粗细
    var rowHeight: CGFloat
    var cardPadding: CGFloat
    var sectionGap: CGFloat
}

// MARK: - 皮肤

struct Theme: Identifiable {
    var id: String
    var name: String
    var tagline: String
    var tier: ThemeTier
    /// 皮肤自带明暗：深色皮肤不该被系统浅色拉回浅色
    var scheme: ColorScheme?
    var palette: ThemePalette

    var face: FaceDesign
    var displayWeight: Font.Weight
    var displayTracking: Double

    /// displayTracking 是照着汉字调的——方块字要透气，衬线皮肤给到 0.8/1.2。
    /// 同一套值套拉丁字母就散成一排省略号，所以英文只收正值，
    /// 负值（无衬线/圆体的紧排）两种文字通用，原样放行。
    var titleTracking: Double {
        L10n.isChinese ? displayTracking : min(displayTracking, 0.3)
    }

    var elevation: Elevation
    var backdrop: Backdrop
    var metric: ThemeMetric
    var motion: MotionSignature

    /// 图标块形状：圆形（软）/ 连续圆角（苹果）/ 方（硬）
    var tileShape: TileShape = .squircle
    /// 图标块上色策略
    var tileStrategy: TileStrategy = .spectrum

    /// `Channel.showsPricing` 为真时这套皮肤按商品展示；开关关闭时所有皮肤都是普通皮肤。
    var isPaid: Bool { Channel.showsPricing && tier == .premium }
}

enum TileShape: Hashable {
    case circle, squircle, rounded
}

/// 侧边栏/行图标块的上色策略。
/// 多数皮肤走 iOS 设置式「一类一色」，靠颜色认路；
/// 克制的黑金/水墨皮肤只准用主色和墨色交替——满屏彩虹会毁掉它们的安静。
enum TileStrategy: Hashable {
    case spectrum
    case duotone
}

extension Theme {
    static let fallback = Theme.dawn
}

// MARK: - 字体

extension Theme {
    func bodyFont(_ style: Font.TextStyle = .body) -> Font {
        switch face {
        case .system: return .system(style)
        case .rounded: return .system(style, design: .rounded)
        case .serif: return .system(style, design: .serif)
        }
    }

    func display(_ style: Font.TextStyle) -> Font {
        switch face {
        case .system: return .system(style).weight(displayWeight)
        case .rounded: return .system(style, design: .rounded).weight(displayWeight)
        case .serif: return .system(style, design: .serif).weight(displayWeight)
        }
    }

    func numeric(_ style: Font.TextStyle) -> Font {
        display(style)
    }

    var animation: Animation {
        switch motion {
        case .still: return .easeOut(duration: 0.12)
        case .calm: return .easeInOut(duration: 0.22)
        case .springy: return .spring(response: 0.42, dampingFraction: 0.62)
        }
    }

    var pressAnimation: Animation {
        switch motion {
        case .still: return .linear(duration: 0.08)
        case .calm: return .easeOut(duration: 0.16)
        case .springy: return .spring(response: 0.26, dampingFraction: 0.5)
        }
    }

    /// 图标块取色：一类一色（认地方）或双色交替（认皮肤）
    func tileColor(index: Int, dark: Bool) -> Color {
        switch tileStrategy {
        case .spectrum:
            let ramp = dark ? Theme.spectrumDark : Theme.spectrumLight
            return ramp[index % ramp.count]
        case .duotone:
            return index % 2 == 0 ? palette.tint : palette.ink
        }
    }

    /// 品牌光谱：顺序与侧边栏条目一一对应，深浅两版保证深色皮肤上不发闷
    static let spectrumLight: [Color] = [
        Color(hex: 0x2A62D6), Color(hex: 0xE0762A), Color(hex: 0x7B4FC9),
        Color(hex: 0xC93F76), Color(hex: 0x18884F), Color(hex: 0x0E8FA8),
        Color(hex: 0xB8860B), Color(hex: 0xC8372D), Color(hex: 0x5B6472),
        Color(hex: 0x0E8F79), Color(hex: 0x6E7B2F)
    ]

    static let spectrumDark: [Color] = [
        Color(hex: 0x6C9BFF), Color(hex: 0xF2954E), Color(hex: 0xA98BE8),
        Color(hex: 0xE879A6), Color(hex: 0x4FC98A), Color(hex: 0x4FC3DD),
        Color(hex: 0xE0B84A), Color(hex: 0xFF6B60), Color(hex: 0x98A0AC),
        Color(hex: 0x3FC9AC), Color(hex: 0xB0BE63)
    ]
}

// MARK: - Environment 注入
//
// v1 用静态 Clay.* 读皮肤，SwiftUI 不知道要重画，只好在 ContentView 上挂
// .id(skin) 强制重建整棵子树——副作用是换肤时所有 @StateObject 被重建，
// 用户每换一次皮肤就把全盘扫描重跑一遍。v2 走 Environment，换肤只是改色，
// 扫描状态完好保留。

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue: Theme = .dawn
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

extension View {
    /// 皮肤页的迷你预览靠这个把整棵子树渲染成另一套皮肤
    func themed(_ theme: Theme) -> some View {
        environment(\.theme, theme)
    }
}

// MARK: - 十六进制

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
