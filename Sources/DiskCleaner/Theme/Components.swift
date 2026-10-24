import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DiskCleanerCore

// ── 组件库：所有视觉都从这里出，视图层不许手写色值/圆角/阴影 ────────────────
//
// 三条硬规矩（用户实测反馈 + 本次重设计立的）：
//   1. 正文只用 ink / inkSecondary，彩色只出现在图标块、环形图、按钮、徽章；
//   2. 页头禁止整块高饱和底色，靠描边和留白分层；
//   3. 任何进度/勾选都不许用系统控件默认色——那是穿帮重灾区。

// MARK: - 形状

extension Theme {
    func cardShape(_ inset: CGFloat = 0) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: metric.radiusCard + inset, style: .continuous)
    }

    func controlShape(_ inset: CGFloat = 0) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: metric.radiusControl + inset, style: .continuous)
    }

    func tileShape(_ side: CGFloat) -> AnyShape {
        switch self.tileShape {
        case .circle:
            return AnyShape(Circle())
        case .squircle:
            return AnyShape(RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
        case .rounded:
            return AnyShape(RoundedRectangle(cornerRadius: metric.radiusTile, style: .continuous))
        }
    }
}

// MARK: - 窗口背景

struct ThemedBackdrop: View {
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                theme.palette.paper
                content(in: geo.size)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func content(in size: CGSize) -> some View {
        switch theme.backdrop {
        case .solid:
            EmptyView()
        case .wash(let colors):
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        case .aurora(let colors):
            AuroraLayer(colors: colors)
        case .fiber(let tint, let strength):
            PaperGrain(tint: tint, strength: strength)
        }
    }
}

/// 极光：四束径向光斑缓慢错开位置，做出 mesh gradient 的错觉
/// （真 MeshGradient 要 macOS 15，这里用兼容画法）
private struct AuroraLayer: View {
    var colors: [Color]

    private let spots: [UnitPoint] = [
        UnitPoint(x: 0.12, y: 0.05), UnitPoint(x: 0.9, y: 0.15),
        UnitPoint(x: 0.25, y: 0.95), UnitPoint(x: 1.0, y: 0.85)
    ]

    var body: some View {
        ZStack {
            ForEach(Array(colors.enumerated()), id: \.offset) { i, color in
                RadialGradient(
                    colors: [color.opacity(0.26), color.opacity(0)],
                    center: spots[i % spots.count],
                    startRadius: 0, endRadius: 520
                )
            }
        }
        .accessibilityHidden(true)
    }
}

/// 宣纸肌理：程序生成一张噪声位图平铺，比每帧 Canvas 便宜得多
private struct PaperGrain: View {
    var tint: Color
    var strength: Double

    var body: some View {
        Image(nsImage: NoiseImage.shared)
            .resizable(resizingMode: .tile)
            .opacity(strength)
            .saturation(0)
            .blendMode(.multiply)
            .overlay(Group { tint.opacity(strength * 0.6) }.blendMode(.multiply))
            .accessibilityHidden(true)
    }
}

private enum NoiseImage {
    static let shared: NSImage = {
        let side = 160
        let bytesPerRow = side
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)
        var seed: UInt64 = 0x9E3779B97F4A7C15
        for i in 0..<pixels.count {
            seed ^= seed << 13
            seed ^= seed >> 7
            seed ^= seed << 17
            // 偏高斯分布的浅灰噪声：绝大多数像素接近白
            let v = 255 - Int((Double(seed % 1000) / 1000.0) * 46)
            pixels[i] = UInt8(max(180, min(255, v)))
        }
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: &pixels, width: side, height: side,
                            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: side, height: side))
    }()
}

// MARK: - 卡片

/// 把一句话里的那个**读数**提成灯色，其余一个字都不动。
///
/// 样稿有三处同一规矩：`.lede b`、`.row .sub b`、`.acct-lab u` 都把那个数单独染成
/// `--lamp`——六行一个嗓门、一句话一个嗓门，读者的眼睛没有地方落。
/// 这里不写正则、也不改本地化串：调用方把要染的那一段原样递进来（就是 `human(...)`
/// 的输出），在中英两种渲染结果里各找各的位置，所以 l10n 目录一行都不用动。
///
/// 底色也写进属性串，不给调用方留 `.foregroundStyle`：那个修饰符会把整段
/// 前景色一并盖掉，跑在后面的灯色就白染了。
func lampRun(_ text: String, _ run: String, _ color: Color,
             base: Color, font: Font? = nil) -> AttributedString {
    var out = AttributedString()
    func add(_ slice: Substring, _ c: Color, _ f: Font?) {
        var a = AttributedString(String(slice))
        a.foregroundColor = c
        if let f { a.font = f }
        out += a
    }
    guard !run.isEmpty, let hit = text.range(of: run) else {
        add(text[...], base, nil)
        return out
    }
    add(text[..<hit.lowerBound], base, nil)
    add(text[hit], color, font)
    add(text[hit.upperBound...], base, nil)
    return out
}

struct ThemedCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat? = nil
    var tintBorder: Color? = nil
    /// 打一层灰底（`surfaceAlt`）：两张卡并排时用它把「主 / 次」分开。
    ///
    /// 废纸篓那一屏原先两张卡两个 34pt 数字，谁主谁次全靠读文字；现在一张白底大数、
    /// 一张灰底小数，一眼就知道屏幕上那个「34pt」说的是哪件事。
    var alt: Bool = false
    /// 只留版式、不画盒子。样稿的招牌那一屏没有卡：`.mapwrap` 直接坐在窗口画布上，
    /// 一圈光洇到整页。给它套一张卡，环就成了「表单里的一个控件」——
    /// 招牌画面必须独占这块场，所以这一处允许把底、边、投影三样都撤掉。
    var chromeless: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        let p = padding ?? theme.metric.cardPadding
        let shape = theme.cardShape()
        content()
            .padding(chromeless ? 0 : p)
            .background(chromeless ? AnyView(EmptyView()) : AnyView(cardBackground(shape)))
            .overlay(chromeless ? AnyView(EmptyView()) : AnyView(cardStroke(shape)))
            .modifier(ShadowModifier(shape: shape, off: chromeless))
    }

    @ViewBuilder
    private func cardBackground(_ shape: some Shape) -> some View {
        switch theme.elevation {
        case .glass:
            shape.fill(.ultraThinMaterial)
            shape.fill(alt ? theme.palette.surfaceAlt.opacity(0.72)
                           : theme.palette.surface.opacity(0.72))
        case .flat, .soft, .hard:
            shape.fill(alt ? theme.palette.surfaceAlt : theme.palette.surface)
        }
    }

    @ViewBuilder
    private func cardStroke(_ shape: some Shape) -> some View {
        shape.stroke(
            tintBorder ?? (theme.elevation == .glass ? Color.white.opacity(0.55) : theme.palette.separator),
            lineWidth: theme.metric.stroke
        )
    }
}

private struct ShadowModifier<S: Shape>: ViewModifier {
    @Environment(\.theme) private var theme
    var shape: S
    var off: Bool = false

    @ViewBuilder func body(content: Content) -> some View {
        if off {
            content
        } else {
            switch theme.elevation {
            case .flat:
                content
            case .soft:
                content.shadow(color: theme.palette.shadow, radius: 8, x: 0, y: 3)
            case .glass:
                content.shadow(color: theme.palette.shadow, radius: 18, x: 0, y: 8)
            case .hard:
                content.shadow(color: theme.palette.shadow, radius: 0, x: 4, y: 4)
            }
        }
    }
}

// MARK: - 按钮

/// 钮上那枚键位角标（样稿的 `kbd`：9 px 等宽、比钮面暗一档、一圈发丝边）。
///
/// 底色和描边都从 `ink` 掺出来，不写死黑白：同一枚角标要站在深色皮肤的暗灰钮面上，
/// 也要站在浅色皮肤的白钮面上——写死 `Color.black` 的那一档在暗皮肤里直接消失，
/// 写死白色的那档在浅皮肤里像贴了块膏药。
///
/// **只画真绑上了的键。** 角标是一句「按它有这个效果」的承诺，画一个没绑的键比不画更坏：
/// 人按下去没反应，学到的是「这屏上印的提示不可信」——那一课比少一个键位贵得多。
/// 所以 `shortcut` 与 `keyHint` 必须成对出现，两个参数一个是分派、一个是回执。
struct KeyCap: View {
    @Environment(\.theme) private var theme
    var text: String
    /// 角标站在哪一块面上。nil = 页面或控件的底，走皮肤墨色；把一颗**涂了主色的钮**
    /// 自己的前景递进来，字、底、描边就跟着那个色走。跟着页面墨色写死的那一档两头都输：
    /// 浅皮肤的蓝钮上糊成一片，暗皮肤上又比钮上那几个字淡一档
    /// （2026-10-22 dawn/graphite 两皮实拍「重新扫描 ⌘R」）。
    var face: Color? = nil

    var body: some View {
        let ink = face ?? theme.palette.ink
        Text(text)
            .font(theme.numeric(size: 9))
            .foregroundStyle(face ?? theme.palette.inkSecondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ink.opacity(face == nil ? 0.10 : 0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(ink.opacity(face == nil ? 0.18 : 0.30), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}

struct ThemeButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemScheme
    enum Kind { case primary, secondary, ghost, danger, compact, lamp }
    var kind: Kind = .primary
    var symbol: String? = nil
    var title: String
    var isDisabled: Bool = false
    /// 快捷键。默认 nil：这一屏的**回车**只给「开始」那颗，别的按钮一律不带——
    /// 带上的那颗会在用户还没读完这一屏时就吃掉回车。
    /// 另外，`KeyboardShortcut(.return)` 不写 `modifiers:` 会缺省成 ⌘R（真正绑到菜单的那条），
    /// 要裸回车必须显式 `modifiers: []`。
    var shortcut: KeyboardShortcut? = nil
    /// 角标上印的那几个字（「⌘R」）。**给了 `shortcut` 才给这个**，见 `KeyCap` 头注。
    var keyHint: String? = nil
    /// 铺满所在那一栏（样稿 `.act{width:100%}`）。只在标签上撑，不在按钮外面撑——
    /// 外面撑的话背景仍按标签大小画，得到的是「一颗小钮漂在一条空白中间」。
    var fillsWidth: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold))
                }
                // 标签**只给一行**：按钮被挤窄时默认会折行，而中文没有词间空格，
                // 折出来的是「访／达／显／示」四个字竖成一列——那已经不是一颗按钮了。
                // 宁可截成「访达显…」，也不能让它长成这样。这一处改的是**所有**按钮，
                // 因为「挤窄了会竖排」跟按钮是哪一颗无关（2026-10-01 总览明细行实拍）。
                Text(title).font(font).lineLimit(1)
                if let keyHint {
                    KeyCap(text: keyHint, face: keyCapFace)
                        // 角标不参与挤压：宁可标签截字，也不能把「⌘R」切成「⌘」。
                        // 一个残缺的键位比没有键位更坏——它会教人去按一个不存在的组合。
                        .fixedSize()
                }
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .contentShape(theme.controlShape())
        }
        .buttonStyle(.plain)
        .modifier(ThemeButtonVisual(kind: kind))
        .disabled(isDisabled)
        .keyboardShortcut(shortcut)
        .accessibilityLabel(title)
    }

    private var isCompact: Bool { kind == .compact }

    /// 深色皮上灯钮是「蓝玻璃 + 浅字」（见 `ThemeButtonVisual`），角标得跟着这一档走。
    private var darkSkin: Bool {
        (theme.scheme ?? systemScheme) == .dark
    }

    /// 涂了主色的那几颗（灯钮/主钮/危险钮）面上，角标得跟着**钮自己的前景**走，
    /// 不跟页面的墨色——理由记在 `KeyCap.face`。禁用态下钮的字退成 `inkTertiary`、
    /// 底退成 `tintSoft`，那一档又回到浅底，所以给 nil。
    private var keyCapFace: Color? {
        guard !isDisabled else { return nil }
        switch kind {
        case .primary: return theme.palette.onTint
        case .lamp: return darkSkin ? theme.palette.ink : theme.palette.onTint
        case .danger: return theme.palette.onDanger
        default: return nil
        }
    }
    private var hPad: CGFloat { isCompact ? 10 : 16 }
    private var vPad: CGFloat { isCompact ? 5 : 9 }
    private var iconSize: CGFloat { isCompact ? 11 : 13 }
    private var font: Font {
        switch kind {
        case .compact: return theme.bodyFont(.caption).weight(.semibold)
        // 样稿 `.btn` 写的是 500 13px。走 `.callout` 在 macOS 上只有 11，
        // 招牌那颗按钮比它下面的说明文字还小一圈。
        case .lamp: return theme.prose(size: 13, weight: .medium)
        default: return theme.bodyFont(.callout).weight(.semibold)
        }
    }
}

private struct ThemeButtonVisual: ViewModifier {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var systemScheme
    @State private var hovering = false
    @State private var pressed = false
    var kind: ThemeButton.Kind

    private var isDark: Bool { (theme.scheme ?? systemScheme) == .dark }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(foreground)
            .background(background)
            .overlay(stroke)
            .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowY)
            .scaleEffect(pressed ? 0.97 : (hovering ? 1.01 : 1.0))
            .opacity(isEnabled || kind == .primary || kind == .danger || kind == .lamp ? 1 : 0.55)
            .animation(theme.pressAnimation, value: pressed)
            .animation(theme.pressAnimation, value: hovering)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false }
            )
    }

    private var shape: RoundedRectangle {
        // 灯钮跟着皮肤的控制圆角走。这里原来钉的是 `cornerRadius: 999`（一粒胶囊），
        // 抄的是更早那版样稿；v2.6 的 `.act` 写的是 `border-radius:8px`，
        // 而 graphite 的 `radiusControl` 就是 9——形状交回皮肤，六档皮才不会共用一颗钮。
        theme.controlShape()
    }

    /// 深色皮上灯钮那一档是不是蓝玻璃（样稿 `.act` / `.cbtn` 的配方）。
    private var glassLamp: Bool { isDark && kind == .lamp }

    private var background: some View {
        ZStack {
            switch kind {
            case .primary:
                if isEnabled {
                    shape.fill(theme.palette.tint)
                    if hovering { shape.fill(Color.white.opacity(0.08)) }
                } else {
                    shape.fill(theme.palette.tintSoft)
                }
            case .lamp:
                // 样稿 `.act`：`linear-gradient(180deg, rgba(58,94,178,.30), rgba(34,56,110,.24))`
                // ——一层压暗的蓝玻璃，靠描边和落影立起来，不靠自身亮度。
                // 2026-10-23 之前这一档涂的是 `lampHot→lamp`（实拍填充 (177,200,251)、
                // 字 L8.7），整屏最亮的一粒压过了环上任何一条弧。
                // 浅色皮仍走实心：那两层 .30/.24 的蓝压到白纸上只剩一抹浅蓝，
                // 而稿子那支近白字（`ink`）先就没了对比。
                if isEnabled {
                    if glassLamp {
                        shape.fill(LinearGradient(colors: [Color(hex: 0x3A5EB2).opacity(0.30),
                                                           Color(hex: 0x22386E).opacity(0.24)],
                                                  startPoint: .top, endPoint: .bottom))
                    } else {
                        shape.fill(LinearGradient(colors: [SweepRing.lampHot(theme.palette.tint),
                                                           SweepRing.lamp(theme.palette.tint)],
                                                  startPoint: .top, endPoint: .bottom))
                    }
                    if hovering { shape.fill(Color.white.opacity(0.08)) }
                } else {
                    shape.fill(theme.palette.tintSoft)
                }
            case .secondary, .compact:
                shape.fill(theme.palette.surfaceAlt)
                if hovering { shape.fill(theme.palette.tint.opacity(0.08)) }
            case .ghost:
                shape.fill(hovering ? theme.palette.tintSoft : Color.clear)
            case .danger:
                if isEnabled {
                    shape.fill(theme.palette.danger)
                    if hovering { shape.fill(Color.white.opacity(0.08)) }
                } else {
                    shape.fill(theme.palette.danger.opacity(0.14))
                }
            }
        }
    }

    private var foreground: Color {
        guard isEnabled else { return theme.palette.inkTertiary }
        switch kind {
        // 蓝玻璃上印的是稿子那支近白（`#E9F0FD`，graphite 的 `ink` 是 `#F2F4F7`）：
        // `onTint` 在这套语言里说的是「实心主色上用什么字」，玻璃不是实心主色。
        case .lamp where glassLamp: return theme.palette.ink
        case .primary, .lamp: return theme.palette.onTint
        case .danger: return theme.palette.onDanger
        case .secondary, .compact: return theme.palette.ink
        case .ghost: return theme.palette.tint
        }
    }

    private var stroke: some View {
        shape.stroke(strokeColor, lineWidth: theme.metric.stroke)
    }

    private var strokeColor: Color {
        // 样稿 `.act{border:1px solid rgba(108,155,255,.30)}`：深色皮上整屏都是低亮度，
        // 一颗钮要跟背景分开，靠的就是这一圈描边——填充自己只有 L46，背景 L34。
        if glassLamp && isEnabled { return theme.palette.tint.opacity(0.30) }
        if kind == .primary || kind == .danger || kind == .lamp { return Color.clear }
        return theme.palette.separator
    }

    private var shadowColor: Color {
        // `.lamp` 的那团光是按钮本身的一部分，不跟着皮肤的 elevation 走：
        // 极夜黑金是 `.flat`，一收力这颗按钮就成了一个色块。
        // 深色皮按稿子 `.act{box-shadow:0 8px 26px -12px rgba(70,110,220,.8)}`——
        // 往下压 8 px 的一团蓝，不是四周匀着亮起来的一圈白。
        if glassLamp && isEnabled { return Color(hex: 0x466EDC).opacity(0.8) }
        if kind == .lamp { return SweepRing.lamp(theme.palette.tint).opacity(0.5) }
        if kind == .primary { return theme.palette.tint.opacity(theme.elevation == .flat ? 0 : 0.26) }
        if kind == .danger { return theme.palette.danger.opacity(theme.elevation == .flat ? 0 : 0.22) }
        return theme.palette.shadow
    }
    private var shadowRadius: CGFloat {
        if glassLamp && isEnabled { return pressed || hovering ? 16 : 13 }
        if kind == .lamp { return pressed || hovering ? 17 : 12 }
        return theme.elevation == .flat ? 0 : (pressed ? 2 : 7)
    }
    private var shadowY: CGFloat {
        if glassLamp && isEnabled { return 8 }
        if kind == .lamp { return 0 }
        return theme.elevation == .flat ? 0 : (pressed ? 1 : 3)
    }
}

// MARK: - 勾选框（自绘，彻底摆脱系统 accent）

struct ThemeCheckStyle: ToggleStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    var side: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        Button {
            guard isEnabled else { return }
            withAnimation(theme.animation) { configuration.isOn.toggle() }
        } label: {
            HStack(spacing: 10) {
                box(on: configuration.isOn)
                configuration.label
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func box(on: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: theme.metric.radiusControl * 0.55, style: .continuous)
        ZStack {
            shape.fill(on ? theme.palette.tint : theme.palette.surfaceAlt.opacity(0.45))
            // 未勾选态不能只用分隔线色：这颗粒子决定删什么，是整页权重最高的控件，
            // 而在深色皮肤上 separator 描边几乎看不见，反倒输给行里那些装饰性的线。
            shape.stroke(on ? theme.palette.tint : theme.palette.inkTertiary.opacity(0.62),
                         lineWidth: on ? 1 : 1.4)
            if on {
                Image(systemName: "checkmark")
                    .font(.system(size: side * 0.62, weight: .bold))
                    .foregroundStyle(theme.palette.onTint)
            }
        }
        .opacity(isEnabled ? 1 : 0.4)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - 图标块

struct IconTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var symbol: String
    var side: CGFloat = 30
    var fill: Color? = nil
    var foreground: Color? = nil
    /// 浅底同色 glyph：用在「一排里只要认得出、不该抢视线」的位置。
    /// 满屏实心彩块会让导航变成启动器，而且和主按钮撞形——用户会去点它。
    var muted: Bool = false

    var body: some View {
        let color = fill ?? theme.palette.tint
        let isDark = (theme.scheme ?? colorScheme) == .dark
        ZStack {
            theme.tileShape(side).fill(muted ? color.opacity(theme.tileWash(dark: isDark)) : color)
            Image(systemName: symbol)
                .font(.system(size: side * 0.46, weight: muted ? .medium : .semibold))
                .foregroundStyle(foreground ?? (muted ? color : .white))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - 列表行首的图形

/// 一行开头那一格是什么。只有两种：这一行背后有一个真实路径，或者它只是一个类别
/// （Docker `docker system df` 那几行没有路径）。路径那一格再分三档，顺序定死在
/// `RowIconView.resolveIcon`：归属 App 的真图标 → 各家官方品牌标 → 系统通用图标兜底。
///
/// 原来还有第三种兜底"什么都取不到就印首字母"，删掉了：同一屏里首字母色块、类别符号、
/// 通用文件夹三种东西混着一列，比统一走一张兜底更认不出东西。
enum RowIcon {
    case path(URL)
    case symbol(String)
}

/// 行首图形。
///
/// 挂真图标不是为了好看：一整列同色的小方块读起来是「一张表」，而用户判「这条我认不认得」
/// 靠的是形状。LaunchServices 会顺着路径往上找到归属的那个 App，所以
/// `~/Library/Caches/com.apple.WebKit` 直接拿到 Safari 的图标——不用我们自己猜包名。
///
/// 商店沙盒里读不到的路径、以及系统只给通用文件夹的那些目录（`~/.ollama/models` 这类），
/// 一律照上面那三档往下走，不再各页自己发明兜底。
struct RowIconView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var icon: RowIcon
    var side: CGFloat = 26
    /// 条目自己声明的归属 App 包名（safety_db 的 `app` 字段）。
    ///
    /// 路径里带包名的目录（`Containers/com.tencent.qq`）不用填这一格，系统顺着路径就能查到；
    /// 要填的是那些**路径里没有包名**的行：`~/Library/Developer/Xcode/DerivedData` 一眼就该是
    /// Xcode 的东西。查不到（没装、或商店版签名带 team 前缀对不上）就照原样退回文件夹。
    var appID: String? = nil
    /// 没有 .app 可查的工具（只有命令行的那些）用哪家官方品牌标——safety_db 的 `icon` 字段。
    /// 排在归属 App 之后：装了 Xcode 的行该看到 Xcode，不该看到一张标。
    var brand: String? = nil

    /// 系统图标按路径缓存：同一趟扫描里 200 行问的是同几个目录，而首次解析要跨进程问
    /// IconServices（实测单路径 0–9 ms，命中后 0 ms）。
    private static let cache = NSCache<NSString, NSImage>()

    var body: some View {
        switch icon {
        case .path(let url):
            switch Self.resolveIcon(url, appID: appID, brand: brand) {
            case .image(let img):
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: side, height: side)
                    .accessibilityHidden(true)
            case .brand(let slug):
                BrandTile(slug: slug, side: side)
            }
        case .symbol(let name):
            // 类别符号走「浅底同色」那一档，跟侧栏一个规矩：整列实心彩块会抢过数字那一列
            IconTile(symbol: name, side: side, fill: theme.palette.tint, muted: true)
        }
    }

    /// 这一格挂什么，三档按顺序判，全项目只有这一处判它（各页不许各定口径）：
    /// ① 归属 App 的真图标 → ② 条目声明的官方品牌标 → ③ 系统那张通用图。
    enum IconFace {
        case image(NSImage)
        case brand(String)
    }

    static func resolveIcon(_ url: URL, appID: String? = nil, brand: String? = nil) -> IconFace {
        if let img = ownerAppIcon(url, appID: appID) { return .image(img) }
        if let slug = brand, BrandIcons.image(slug) != nil { return .brand(slug) }
        return .image(systemIcon(url))
    }

    /// 系统给这张路径的图——所有行的最后一站。
    ///
    /// 目录本身在访达里就是那只通用文件夹（实测 `~/Library/Developer/Xcode/DerivedData`、
    /// `~/.Trash`、`~/.ollama/models` 拿到的图标与空目录逐字节相同），所以这一档不承载身份，
    /// 身份在 ①② 两档就判完了。读不到的路径（商店沙盒）不去白跑一趟跨进程查询，
    /// 直接给文件夹那张。
    ///
    /// 按路径缓存：同一趟扫描里 200 行问的是同几个目录，而首次解析要跨进程问
    /// IconServices（实测单路径 0–9 ms，命中后 0 ms）。
    private static func systemIcon(_ url: URL) -> NSImage {
        let key = url.path as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            return NSWorkspace.shared.icon(for: UTType.folder)
        }
        let img = NSWorkspace.shared.icon(forFile: url.path)
        if !img.representations.isEmpty { cache.setObject(img, forKey: key) }
        return img
    }

    /// 这一格该挂哪个 App 的图标。两条来源，一条一条判：条目自己声明的包名（`appID`，
    /// 走 safety_db 的 `app` 字段）→ 路径里那段反向域名 → 都没有就不挂，退回系统给的样子。
    ///
    /// 只问目录：重复文件页里躺在某个沙盒里的 .mov 该挂 .mov 的图标，那一页用户判的是
    /// 「这是什么东西」，不是「这是谁的数据」。
    ///
    /// 顺着路径查那一条在演示树里关掉：演示那份「装了哪些 App」是假的（`applicationsDir()`
    /// 跟着搬进假树），拿真机的 LaunchServices 一起用会拍出「这一页说微信卸载了、行首却挂着
    /// 活微信图标」。条目自己声明的包名不受这条影响——那是写在数据里的知识，跟这台机器
    /// 装了什么都无关，所以演示图里 Xcode 那几行照样挂得上。
    static func ownerAppIcon(_ url: URL, appID: String? = nil) -> NSImage? {
        guard isDirectory(url) else { return nil }
        let derived = homeIsDemo ? nil : url.pathComponents.reversed().first(where: isBundleID)
        guard let bundleID = appID ?? derived else { return nil }
        let key = bundleID as NSString
        if let hit = ownerCache.object(forKey: key) { return hit }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        guard !icon.representations.isEmpty else { return nil }
        ownerCache.setObject(icon, forKey: key)
        return icon
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    /// 归属 App 另存一份缓存：`rowIcon(_:[URL]:…)` 在渲染前要先问一遍「这条挂不挂得上 App」，
    /// 跟渲染期那次问的是同一件事，不能各查各的。
    private static let ownerCache = NSCache<NSString, NSImage>()

    /// 反向域名形状：`com.docker.docker` 算；`MobileSync`、`iOS DeviceSupport`、
    /// `docker-compose.yml` 都只有两段以下，不算。判错也不亏——真查不到 App 就回退文件夹。
    private static func isBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: true)
        guard parts.count >= 3 else { return false }
        return parts.allSatisfy { p in
            p.first.map { $0.isLetter } == true &&
            p.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }
}

/// 有路径就挂真图标，没有路径的才挂类别符号。
///
/// 各页那些「可能没有路径」的行（重复组的 files 为空、Docker 只在回退模式下有目录）
/// 都走这里，别在页面里各写一遍 `if let`——那会写成七种口径。
func rowIcon(_ url: URL?, _ symbol: String) -> RowIcon {
    url.map { .path($0) } ?? .symbol(symbol)
}

/// 一个条目背后有好几处路径时（缓存页那种「2 处」），挑挂得上归属 App 图标的那一条。
///
/// 不挑就是拿枚举顺序当图标来源：同一行这趟是企鹅、下趟是文件夹，那一列反而更认不出。
func rowIcon(_ urls: [URL], _ symbol: String) -> RowIcon {
    let url = urls.first { RowIconView.ownerAppIcon($0) != nil } ?? urls.first
    return url.map { RowIcon.path($0) } ?? .symbol(symbol)
}

// MARK: - 窗口外框

/// 自绘标题栏区：红绿灯是系统画的，我们只负责在它下面留出一条跟皮肤走的分隔线。
enum Chrome {
    /// 我们自己再让的宽度。0 不是随手写的：窗口是 fullSizeContentView + 带侧栏切换按钮的
    /// 工具条，系统已经把标题栏那一条（实测 52pt）让了出来，再叠一条就成了大片空白。
    static let topClearance: CGFloat = 0
    /// 侧边栏顶部这条要给红绿灯让出的宽度（三颗灯 + 右边呼吸）
    static let trafficLightInset: CGFloat = 72
}

/// 把内容顶到窗口最上边：SwiftUI 的 hiddenTitleBar 只把标题栏涂透明，
/// 并没有让内容铺到它下面，于是系统那 28pt 白带 + 我们自己的让位条叠成
/// 一条 58pt 的空档，而且它不跟皮肤走（极光那套下就是一块死白）。
/// 补上 fullSizeContentView，让位只由 ChromeStrip 这一处负责。
struct WindowContentUnderTitleBar: NSViewRepresentable {
    /// 尺寸只在第一次配置时定一次，否则每次视图更新都会把窗口拽回那个尺寸，用户就再也拉不动了。
    private static var sized = false

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        // 建视图时还没挂到窗口上，下一轮 runloop 才有
        DispatchQueue.main.async { configure(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // 没设 `toolbarStyle`：样稿 `.vol` 直接坐在标题带上，而系统给 `.navigation`
        // 那一格画了圈圆角底板。试过 `.unifiedCompact`（2026-10-24 两皮同视口对拼），
        // 底板一点没变，白改一次窗口风格。顶栏那两组因此整个搬出工具条，
        // 走 `TitlebarAccessory` 自己画的那一格。
        if !Self.sized, let size = SnapshotMode.requestedWindowSize {
            Self.sized = true
            window.setContentSize(size)
        }
    }
}

/// 把一组控件钉在标题带的某一沿，**不走系统工具条那一格**。
///
/// 稿子 `.titlebar` 是两段：`.vol{margin-right:auto}` 把盘符那一组钉在左，`.tb-right`
/// 因此落到窗口右沿。右半段只有这一条路（2026-10-24 三条实拍）：
/// ① `.primaryAction` 不会自己贴右——1700 pt 的窗里整条工具条从内容区左沿一路排到底，
///    右边空着九百多 pt，他圈的就是这一条；
/// ② 中间塞一根 `maxWidth:.infinity` 的空件能把两段撑开，但那件自己会被画成一块
///    10×39 的系统底板；换成 `EmptyView()` 之后底板没了，撑开的力也一起没了（实拍）；
/// ③ 非控件的 toolbar 件自带一圈圆角灰底板，稿子上没有——那一条另有解
///    （`ToolbarItemUnbordered`），可它治不了①：贴右仍然只能靠这一格。
///
/// **左半段别用 `.leading` 这一格**（2026-10-25 走过一次，实拍为证）：`.leading` 的
/// clip view 落在 x=88，正是系统侧栏切换按钮的位置，两组叠在一格里，系统就把那颗按钮
/// 挤成了工具条溢出——他那张图右边因此多出 ▢⋯，而附件自己还停在扫描中量到的 174 pt
/// 宽里，「量完」「重新扫描」整段被裁没、「?」被推出窗口右沿。左半段因此留在工具条里。
///
/// 附件里是**另一棵** SwiftUI 树，接不到 `ContentView` 那层的 Environment，
/// 所以皮肤、`AppStore`、`ThemeManager` 得由调用点重新注入一遍（见 `DiskCleanerApp`）。
struct TitlebarAccessory<Content: View>: NSViewRepresentable {
    var attribute: NSLayoutConstraint.Attribute = .trailing
    var content: () -> Content

    init(attribute: NSLayoutConstraint.Attribute = .trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.attribute = attribute
        self.content = content
    }

    func makeNSView(context: Context) -> NSView {
        let anchor = Anchor()
        anchor.attribute = attribute
        anchor.root = { AnyView(content()) }
        return anchor
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let anchor = nsView as? Anchor else { return }
        anchor.root = { AnyView(content()) }
        anchor.refit()
    }

    /// 附件那一格的帧是 AppKit 按我们给的那张排的，SwiftUI 内容自己变宽传不过去。
    /// 所以内容尺寸一变就把新尺寸推回去——不推的话 HStack 被压在旧宽度里，
    /// 2026-10-24 石墨那两张实拍上「重新扫描」「声音」两枚钮的字就是这么被挤没的
    /// （扫描期「量完 · 今天」整句收起时量的宽，量完之后它回来了，宽却没跟着回来）。
    ///
    /// 高度不归内容管：报上去的是**整条标题带的高**（实测 52pt）。跟着内容报的话
    /// AppKit 会把这一格按内容的矮个子摆在带子顶沿（`NSTitlebarAccessoryClipView`
    /// 给的是 {{88,0},{227,52}} 而里面的宿主只有 13 高，y=0），于是整组字贴着窗口顶边
    /// 被切掉一截——2026-10-25 他那张实拍就是这个。填满带子之后由 SwiftUI 自己居中。
    ///
    /// 这条重排有个循环：宿主报的宽是 SwiftUI 在**当前帧宽**里排出来的结果，内容一旦被
    /// 压过一次，报上去的就是压后的宽，这一格就冻在那个窄值上（2026-10-25 扫描期实测
    /// 整趟停在 174pt，「停止」两字被扣成省略号）。所以右组在调用点钉了
    /// `fixedSize(horizontal:)`，让报上来的宽与帧宽无关——见 `DiskCleanerApp` 那一处注释。
    private final class AccessoryHost: NSHostingView<AnyView> {
        var bandHeight: CGFloat = 0

        override var intrinsicContentSize: NSSize {
            let s = super.intrinsicContentSize
            return NSSize(width: s.width, height: bandHeight > 0 ? bandHeight : s.height)
        }

        override func invalidateIntrinsicContentSize() {
            super.invalidateIntrinsicContentSize()
            refitNow()
            // 内容换档那一下是带动画的（「量完 · 今天」整格收起走一段过渡），过渡中途
            // 报上来的是半截宽；只跟着回调排，这一格就可能停在半截上——2026-10-25 他
            // 那张扫描期实拍里「停止」被扣成省略号就是停在了那里。收尾后再排两次，
            // 让它落在真值上。
            DispatchQueue.main.async { [weak self] in self?.refitNow() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                self?.refitNow()
            }
        }

        private func refitNow() {
            // 只在尺寸真的变了时重排——`frame = ` 会再走一轮布局，不设这道闸就成回环。
            let s = intrinsicContentSize
            guard abs(frame.width - s.width) > 0.5 || abs(frame.height - s.height) > 0.5
            else { return }
            var f = frame
            f.size = s
            frame = f
            // 格子宽了还不够：外面那圈 `NSTitlebarAccessoryClipView` 和标题带是
            // NSThemeFrame 排的，不点名让它们重排一次，附件会一直被压在旧宽度里裁字。
            superview?.needsLayout = true
            window?.contentView?.superview?.needsLayout = true
        }
    }

    /// 一个零尺寸的锚点，唯一的作用是拿到 `window`。它铺在内容区底下，
    /// 所以 `hitTest` 直接回 nil——不然这一整块区域就点不动了。
    private final class Anchor: NSView {
        var attribute: NSLayoutConstraint.Attribute = .trailing
        var root: (() -> AnyView)?
        private var host: AccessoryHost?
        private var accessory: NSTitlebarAccessoryViewController?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// 换一次 rootView，再按内容的理想尺寸重排一次帧。
        func refit() {
            guard let host, let root else { return }
            host.rootView = root()
            host.invalidateIntrinsicContentSize()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard accessory == nil, let window, let root else { return }
            let host = AccessoryHost(rootView: root())
            // 让附件这一格的 `intrinsicContentSize` 跟着 SwiftUI 内容报——不给的话
            // 它会按容器默认值占位，字被裁一半。高由下面那道 `bandHeight` 顶成整条带子。
            host.sizingOptions = .intrinsicContentSize
            host.bandHeight = max(0, window.frame.height - window.contentLayoutRect.height)
            host.frame = NSRect(origin: .zero, size: host.intrinsicContentSize)
            host.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = attribute
            accessory.view = host
            window.addTitlebarAccessoryViewController(accessory)
            self.host = host
            self.accessory = accessory
            // 装上去这一帧量的宽可能是早一拍的（自定义字体晚到一步、扫描期正好收起
            // 了「量完 · 今天」那句），下一轮 runloop 再按内容重排一次。
            DispatchQueue.main.async { host.invalidateIntrinsicContentSize() }
        }
    }
}

/// 系统给「非控件」的 toolbar 件画一圈圆角灰底板（稿子上没有这种胶囊）。
/// 这一枚垫在件里，挂上窗口后顺着自己的祖先链找到所属的 `NSToolbarItem`，
/// 把它的 `isBordered` 关掉——这一格是读数，不是按钮，不该有按钮底板。
struct ToolbarItemUnbordered: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Marker() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? Marker)?.unborder() }

    private final class Marker: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.unborder() }
        }

        func unborder() {
            guard let toolbar = window?.toolbar else { return }
            var chain: [NSView] = []
            var v: NSView? = self
            while let cur = v { chain.append(cur); v = cur.superview }
            for item in toolbar.items {
                guard let host = item.view, chain.contains(where: { $0 === host }) else { continue }
                item.isBordered = false
            }
        }
    }
}

/// 贴在窗口最上面的一条：只做出让和分隔，不放控件
struct ChromeStrip: View {
    @Environment(\.theme) private var theme
    var leading: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: leading, height: Chrome.topClearance)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.palette.separator).frame(height: theme.metric.stroke)
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}

/// 窗口顶上那条常驻的容量读数。
///
/// 各页的账都要先扫一遍才有数，而「这盘还剩多少」不用——它是最常被瞟一眼的数，
/// 也是清完一轮后唯一当场会变的数。所以它挂在窗口上，不跟着页面切走。
///
/// 每 5 秒重读一次 `volumeUsage()`：那是一次 statfs，比画面上任何一处重排都便宜。
/// 不做成「扫完才更新」，因为别的进程也在往盘上写东西。
struct VolumeChip: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemScheme
    /// 「可用 X GB」这一句要不要写。总览那一屏由环心的大数报同一个数，顶栏再说一遍
    /// 就是同一屏两遍（样稿 `body.on-overview .volfree{display:none}` 收的就是这条）。
    /// 别的页环不在场，顶栏这句是整屏唯一的可用读数，撤了就没有了。
    var showsFree: Bool = true

    private var isDark: Bool { (theme.scheme ?? systemScheme) == .dark }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            if let u = volumeUsage() {
                // 样稿 `.vol{gap:9px}`：盘符、卷名、条子、可用量四件同一道间距。
                HStack(spacing: 9) {
                    VolumeDisc()
                    if let name = Self.volumeName {
                        Text(name)
                            .font(theme.bodyFont(.caption2))
                            .foregroundStyle(theme.palette.inkSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // 条子涂的是「已经占掉的」，用的是主色：样稿 `.volbar b` 就是
                    // `#6C9BFF` 那一支渐变，而它正是这套语言的 tint。
                    //
                    // 2026-10-23 之前这里钉的是中性墨（`inkSecondary`），理由是「主色只说
                    // 这里动得了」。那条理由站不住：同一个 `ProportionBar` 在其余六页默认
                    // 涂的就是 `tint`（见上面 `color ?? theme.palette.tint`），只有顶栏这一处
                    // 特殊。而且中性墨配 `separator` 轨道实拍下来轨道与 chrome 底色同档
                    // （实测都是 43,47,49），整条读起来是一截灰头，看不出总长。
                    ProportionBar(fraction: Double(u.usedPhysical) / Double(max(1, u.total)),
                                  track: isDark ? Color.white.opacity(0.065) : theme.palette.separator,
                                  height: 3, trackWidth: 126,
                                  gradient: Gradient(stops: [
                                    .init(color: theme.palette.tint.opacity(0.30), location: 0),
                                    .init(color: theme.palette.tint, location: 0.6),
                                    .init(color: Color(hex: 0xB6CCFF), location: 1),
                                  ]))
                        // 样稿 `box-shadow:0 0 9px rgba(108,155,255,.6)`：一条 3 pt 的细线
                        // 靠这团光才在深色 chrome 上读得出边界。稿子只有深底一种，同一个数
                        // 落在晨雾那种浅底上就不是「读出边界」而是糊成一坨蓝雾（2026-10-24
                        // 实拍顶栏那一格比稿子脏）——所以这团光只在深皮给，浅皮让轨道自己
                        // 那一档灰去分总长。
                        .shadow(color: theme.palette.tint.opacity(0.6),
                                radius: isDark ? 4.5 : 0)
                    if showsFree {
                        Text(LF("可用 %@", human(u.available)))
                            .font(theme.bodyFont(.caption2))
                            .monospacedDigit()
                            .foregroundStyle(theme.palette.inkSecondary)
                            .fixedSize()
                    }
                }
                // 这里曾经补过一道 `.padding(.horizontal, 6)`：那时这一组坐在系统工具条
                // 给的灰胶囊里，胶囊的内边距按它以为的字号算，行尾那个数贴着边。
                // 现在这组在 `TitlebarAccessory` 自己那一格，没有胶囊，这道白边就成了
                // 稿子 `.vol{gap:9px}` 之外多出来的东西——撤。
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 卷名读一次就够：它不会在运行中改名，而每 5 秒去问一次沙盒外的路径不值得。
    /// 取不到（沙盒挡了）就整段不写，不拿 "/" 或硬编码的名字顶上去。
    /// 唯一的例外是演示模式：那一屏的容量本来就是造的，卷名跟着钉住（见 `demoVolumeName()`）。
    ///
    /// 抹盘时没起名留下的默认值（「未命名 / Untitled」）**照写**。2026-10-23 那一版把它判成
    /// 「不算名字，印出来像我们回退失败」而整段收起，代价是顶栏第一句只剩一根条子——稿子
    /// `.volname` 那一格空着，2026-10-24 他拿稿子对着要回来。访达侧栏同一块盘也就写「未命名」：
    /// 那是这块盘的真名，不是我们编的占位符。仍然不换成「Macintosh HD」那种假名字——
    /// 稿子那台机器叫这个，用户这台不是。
    private static let volumeName: String? = demoVolumeName() ?? {
        guard let name = try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()
}

/// 顶栏那枚 13 pt 的盘符，样稿 `.vol .disc`：一圈细边，环心一颗发亮的蓝点。
/// 它是这句读数的主语（「这块盘」），不是装饰——稿子里它排在卷名左边，
/// 卷名收掉之后顶栏就只剩一根没有主人的条子。
///
/// 稿子的描边钉的是 `rgba(255,255,255,.15)`，那是深底上的数；浅皮同值等于不画，
/// 所以这一圈跟着墨色走，只把透明度按皮肤分两档。
private struct VolumeDisc: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        let isDark = (theme.scheme ?? systemScheme) == .dark
        ZStack {
            Circle()
                .strokeBorder(theme.palette.inkTertiary.opacity(isDark ? 0.34 : 0.30),
                              lineWidth: 1)
            Circle()
                .fill(theme.palette.tint.opacity(0.55))
                .frame(width: 6.2, height: 6.2)
                .shadow(color: theme.palette.tint.opacity(0.7), radius: 3)
        }
        .frame(width: 13, height: 13)
        .accessibilityHidden(true)
    }
}

/// 顶栏那句「量完 · 今天 09:41」：右边那一整列账是**哪一刻**结的。
///
/// 为什么值得占顶栏一格：总览这一屏处处在报数，却没有一处回答这些数是什么时候的。
/// 一台天天在编译的开发机，早上量出来的 20.4 GB 到晚上可能只剩一半——旧版只在
/// **这一趟**没走完时说话（页头那颗「扫描中 · 58%」、账目列底下那句「已读 x / y」），
/// 而昨天那趟有多旧，画面上一句都不说。它挂在窗口上不挂在总览页里，跟容量读数同一条理由：
/// 别的页的账也是按同一趟扫描结的。
///
/// 只报走完的那一轮（见 `Prefs.noteGaugeFinished`）。两种情况下**整格不画**：
/// 从没走完过（上一轮的钟点根本不存在），以及这一轮正在跑（钟点还是上一轮的，
/// 画面上的数却已经换成了半截账）。空着一个位置，比写一句「量完 · 从没量过」诚实。
struct GaugeFreshness: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        // 跑着的时候整格收起：这一格说的是「画面上这一圈数定稿于何时」，
        // 而重扫途中那些数正在被重写。跟右栏「这本账」小节头同一条判据。
        if let at = prefs.lastGaugeAt, !prefs.gaugeRunning {
            HStack(spacing: 6) {
                Circle()
                    .fill(theme.palette.safeFG)
                    .frame(width: 5, height: 5)
                Text(LF("量完 · %@", Self.stamp(at)))
                    .font(theme.numeric(size: 10))
                    .kerning(0.5)
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.inkTertiary)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LF("上一轮量完于 %@", Self.stamp(at)))
        }
    }

    /// 「今天 09:41」／「昨天 22:07」／「3 天前」／「10月14日」。
    ///
    /// 越近给越细的时刻：今天几点量完直接决定要不要重来一趟，而三周前的那一趟
    /// 几点收的尾没有任何行动价值——那种时候要的是「多久以前」这个量级本身。
    /// 七天以上换成具体日期，因为「23 天前」已经长到不如一个日期号号好核对。
    static func stamp(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")   // 小时:分固定两位，不跟地区走
        time.dateFormat = "HH:mm"
        if cal.isDate(date, inSameDayAs: now) {
            return L("今天") + " " + time.string(from: date)
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: now)),
           cal.isDate(date, inSameDayAs: yesterday) {
            return L("昨天") + " " + time.string(from: date)
        }
        let days = cal.dateComponents([.day],
                                      from: cal.startOfDay(for: date),
                                      to: cal.startOfDay(for: now)).day ?? .max
        if days < 7 { return LF("%1$d 天前", days) }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("MMMd")    // 跟着系统语言排「10月14日 / Oct 14」
        return day.string(from: date)
    }
}

// MARK: - 徽章


struct ThemeBadge: View {
    enum Tone { case safe, warn, neutral, tint, danger }

    @Environment(\.theme) private var theme
    var text: String
    var tone: Tone = .neutral
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(theme.bodyFont(.caption2).weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(theme.controlShape().fill(background))
        .foregroundStyle(foreground)
        .fixedSize()
        .accessibilityLabel(text)
    }

    private var background: Color {
        switch tone {
        case .safe: return theme.palette.safeBG
        case .warn: return theme.palette.warnBG
        case .danger: return theme.palette.danger.opacity(0.12)
        case .tint: return theme.palette.tintSoft
        case .neutral: return theme.palette.surfaceAlt
        }
    }
    private var foreground: Color {
        switch tone {
        case .safe: return theme.palette.safeFG
        case .warn: return theme.palette.warnFG
        case .danger: return theme.palette.danger
        case .tint: return theme.palette.tint
        case .neutral: return theme.palette.inkSecondary
        }
    }
}

// MARK: - 比例条

/// 相对量级的迷你刻度。
///
/// 刻意不做成通栏细线：贴在文字底下、铺满整行的 3pt 长条会被读成下划线或链接，
/// 深色皮肤下轨道看不见，短条就更像「画了一半的墨线」。定宽 + 可见轨道，
/// 让它先被认成仪表，再谈颜色。宽度封顶在这里，四个页面共用一条规则。
struct ProportionBar: View {
    @Environment(\.theme) private var theme
    var fraction: Double
    var color: Color? = nil
    var track: Color? = nil
    var height: CGFloat = 4
    var trackWidth: CGFloat = 96
    /// 这道条最窄能压到多少。默认不给 = 宽度是硬的（其余六页都是硬的）。
    /// 只有总览那一屏需要它软：环和这本账住在同一行里，环收下去的时候
    /// 条子不让步，被挤出窗口边的就是右边那一列数。
    var minTrackWidth: CGFloat? = nil
    /// 给了就按横向渐变涂填充（顶栏容量条：样稿 `.volbar b` 的
    /// `linear-gradient(90deg, rgba(108,155,255,.30), #6C9BFF 60%, #B6CCFF)`）。
    /// 只在这一处用得上，所以不开新样式、只在填充那一步分个叉。
    var gradient: Gradient? = nil

    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, fraction)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track ?? theme.palette.separator)
                if let gradient {
                    Capsule()
                        .fill(LinearGradient(gradient: gradient,
                                            startPoint: .leading,
                                            endPoint: .trailing))
                        .frame(width: max(w, height))
                } else {
                    Capsule()
                        .fill(color ?? theme.palette.tint)
                        .frame(width: max(w, height))
                }
            }
        }
        .frame(minWidth: minTrackWidth ?? trackWidth,
               idealWidth: trackWidth, maxWidth: trackWidth, alignment: .leading)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 两档数字：数用细体大字，单位缩到 11pt 并压成灰的。
///
/// 一整列都写一样大的「23.2 GB」，读起来是六行标签——这一列的用途是拿数比大小，
/// 眼睛得先扫到数。串里认不出单位（不到 1 KB 的「812 B」、没量到的「统计中…」）
/// 就整串当数，不硬拆。
struct SizeNumber: View {
    @Environment(\.theme) private var theme
    var shown: String
    var size: CGFloat = 21
    var color: Color? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(parts.num).font(theme.numeric(size: size, weight: .light))
            if !parts.unit.isEmpty {
                Text(parts.unit).font(theme.numeric(size: 11, weight: .regular))
                    .foregroundStyle(theme.palette.inkTertiary)
            }
        }
        .monospacedDigit()
        .foregroundStyle(color ?? theme.palette.ink)
        .fixedSize()
    }

    private var parts: (num: String, unit: String) {
        guard let i = shown.lastIndex(of: " ") else { return (shown, "") }
        return (String(shown[..<i]), String(shown[shown.index(after: i)...]))
    }
}

// MARK: - 环形用量仪表
//
// 磁盘清理类产品的招牌画面。设计约束（来自 r02 · A 扫描光带原型）：
//   ①一整圈 = 整块盘，任何一帧各段之和都等于它；
//   ②**彩色只给动得了的弧**——其余一律中性灰，颜色这一票只用来回答「哪儿能腾出手」；
//   ③每段直接标注数值，不靠颜色单独传达——旁边的行就是无障碍兜底。

/// 一条弧在「彩色只给动得了的地方」这条规矩里属于哪一档。
///
/// 原型把这条写得很死：一整圈里只有能整个搬走的那几段上色，其余一律中性灰。
/// 六色数据系列铺满一圈，读出来是「这盘被六样东西吃掉了」，而这一屏要回答的
/// 只有一件事——**哪儿能腾出手来**。颜色给多了，答案就没了。
enum ArcTone: Hashable {
    /// 动得了：主色从上往下打满（上面亮、下面沉），内侧再补一道暖沿
    case hot
    /// 系统随时能腾、本工具不动手：主色洗到很淡，读成「有色，但按不动」
    case washed
    /// 动不了：不上色。已量到的和没量到的用两档灰分开，别再混成一坨
    case neutral
    /// 已经搬进废纸篓、还没让位：主色 + 虚线（那段是斜纹的意思）
    case moved
    /// 「按代价」那四类：整圈按清掉要付什么分成四段，**四段都上色**。
    ///
    /// 这条读法的问题不是「哪儿能腾出手来」，而是「清掉它分别要付什么」，
    /// 所以「彩色只给动得了的」那条规矩在这里不成立——四类各自是一种答案。
    /// 颜色由页面给（皮肤的安全/警告/危险/次要色），弧本身按灯芯那套上亮下沉，
    /// 弧上的数按段色明暗选黑或白（见 `RingLayers.arcNumberColor`）。
    case cost
}

/// 账目行**就地**摊开时，这一段名下是什么。
///
/// 三种载荷都已经在页面上算好了，这里只说「点开是哪一种」——下钻不再跳去页面底下
/// 另一段列表，所以环形旁边这本账是唯一的清单，它必须自己带得动下一级。
enum SegmentDrill: Equatable {
    /// 这一段的下一级目录（点开真去量，量过走缓存）。
    case children(String)
    /// 「其他已统计」名下、第 4 名往后的那些位置。
    case restGroup
    /// 「没量到」那几行卷账。
    case gapRows

    /// 这一种明细的身份键，顺便充当上膛用的键。**不能用显示名**：语言一换它就变，
    /// 而这条串要跨重画指着同一段。`children` 那一档本来就是路径。
    var key: String {
        switch self {
        case .children(let p): return p
        case .restGroup: return "overview.restGroup"
        case .gapRows: return "overview.gapRows"
        }
    }
}

/// 环形账的一**段**。故意不做 `Identifiable`：这段每次 `body` 求值都会重新构造一份，
/// 一旦给它一个每次都不一样的 id（`UUID()`），SwiftUI 就把整列账目行当成「全换了一批新行」
/// 拆掉重挂——那六行的鼠标跟踪区跟着重注册，AppKit 对着**没动过**的光标再放一次
/// exit+enter，悬停那条线被写两次，于是「鼠标停在这一列里」＝每秒 85 次整页重画＋730 次
/// 悬停事件的自激环（2026-09-26 真鼠标静止实测，探针产物 `r04-consistency/mj-b4-park2-probe.log`）。
/// 那个自激环由「值真变了才写」守掉，整页的账由 2026-10-22 的收窄订阅解决
/// （`LedgerHoverSignal` / `HoverSpotlight`）。
/// 行的身份一律由使用方按**位置**给（`ForEach(..., id: \.offset)`）。
struct GaugeSegment {
    var label: String
    var value: Int64
    /// 账目行色块与底部带子用的实色。环形上 `.hot` 那条会用它派生出灯芯渐变，
    /// 其余三档直接用它——两处同源，才不会「弧上一个色、行上一个色」。
    var color: Color
    /// 弧怎么上色 + 环上的数怎么给色。
    var tone: ArcTone = .neutral
    /// 行上那句小字：这一块**是什么**，以及动得了多少。环上只写数，
    /// 「这是谁、我动得了吗」这两问落在这一句上。
    var sub: String = ""
    /// 点这一行要跳到哪儿（值是页面里那个视图的 id）。nil = 这块弧落不到任何一行上，
    /// 比如「空闲」「系统可清除」——它们本来就不是「谁占了地方」的答案。
    var jumpTo: String? = nil
    /// 这条弧**就是**哪个目录（nil = 不是某个具体目录，比如「其他已统计」「没量到」）。
    /// 弧上的点击认的是这个，不是 `jumpTo`：后者说「跳到哪儿」，前者才说「这是谁」。
    var path: String? = nil
    /// 这个工具能从这条弧上搬走多少。0 = 动不了，弧上就不许画那道「点我」的亮沿——
    /// 画了收不走，那一格是在骗人点击。
    var reclaim: Int64 = 0
    /// `reclaim` 在屏幕上印成哪串字。由总览页一次性按「这一列各行相加要等于圆心那个总数」
    /// 分配好（Core 的 `addableHuman`），不在这里自己 `human()`：各行独立四舍五入会各自
    /// 往上飘，实测飘出过「12.0 + 6.3 + 4.2 = 22.5」而圆心写 22.4。
    /// 空 = 没参与那次分配，退回按字节现算。
    var reclaimText: String = ""
    var reclaimShown: String { reclaimText.isEmpty ? human(reclaim) : reclaimText }
    /// `value` 在屏幕上印成哪串字。跟 `reclaimText` 同一套办法，只是钉的是另一句对账：
    /// 带子右边明写着「各段之和 494.4 GB」，那么这一列各行相加就得正好是它。
    /// 各行独立四舍五入会飘出 494.5（2026-09-25 真机实拍到的就是这个），
    /// 所以这一列由总览页统一到总数的单位后再分配（Core 的 `addableHumanColumn`）。
    /// 空 = 没参与那次分配，退回按字节现算。
    var sizeText: String = ""
    var sizeShown: String { sizeText.isEmpty ? human(value) : sizeText }
    /// 这条弧上点名要搬走的那几处。空 = 整段一起搬（`path` 那一坨）。
    /// 内侧那道暖沿铺多宽就按它的合计占弧的比例画：`~/Library` 23 GB 里能清 13 GB，
    /// 亮沿就该只咬住弧的一半多一点，铺满整条弧是在说「这 23 GB 全收得走」。
    var targets: [ReclaimTarget] = []
    /// 上膛时认这条弧用的键。绝大多数弧就是它那个目录，所以键就是路径；
    /// 但「其他已统计」不指向某一个位置（它名下的可回收量是十几处缓存），
    /// 没有这个键的话，点它会走到 `arm(path!)` 上——那是一颗必崩的按钮。
    /// 能就地摊开的段一律先取 `drill.key`：那条弧没有路径，而它的键还要跨语言稳定。
    var armKey: String { drill?.key ?? path ?? jumpTo ?? label }
    /// 虚线 = 这些字节还占着盘、只是换了地方（「本次移入废纸篓」那条弧）
    var dashed = false
    /// 环旁那一行账目的提示语（悬停气泡 + 读屏）。nil = 按「点开摊开这一段的明细」拼：
    /// 落点是**另一页**时必须自己给一句，不然提示写着「下面」而画面整页换掉，
    /// 指错方向的箭头比没有箭头更糟。
    var hint: String? = nil
    /// 这一行行首画不画 `▸`、点开摊出什么。nil = 这一段没有下一级可看
    /// （「空闲」「系统可清除」就是——给它们一个展开记号是在请人点一个空抽屉）。
    var drill: SegmentDrill? = nil
    /// 环上不写这一段的数。扫描中的「其他已统计」用它：它还在长，此刻印一个
    /// 正在跳的数会让人当成结论；等量完那一帧它自然回来（扫描态用的是另一本账）。
    var hidesArcValue = false
    /// 「按代价」那四行：这一行是**一类字节**，不是盘上一个位置。
    ///
    /// 行尾不画「点两次收走」那道 `›`，条子用这一类的颜色而不是灯色——
    /// 代价模式下弧上不接上膛（点的是类别，没法整类挪），勾选框和主按钮照旧工作。
    /// 不给这道记号，是因为一行灰/红/绿的「位置」按下去没反应，读起来像按钮坏了。
    var costClass = false
}

/// 招牌画面：**一段弧 = 盘上一块真实的字节**，一整圈加起来永远等于整块盘。
///
/// 环上只有三种东西：弧、弧上的数、两道光。会扫的那道光在扫描期间钉在「量到的字节」上，
/// 扫完换成一道反光永远绕环——它不是循环装饰，是「这一圈刚量完」的余温。
/// 动得了的弧内侧有一道暖沿，点两下才搬进废纸篓；搬走的字节当场从那条弧挪到虚线那条弧上
/// ——不从天上掉，也不凭空少。
///
/// 这一屏旁边的账目行（`RingLedgerRow`）不归它画：环形只管圆，行归页面排。
///
/// **这个视图现在只管三件事**：状态（扫描进度、呼吸相位、上膛脉冲、入场那 0.9 秒）、
/// 事件（`ringHitLayer` 那一层，按落点问 Core 这一点归谁）、无障碍与圆心那三行读数。
/// 「这一段画成什么样」全在 `RingLayers`，那些数（几档亮度、光洇多远、哪个色相当灯、
/// 每个实测读数的来历）全在 `RingStyle`。分家那次一个像素都没动，判据是六套皮肤的
/// **环带那一圈**（`r 290–428`）逐字节相同——不是「看着没变」，也不是整张图的 md5；
/// 为什么换成带 md5，写在 `RingStyle.swift` 顶部和 `tools/ring-gate.py` 里。
///
/// 往这里加代码前先问一句：这段是在**决定谁被点**（那是几何，只能进 Core 的
/// `GaugeLayout`），是在**决定亮不亮**（那是材质，进 `RingStyle` 配 `RingLayers`），
/// 还是在**读此刻的状态**（那才留在这里）。
struct SweepRing: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme

    /// 「把这一圈里动得了的全上膛」——`armed` 取这个值时所有可回收的弧一起描边。
    static let armAll = "*"

    /// 没有悬停可用时给带子叶子挂的那只哑信号：永不写，永不发变更。
    /// 用它的两处 = 不传 `hoverNote` 的那两处（引导页那面示例环、清理三屏那面只读的环）。
    fileprivate static let stillHover = LedgerHoverSignal()
    /// 同上，预演那一档的哑信号：不吃按住空格的那两处在用（引导页那面示例环、清理三屏那面
    /// 只读的环）——它们连 `preview` 都不传，`dial` 里给它们兜的就是这一只。
    fileprivate static let stillPreview = PreviewSignal()

    var segments: [GaugeSegment]
    /// 圆心那三行：`centerTop` 是那句问话（还能腾出 / 确认移入废纸篓），
    /// `centerValue` 是数，`centerCap` 是数的口径（空余多少、全部清空后多少）。
    /// 整块盘只有一个答案，所以它只放在圆心，不在别处再放一个总数。
    var centerTop: String = ""
    var centerValue: String
    var centerCap: String = ""
    var diameter: CGFloat = 232
    /// 点一条弧时回调。给整条段而不只是落点：
    /// 动得了的弧要点完才知道要不要跳，光有 `jumpTo` 分不出「能收走」和「本工具不碰」。
    var select: ((GaugeSegment) -> Void)? = nil
    /// 上了膛的那条弧（`GaugeSegment.path`，或 `Self.armAll`）。描边画成实墨，
    /// 是在说「再点一下就真搬」。
    var armed: String? = nil
    /// 点圆心：解除上膛。上膛是一次要反悔的动作，而「点空处取消」是人唯一会自然试的手势。
    var tapCenter: (() -> Void)? = nil
    /// 扫描中：光束读的就是这条进度，它一亮着就说明这一圈还没量完
    var scanning = false
    /// 预演（按住空格）那一档的通知线。**故意不是 `@ObservedObject`**，同 `hoverNote`
    /// 那条纪律：一订阅，一发空格就让整个 `body`/`dial` 重算（轨道、六枚弧上数、命中层、
    /// 四层光全跟着走一遍）。这里只存引用，真正吃它的是那几颗自己订阅的叶子：
    /// 两组环带、两根亮丝的流速、那截绿光弧、盘心三行。
    var preview: PreviewSignal? = nil
    /// 预演那三行盘心读数。空串 = 这一圈不接预演（引导页那面示例环、清理三屏那面只读的环
    /// 都留默认空串），叶子就永远读上面那三行。
    ///
    /// 为什么是**两套字符串**而不是一句「在预演」：预演那一档盘心要说的是另一笔账
    /// （「全部清空后 / 26.8 / 这一笔还没发生·松开空格就回去」），而这些句子只有页面
    /// 算得出来（那本账在视图里）。要是让页面把 `previewing` 收进 body 去挑句子，
    /// 整页就跟着空格重算一次——`PreviewSignal` 上面记的正是这一笔。
    /// 两套都在场，挑哪一套由叶子自己决定，页面一个字都不用重算。
    var centerTopPreview: String = ""
    var centerValuePreview: String = ""
    var centerCapPreview: String = ""
    /// 0…1，这一圈量完了多少条（只有 `scanning` 为真时有人读它）。
    /// 读它的是环底下那截进度条，和光束在减弱动态/静图那一档的落点；
    /// 真机量盘时那道光走的是匀速绕环，不跟着这个数一跳一跳（`RingLayers.scanOrbitSeconds`）。
    var scanProgress: Double = 0
    /// 悬停信号（整页不订阅的那一只）。**故意不是 `@ObservedObject`**：它挂在
    /// `SweepRing` 上就会让整个 `body` 跟着每一次悬停重跑——2026-10-22 的 `sample`
    /// 里 670 个主线程样本停在 `SweepRing.dial`、401 个在重算 `frame`，都是这么来的。
    /// 这里只存引用；真正订阅它的是三颗小叶子：会发光的那两组环带、盘心那句副读。
    /// 命中层只负责写，不订阅。
    var hoverNote: LedgerHoverSignal? = nil
    /// 没有鼠标的截图里钉住的那一段（`DISKWISE_HOVER`，下标由页面换成 label）。
    var hoverFallback: String? = nil
    /// 鼠标进（给 label）/ 出（给 nil）某一段。
    var onHover: ((String?) -> Void)? = nil
    /// 圆心最底那行副读（样稿 `.mid .now`）：悬停时把「这是谁、占多少、我收得走多少」
    /// 写在盘心。眼睛此刻在环上，让它跑到右边那列字里去对名字就是惩罚读图的人。
    ///
    /// 文字**不在这里算**：悬停每秒能来好几发，算在 `SweepRing` 的 body 里就会让
    /// 整圈跟着重算。这里只给「怎么算」和「这会儿要不要」，读的是哪一段由叶子
    /// 自己订阅 `hoverNote` 决定。
    var centerNowEnabled: Bool = false
    var centerNowLine: ((GaugeSegment) -> String)? = nil
    /// 形状。**默认就是今天线上那一种：环。** 这一格存在的意义是把「段→画面」与
    /// 「落点→段」这两件事从视图的 `Circle().trim` 与极角换算里解绑（Core 的 `GaugeLayout`）。
    ///
    /// 换形状不是换一个数：绘制层里有 7 处 `Circle()`，而四层光（halo=内孔呼吸、
    /// bloom=绕环余晖、glint=常驻绕环反光、beam=扫描弧）**本身就是用极坐标定义的**，
    /// 它们写在 `RingLayers` 里，得跟着一起重写。所以这里刻意不叫 `ringStyle`
    /// 之类的名字去暗示「改一个数就换形」：那会是个谎。
    var layout: any GaugeLayout = RadialGaugeLayout()

    @State private var reveal: CGFloat = 0
    @State private var entryBeam = false
    @State private var glint = false
    @State private var spinStart = Date()
    /// 上膛脉冲此刻在哪一档：由 `withAnimation` 来回，只在「上了膛」那几秒活着。
    @State private var pulse = false
    /// 环上两根光的两个开关（`RingEdgeLightsBands`）：
    /// `edgeWarm` = 入场那 0.9 秒不接（弧还在从 12 点钟往里长，而这一层只有「画完」这一档），
    /// `edgeFlash` = 每量完一整圈 +1，线框沿每条弧走一笔。
    @State private var edgeWarm = false
    @State private var edgeFlash = 0

    /// 材质。**默认由皮肤决定**：`skins.json` 的 `ring` 字段 → `Theme.ring` → `RingStyle`，
    /// 没写这一字段的皮肤拿到 `.standard`（= 今天线上那一版）。每个数的来历与实测读数
    /// 都记在 `RingStyle.swift` 里，不在这里重复。
    ///
    /// 为什么是**计算属性**而不是带默认值的存储属性：材质得跟着「此刻生效的那套皮肤」变，
    /// 而试穿皮肤不重建视图树（重建会把全盘扫描重跑一遍，见 `Theme.swift` 末尾那段）。
    /// 存储属性会在 `SweepRing` 构造那一刻把皮肤冻进 `style`，试穿时环还是旧材质。
    ///
    /// 这一格和上面的 `layout` 是一对，各管一半：`layout` 定「哪一段画在哪儿、这一点归谁」，
    /// `style` 定「那一块涂成什么样、光洇出去多远」。换材质不许碰几何，换几何不许碰材质
    /// ——理由写在 `RingGeometry.swift` 那条「几何不进配置」的线上。
    private var style: RingStyle { RingStyle.selected(for: theme.ring) }

    /// 交给绘制层的那一帧输入：材质、几何、此刻的状态在这里汇齐。
    ///
    /// **这里不吃 `preview`**：`RingFrame.previewing` 一律留 `false`，那一档由会反应的
    /// 叶子自己 `layers.previewed(preview.on)` 现兑（见 `RingBands`）。这一帧要是跟着
    /// 空格变，整棵 `dial` 就跟着重算——那正是 `PreviewSignal` 要避免的那一笔。
    ///
    /// 半径**不在**这里传——`band`/`rIn`/`rOut` 全由 `RingFrame` 现向 `layout` 要。
    /// 这不是讲究，是防呆：画和点必须吃同一圈半径，否则形状一换就出现
    /// 「看着点在带子上、命中层说带子以外」，而那一次的代价是删错目录。
    private var frame: RingFrame {
        RingFrame(style: style,
                  layout: layout,
                  theme: theme,
                  isDark: isDark,
                  diameter: diameter,
                  reveal: reveal,
                  armed: armed,
                  pulse: pulse,
                  halo: haloMotion,
                  // 截图默认走静态相位；`DISKWISE_RING_SPIN=on` 时改走真机那条 CA 环，
                  // 否则「图层动画把光晕画到哪儿」这条在静图里永远是空白账。扫描光束同一条
                  // 分界，但相位各管各的（`DISKWISE_SCAN_BEAM`）——两道光钉在同一格，
                  // 图上那团亮斑就说不清是谁了。
                  glintSpins: glint && (canAnimate || SnapshotMode.forceRingSpin),
                  scanBeamSpins: scanning && (canAnimate || SnapshotMode.forceRingSpin
                                              || SnapshotMode.scanBeamPhase != nil))
    }

    /// 预演那截绿光弧该走到整块盘的几分之几。
    ///
    /// 分母是**整盘**、分子是可回收量——跟旁边那本账的每一格同一口径（`RingLedgerRow`
    /// 那条 `fraction` 也是这么算的）。用「已用」当分母的话，这一截会跟账对不上，
    /// 而它是这一屏唯一一处还没发生的数。
    private var gainTarget: CGFloat {
        let total = segments.reduce(Int64(0)) { $0 + $1.value }
        let reclaim = segments.reduce(Int64(0)) { $0 + $1.reclaim }
        guard total > 0 else { return 0 }
        return min(1, CGFloat(reclaim) / CGFloat(total))
    }

    /// 本视图里**所有**绘制都走这一条路（层在哪、长什么样，见 `RingLayers.swift`）。
    /// 这里只留状态、事件和无障碍——环上唯一的悬停追踪层是 `ringHitLayer`，
    /// 往任何子视图上再加 `.onHover` 就会把 2026-09-25 那个 bug 放回来。
    private var layers: RingLayers { RingLayers(frame: frame) }

    /// 环带厚度。**照抄原型的比例**：它的环外径 412、带 56，也就是 0.136。
    /// 上一版取 0.17 是为了「把一枚 23.2 GB 躺进带里」，代价是内孔只剩 0.66 框宽——
    /// 圆心那三行排不下，光带也糊成一大片。带一薄，孔就大了，数照样放得下。
    ///
    /// 数住在 `layout` 里（`RadialGaugeLayout.bandRatio`，默认值 0.145），不在这里写死：
    /// 命中层用的是同一个 `thickness(of:)`，各算一遍就会出现「看着点在带子上、
    /// 命中层说带子以外」——而那一次的代价是第二下点击把别的目录搬进废纸篓。
    private var band: CGFloat { frame.band }
    private var isDark: Bool { (theme.scheme ?? systemScheme) == .dark }

    // 环带的两条半径。都从 `frame` 拿，本视图里不许再出现第四处半径换算。
    private var rOut: CGFloat { frame.rOut }
    private var rIn: CGFloat { frame.rIn }

    /// 发光用哪个色相、灯芯最亮那一档：配方与数的来历都搬到了 `RingMaterial` /
    /// `RingStyle`（这块盘上「同一个光源」不止环一处——主按钮那颗胶囊、账目行、
    /// 飞废纸篓那道轨迹都调这两个函数，共 15 处外部引用，所以名字原样留在这儿）。
    static func lamp(_ tint: Color) -> Color { RingMaterial.lamp(tint) }
    private var lamp: Color { Self.lamp(theme.palette.tint) }
    /// 整屏只有两处用到它：主按钮那颗胶囊的渐变顶部、`.row.lit` 的那个数。
    static func lampHot(_ tint: Color) -> Color { RingMaterial.lampHot(tint) }
    /// 会不会「一直动」：「减弱动态效果」下不转、不呼吸；截图模式下同样停住——
    /// `waitSettled` 靠比对连续六帧判静帧，光带永续绕环会让每一张总览图都拖到上限。
    /// 注意这里关的只是**由 Core Animation 驱动的那条永续循环**：光带本身不藏，截图里钉在 0°
    /// （一圈量完的边界就在正上方，相位可用 `DISKWISE_RING_GLINT` 挪去别处取证），
    /// 静止态在真机上长什么样，截图就得是什么。
    /// 而 `DISKWISE_FILM` 那一趟要证的恰恰是「它在走」，所以那条路不从这里过：
    /// 相位改由连拍时钟逐帧推（`SnapshotMode.filmClock`），静帧判定不受影响。
    ///
    /// ⚠️ 这一句同时意味着**截图看不见图层那一路画出来的东西**。2026-10-23 就是被它坑的：
    /// 他真机上环外那一圈平色硬边的皮带（rOut 外 3…43 px，七段各自的颜色、断口正好在
    /// `rOut + band*haloBlurRatio`），在截图里一条都不出现——因为截图走的是静态那一路，
    /// 而呼吸的那团光只有真机才挂 `CALoopView`。我把同一张截图的"干净"当成了真机的干净，
    /// 结案了一次没修掉的账（#94）。`DISKWISE_RING_SPIN=on` 现在把**全部**永续循环都换回
    /// 图层那一路，取证时要它配合；配合 `DISKWISE_MIDSCAN=overview DISKWISE_MIDSCAN_AT=25`
    /// 可以不等 `waitSettled` 泡到上限，二十多秒就出一张图层路的图。
    private var canAnimate: Bool {
        !reduceMotion && (!SnapshotMode.active || SnapshotMode.forceRingSpin)
    }
    /// 余晖怎么动。**照原型的呼吸幅度**：`.halo` 在 .34↔.9 之间走一轮 6.5 秒（单程 3.25）。
    /// 静皮收到一半（.50↔.78）：它要「静」，但样稿那圈光本来就是一起一伏的，
    /// 整层关掉等于把招牌画面少画一半——上一版就是这么把「有光晕」弄没的。
    /// 两个区间都是材质数（`breathActive` / `breathStill`）；挑哪一档、什么时候钉住，
    /// 是状态，留在这里。截图模式取中位当定值，或用 `DISKWISE_RING_BREATH` 钉在指定档取证。
    ///
    /// 会动的那一档交给 Core Animation（`RingFrame.HaloMotion.breathe`）：只有换成图层动画，
    /// 这条 60 Hz 的循环才不经过主线程。缩放只给会动的皮肤——它比亮度更「活」，
    /// 静皮留着就是穿帮；往外扩那一档只作用在内孔那团光上，它本来就在环里，扩不出去。
    private var haloMotion: RingFrame.HaloMotion {
        let range = theme.motion == .still ? style.breathStill : style.breathActive
        let (lo, hi) = (range.lowerBound, range.upperBound)
        let amp = theme.motion == .still ? 0 : style.haloBreathAmplitude
        if canAnimate { return .breathe(lo: lo, hi: hi, scaleAmp: amp, period: 3.25) }
        // 连拍那一趟按连拍时钟走这一伏一起，见 `SnapshotMode.filmClock`。
        if SnapshotMode.filmMotion {
            return .still(level: lo + (hi - lo) * SnapshotMode.filmBreathLevel,
                          scale: 1 - amp + 2 * amp * CGFloat(SnapshotMode.filmBreathLevel))
        }
        // 钉的是**呼吸区间的几分位**，不是原始透明度：0 = 最暗那档、1 = 最亮那档，
        // 这样同一张相位表在静皮与会动的皮肤上量的是同一件事。
        guard let b = SnapshotMode.ringBreath else { return .still(level: (lo + hi) / 2, scale: 1) }
        return .still(level: lo + (hi - lo) * b, scale: 1)
    }
    /// 反光在**静态**那几条路上的相位：连拍读连拍时钟，普通静图钉在
    /// `DISKWISE_RING_GLINT`（不给就停在 0°）。真机这条路不读它——
    /// 转圈是 `CALoopView` 图层上的事，见 `RingFrame.glintSpins`。
    private var glintAngle: Double {
        if SnapshotMode.filmMotion { return SnapshotMode.filmGlintAngle }
        return SnapshotMode.ringGlintPhase ?? 0
    }

    var body: some View {
        dial
            // 弧的几何只在这一处算过。页面要放「字节离开这一段的动效」时不自己按
            // `regions(for:)` 再切一遍：那个 `zip` 剔掉零值段之后，页面的下标就跟
            // 弧对不上了（见 `slices`）。扫描中不报：那几秒弧一直在长，报一次就是
            // 一次整页的 `onPreferenceChange`，而扫描中本来也点不成。
            .preference(key: RingArcMapKey.self, value: scanning ? RingArcMap() : arcMap)
            .onAppear {
                run()
                // 入场动画走完才接这两根光。用的是**一次**延时，不是每条弧一个：
                // 0.9 秒那一段里环自己在往里长，而这一层只画得出「画完」的形状。
                // 但**静图与「减弱动态效果」那一趟直接放行**：那两趟没有入场循环可等，
                // 而真机上静止态的环上一直有这两根光——静图少画一半就是撒谎
                // （同 `canAnimate` 那条纪律：亮丝不藏，钉在一档）。
                if !canAnimate {
                    edgeWarm = true
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { edgeWarm = true }
                }
            }
        // 不按 segments.count 重放：总览是边扫边填的，段数一路 2→3→4→5，
        // 每次变化都把整圈打回零重扫，看着像坏了几次。
        .onChange(of: scanning) { now in
            // S0：读数头与常驻弧光**同时在环上**。扫描期间只关掉弧光的那一版，
            // 量完之前整圈只剩一道宽光束，招牌画面的「流动」在最长的那十几秒里消失。
            startSpin()
            // 「先有轮廓、再有实体」那一笔：一整圈量完，线框沿每条弧走一遍。
            // 只在**收尾**那一下走，不在开跑时走——开跑时环上还什么都没有。
            if !now { edgeFlash += 1 }
        }
        .onChange(of: armed) { path in
            guard path != nil, canAnimate else { pulse = false; return }
            withAnimation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        // 预演那截绿光弧的生长不在这里：动画量住在 `RingGainArc` 自己那格 `@State` 里，
        // 挂在这一层会让 1.05 秒里的每一帧都重算整个 `dial`（理由与实测数都写在叶子上）。
        // 悬停停在弧上的那一刻切页，`.onContinuousHover` 的 `.ended` 不保证会来（视图已经拆了）。
        // 不补这一下：旁边那列账会一直停在「一指退五」的样子，系统光标也留在手型上。
        // 光标由命中层自己在 `onDisappear` 里还回去——它才是那只改光标的手。
        .onDisappear {
            onHover?(nil)
        }
    }

    private var dial: some View {
        let slices = self.slices
        return ZStack {
            // 两层整圈的光，都垫在轨道**下面**——原型 DOM 就是这个顺序（halo → bloom → track → 弧）。
            // 压在弧上面会把三档灰洗成一档，垫在下面才是「整块盘坐在光里」：
            // 弧是把光盖住，光只从没画弧的地方（空闲那段、内孔）透出来。
            // 那两档能被 `DISKWISE_LIGHTS=halo,bloom` 逐个摘掉，是为了量出环外那圈灰阶
            // 各是谁抬的（规矩与理由记在 `RingLayers.lightsOff`）。同一个开关也管
            // `wall` / `bore` / `hairline` 这三块硬结构：加一层就得能摘一层。
            if !RingLayers.lightsOff.contains("halo") { layers.haloGlow }
            if !RingLayers.lightsOff.contains("bloom") { layers.bloomGlow }

            // 会搬走的那段自己发光。浅皮收到哪一档、糊开多远，连同那些实测读数
            // 都记在 `RingStyle`（reclaimGlow*）与 `RingLayers.reclaimGlow` 上。
            //
            // 这一组和下面那组带子**自己订阅** `hoverNote` 与 `preview`：悬停只让这两组
            // 重画，按住空格只让这两组退到后面，都不再经过 `SweepRing.body`。
            // 没有悬停可用的两处（引导页那面示例环、清理三屏那面只读的环）不传 `hoverNote`，
            // 这里给它们兜的是 `stillHover`，永远不会发变更；
            // 不吃预演的那两处挂的是 `stillPreview`，同理。
            RingGlowBands(note: hoverNote ?? Self.stillHover,
                          preview: preview ?? Self.stillPreview,
                          fallback: hoverFallback, layers: layers, slices: slices)

            // 盘自身的金属沿（样稿 `.wall`，排在弧**下面**）。它管的是「没光的那几段还连不
            // 连在盘上」：整圈对称、不随段色灭，所以空闲段的法向末端也有边。
            // 那道沿该落在 206→212，实测过 App 原来的环在这几段只有 63/62（样稿 141/144）——
            // 数与换算都记在 `RingStyle` 7b。
            if !RingLayers.lightsOff.contains("wall") { layers.wallRim }

            // 轨道：一整块盘的形状由它闭合。灰阶地板那一档为什么是 0.035，记在
            // `RingStyle.trackOpacityDark` 上。
            layers.track

            // 一段环带 = 底纹 + 段身 + 内侧暖沿 + 上膛描边，整段一起反应。
            // 这些弧一律不接事件（`visualBand` 末尾的 `allowsHitTesting(false)`），
            // 点击与悬停全交给 `ringHitLayer` 那一层按角度算。
            // `DISKWISE_LIGHTS=bands` 摘的是这一整摞（含上膛描边）——段身是环上唯一
            // 没有开关的实心绘制，2026-10-24 那条「最外一圈暖沿」就是被它挡在门外。
            if !RingLayers.lightsOff.contains("bands") {
                RingBands(note: hoverNote ?? Self.stillHover,
                          preview: preview ?? Self.stillPreview,
                          fallback: hoverFallback, layers: layers, slices: slices)
            }

            // 孔底那口井（样稿 `.bore`）：盖在弧**上面**，这是样稿的 z 序（弧 → bore → fx）。
            // 它也正是那团「洞里的雾」该被盖住的地方——样稿有 `.halo`，但那块不透明底板
            // 把它压到只剩弧缝里透出的一点，所以孔底读数 4–8；真机原来没有这块板，
            // 灯直接糊在卡片背景上，孔底 19–25，读起来像洞里着一团雾（数记在 `RingStyle` 7b）。
            // 盘心那三行数排在它后面，井是暗底、字是亮字，这个顺序不能倒。
            if !RingLayers.lightsOff.contains("bore") { layers.borePlate }
            // 环上两根光：扫描期那圈线框、量完之后那对能量流亮丝。画在弧**上面**、
            // 事件层**下面**。只有活的那一圈有它（参照盘与引导页不传 `hoverNote`），
            // 动画一律在 Core Animation 上跑——理由写在 `RingEdgeLights.swift` 顶部。
            // 单独一把 `DISKWISE_LIGHTS=edge` 给像素账（另有 `DISKWISE_EDGE=off` 管性能账）。
            if let note = hoverNote, !RingLayers.lightsOff.contains("edge") {
                RingEdgeLightsBands(note: note, fallback: hoverFallback,
                                    layers: layers, slices: slices,
                                    scanning: scanning, animate: canAnimate,
                                    preview: preview ?? Self.stillPreview,
                                    flowScale: style.previewFlowSpeedScale,
                                    flashTick: edgeFlash, warm: edgeWarm)
            }

            // 预演那一截「全部清空之后多出来的可用」。画在弧**上面**、事件层**下面**：
            // 它说的是一整圈的除法，不是某一段的位置，所以不许抢任何一条弧的点击。
            // 进不进树由这颗叶子自己跟着 `preview` 决定——写在这里就是让整棵 `dial`
            // 跟着一次空格重算（`RingGainArcHost` 上面记着这一发的实测账）。
            RingGainArcHost(preview: preview ?? Self.stillPreview,
                            layers: layers, target: gainTarget,
                            seconds: style.gainGrowSeconds, animate: canAnimate)
                .opacity(RingLayers.lightsOff.contains("gain") ? 0 : 1)

            // 整圈只有这一层接事件，且它画在弧**上面**：见 `ringHitLayer`。
            // `DISKWISE_LIGHTS=hit` 只为了像素账——摘掉它点击就没了，取证批不吃点击。
            if !RingLayers.lightsOff.contains("hit") { ringHitLayer }

            // 常驻反光画在**标签下面**。样稿里 `.glint` 排在最后，但样稿的刻字是亮字 + 暗晕，
            // screen 只往上提、字不会没；浅皮这层近白、0.62，压在深色数字上会把「16.0」
            // 洗成浅灰——光扫到哪一格，哪一格的数就淡一下（g0/g180 差图里那一块就是它）。
            // 光在带上走，字在光上面。
            if glint, !RingLayers.lightsOff.contains("glint") {
                layers.orbitGlint(glintAngle)
                    .allowsHitTesting(false)
            }

            // 弧上直接标数：让环和旁边那列账靠数对位，不必悬停才知道 16.4 是哪一段。
            // 只标数不标名——最短那段弧只有几十 px，写名字就会出现「为什么这两段没名字」。
            // 收成参照盘那一档（下钻时 132pt）整排都不标：带厚只剩 19pt、那段弧的弧长
            // 也只剩十几 px，六枚 11pt 的数会叠成一片字糊在环上。数全在右边那一列里。
            // 前两道门槛是材质数（`labelMinSpan` / `labelMinDiameter`，换材质就换阈值）；
            // 后两道是那本账自己说了算：`hidesArcValue` = 这条弧还在长、数不许印上去
            // （扫描中那条「其他已统计」），没名字的段则连对位的对象都没有。
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                if slice.span >= style.labelMinSpan && diameter >= style.labelMinDiameter
                    && !slice.seg.hidesArcValue && !slice.seg.label.isEmpty
                    && !RingLayers.lightsOff.contains("label") {
                    layers.arcLabel(slice)
                }
            }

            // 扫描期那圈刻度（样稿 `.ticks`）：排在反光**下面**、井**上面**，正是样稿
            // `toplight → ticks → glint → hairline` 里那一格。量完就整层撤掉。
            if scanning, style.tickOpacityDark > 0 || style.tickOpacityLight > 0,
               !RingLayers.lightsOff.contains("ticks") { layers.dialTicks }

            lights

            // 最外那道发丝（样稿 `.hairline`）：DOM 里排最后，也就是盖在弧、井、反光全部上面。
            // 它只管一件事——整块盘的轮廓是不是一个正圆。按段画的边会让亮段和暗段各收各的口，
            // 一圈连续的 0.8 px 才把六段收成一根棒。画在盘心那三行数**下面**（样稿 `.core`
            // 排在 `.ring` 之后），所以井是井、字是字。
            if !RingLayers.lightsOff.contains("hairline") { layers.outerHairline }

            VStack(spacing: 5) {
                // 那三行连同「此刻读哪一套」都在这颗叶子里。环底下那一摞的排布
                // （spacing 5、overlay 的 `.bottom` 基准）不能因为多包一层而变，
                // 所以这一摞仍留在父级的 VStack 里，叶子只交那三行。
                RingCenterReadout(preview: preview ?? Self.stillPreview,
                                  diameter: diameter, band: band,
                                  top: centerTop, value: centerValue, cap: centerCap,
                                  topPreview: centerTopPreview,
                                  valuePreview: centerValuePreview,
                                  capPreview: centerCapPreview)
                // S0 样稿里 ETA 下面还有一道细进度条：环上的弧在长，但那截暗轨
                // 容易读成「没有这回事」；一条从左往右填满的线把「还差多少」说死。
                if scanning {
                    scanBar
                        .padding(.top, 3)
                }
            }
            // `.mid .now`：只有悬停（或上膛）那几秒在，用灯色而不是灰——
            // 这一行是「你手上这一段是什么」，比旁边那两行口径更近。
            //
            // 它画在**布局之外**：挂到这一摞的 overlay 上，不参与 VStack 的高度。
            // 早先它是 VStack 的最后一个孩子，出现/消失会把整摞往上顶半个行高；
            // 这一步改布局本身不贵，贵的是它带着整扇窗重跑一轮 Auto Layout——
            // 环还在 SwiftUI 里每秒画 60 帧那会儿，这轮布局本来就在发生，免费搭了车；
            // 把环搬去 CA 之后它就现了原形：配对实测静置 1.6/1.9、悬停 6.6/6.8，
            // 尾段 p99 17.9/17.7、>33.4 23/27 次每 24 s（见 `PerfProbe` 顶部）。
            // 改成 overlay 之后布局不动，只有这一行字在换。
            //
            // 算哪一段、写什么，全交给这颗叶子自己现读：悬停每秒能来好几发，
            // 在这里算就等于让整圈跟着重算（`sample` 里那 670 个 `SweepRing.dial`
            // 样本正是这么来的）。叶子订阅 `hoverNote`，圆心的 body 一动不动。
            .overlay(alignment: .bottom) {
                // `alignmentGuide` 必须挂在 `Group` 上，不能挂进 `if` 里头：
                // 直接写在条件分支上的那条 guide 会被丢掉，overlay 退回默认的
                // 「底边贴底边」——悬停那两行字当场压在口径行上（2026-10-22 实拍）。
                Group {
                    if centerNowEnabled, let centerNowLine {
                        RingNowLine(note: hoverNote ?? Self.stillHover,
                                    preview: preview ?? Self.stillPreview,
                                    fallback: hoverFallback,
                                    segments: segments,
                                    line: centerNowLine,
                                    maxWidth: (diameter - 2 * band) * 0.78)
                    }
                }
                // 把这行的上沿钉在这一摞底边下方 5 pt：和它原先排在 VStack
                // 末尾、且不顶动大数时该在的位置一样。
                .alignmentGuide(.bottom) { d in d[.top] - 5 }
            }
            // 圆心那三行只是读数，不承担点击：热区一律交给下面的 `centerHitLayer`。
            // 文字框比孔小得多，事件层跟着 frame 走的话，字底下那片空会掉回环上。
            //
            // 圆心这一摞和 overlay 里那道叶子**都不挂隐式动画**：它跟着悬停
            // 出现/消失，而悬停是这一页每秒能来好几发的动作。挂在深叶子上的
            // `.animation(value:)` 会把整扇窗的 Auto Layout 按动画时长重跑一遍——
            // 翻勾那颗框上那段 `215 ms → 32 ms` 就是摘掉它换来的（见 `PerfProbe`
            // 末尾那条结论）。
            .allowsHitTesting(false)

            centerHitLayer
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// 圆心那道细进度条。宽度按样稿跟「已读 / 总数」那行同量级，
    /// 封在 196 pt：再宽的环也不让它长过那行字，否则读数变成图注。
    private var scanBar: some View {
        let progress = min(1, max(0, scanProgress))
        return ZStack(alignment: .leading) {
            Capsule().fill(theme.palette.separator.opacity(0.55))
            GeometryReader { g in
                Capsule()
                    .fill(lamp)
                    .frame(width: max(2, g.size.width * CGFloat(progress)))
            }
        }
        .frame(width: min(196, (diameter - 2 * band) * 0.55), height: 3)
        .animation(theme.animation, value: progress)
    }

    /// 内孔那一格也点得动：上膛之后点孔里任何地方＝取消。
    ///
    /// 半径卡在 `rIn - 2`，和 `ringArcIndex` 那条「带子以外一律不算」的下界同一档：
    /// 两层之间不留缝也不重叠，否则内沿上那两个像素会一会儿归环、一会儿归孔。
    /// 上一版把这个热区挂在圆心 `VStack` 上，而 `contentShape(Circle())` 吃的是
    /// 文字框的内切圆（半径 ≈87pt，孔有 118pt）——戳字底下那片空其实什么都没发生。
    private var centerHitLayer: some View {
        Color.clear
            .frame(width: (rIn - 2) * 2, height: (rIn - 2) * 2)
            .contentShape(Circle())
            .onTapGesture { tapCenter?() }
    }

    /// 圆心那个大数已经跟着那三行一起搬进 `RingCenterReadout`：那一档要跟着预演换数，
    /// 留在 `SweepRing` 里就得让整棵 `dial` 陪一次空格。
    private func run() {
        spinStart = Date()
        // 呼吸不在这里发条：`haloMotion` 让 `RingLayers.haloGlow` 把这一份画面
        // 交给 `CALoopView` 的图层动画，视图出现的那一刻就开始走（见 `RingLayers`）。
        guard !reduceMotion else { reveal = 1; return }
        reveal = 0
        withAnimation(.easeOut(duration: 0.9)) { reveal = 1 }
        entryBeam = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            entryBeam = false
            // 切回这一页时扫描早就完了，没人会再触发 `onChange(of: scanning)`：
            // 入场那道光走完就得把常驻的反光交出去，否则这一屏留下的是一张没有光带的环。
            // 扫描中也一样上发条：S0 要求读数头推进时弧光继续绕着走。
            startSpin()
        }
    }

    /// 环上的每一段 = 一块真实的字节。类型、切法与「为什么画的是 from/to、
    /// 命中比的却是 claim 区间」都记在 `RingSlice` 与 Core 的 `ringArcs` 上（SelfTest 逐段断言）。
    /// 往页面报的那一份弧表：键是 `armKey`（无路径的弧也有键），值是它此刻的角区间。
    private var arcMap: RingArcMap {
        RingArcMap(diameter: diameter,
                   band: band,
                   spans: Dictionary(slices.map { ($0.seg.armKey, $0.arc) },
                                     uniquingKeysWith: { first, _ in first }))
    }

    private var slices: [RingSlice] {
        let live = segments.filter { $0.value > 0 }
        // `zip` 不是随手写的：`regions(for:)` 会把 0 值的段整个剔掉，返回下标因此**不等于**
        // `segments` 的下标。谁以后图省事改成按下标取 `segments[i]`，就会把账配错到隔壁段上——
        // 弧亮的是缓存，点下去上膛的是废纸篓。
        return zip(live, layout.regions(for: live.map { $0.value })).map { seg, arc in
            RingSlice(arc: arc, seg: seg)
        }
    }

    /// 整圈的命中层：**只有这一层接事件**，落点归哪一段由 Core 的 `ringArcIndex` 算。
    ///
    /// 为什么不是一段一层铺 `contentShape(扇面)`：macOS 上的 `.onHover` 是宿主 NSView
    /// 里的 NSTrackingArea，跟的是**视图的 frame 矩形**、不吃 contentShape。于是一条弧的
    /// 悬停区是整个 340×340 的方框，最后画的那段（空闲）把上面几段全盖住——你报的那句
    /// 「无论点哪儿都是左上角这一块儿有反应」就是它（2026-09-25）。改成一层之后，
    /// 带子以外（孔里、环外）谁都不亮，带子里则按累计占比算出那一段。
    ///
    /// **不变量：这一层是环上唯一的悬停追踪层。** 往 `dial` 的任何子视图上再加 `.onHover`，
    /// 上面那个 bug 就原地复活。
    private var ringHitLayer: some View {
        RingHitLayer(diameter: diameter,
                     segment: { segment(at: $0) },
                     select: select,
                     onHover: onHover,
                     helpFor: { segHelp($0) })
    }

    /// 环心坐标系里的一个落点归哪一段；带子以外一律 nil。数学在 Core，SelfTest 逐段断言。
    ///
    /// 走 `layout` 而不是直接调 `ringArcIndex`：这两行参数里有三处半径
    /// （`diameter`/`rIn`/`rOut`），它们必须和 `visualBand` 画出来的那圈**同源**，
    /// 否则形状一换，画在 A 半径上、点算在 B 半径上。半径现在由 `layout` 一家算。
    private func segment(at p: CGPoint) -> GaugeSegment? {
        let ss = slices
        guard let i = layout.regionIndex(at: GaugePoint(x: Double(p.x), y: Double(p.y)),
                                         canvas: GaugeCanvas(width: Double(diameter),
                                                             height: Double(diameter)),
                                         regions: ss.map(\.arc), reveal: Double(reveal))
        else { return nil }
        return ss[i].seg
    }

    /// 扫描期那道光束。常驻反光已经挂到标签下面（见 `dial` 里那段），这里只剩
    /// `.beam` 一笔。两笔的驱动方式**不一样**，而且是故意分开的：
    ///
    /// - 入场那 0.9 秒：一条走完就停的行程，用 `TimelineView` 读时间，转到正上方收工。
    /// - 量盘中：不读进度，交给图层自己绕（`RingLayers.scanBeam`，3 秒一圈）。上一版把它
    ///   钉在字节边界上，而真机一次量盘是几十秒到三分钟——光就两秒跳一格，他看到的
    ///   「没这个动画」是这一条（2026-10-23）。样稿那段光也是**在走**的（`scan()` 里
    ///   `beam rotate(p*360deg)` 匀速一圈），进度从来不靠它报：靠的是盘心的数和环底那截线。
    @ViewBuilder private var lights: some View {
        // `DISKWISE_LIGHTS=beam` 摘这两道光（扫描期绕环的光束、入场那 0.9 秒的扫光）。
        if !RingLayers.lightsOff.contains("beam") {
            if entryBeam {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    layers.sweepBeam(beamAngle(tl.date))
                        .allowsHitTesting(false)
                }
            } else if scanning {
                layers.scanBeam(min(1, max(0, scanProgress)) * 360)
                    .allowsHitTesting(false)
            }
        }
    }

    /// 入场那道光此刻走到哪儿。0.9 秒、匀速、终点在正上方——正上方是「整圈量完」那一格，
    /// 它停在那儿，接得上随后绕环的那道扫描光和常驻反光（两者都从 0° 起算）。
    private func beamAngle(_ now: Date) -> Double {
        let p = now.timeIntervalSince(spinStart) / 0.9
        return min(1, max(0, p)) * 360
    }

    /// 反光开始绕环：画面只画一次，9 秒一圈的转交给 `CALoopView` 的图层动画，与原型同速。
    /// 一圈量完了边界在正上方，所以起算点就是 0°，它正好接在入场那道光束停下的那一格上。
    /// 这里只负责「该不该亮」：动画由宿主持有，重扫、切页回来都不会被搬回 0°。
    /// 截图模式下照样亮，但相位由 `DISKWISE_RING_GLINT` 钉住（见 `lights`）。
    private func startSpin() {
        spinStart = Date()
        glint = !reduceMotion
    }

    /// 悬停在弧上的那句话必须跟旁边那一行说的是同一件事：一处写「跳到下面」、
    /// 一处写「去另一页」，人点了才会被画面甩到他没预期要去的地方。
    ///
    /// 这一页现在只有一本账：摊明细的弧说的是「摊开」，只有「本次移入废纸篓」那条
    /// 真去另一页。
    private func segHelp(_ seg: GaugeSegment) -> String {
        if let hint = seg.hint { return hint }
        if seg.drill != nil { return LF("点开摊开「%@」的明细", seg.label) }
        if seg.jumpTo != nil { return LF("点这一条去另一页看「%@」", seg.label) }
        return seg.label
    }

    private var accessibilitySummary: String {
        let parts = segments.filter { !$0.label.isEmpty }.map { "\($0.label) \($0.sizeShown)" }
        return LF("磁盘占用环形图：%@", parts.joined(separator: L10n.isHanScript ? "，" : ", "))
    }
}

// MARK: - 环上的墨

extension SweepRing {
    // 这三档不上色的底：动得了的段用主色，其余只能靠灰的深浅分层。
    //
    // 这三档必须**分得开**，而且必须**比金色暗**。上一版 blocked 0.17 / unmeasured 0.45 /
    // 空闲用 separator，实拍逐段量出来是 (71,68,62)、(70,65,55)、(58,52,44)——三档灰差不到 12，
    // 眼睛读成「一坨等大的灰」，也就是默认饼图。原型敢让空闲段几乎不画，
    // 是因为它把「一整块盘」这个形状交给轨道去闭合。
    // 0.10 / 0.22 是照着轨道 0.035 这条底线排的，三档每一步都看得见，
    // 而最亮那档也还不到金色的一半。
    // 深皮换成 `greyInk` 之后透明度按 247/164≈1.5 乘上来补回亮度，分层原样不动：
    // 实拍带中圈灰弧 L 77.6（金色那档 215），而红道减蓝道从 ink 版的 +47 收到 +23
    // （样稿同位 +20）——环带上的芥末味就是这么没的。
    // 2026-09-25 用 measure_ring.py 在**同名槽位**上重量了一遍，三档全都比样稿暗
    // 20~34 个灰阶：我这边 (63,61,53) / (82,84,80) / (51,48,35)，样稿带中圈
    // mix(其他已统计) (97,89,77)、dust(没量到) (93,90,88)、free(空余) (71,60,47)。
    // 于是整圈只剩那一条金弧看得见，「这一圈 = 整块盘」当场不成立——
    // 样稿那张图首先是一块**亮**的盘，其次才是金。
    // 分层也不再按「越亮越要紧」排：样稿的 mix 与 dust 一样亮（差 4 个灰阶），
    // 把它们分开的是色温，R−B 一个 +20 一个 +5。所以这里暖＝量到了、冷＝没量到，
    // 空闲单独压到 L≈62 当这条带的地板（它比轨道亮，但一眼读得出「没画东西」）。
    // 差多少按当天的实测比补：样稿带中圈 / 我这边 = 97/86、93/84、71/61，
    // 于是 0.23→0.26、0.40→0.44、0.09→0.105。透明度到像素不是线性的（底下还压着
    // 轨道和卡面），所以补完必须再量一遍，不能当算完了。
    //
    // 为什么这几个函数在环上而不在 `RingStyle` 里：`RingStyle` 装的是**一款材质**的数，
    // 而这三档灰两套材质（`shipped` / `crystal`）共用一份，且必须跟着皮肤取色
    // （`palette.ink` / `palette.tint`）——和 `lamp(_:)` 同一类，所以放在一起。
    // 搬过来的另一个理由是**第二个用环的人**：首次运行那一屏（`FirstRunView`）要画一枚
    // 示例环教同一套颜色语言。写在 `OverviewView` 里就是私有配方，第二个调用方只能重抄一遍，
    // 而重抄的灰迟早和真页面对不上——那条弧到底动得了动不了，界面全靠这一档灰说话。

    /// 暖底：量到了、但这一屏不动手的那一档用的底色。浅皮就是正文墨，深皮是暖白。
    static func warmInk(theme: Theme, dark: Bool) -> Color {
        dark ? Color(red: 247 / 255, green: 246 / 255, blue: 243 / 255) : theme.palette.ink
    }

    /// 冷底：压根没量到的那一档。样稿的灰从来不是中性灰（`.seg.dust` 写的是
    /// `rgba(150,164,182,.30)`，一条**蓝灰**）。深皮这一圈底下垫着金色余晖，
    /// 正文 ink 透上去读出来是芥末（实拍量到蓝道比红道低 47，样稿只低 19），
    /// 把蓝道抬回去灰才读成灰；透明度按 247/164 补回亮度，三档落差原样不动。
    static func greyInk(theme: Theme, dark: Bool) -> Color {
        dark ? Color(red: 150 / 255, green: 164 / 255, blue: 182 / 255) : theme.palette.ink
    }

    /// 量到了、动不了（前几名为 0 的那几段、以及「其他已统计」里一分都腾不出来的那些）。
    static func blockedInk(theme: Theme, dark: Bool) -> Color {
        warmInk(theme: theme, dark: dark).opacity(dark ? 0.26 : 0.09)
    }

    /// 压根没量到的那几处卷账。
    static func unmeasuredInk(theme: Theme, dark: Bool) -> Color {
        greyInk(theme: theme, dark: dark).opacity(dark ? 0.44 : 0.16)
    }

    /// 空闲：≈ 轨道，几乎不画，但要它闭合整圈。
    ///
    /// 深皮这一档 2026-10-24 从暖白换到 `greyInk`（蓝灰），0.105 → 0.13。原因是他圈出来的
    /// 那半圈「黑灰色」：空闲占他整块盘的 43%，环上最大一块面色由这段说了算，而它原先的
    /// 身子按 `tubeArcsOpaque` 预合成到卡面 `#16181D` 上是 **(46,47,52)——极差只有 6 档的
    /// 近中性灰**。身子是死灰，棒形再怎么调都只是「灰带子上画了一道亮线」，不是玻璃。
    /// 换到蓝灰后同处 (39,42,49)、极差 10、蓝道比红道高 10 档，和环外那圈反光同一色系；
    /// 「空着的地方」本来就该和「压根没量到」共用一支冷灰，暖白留给「量到了、不动手」。
    /// 0.13 对 `unmeasuredInk` 的 0.44 那道落差照旧，浅皮两支函数都返回 `palette.ink`，
    /// 那一路一个像素没动。
    static func freeInk(theme: Theme, dark: Bool) -> Color {
        greyInk(theme: theme, dark: dark).opacity(dark ? 0.13 : 0.025)
    }

    /// 已经搬进废纸篓、还没让位那一档：主色压淡 + 虚线。它比 `blockedInk` 亮、比灯色暗，
    /// 因为这段字节**还占着盘**，只是换了地方。
    static func movedInk(theme: Theme, dark: Bool) -> Color {
        lamp(theme.palette.tint).opacity(dark ? 0.62 : 0.48)
    }
}

/// 环带上那两组会跟着悬停变的东西。`SweepRing` 只把信号**递进来**，自己不订阅：
/// 一订阅，每次换段都要让整个 `dial` 重算（轨道、六枚弧上数、命中层、四层光），
/// 2026-10-22 的 `sample` 里那是 670 个主线程样本、外加 401 次 `frame` 重算。
/// 这两颗叶子的 body 只有几条弧，换一段只重画一段。
private struct RingBands: View {
    @ObservedObject var note: LedgerHoverSignal
    @ObservedObject var preview: PreviewSignal
    let fallback: String?
    let layers: RingLayers
    let slices: [RingSlice]

    var body: some View {
        let hovered = note.label ?? fallback
        // 退到后面那一档在**这一颗叶子里**现兑：`layers` 是从 `SweepRing.frame` 来的，
        // 那一帧故意不带预演（带了就让整棵 `dial` 跟着空格重算，见 `SweepRing.frame`）。
        let ls = layers.previewed(preview.on)
        ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
            ls.visualBand(slice, hovered: hovered)
        }
    }
}

private struct RingGlowBands: View {
    @ObservedObject var note: LedgerHoverSignal
    @ObservedObject var preview: PreviewSignal
    let fallback: String?
    let layers: RingLayers
    let slices: [RingSlice]

    var body: some View {
        let hovered = note.label ?? fallback
        let ls = layers.previewed(preview.on)
        ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
            if slice.seg.reclaim > 0, !RingLayers.lightsOff.contains("reclaim") {
                ls.reclaimGlow(slice, hovered: hovered)
            }
        }
    }
}

/// 预演那一截绿光弧，**连同它的生长一起住在这里**。
///
/// 为什么必须是颗叶子：生长是 1.05 秒里每一帧都在变的一个数。原先 `gainShown` 挂在
/// `SweepRing` 的 `@State` 上，于是每一帧都重算整个 `dial`——轨道、六枚弧上数、
/// 命中层、四层光、两根亮丝、盘心三行，全跟着那条会变的弧走一遍。
/// 2026-10-22 用 `sample` 量的：0.4 s 压一次空格，主线程 49 %、83 格 >16.7 ms、
/// 55 格 >100 ms（同场对照：静帧 1.9 % / 0 格 / 0 格；已上线的上膛 24.7 % / 55 格 / 4 格）。
/// 栈里最热的三格是 `SweepRing.frame`/`body`/`dial` 的 getter。
/// 挪进来之后每帧只有这一条弧自己重画。
///
/// 跟 `RingBands` 那条是同一个修法，只是这里动的不是悬停信号而是动画量。
private struct RingGainArc: View {
    let layers: RingLayers
    let target: CGFloat
    let seconds: Double
    let animate: Bool
    @State private var shown: CGFloat = 0

    /// 量具：`DISKWISE_GAIN=off` 把这一整层摘掉。预演那一发为什么贵，得先分清是
    /// 这截带模糊和两道投影的弧，还是旁边六颗角标加底下那条决策条——配对跑两次
    /// PerfProbe 才量得出来。规矩同 `RingEdgeLightsBands.offByEnv`：环上任何一层
    /// 都要有一个能摘掉它的开关，否则它的价永远是一笔糊涂账。
    static let offByEnv: Bool = {
        (ProcessInfo.processInfo.environment["DISKWISE_GAIN"] ?? "").lowercased() == "off"
    }()

    var body: some View {
        layers.gainArc(fraction: shown)
            .onAppear {
                // 减弱动态效果与截图那一趟不等这一秒：静图要拍到的就是长到位的那一截。
                guard animate else { shown = target; return }
                // 插进树的那一帧这个视图还不存在，`withAnimation` 追不上它，
                // 所以推到下一轮再动——同 `edgeWarm` 那一次延时是同一个道理。
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: seconds)) { shown = target }
                }
            }
    }
}

/// 预演那截绿光弧的**闸门**。
///
/// 它存在的理由跟 `RingBands` 那两条一模一样：「这一档进不进树」要是写在 `dial` 里，
/// 那个判断就得读 `previewing`，而读它的那个视图就得订阅它——一发空格就把整棵 `dial`
/// 重算一遍（轨道、六枚弧上数、命中层、四层光、两根亮丝、盘心三行）。同一发空格在
/// `sample` 里的账：主线程 49 %、83 格 >16.7 ms、55 格 >100 ms（0.4 s 一次，同场静帧
/// 1.9 % / 0 / 0）。挪到这里之后，空格只让这一颗叶子的 body 换一个 `if`。
///
/// 弧自己那格 `@State shown` 仍留在 `RingGainArc` 里：闸门只决定它在不在这儿，
/// 一出现就从 0 长到 `target`，松手拆掉时那截生长跟着消失——这是这一档该有的样子。
private struct RingGainArcHost: View {
    @ObservedObject var preview: PreviewSignal
    let layers: RingLayers
    let target: CGFloat
    let seconds: Double
    let animate: Bool

    var body: some View {
        if preview.on && !RingGainArc.offByEnv {
            RingGainArc(layers: layers, target: target,
                        seconds: seconds, animate: animate)
        }
    }
}
/// 盘心最底那句副读（样稿 `.mid .now`）。自己订阅、自己算，圆心的 VStack 不参与——
/// 它跟着悬停出现/消失，而悬停是每秒好几发的动作。
private struct RingNowLine: View {
    @Environment(\.theme) private var theme
    @ObservedObject var note: LedgerHoverSignal
    /// 预演那几秒这一句要让位（盘心此刻报的是「全部清空之后」，鼠标划过弧不能把它换成
    /// 「这一条 6.3 GB」）。这一档由叶子自己判：写在页面上就是让整页跟着空格重算一次。
    @ObservedObject var preview: PreviewSignal
    let fallback: String?
    let segments: [GaugeSegment]
    let line: (GaugeSegment) -> String
    let maxWidth: CGFloat

    var body: some View {
        if !preview.on, let seg = (note.label ?? fallback).flatMap({ label in
            segments.first { $0.label == label }
        }) {
            Text(line(seg))
                .font(theme.numeric(size: 11.5))
                .monospacedDigit()
                .foregroundStyle(SweepRing.lamp(theme.palette.tint))
                .opacity(0.9)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: maxWidth)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 圆心那三行读数，**连同「此刻读哪一套」一起住在这里**。
///
/// 为什么不由页面挑好了传一行进来：预演那一档盘心要说另一笔账（「全部清空后 / 26.8 /
/// 这一笔还没发生·松开空格就回去」），而这些句子只有页面算得出来——那本账在视图里。
/// 页面一挑就得订阅「在不在预演」，一发空格于是变成**整页重算**：`OverviewView.body`、
/// `SweepRing.body`、`dial` 全跟着走一遍。同场配对实测（30 s 探针、`DISKWISE_PERF_PREVIEW=1.6`、
/// 尾段 22.7 s；那一趟用当时还在的 `DISKWISE_RINGPREV=off` 把整圈钉死，隔离出的正是
/// 「只剩页面重算」这一笔。改成叶子之后那颗开关已摘，分账改用逐层开关）：
/// 尾段 p99 35.9 ms、最长一格 100.1 ms、主线程 9.8 %，同场静帧地板 p99 9.4 ms / 5.3 %。
/// 两套句子都在场、由这颗叶子自己挑，页面一个字都不用重算。
///
/// `topPreview` 给空串 = 这一圈不接预演，于是永远读上面那三行。两种不给法：引导页那面
/// 示例环与清理三屏那面只读的环根本不留预演的引用（挂的是永不发变更的哑信号），
/// 总览那面在扫描/代价读法里由页面传空串（`holdPreview` 那三句拒绝的同一判据）。
private struct RingCenterReadout: View {
    @Environment(\.theme) private var theme
    @ObservedObject var preview: PreviewSignal
    let diameter: CGFloat
    let band: CGFloat
    let top: String
    let value: String
    let cap: String
    let topPreview: String
    let valuePreview: String
    let capPreview: String

    private var on: Bool { preview.on && !topPreview.isEmpty }
    private var t: String { on ? topPreview : top }
    private var v: String { on ? valuePreview : value }
    private var c: String { on ? capPreview : cap }

    var body: some View {
        VStack(spacing: 5) {
            if !t.isEmpty {
                // 这句问话用主色，不用灰：原型里它是 `.eyebrow`＝灯色。
                // 灰的话圆心只剩一个大数，而那个数不带单位口径——「6.3」到底是
                // 还能腾出、还是已经搬走，全靠这一行说清。
                // 预演那几例外：这句说的是「全部清空之后」，一笔还没发生的账，
                // 用绿（皮肤里「零代价、现在动得了」那一档的字色）而不是灯色，
                // 人才不会把它读成今天的可用。同 `RingLayers.gainArc` 一个颜色。
                Text(t)
                    .font(theme.bodyFont(.caption))
                    .tracking(0.6)
                    .foregroundStyle(on ? theme.palette.safeFG : theme.palette.tint)
            }
            heroNumber
            if !c.isEmpty {
                Text(c)
                    // 10.5 = 420 那一档的 0.025 倍。环里其他字都按直径等比
                    // （大数 0.21、带厚 0.145），这一行以前是死的：环一收，
                    // 孔按比例小下去而字号不动，「已用 80.0 GB」的 `GB` 就被甩成
                    // 孤零零一行（2026-09-28 实拍 900 pt 窗，中英各一版）。
                    // 地板 8.5 以下就不等了——那已经是「看不清」而不是「排不下」。
                    .font(theme.numeric(size: max(8.5, diameter * 0.025)))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.inkTertiary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    // 216 那个数是原型量出来的：cap 落在圆心下方，那里内孔的弦只有
                    // 2×√(R0²−y²)。换成按孔直径排字，字会压到环带上把段上的数盖住。
                    .frame(maxWidth: (diameter - 2 * band) * 0.78)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 圆心那个大数：数字给满，单位收到三分之一。
    /// 「17.9」和「GB」一样大的话，这一格读起来是一行标签而不是一个答案。
    ///
    /// 不用 `Text + Text` 拼：那个写法要 macOS 14 才有的 `Text.foregroundStyle`，
    /// 而基线对齐的 HStack 在 13 上就是同一件事。
    private var heroNumber: some View {
        let parts = v.split(separator: " ", maxSplits: 1,
                            omittingEmptySubsequences: true)
        let num = parts.first.map(String.init) ?? v
        let unit = parts.count > 1 ? String(parts[1]) : ""
        // 0.21 / 0.30 都是从样稿量过来的：`.mid .hero-num` 92px 挂在 412 的环上＝0.223，
        // 单位 `u` 是 `.30em`。上一版取 0.175，换成 340 的环只有 59.5pt，
        // 圆心那枚数比旁边账目行的 17pt 强不了多少——招牌画面里最该最大的数不是最大的。
        let size = diameter * 0.21
        return HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(num)
                .font(theme.numeric(size: size, weight: .light))
                .monospacedDigit()
                // 样稿 `.hero-num` 的字面自带一道纵向渐变（#fff 6% → ink 52% 78%，
                // background-clip:text）。纯色的一枚大数是「印」上去的，带渐变才是
                // 「被那圈光照出来」的——这一屏的光源是环，字要跟着环走。
                // 浅皮下 ink 是深色，同一道渐变读作「上实下虚」，方向不用换。
                .foregroundStyle(LinearGradient(colors: [theme.palette.ink,
                                                         theme.palette.ink.opacity(0.52)],
                                                startPoint: .top, endPoint: .bottom))
            if !unit.isEmpty {
                Text(unit)
                    .font(theme.numeric(size: size * 0.30, weight: .regular))
                    .foregroundStyle(theme.palette.inkSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // 这里刻意不加 `contentTransition`：圆心那个数从 0 滚到 17.9 的每一帧
        // 都在说一个错数。弧和带子可以过渡，数不行。
        .accessibilityElement(children: .combine)
    }
}

/// 整圈的命中层。从 `SweepRing` 拆出来，是因为它身上有两格状态（手型、当前段）——
/// 留在 `SweepRing` 里，鼠标每跨一段就让整圈重算一次，而它要改的只是一句 tooltip。
/// 这里改的都是自己的 @State，环那几个大视图一个字都不动。
private struct RingHitLayer: View {
    let diameter: CGFloat
    let segment: (CGPoint) -> GaugeSegment?
    let select: ((GaugeSegment) -> Void)?
    let onHover: ((String?) -> Void)?
    let helpFor: (GaugeSegment) -> String

    /// 此刻环上是不是「点得动」的那一段——只用来记手型光标该不该是手，
    /// 免得每次 `mouseMoved` 都去刷一遍系统光标。
    @State private var cursorHand = false
    @State private var lastLabel: String?
    @State private var help = ""

    var body: some View {
        Color.clear
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = segment(p)
                    // 扫描中那截暗轨是一段 label 为空的填充弧：它只负责把圆闭合，
                    // 不是一条「谁的账」。不映射成 nil 的话，鼠标扫过未量区会把整列
                    // 账当成「有别处在被指」一起压暗。
                    let label = (seg?.label).flatMap { $0.isEmpty ? nil : $0 }
                    // 只有**换段**时才回调。`mouseMoved` 每挪一个像素就来一次，上一版每次都
                    // 写页面那格悬停状态，于是鼠标在环这 420×420 里划过＝每秒几十次整页
                    // body 重跑（环形账、右边那列、下面整列热点行、缓存目标全过一遍）。
                    // 他报的「鼠标放到右边的目录上经常卡顿」就是这个空转。现在写的是
                    // `LedgerHoverSignal`，整页不订阅，只有环上两组带子和行里那三颗小叶子重算。
                    if label != lastLabel {
                        lastLabel = label
                        help = seg.map(helpFor) ?? ""
                        onHover?(label)
                    }
                    // 样稿 `.seg.hot{cursor:pointer}`：只有真收得走的段才配变手型，
                    // 动不了的段给个手型就是骗人来点。代价读法整圈不接点击（`select == nil`），
                    // 那几类再「可勾」也不该长出手型——手型说的是「这一下按得动」。
                    setHand(select != nil && (seg?.reclaim ?? 0) > 0)
                case .ended:
                    lastLabel = nil
                    help = ""
                    onHover?(nil)
                    setHand(false)
                }
            }
            // 弧也能点：这一屏的招牌画面就是「哪一段占地方」，人第一眼戳的是图上那一块，
            // 不是旁边那行字。旁边的行仍是同一条动作的兜底（读屏只走得到行）。
            //
            // 为什么不用 `.onTapGesture`：macOS 13 它不给坐标，而**点在哪一段**必须由
            // 按下那一刻的落点决定。上一版读的是「上一次悬停停过的位置」，快速划过再点
            // 就会上膛另一条弧——而第二下是真把目录搬进废纸篓的那一下。
            // 用 `simultaneousGesture` 而不是 `gesture`：后者会吃掉从环上起手的滚动。
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onEnded { ev in
                    guard hypot(ev.translation.width, ev.translation.height) <= 4 else { return }
                    if let seg = segment(CGPoint(x: Double(ev.location.x),
                                                 y: Double(ev.location.y))) { select?(seg) }
                }
            )
            .help(help)
            // 切页/换皮肤时 `.ended` 不保证会来，箭头得自己还回去。
            .onDisappear {
                onHover?(nil)
                NSCursor.arrow.set()
            }
    }

    /// 手型光标只在该变的时候变。每次 `mouseMoved` 都 `set()` 一遍是白刷。
    private func setHand(_ on: Bool) {
        guard cursorHand != on else { return }
        cursorHand = on
        (on ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
}

/// 环形旁边那一行：色块 ↔ 弧上的亮度一一对位，右边那个数就是弧上写的数。
///
/// 段名不写在环上——六段里只有四段的弧够宽，写上去就是「为什么这两段没名字」。
/// 名字、这句话是什么、动得了多少，全落在这一行上。
///
/// 上膛的那一行跟着一起亮：眼睛在环上，手可能还在列表上。
struct RingLedgerRow: View {
    @Environment(\.theme) private var theme

    /// 这道条最窄压到 136：再窄就配不上它上面那行名字（`~/openclaw-private-backup`
    /// 这类长路径本来就在中间截断），条子内那格也不再代表一个能读的量。
    /// 136 的来历：`ledgerFloor` 还写 336 的那一版，窗口收到最窄一档时这一列只剩 336，
    /// 而条子按 150 不让时整行要 344——差的那 8 pt 正好把行尾那列数推出窗口边
    /// （2026-09-28 实拍 `liveC/s232-900`）。后来把 336 换成逐颗点图量出来的压不动档 356
    /// （`OverviewView.ledgerFloor`），这一列不再靠条子让步来救，136 于是退成上面那句
    /// 「配不上那行名字」的下限，不再同时承担「别让数出界」那条责任。
    /// 整行（连同右边那一整列账）压不动的那一档，量在 `OverviewView.ledgerFloor`——
    /// 那一列里除了这道条还有行尾那簇数和「各段之和」那行分母，只有列知道全部。
    static let barFloor: CGFloat = 136

    var seg: GaugeSegment
    /// 这一段占整块盘的比例。以前这个信息只画在页面最底下那条没标签的带子上，
    /// 读不出哪一段是哪一段（2026-09-27），于是把它搬到它描述的那一行上来。
    var fraction: Double = 0
    var armed: Bool = false
    /// 悬停那条通知线。**行体不订阅它**：指着哪一行每秒能来好几发，
    /// 而这一行是整页最重的一颗视图；订阅它的只有行尾那枚数、底光、
    /// 整行暗态三颗小叶子（见 `HoverSpotlight` / `HoverNumber`）。
    var hoverNote: LedgerHoverSignal? = nil
    /// 这一行上面要不要画那道分隔线（样稿 `.row+.row::before`，第一行没有）。
    var showRule: Bool = true
    var onHover: ((Bool) -> Void)? = nil
    /// 「点两次才收走」那一档。命中区是行尾那道 `›` 连同它管着的那个数（`armCluster`）；
    /// 没有下一级的行（`onExpand == nil`）整行左半块也落回这里，那一行本来没别的动作。
    var tap: (() -> Void)? = nil
    /// 这一段已经摊开了没有——只决定行首那个记号朝右还是朝下。
    var expanded: Bool = false
    /// 摊明细，**整行左半块**（记号 + 名字 + 条子）都是它的命中区：2026-09-27 他
    /// 点的就是这里——「只点左边那颗箭头才摊开，体验不好」。那颗 `▸` 于是退回成记号。
    /// nil = 这一段没有下一级，行首留一个空槽把名字对齐在原处。
    /// 它**不碰两段式确认**：点它只摊明细，不上膛、不搬东西。
    var onExpand: (() -> Void)? = nil
    /// 行尾那颗「去授权」。整盘账里只有这一处要点开系统设置，而它原本挂在
    /// 「没量到的地方」那段明细里——明细收起来就等于把唯一的入口一起藏了。
    var onGrant: (() -> Void)? = nil
    /// 行尾那颗「访达显示」。只在**这一行摊开着**的时候给：招牌那一屏六行全带它会把
    /// 列宽吃光（环还占着 420），而人真要用它，是在看完这一段明细之后想去盘上确认一眼。
    var onReveal: (() -> Void)? = nil
    /// 行尾那颗「深挖」：带着这一个目录去大文件页做定向扫描。
    ///
    /// 从前它常驻在「最占地方的文件夹」每一行上；那一段列表被收进这本账之后，
    /// 它只跟着**摊开着的那一行**出现，跟「访达显示」同批。一整列六行全挂两颗钮，
    /// 这一列就没法读了，而「去大文件页细看」是看完明细之后才产生的念头。
    var onDeepDive: (() -> Void)? = nil
    /// 这一列窄到装不下「去授权」那三个字时收成只有图标。
    /// 带字的那颗要 84 pt，整行于是从压不动的 336 抬到 414；这本账在默认窗口里
    /// 只有 364，那一行会把行尾的数顶出窗口边——而它是全页唯一一处要点开系统设置的地方，
    /// 不能因为窄就整颗删掉，所以退成图标，`help` 里仍然写全去哪勾。
    var grantCompact: Bool = false
    /// 「刚从预演里给整圈上了膛」那一档（`armedPath == SweepRing.armAll`）：这一档下
    /// 每一行末尾也挂着那截 `+N`——人看的正是「按下去会拿走哪几笔」，撤掉等于把确认的
    /// 凭据撤走。这一位是 `@Published` 上的账，页面本来就跟着它重算，所以由页面传进来。
    var afterClearAll: Bool = false
    /// 预演（按住空格）时，这一行小字末尾多接一截绿色的 `+N`（稿子⑪）用的那条通知线。
    ///
    /// **行体故意不订阅它**：这一行是整页最重的一颗视图，一发空格让六行一起重算就等于
    /// 让右边那本账重排一次。只有末尾那一句（`LedgerSubLine`）订阅。
    ///
    /// 数由 `GaugeSegment.reclaim > 0` 在叶子里筛：动不了的段没有「+」可挂，挂了就是在
    /// 许一笔收不走的账。样稿把这颗放在**名字后面**（`.lrow .gain`），这里挪到行尾那簇数
    /// 旁边，两个理由：①我们的名字会长到中间截断（`~/openclaw-private-backup` 这类），跟在
    /// 名字后面的数会被截断吃掉一半，跟在数后面永远看得见；②这六颗并排成一列才读得出
    /// 「每一行各加多少、加起来就是这一圈动得了的那个总数」——它是一列账，不是六句注脚。
    let preview: PreviewSignal

    var body: some View {
        // 悬停那三样（底光、暗态、行尾数的色）住在这一层壳里，不住行体：
        // 壳订阅通知线，行体不订阅。悬停换一行只重算这一壳，账目行的正文
        // （名字、小字、条子、四颗钮）一个都不重算。
        if let hoverNote {
            chrome.modifier(HoverSpotlight(note: hoverNote, label: seg.label, armed: armed))
        } else {
            chrome
        }
    }

    private var chrome: some View {
        HStack(alignment: .center, spacing: 12) {
            // 行首那一格：能勾的那几行放勾选框，其余放行档色块。两种都占满 16 pt，
            // 六行的名字才对齐在同一条竖线上。
            //
            // 框必须住在展开按钮**外面**：点框只改「这一类算不算进这一笔」，
            // 点名字才是摊明细。同一块落点兼两件事，浏览明细的手势会误改承诺。
            leadingSlot
            // 摊明细住在**整行的左半块**，不住那颗 12pt 的箭头：2026-09-27 他点的就是这里
            // ——「点这一行就要圆环缩小，只点左边箭头才缩小，体验不好」。命中区照 `ItemRow`
            // 那一套给（箭头 + 名字 + 条子一起算），换页时点的还是同一块地方。
            Button(action: { (onExpand ?? tap)?() }) {
                HStack(alignment: .center, spacing: 12) {
                    // 槽位固定 12pt、不按段给 0/12——六行的名字要对齐在同一条竖线上，
                    // 有箭头的行缩进去、没箭头的顶到边，这一列就读不成一列了。
                    if onExpand != nil {
                        ThemeChevron(expanded: expanded, color: theme.palette.inkSecondary)
                            .frame(width: 12, height: 12)
                    } else {
                        Color.clear.frame(width: 12, height: 12)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seg.label)
                            .font(theme.bodyFont(.callout))
                            .foregroundStyle(theme.palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !seg.sub.isEmpty {
                            // 样稿 `.row .sub b`：小字里只有「还剩多少能搬走」这一个数染灯色，
                            // 后半句「已搬走 x」保持灰的。全染就没有重音了。
                            //
                            // 这一句是颗自己订阅预演的叶子：末尾那截 `+N` 跟着空格走，
                            // 但只有这一句跟着重算，行体（名字、条子、四颗钮）一个字不动。
                            LedgerSubLine(preview: preview, seg: seg, all: afterClearAll)
                        }
                        // 232 是「满幅」那一档，跟其余六页 `ItemRow` 那道条同一个尺寸，
                        // 换页时「一格的长度代表多少」不用重新学。区别只有一条：这一屏的
                        // 条子可以让到 `barFloor`，因为环和它住在同一行里——窗口收到最小那
                        // 一档时不让步的就是右边那列数被推出窗口边（2026-09-28 实拍）。
                        // 颜色走 `ItemRow` 那条老规矩（`DESIGN.md` §6 第 4 条）：灯色只给动得了的，
                        // 其余一律 `inkTertiary`。**不拿 `seg.color`**——档色是为环上那条大弧调的，
                        // 「没量到」「可清除」在浅皮下本来就只有 9%~16% 的不透明度，
                        // 压进 3 磅高的条里就等于没画，一格 42.6 GB 的行会看着像 0。
                        // 哪一档仍然认得出来：行首那 16 pt 那一格就是档色。
                        ProportionBar(fraction: fraction,
                                      color: seg.costClass
                                            ? seg.color
                                            : (seg.reclaim > 0
                                                ? SweepRing.lamp(theme.palette.tint)
                                                : theme.palette.inkTertiary),
                                      track: theme.palette.surfaceAlt,
                                      height: 3, trackWidth: 232,
                                      minTrackWidth: Self.barFloor)
                            .padding(.top, 5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(onExpand == nil ? seg.label
                : (expanded ? LF("收起 %@ 的明细", seg.label)
                            : LF("摊开 %@ 的明细", seg.label)))
            Spacer(minLength: 6)
            armCluster
            if let onGrant {
                ThemeButton(kind: .compact, symbol: "lock.open",
                            title: grantCompact ? "" : L("去授权")) { onGrant() }
                    .accessibilityLabel(L("去授权"))
                    .help(L("打开「系统设置 › 隐私与安全性 › 完全磁盘访问权限」；勾完要重启 DiskWise 才生效"))
            }
            if let onReveal, let path = seg.path {
                ThemeButton(kind: .ghost, title: L("访达显示")) { onReveal() }
                    .help(LF("在访达里打开 %@", path))
            }
            if let onDeepDive, let path = seg.path {
                ThemeButton(kind: .ghost, title: L("深挖")) { onDeepDive() }
                    .help(LF("只扫 %@ 这一棵，去大文件页列它名下最大的那些文件", path))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            if showRule {
                Rectangle().fill(theme.palette.separator.opacity(0.7))
                    .frame(height: 1).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onHover { onHover?($0) }
        .help(seg.hint ?? (seg.drill == nil ? seg.label
                                             : LF("点开摊开「%@」的明细", seg.label)))
        .accessibilityElement(children: .combine)
        .accessibilityHint(onExpand == nil ? ""
                        : LF("点这一行摊开「%@」的明细；带着那道记号的数点两次才收走", seg.label))
    }

    /// 行首那一格：8×8 的档色块，占满 16 pt 的槽，六行的名字才落在同一条竖线上。
    ///
    /// 8×8 的圆角小方块不是竖条：上一版画成 8×20，六行排下来像六根文本光标插在那儿。
    /// 它只说一件事——「这一格是哪种档」，靠颜色对位，不靠形状抢戏。
    /// 2026-10-22 起这一格不再放勾选框：总览的动作是「点一段两次收走那一段」，
    /// 选哪几处由清理清单负责；在账本上再放一排框等于同一条承诺有两个入口。
    private var leadingSlot: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(seg.color)
            .frame(width: 8, height: 8)
            .frame(width: 16)
            .accessibilityHidden(true)
    }

    /// 上膛那一档的命中区：那道 `›` 连同它管着的那个数。
    ///
    /// 行身整个交给「摊明细」之后，同一处落点不能兼任两件事——「点两下收走」必须有个
    /// 比整行小的落点，否则浏览明细的手势和动手的手势是同一个。那道 `›` 本来就是标在
    /// 这个数上的（样稿 `.row.act::after`），命中区跟着它走，眼睛不用重新学位置。
    /// 环上那条弧仍然是第一个入口，摊开之后环收成 132 pt 参照盘时这里才是。
    @ViewBuilder private var armCluster: some View {
        // 代价读法那四行是「一类字节」，没有上膛这一说：弧上不接点击，
        // 行尾再挂一颗 `›` 就是请人点一个没反应的地方。
        let armable = seg.reclaim > 0 && !seg.costClass
        let both = HStack(spacing: 12) {
            Text(armable ? "›" : "")
                .font(theme.numeric(size: 15, weight: .regular))
                .foregroundStyle(SweepRing.lamp(theme.palette.tint).opacity(0.72))
                .frame(width: 8, alignment: .leading)
            // 数和单位分两档，见 `SizeNumber`。两档字重再加一档分档：样稿 `.row .gb`
            // 21px / `:not(.act)` 17px 且退到 ink-2。也就是「动得了的那几行」数更大、
            // 更亮，「只能看的」更小、更灰——上一版六行全是 17pt regular，
            // 这一列把所有段说成了同一件事。
            if let hoverNote {
                HoverNumber(note: hoverNote, label: seg.label, armed: armed,
                            shown: seg.sizeShown,
                            size: seg.reclaim > 0 ? 21 : 17,
                            base: seg.reclaim > 0 ? theme.palette.ink : theme.palette.inkSecondary)
            } else {
                SizeNumber(shown: seg.sizeShown,
                           size: seg.reclaim > 0 ? 21 : 17,
                           color: armed ? SweepRing.lampHot(theme.palette.tint)
                                        : (seg.reclaim > 0 ? theme.palette.ink
                                                           : theme.palette.inkSecondary))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if armable { tap?() } }
        if armable {
            both.help(LF("点两次把「%@」移进废纸篓", seg.label))
        } else {
            both
        }
    }

    /// 量具：`DISKWISE_CHIPS=off` 把这一行末尾那截绿的 `+N` 摘掉（其余预演画面不动）。
    /// 每次交互都要变的东西先留一个能摘掉它的开关，同 `DISKWISE_EDGE`、`_GAIN`、`_BAR`
    /// 那几条规矩：摘掉前后各跑一次，才量得出这一笔花几个点。
    static let gainRunOffByEnv: Bool = {
        (ProcessInfo.processInfo.environment["DISKWISE_CHIPS"] ?? "").lowercased() == "off"
    }()

}

/// 行里那一句小字，**连同末尾那截绿色的 `+N`**。
///
/// 从 `RingLedgerRow` 里拆出来只为一件事：`+N` 跟着预演走，而预演是「一发空格改六处画面」
/// 那一档。订阅留在行体上，一发空格就让六行重算、右边那本账跟着重排——2026-10-22 逐层配对
/// 量下来的账写在 `subLine` 下面那段，拆到这一句之后，行体（名字、条子、四颗钮）跟着
/// `hoverNote` 一样不为预演重算。
private struct LedgerSubLine: View {
    @Environment(\.theme) private var theme
    @ObservedObject var preview: PreviewSignal
    let seg: GaugeSegment
    /// 整圈上膛那一档（`armedPath == "*"`）由页面传：那一档跟 `@Published` 同一条线，
    /// 页面本来就会重算，不需要这条通知线。见 `RingLedgerRow.afterClearAll`。
    var all: Bool = false

    var body: some View {
        Text(subLine)
            .font(theme.bodyFont(.caption2))
            // 只给一行，宁可让尾句收成省略号：2026-09-28 试过 `lineLimit(2)`，
            // 三句长注解在 900/1080 档确实摊开了，代价是这本账高出约 40 pt，
            // 把「把可回收的 x 移进废纸篓」那颗主钮顶到折线以下——招牌屏丢了
            // 主行动，比丢半句解释贵。1440（商店配图画幅）两边都放得下，不受影响。
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// 预演时这一行名下还能腾出多少（稿子⑪），接在小字末尾那一截绿。
    ///
    /// 走 `AttributedString` 追加，而不是往行尾插一颗角标视图：2026-10-22 用
    /// `DISKWISE_PERF_PREVIEW=0.4` 同一场配对量过（每 0.4 秒压放一次空格，约 55 次），
    /// 尾段 >100 ms 那几列——行尾插角标 56 格、只换条子 46 格、两处都不动 13 格，
    /// 接进这一句 19 格，同场静帧 0 格。贵的是「行尾那一簇变宽 → 右边那列数跟着重排 →
    /// 整本账的列高跟着变」，不是这一行重算几个字。样稿⑪那颗是绿色胶囊，这里换成一截绿字：
    /// 数的口径、绿的身份、六颗加起来等于盘心那一笔，三样都留着，胶囊的形状为手感让掉。
    ///
    /// 单位不省：样稿那串是 `+6.3`（它左边就是「6.3 GB」），我们这一列里有「812 B」
    /// 也有「6.3 GB」，只印数字的话 `+812` 会被读成 GB，而这一列的加总就是要跟盘心对账的。
    /// 颜色取皮肤的 `safeFG`：跟盘心那行「全部清空后可用」、环上那截绿光弧同一个绿。
    ///
    /// 只在这一行本来就有小字时接：`sub` 空着的那些行（排队中、正在量）此刻在扫描，
    /// 而扫描中这一屏不接预演；真接上，凭空多出一行会把整本账顶高，那正是上面那笔账。
    private var subLine: AttributedString {
        var out = lampRun(seg.sub, seg.reclaim > 0 ? human(seg.reclaim) : "",
                          SweepRing.lamp(theme.palette.tint),
                          base: theme.palette.inkTertiary)
        guard preview.on || all, seg.reclaim > 0, !RingLedgerRow.gainRunOffByEnv else { return out }
        // 「·」保持灰的，绿只盖住那一截数：一句里两段重音就没有重音了。
        func piece(_ s: String, _ c: Color) -> AttributedString {
            var a = AttributedString(s)
            a.foregroundColor = c
            return a
        }
        out += piece(" · ", theme.palette.inkTertiary)
             + piece("+" + seg.reclaimShown, theme.palette.safeFG)
        return out
    }
}

/// 悬停聚光那一层壳：底光、整行暗态。
///
/// 它订阅 `LedgerHoverSignal`，行体不订阅——悬停每秒能来好几发，而一次整页变更
/// 在这台 Intel 上值 60–100 ms（见 `PerfProbe` 的底价）。壳里只做两件事：
/// 换一个 `LinearGradient` 的透明度、换一个整行的 `.opacity`；两者都不动布局。
///
/// 底光只有一道，**armed 压过 lit**：上膛是「再按一下就动手」，悬停是「我在看这条」，
/// 两档同时亮会把后者说过头。数与光的档位见 `HoverNumber`。
private struct HoverSpotlight: ViewModifier {
    @Environment(\.theme) private var theme
    @ObservedObject var note: LedgerHoverSignal
    let label: String
    let armed: Bool

    func body(content: Content) -> some View {
        let lit = note.label == label
        let dim = note.label != nil && !lit
        content
            .background(glow(lit: lit), in: theme.controlShape())
            .opacity(dim ? 0.32 : 1)
    }

    /// 上膛那一行的底：一道从左边打进来的暖光，不是描边。
    /// 描边会在这一列里凭空多出两个矩形框，而这一屏的框只留给能真按的东西。
    ///
    /// 悬停走同一道光但只有 .13（样稿 `.row.lit` 就是 .13，`.row.armed` 是 .20）：
    /// 「我在看这条」和「再按一下就动手」不能长一个样，后者重一分才不至于让人误以为已经选中。
    private func glow(lit: Bool) -> AnyShapeStyle {
        let level = armed ? 0.22 : (lit ? 0.13 : 0)
        guard level > 0 else { return AnyShapeStyle(Color.clear) }
        // 样稿这道光在行宽 70% 处就已经透明：光是从左缘打进来然后灭掉，
        // 不是整行蒙一层。铺满的话六行会连成一条灰带子。
        return AnyShapeStyle(LinearGradient(stops: [
            .init(color: SweepRing.lamp(theme.palette.tint).opacity(level), location: 0),
            .init(color: .clear, location: 0.7)
        ], startPoint: .leading, endPoint: .trailing))
    }
}

/// 行尾那枚数：悬停/上膛时换成 `--lamp-hot`（近白的暖金），否则是行自己的那档墨。
///
/// 单独立一颗小视图，是为了让「换色」只重算这一枚数，不重算整行（见 `HoverSpotlight`）。
/// 悬停那一档要跟 `.row.lit` 那道 13% 的底光一起回答「就是这条」，用同一支灯的浅色
/// 才不会跟下面小字里那个 `--lamp` 抢谁更亮。
private struct HoverNumber: View {
    @Environment(\.theme) private var theme
    @ObservedObject var note: LedgerHoverSignal
    let label: String
    let armed: Bool
    let shown: String
    let size: CGFloat
    let base: Color

    var body: some View {
        SizeNumber(shown: shown, size: size,
                   color: (armed || note.label == label)
                       ? SweepRing.lampHot(theme.palette.tint) : base)
    }
}

// MARK: - 页头

struct PageHeader<Trailing: View>: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var title: String
    var subtitle: String
    var tileFill: Color? = nil
    var variant: Variant = .compact
    /// 标题与右侧控件装不下同一行时，是否让控件退到下一行、整行右对齐。
    ///
    /// 这一条的宽度全押在译文长度上：`Entwicklerordner überspringen` 是「跳过开发目录」的
    /// 两倍多，同一套控件在中文里占 692 pt，到德语就是 997 pt，而 1060 窗的内容区只有 774 pt。
    /// 所以「并列」只在短译文下成立，长译文必须能退让——退让比让 `Spacer` 把副标题挤断、
    /// 控件顶出窗口边要体面。
    ///
    /// 默认关着：右侧只挂一颗小按钮的页本来就装得下，多一层 `ViewThatFits` 只是白量一遍。
    var wrapsControls: Bool = false
    /// 副标题**后面**那一枚小徽章（样稿 `.phead .sub .cost`）。
    ///
    /// 总览用它说环的读法：「亮起来的那几段，现在就能收走」——那句话讲的是颜色，
    /// 而颜色没有文字标签，不写出来就得由人自己猜「为什么有一段是亮的」。
    var subBadge: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    enum Variant { case compact, display }

    var body: some View {
        layout
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var layout: some View {
        if wrapsControls {
            ViewThatFits(in: .horizontal) {
                row
                stacked
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(alignment: variant == .display ? .center : .top, spacing: 14) {
            heading
            Spacer(minLength: 12)
            trailing()
        }
    }

    /// 控件退让的那一档：标题自己一行，控件整行右对齐。
    ///
    /// 右对齐不是审美选择——这一行的右缘要跟标题行、读数卡、账卡落在同一条竖线上，
    /// 靠左的话整屏会多出一条谁都不挨着谁的边。
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                trailing()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var heading: some View {
        HStack(alignment: variant == .display ? .center : .top, spacing: 14) {
            IconTile(symbol: symbol, side: variant == .display ? 46 : 38, fill: tileFill)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.display(variant == .display ? .title : .title3))
                    .tracking(theme.titleTracking)
                    .foregroundStyle(theme.palette.ink)
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(subtitle)
                        .font(theme.bodyFont(.callout))
                        .foregroundStyle(theme.palette.inkSecondary)
                    if let subBadge {
                        // 样稿 `.cost`：`padding:1px 7px; border-radius:5px; font-size:9.5px;
                        // color:#8CA6C4; background:rgba(126,172,255,.085);
                        // border:1px solid rgba(126,172,255,.17)`。
                        // 那支蓝灰按皮肤的 tint 走：graphite 的 tint 就是 `#6C9BFF`，
                        // 也就是稿子那个蓝，别的皮各拿各的主色，不跟六档皮共用一个死色值。
                        Text(subBadge)
                            .font(theme.bodyFont(.caption2))
                            .tracking(0.2)
                            .foregroundStyle(theme.palette.tint.opacity(0.92))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.palette.tint.opacity(0.085)))
                            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(theme.palette.tint.opacity(0.17), lineWidth: 1))
                            .fixedSize()
                    }
                }
            }
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(symbol: String, title: String, subtitle: String,
         tileFill: Color? = nil, variant: Variant = .compact) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.tileFill = tileFill
        self.variant = variant
        self.trailing = { EmptyView() }
    }
}

// MARK: - 区块标题

struct SectionLabel: View {
    @Environment(\.theme) private var theme
    var text: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text)
                .font(theme.display(.subheadline))
                .tracking(theme.titleTracking + 0.2)
                .foregroundStyle(theme.palette.ink)
            if let detail {
                Text(detail)
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkTertiary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }
}

// MARK: - 折叠箭头

/// 展开/收起那一颗尖角。
///
/// 用 Path 画而不是 `Image(systemName: "chevron-*")`：实测 9pt 的 SF Symbol 箭头
/// 在行里只占位不落地（重复文件、node_modules、缓存的行都看不见它），
/// 而「这行能不能点开」全押在这颗箭头身上——看不见就等于没有。
/// 描边形状跟进度条一样在每条渲染路径上都在。
struct ThemeChevron: View {
    @Environment(\.theme) private var theme
    var expanded: Bool
    var color: Color? = nil

    var body: some View {
        Path { p in
            if expanded {   // 朝下
                p.move(to: CGPoint(x: 2.9, y: 3.9))
                p.addLine(to: CGPoint(x: 5.0, y: 6.1))
                p.addLine(to: CGPoint(x: 7.1, y: 3.9))
            } else {        // 朝右
                p.move(to: CGPoint(x: 3.9, y: 2.9))
                p.addLine(to: CGPoint(x: 6.1, y: 5.0))
                p.addLine(to: CGPoint(x: 3.9, y: 7.1))
            }
        }
        .stroke(color ?? theme.palette.inkTertiary,
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        .frame(width: 10, height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - 数字块

/// 一排等宽数字卡
struct StatRow: View {
    @Environment(\.theme) private var theme
    var items: [(String, String)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.0)
                        .font(theme.bodyFont(.caption))
                        .foregroundStyle(theme.palette.inkSecondary)
                    Text(item.1)
                        .font(theme.numeric(.title3))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, theme.metric.cardPadding)
                .padding(.vertical, theme.metric.cardPadding * 0.75)
                .background(
                    theme.cardShape().fill(theme.palette.surface)
                )
                .overlay(theme.cardShape().stroke(theme.palette.separator,
                                                  lineWidth: theme.metric.stroke))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 空态 / 加载

struct EmptyState: View {
    @Environment(\.theme) private var theme
    var symbol: String
    var title: String
    var hint: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            ZStack {
                Circle().fill(theme.palette.tintSoft)
                    .frame(width: 76, height: 76)
                Image(systemName: symbol)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(theme.palette.tint)
            }
            .accessibilityHidden(true)
            Text(title).font(theme.display(.headline)).foregroundStyle(theme.palette.ink)
            Text(hint).font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// `ControlStrip` 换了行、这一行里只剩内容自己时置位。
///
/// 为什么要让里面的读数卡知道这件事：控制条一行装不下时会拆成「内容一行、动作一行」，
/// 而内容那一行若还按自己的理想宽度收着（读数卡 + 徽章），就等于**上面一行靠左、下面一行靠右**，
/// 两块谁都不挨谁的边——看着像两张没对齐的卡。撑满之后这一行的右缘与下面那行、
/// 以及再下面的账卡落在同一条竖线上。
///
/// 只在换行那一档置位：宽窗口下整条仍是一行，读数卡照旧收着自己的宽度，
/// 不会把一行卡片拉成一条长条。
private struct ControlStripWrappedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var controlStripWrapped: Bool {
        get { self[ControlStripWrappedKey.self] }
        set { self[ControlStripWrappedKey.self] = newValue }
    }
}

struct LoadingRow: View {
    @Environment(\.theme) private var theme
    var text: String
    /// 给它就在下面多印两行现场读数：正在看哪个目录、已经检查了多少、走了多少字节、多久。
    ///
    /// 为什么值得占这三行：整盘范围一趟要走几分钟，而这段时间是用户判断「工具坏了」
    /// 还是「它真的在翻我的盘」的唯一窗口。只有一句「正在扫描…」等于没回答。
    /// 刻意不报百分比和剩余时间——沙盒里量不到整盘的文件总数，报出来的是编的。
    var progress: ScanProgress? = nil

    /// 「正在看」那一行路径的槽宽。
    ///
    /// 必须**定宽**，不能写成 `maxWidth`：读数每 0.4 秒来一次，路径长短和计数位数一直在变，
    /// 让文字自己决定宽度的话整条卡片就跟着一伸一缩，旁边那几枚徽章和「停止」按钮
    /// 也跟着左右挪——一屏上最需要稳的东西（正在跑的现场）恰恰是最不稳的那个。
    ///
    /// 460 的来历：380 定宽的那一版，一条 380 的路径槽配着右边一大片空地
    /// （控制条里内容和动作之间是 `Spacer`），读起来像卡片没画完；而 node_modules 那页
    /// 同时挂着一枚**永远只会说同一句话**的范围徽章（该页范围写死，徽章跟着撤了）。
    /// 徽章让出来的那 ~80 pt 就补到这里：卡片变宽，路径能多露出一截，整条控制条的总宽没变。
    ///
    /// 只有一种情况它不再是上限：这一行里只剩这张卡自己。那时把它撑满整行，
    /// 行右缘才跟上下那些卡片对齐；此时它是**下限**。
    static let readWidth: CGFloat = 460

    /// 这一行是不是只剩这张卡自己 —— 是就撑满整行。
    ///
    /// 默认跟着 `ControlStrip` 的换行档位走（见 `controlStripWrapped`）；控件被页头收走之后
    /// 读数那行本来就只剩它自己，调用点直接传 true，不必再借环境值转达。
    var fillsRow: Bool? = nil

    @Environment(\.controlStripWrapped) private var stripWrapped

    private var fills: Bool { fillsRow ?? stripWrapped }

    var body: some View {
        if fills {
            card.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 9) {
            // **这一屏上唯一的转圈**，所以它归这里：整页只有这句话在回答「它还在不在走」。
            // 下面那张扫描清单答的是**状态**（走到哪一处了）——卡头用确定的分数配细条、
            // 行上用静止的三态符号，转圈摆在那两处只是噪声。读数本身当然也在动
            // （用时每 0.4 秒必跳一次），但那是「走得多快」，不是「还在不在走」，
            // 两件事各归各的说。
            ProgressView().controlSize(.small)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.inkSecondary)
                if let progress {
                    // TimelineView 自己按节拍重画，不去打扰模型：读数每 0.4 秒看一眼就够，
                    // 而遍历那边每来一个条目都 @Published 一次的话，UI 会被淹死。
                    TimelineView(.periodic(from: .now, by: 0.4)) { _ in
                        let r = progress.snapshot()
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Text(L("正在看"))
                                    .foregroundStyle(theme.palette.inkTertiary)
                                Text(r.current.isEmpty
                                     ? L("刚开始，还没进到目录里")
                                     : displayPath(URL(fileURLWithPath: r.current)))
                                    .foregroundStyle(theme.palette.inkSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(minWidth: Self.readWidth,
                                           maxWidth: fills ? .infinity : Self.readWidth,
                                           alignment: .leading)
                            }
                            HStack(spacing: 5) {
                                Text(LF("已检查 %@",
                                        cnt(r.files, progress.counted == .files ? "个文件" : "个条目")))
                                // 找目录那一趟不量体积（node_modules 页），这一格就永远是 0 B。
                                // 报一个永远不动的 0 是在演示一个不存在的能力——跟「空的那一堆不写」同一条规矩。
                                if r.bytes > 0 {
                                    Text("·")
                                    Text(LF("已走过 %@", human(r.bytes)))
                                }
                                Text("·")
                                Text(LF("用时 %@", elapsed(r.elapsed)))
                            }
                            .foregroundStyle(theme.palette.inkTertiary)
                        }
                        .font(theme.bodyFont(.caption2))
                        .textSelection(.disabled)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.controlShape().fill(theme.palette.surface))
        .overlay(theme.controlShape().stroke(theme.palette.separator,
                                            lineWidth: theme.metric.stroke))
        .accessibilityElement(children: .combine)
    }

    /// `0:37` / `12:04`。不写「秒」也不写「分钟」：这一格里它是计时器读数，
    /// 前面已经有「用时」两个字管着它了。
    private func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - 提示条（撤销入口常驻）

struct NoticeBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let notice = store.notice {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.palette.tint)
                Text(notice)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.ink)
                    .lineLimit(2)
                Spacer(minLength: 10)
                if !store.trashHistory.isEmpty {
                    Button(L("撤销")) { store.notice = store.undoLast() }
                        .buttonStyle(.plain)
                        .font(theme.bodyFont(.callout).weight(.semibold))
                        .foregroundStyle(theme.palette.tint)
                }
                Button {
                    store.notice = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.palette.inkTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("关闭提示"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(theme.cardShape().fill(theme.palette.surface))
            .overlay(theme.cardShape().stroke(theme.palette.separator,
                                             lineWidth: theme.metric.stroke))
            .shadow(color: theme.palette.shadow, radius: 14, x: 0, y: 6)
            // 浮在底沿，间距照稿子：`.dbar` 是 `right:20px;bottom:14px`。
            // 它是 overlay，不占版面一行——原因见 `DiskCleanerApp.swift` 那处 `.overlay`。
            .padding(.horizontal, 20)
            .padding(.bottom, 14)
            .transition(reduceMotion ? .opacity
                                     : .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                                   removal: .opacity))
        }
    }
}
