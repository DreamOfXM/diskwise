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

struct ThemeButton: View {
    enum Kind { case primary, secondary, ghost, danger, compact, lamp }

    @Environment(\.theme) private var theme
    var kind: Kind = .primary
    var symbol: String? = nil
    var title: String
    var isDisabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: iconSize, weight: .semibold))
                }
                Text(title).font(font)
            }
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .contentShape(theme.controlShape())
        }
        .buttonStyle(.plain)
        .modifier(ThemeButtonVisual(kind: kind))
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }

    private var isCompact: Bool { kind == .compact }
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
    @State private var hovering = false
    @State private var pressed = false
    var kind: ThemeButton.Kind

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
        // 样稿那颗主按钮是 `border-radius:999px` 的一粒胶囊，而皮肤的控制形状是 4 pt 方角。
        // 圆角半径会被 SwiftUI 夹到短边的一半，所以这里给一个超大的数就是胶囊。
        kind == .lamp ? RoundedRectangle(cornerRadius: 999, style: .continuous)
                      : theme.controlShape()
    }

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
                // 样稿 `.btn`：linear-gradient(180deg, --lamp-hot, --lamp)。
                // 顶亮底沉的一粒才读得出它是「这一屏唯一那颗按钮」；平涂主色
                // 和环上那条弧是同一个色温，压不出这个层级。
                if isEnabled {
                    shape.fill(LinearGradient(colors: [SweepRing.lampHot(theme.palette.tint),
                                                       SweepRing.lamp(theme.palette.tint)],
                                              startPoint: .top, endPoint: .bottom))
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
        case .primary, .lamp: return theme.palette.onTint
        case .danger: return theme.palette.onDanger
        case .secondary, .compact: return theme.palette.ink
        case .ghost: return theme.palette.tint
        }
    }

    private var stroke: some View {
        shape.stroke(
            kind == .primary || kind == .danger || kind == .lamp
                ? Color.clear : theme.palette.separator,
            lineWidth: theme.metric.stroke
        )
    }

    private var shadowColor: Color {
        // `.lamp` 的那团光是按钮本身的一部分（样稿 box-shadow 0 0 24px rgba(242,180,92,.5)），
        // 不跟着皮肤的 elevation 走：极夜黑金是 `.flat`，一收力这颗按钮就成了一个色块。
        if kind == .lamp { return SweepRing.lamp(theme.palette.tint).opacity(0.5) }
        if kind == .primary { return theme.palette.tint.opacity(theme.elevation == .flat ? 0 : 0.26) }
        if kind == .danger { return theme.palette.danger.opacity(theme.elevation == .flat ? 0 : 0.22) }
        return theme.palette.shadow
    }
    private var shadowRadius: CGFloat {
        if kind == .lamp { return pressed || hovering ? 17 : 12 }
        return theme.elevation == .flat ? 0 : (pressed ? 2 : 7)
    }
    private var shadowY: CGFloat {
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
        if !Self.sized, let size = SnapshotMode.requestedWindowSize {
            Self.sized = true
            window.setContentSize(size)
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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            if let u = volumeUsage() {
                HStack(spacing: 7) {
                    if let name = Self.volumeName {
                        Text(name)
                            .font(theme.bodyFont(.caption2))
                            .foregroundStyle(theme.palette.inkTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // 条子涂的是「已经占掉的」，用的是中性墨色：主色在这套语言里
                    // 只说「这里动得了」，容量条借它就会被读成一个可点的东西。
                    ProportionBar(fraction: Double(u.usedPhysical) / Double(max(1, u.total)),
                                  color: theme.palette.inkSecondary,
                                  height: 4, trackWidth: 96)
                    Text(LF("可用 %@", human(u.available)))
                        .font(theme.bodyFont(.caption2))
                        .monospacedDigit()
                        .foregroundStyle(theme.palette.inkSecondary)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 卷名读一次就够：它不会在运行中改名，而每 5 秒去问一次沙盒外的路径不值得。
    /// 取不到（沙盒挡了）就整段不写，不拿 "/" 或硬编码的 "Macintosh HD" 顶上去。
    private static let volumeName: String? = {
        try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName
    }()
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

    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, fraction)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track ?? theme.palette.separator)
                Capsule()
                    .fill(color ?? theme.palette.tint)
                    .frame(width: max(w, height))
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
/// exit+enter，`hovKey` 被写两次，于是「鼠标停在这一列里」＝每秒 85 次整页重画＋730 次
/// 悬停事件的自激环（2026-09-26 真鼠标静止实测，探针产物 `r04-consistency/mj-b4-park2-probe.log`）。
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
}

/// 招牌画面：**一段弧 = 盘上一块真实的字节**，一整圈加起来永远等于整块盘。
///
/// 环上只有三种东西：弧、弧上的数、两道光。会扫的那道光在扫描期间钉在「量到的字节」上，
/// 扫完换成一道反光永远绕环——它不是循环装饰，是「这一圈刚量完」的余温。
/// 动得了的弧内侧有一道暖沿，点两下才搬进废纸篓；搬走的字节当场从那条弧挪到虚线那条弧上
/// ——不从天上掉，也不凭空少。
///
/// 这一屏旁边的账目行（`RingLedgerRow`）不归它画：环形只管圆，行归页面排。
struct SweepRing: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemScheme

    /// 「把这一圈里动得了的全上膛」——`armed` 取这个值时所有可回收的弧一起描边。
    static let armAll = "*"

    var segments: [GaugeSegment]
    /// 圆心那三行：`centerTop` 是那句问话（还能腾出 / 确认移入废纸篓），
    /// `centerValue` 是数，`centerCap` 是数的口径（空余多少、全部清空后多少）。
    /// 整块盘只有一个答案，所以它只放在圆心，不在别处再放一个总数。
    var centerTop: String = ""
    var centerValue: String
    var centerCap: String = ""
    var diameter: CGFloat = 232
    /// 点一条弧时回调。给整条段而不只是落点：
    /// 动得了的弧要点完才知道要不要跳，光有 `jumpTo` 分不出「能收走」和「只能看」。
    var select: ((GaugeSegment) -> Void)? = nil
    /// 上了膛的那条弧（`GaugeSegment.path`，或 `Self.armAll`）。描边画成实墨，
    /// 是在说「再点一下就真搬」。
    var armed: String? = nil
    /// 点圆心：解除上膛。上膛是一次要反悔的动作，而「点空处取消」是人唯一会自然试的手势。
    var tapCenter: (() -> Void)? = nil
    /// 扫描中：光束读的就是这条进度，它一亮着就说明这一圈还没量完
    var scanning = false
    /// 0…1，这一轮量完了多少条（只有 `scanning` 为真时光束读它）
    var scanProgress: Double = 0
    /// 鼠标正停在哪一段上（键用 `label`：它在整屏重绘之间稳定，`id` 是每次新铸的 UUID）。
    /// 状态归页面持有，不归环——样稿里环和右边那列账目读的是同一个 `hov`，
    /// 两边各记一份就会出现「弧亮了、行没亮」。
    var hovered: String? = nil
    /// 鼠标进（给 label）/ 出（给 nil）某一段。
    var onHover: ((String?) -> Void)? = nil
    /// 圆心最底那行副读（样稿 `.mid .now`）：悬停时把「这是谁、占多少、我收得走多少」
    /// 写在盘心。眼睛此刻在环上，让它跑到右边那列字里去对名字就是惩罚读图的人。
    var centerNow: String? = nil

    @State private var reveal: CGFloat = 0
    /// 此刻环上是不是「点得动」的那一段——只用来记手型光标该不该是手，
    /// 免得每次 `mouseMoved` 都去刷一遍系统光标。
    @State private var cursorHand = false
    @State private var entryBeam = false
    @State private var glint = false
    @State private var spinStart = Date()
    /// 常驻反光此刻的累计角度。它**不**由 `TimelineView` 每帧算，而是交给
    /// Core Animation 做一次 0→360° 的线性 `repeatForever`：见 `startSpin`。
    @State private var spin: Double = 0
    @State private var breath = false
    @State private var pulse = false

    /// 环带厚度。**照抄原型的比例**：它的环外径 412、带 56，也就是 0.136。
    /// 上一版取 0.17 是为了「把一枚 23.2 GB 躺进带里」，代价是内孔只剩 0.66 框宽——
    /// 圆心那三行排不下，光带也糊成一大片。带一薄，孔就大了，数照样放得下。
    private var band: CGFloat { diameter * 0.145 }
    private var isDark: Bool { (theme.scheme ?? systemScheme) == .dark }

    // 环带的三条半径。光层的每一档都按这三条线定位，不按「框的百分比」：
    // 上一版把峰值写死在 location 0.855，带一薄整团光就掉进洞里。
    private var rOut: CGFloat { diameter / 2 }
    private var rIn: CGFloat { diameter / 2 - band }
    /// 发光用哪个色相：这一屏的主色（极夜＝金、晨雾＝蓝），但**抬到样稿那盏灯的档位**。
    /// 样稿的 `.halo`/`.bloom` 写的是 rgba(242,180,92)——饱和 .62、明度 .95、蓝道 92；
    /// 极夜主色 #C9A227 的蓝道只有 39，直接当灯用，光透到灰弧上就是芥末而不是金。
    /// 所以走 HSB 只动饱和与明度、色相不碰：六套皮肤各发自己那道光，各自都带蓝道。
    static func lamp(_ tint: Color) -> Color {
        let ns = NSColor(tint)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return tint }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s * 0.77),
                     brightness: Double(min(1, b * 1.22 + 0.06)))
    }
    private var lamp: Color { Self.lamp(theme.palette.tint) }
    /// 灯芯最亮那一档 = 样稿的 `--lamp-hot` #FFF0D6：同色相、饱和再收一半、明度顶格。
    /// 主按钮那颗胶囊的渐变顶部用它，整屏只有两处用到（按钮顶、`.row.lit` 的数）。
    static func lampHot(_ tint: Color) -> Color {
        let ns = NSColor(lamp(tint))
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return Color.white }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(s * 0.45), brightness: 1)
    }
    /// 会不会「一直动」：「减弱动态效果」下不转、不呼吸；截图模式下同样停住——
    /// `waitSettled` 靠比对连续三帧判静帧，光带永续绕环会让每一张总览图都拖到上限。
    /// 注意这里关的只是**由 Core Animation 驱动的那条永续循环**：光带本身不藏，截图里钉在 0°
    /// （一圈量完的边界就在正上方，相位可用 `DISKWISE_RING_GLINT` 挪去别处取证），
    /// 静止态在真机上长什么样，截图就得是什么。
    /// 而 `DISKWISE_FILM` 那一趟要证的恰恰是「它在走」，所以那条路不从这里过：
    /// 相位改由连拍时钟逐帧推（`SnapshotMode.filmClock`），静帧判定不受影响。
    private var canAnimate: Bool { !reduceMotion && !SnapshotMode.active }
    /// 皮肤性格：极夜黑金与水墨宣纸的签名是「静」——段不脉冲、不弹跳，
    /// 但反照样绕环、余晖照样呼吸。那道光是这块盘的招牌，不是皮肤的装饰。
    private var canBreathe: Bool { canAnimate }
    /// 余晖此刻的亮度。**照原型的呼吸幅度**：`.halo` 在 .34↔.9 之间走一轮 6.5 秒。
    /// 静皮收到一半（.50↔.78）：它要「静」，但样稿那圈光本来就是一起一伏的，
    /// 整层关掉等于把招牌画面少画一半——上一版就是这么把「有光晕」弄没的。
    /// 截图模式取中位当定值，或用 `DISKWISE_RING_BREATH` 钉在指定档取证。
    private var haloOpacity: Double {
        let (lo, hi) = theme.motion == .still ? (0.50, 0.78) : (0.34, 0.9)
        if canAnimate { return breath ? hi : lo }
        // 连拍那一趟按连拍时钟走这一伏一起，见 `SnapshotMode.filmClock`。
        if SnapshotMode.filmMotion { return lo + (hi - lo) * SnapshotMode.filmBreathLevel }
        // 钉的是**呼吸区间的几分位**，不是原始透明度：0 = 最暗那档、1 = 最亮那档，
        // 这样同一张相位表在静皮与会动的皮肤上量的是同一件事。
        guard let b = SnapshotMode.ringBreath else { return (lo + hi) / 2 }
        return lo + (hi - lo) * b
    }
    /// 缩放只给会呼吸的皮肤：它比亮度更「活」，静皮留着就是穿帮。
    /// 往外扩那一档只作用在内孔那团光上，它本来就在环里，扩不出去。
    private var haloScale: CGFloat {
        guard theme.motion != .still else { return 1.0 }
        if canAnimate { return breath ? 1.02 : 0.98 }
        if SnapshotMode.filmMotion { return 0.98 + 0.04 * SnapshotMode.filmBreathLevel }
        return 1.0
    }
    /// 反光此刻的相位：真机读 Core Animation 的累计角，连拍读连拍时钟，
    /// 普通静图钉在 `DISKWISE_RING_GLINT`（不给就停在 0°）。
    private var glintAngle: Double {
        if canAnimate { return spin }
        if SnapshotMode.filmMotion { return SnapshotMode.filmGlintAngle }
        return SnapshotMode.ringGlintPhase ?? 0
    }

    var body: some View {
        dial
            .onAppear { run() }
        // 不按 segments.count 重放：总览是边扫边填的，段数一路 2→3→4→5，
        // 每次变化都把整圈打回零重扫，看着像坏了几次。
        .onChange(of: scanning) { now in
            if now {
                // 扫描期间由那道钉在进度上的宽光束接管，不叠第二道光
                glint = false
                return
            }
            // 扫完不当场关灯：换成一道反光接着绕环。一圈量完了边界就在正上方，
            // 节拍从 0° 重新起算，它正好接在光束停下的那一格上，不跳。
            startSpin()
        }
        .onChange(of: armed) { path in
            guard path != nil, canAnimate else { pulse = false; return }
            withAnimation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        // 悬停停在弧上的那一刻切页，`.onContinuousHover` 的 `.ended` 不保证会来（视图已经拆了）。
        // 不补这一下：旁边那列账会一直停在「一指退五」的样子，系统光标也留在手型上。
        .onDisappear {
            onHover?(nil)
            setHand(false)
        }
    }

    private var dial: some View {
        ZStack {
            // 两层整圈的光，都垫在轨道**下面**——原型 DOM 就是这个顺序（halo → bloom → track → 弧）。
            // 压在弧上面会把三档灰洗成一档，垫在下面才是「整块盘坐在光里」：
            // 弧是把光盖住，光只从没画弧的地方（空闲那段、内孔）透出来。
            haloGlow
            bloomGlow

            // 会搬走的那段自己发光：同一形状糊开一圈，光晕严格跟着弧的角范围，
            // 所以暗的那几段旁边是暗的——原型里 12→4 点钟那团暖光就是这么来的。
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                if slice.seg.reclaim > 0 {
                    // 浅皮收着走但**不能收到看不见**：纸上这团雾往外洇得太淡就读成
                    // 「没打光」，太浓又成了水彩印糊。深皮 0.45 / 浅皮 0.34：上一版深皮给 0.7，
                    // 三处光（这团 + halo + bloom）叠在金色那一侧，把整张卡染成褐色渐变，
                    // 样稿里金色弧旁边是**黑的**（实测 (12,13,17)＝画布）。
                    arcSlice(slice, width: band, style: AnyShapeStyle(slice.seg.color))
                        .blur(radius: band * 0.4)
                        .opacity(isDark ? 0.45 : 0.34)
                        // 悬停时这团光必须跟着段一起退：段压到 .26 而它不动，
                        // 那几段旁边照样亮，等于「退到后面去」这件事只画了一半。
                        .opacity(hovered == nil || hovered == slice.seg.label ? 1 : 0.26)
                        .allowsHitTesting(false)
                }
            }

            // 轨道：一整块盘的形状由它闭合。空闲那段本身不反光，
            // 没有这条底，环就会在「空着的地方」断掉，读起来像图没画完。
            // 0.035 是**灰阶的地板**：旁边三档灰都是按它往上排的，这条一抬
            // 「几乎不画」的空闲段就跟「量到了但动不了」那档糊在一起。
            Circle()
                .stroke(isDark ? theme.palette.ink.opacity(0.035)
                               : theme.palette.ink.opacity(0.030),
                        lineWidth: band)
                .padding(band / 2)

            // 样稿的悬停是**整段一起**反应的：底纹、段身、内侧暖沿、上膛描边同生同灭。
            // 只给段身上色的话，弹出来的那段会甩下三道没跟上的边，读起来像画坏了。
            // 这些弧一律不接事件（`visualBand` 末尾的 `allowsHitTesting(false)`），
            // 点击与悬停全交给 `ringHitLayer` 那一层按角度算。
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                visualBand(slice, hov: hovered == slice.seg.label)
            }

            // 整圈只有这一层接事件，且它画在弧**上面**：见 `ringHitLayer`。
            ringHitLayer

            // 弧上直接标数：让环和旁边那列账靠数对位，不必悬停才知道 16.4 是哪一段。
            // 只标数不标名——最短那段弧只有几十 px，写名字就会出现「为什么这两段没名字」。
            // 收成参照盘那一档（下钻时 132pt）整排都不标：带厚只剩 19pt、那段弧的弧长
            // 也只剩十几 px，六枚 11pt 的数会叠成一片字糊在环上。数全在右边那一列里。
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                if slice.span >= 0.05 && diameter >= 260 { arcLabel(slice) }
            }

            lights

            VStack(spacing: 5) {
                if !centerTop.isEmpty {
                    // 这句问话用主色，不用灰：原型里它是 `.eyebrow`＝灯色。
                    // 灰的话圆心只剩一个大数，而那个数不带单位口径——「6.3」到底是
                    // 还能腾出、还是已经搬走，全靠这一行说清。
                    Text(centerTop)
                        .font(theme.bodyFont(.caption))
                        .tracking(0.6)
                        .foregroundStyle(theme.palette.tint)
                }
                heroNumber
                if !centerCap.isEmpty {
                    Text(centerCap)
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
                // `.mid .now`：只有悬停（或上膛）那几秒在，用灯色而不是灰——
                // 这一行是「你手上这一段是什么」，比旁边那两行口径更近。
                if let now = centerNow {
                    Text(now)
                        .font(theme.numeric(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(lamp)
                        .opacity(0.9)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: (diameter - 2 * band) * 0.78)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
            }
            // 圆心那三行只是读数，不承担点击：热区一律交给下面的 `centerHitLayer`。
            // 文字框比孔小得多，事件层跟着 frame 走的话，字底下那片空会掉回环上。
            .animation(theme.animation, value: centerNow)
            .allowsHitTesting(false)

            centerHitLayer
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
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

    /// 圆心那个大数：数字给满，单位收到三分之一。
    /// 「17.9」和「GB」一样大的话，这一格读起来是一行标签而不是一个答案。
    ///
    /// 不用 `Text + Text` 拼：那个写法要 macOS 14 才有的 `Text.foregroundStyle`，
    /// 而基线对齐的 HStack 在 13 上就是同一件事。
    private var heroNumber: some View {
        let parts = centerValue.split(separator: " ", maxSplits: 1,
                                      omittingEmptySubsequences: true)
        let num = parts.first.map(String.init) ?? centerValue
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

    /// `.halo` —— 内孔里那团会呼吸的暖光。
    ///
    /// 原型的算法：`inset:14%` 的方框里一枚 `radial-gradient(circle, rgba(242,180,92,.26),
    /// transparent 62%)`，再 `blur(22px)`。换算到环外径 412 上，亮的半径是 164 = 内沿 150
    /// **往外咬进环带 14px**——光和带子是接上的，不是洞里的另一坨。上一版把底光整个撤到
    /// 环外沿一条细线上，于是圆心空成一块黑，招牌画面里的「有光晕」就这么没了。
    ///
    /// 浅皮不能照抄：白纸上 screen 等于没有，往洞里铺一层主色又会让「还能腾出 6.3」那三行
    /// 坐在一片蓝雾上。改成浅皮自己的洗淡底色（`tintSoft`），它本来就是给这种用途准备的。
    private var haloGlow: some View {
        let r = rIn + band * 0.25
        // 0.15 不是审美拍板，是量出来的：样稿那张 `A-sweep_0idle.png` 孔心读数 (32,27,23)、
        // 画布 (12,13,17)，也就是这团光在圆心只抬 **+20 灰阶**；上一版 0.30 抬到 +45
        // （实拍孔心 65,56,29），整块卡被染成一片褐，金色当场不再是全画面唯一的饱和色。
        // 呼吸那一档（`haloOpacity`）乘在这上面，所以峰值落在 +20 附近。
        let fill = isDark ? lamp.opacity(0.15) : theme.palette.tintSoft
        return Circle()
            .fill(RadialGradient(stops: [.init(color: fill, location: 0),
                                         .init(color: fill.opacity(0), location: 1)],
                                 center: .center, startRadius: 0, endRadius: r))
            .frame(width: r * 2, height: r * 2)
            // 第二层 frame 把**布局尺寸**收回 diameter：这团光画得比方框大，
            // 但不许把整块环撑胖——它挪的是像素，不是卡片里的位置。
            .frame(width: diameter, height: diameter)
            .blur(radius: band * 0.42)
            // 样稿这一层是**普通叠加**，不是 screen：`.beam`/`.orbit`/`.bloom` 三处写了
            // mix-blend-mode:screen，`.halo` 偏偏没写。深皮上给屏混合，孔外沿那圈会被抬到
            // 42.8（样稿 25.8），洞里那三行数就坐进雾里了。
            .blendMode(.normal)
            .opacity(haloOpacity)
            .scaleEffect(haloScale)
            .allowsHitTesting(false)
    }

    /// `.bloom` —— 绕着环带的一圈余晖，整圈对称。
    ///
    /// 原型那行注释写得很清楚为什么必须对称：给每段单独挂 drop-shadow，
    /// 只有会亮的三块外面鼓出一圈光，整块盘的轮廓就不再是正圆，读者说不清哪里不对
    /// 但一眼觉得这环画崩了。停停靠半径换算过来的（closest-side 半径 291）：
    /// 内沿起亮、峰值在**带内 64% 处**、外沿收一半、再往外 0.8 个带宽归零。
    ///
    /// 浅皮这一圈整块往外挪：它要是压在带子上，等于给「最该安静」的空闲段上色
    /// （实测过，那段会染成全环第二显眼的颜色）。光只从环**外沿**洇出去，
    /// 读起来是落在纸上的那圈反光，洞和带子都干净。
    private var bloomGlow: some View {
        // 洇出多远是量出来的：样稿那圈余晖在环外沿 0.92 个带宽处才归零，
        // 上一版取 0.85 且中段太陡，实拍到 r=420 就回到卡片色，光晕比样稿窄了一圈。
        let reach = rOut + band * (isDark ? 1.05 : 1.0)
        // 深皮这两档是按样稿读数倒推的，不是随手减半：外沿紧邻处样稿 (21,19,20) 对画布
        // (12,13,17) 只抬 +9，上一版 0.26 抬到 +24（实拍环外 44,39,23），光漫到了整张卡右边。
        // 内沿起亮点从 `rIn − 0.05×band` 挪到 `rIn + 0.05×band`：样稿这层在 rIn 以内是
        // 全透明的（`.bloom` 的 transparent 52% 换算过来正好是内沿），漏进洞里就是第二团雾。
        let stops: [Gradient.Stop] = isDark
            ? [.init(color: .clear, location: (rIn + band * 0.05) / reach),
               .init(color: lamp.opacity(0.12), location: (rIn + band * 0.64) / reach),
               .init(color: lamp.opacity(0.06), location: (rOut + band * 0.10) / reach),
               .init(color: lamp.opacity(0.02), location: (rOut + band * 0.55) / reach),
               .init(color: .clear, location: 1)]
            : [.init(color: .clear, location: (rOut - band * 0.30) / reach),
               .init(color: lamp.opacity(0.20), location: (rOut + band * 0.12) / reach),
               .init(color: lamp.opacity(0.07), location: (rOut + band * 0.55) / reach),
               .init(color: .clear, location: 1)]
        return Circle()
            .fill(RadialGradient(stops: stops, center: .center, startRadius: 0, endRadius: reach))
            .frame(width: reach * 2, height: reach * 2)
            .frame(width: diameter, height: diameter)
            .blur(radius: band * 0.22)
            .blendMode(isDark ? .screen : .normal)
            .allowsHitTesting(false)
    }

    private func run() {
        spinStart = Date()
        if canBreathe {
            withAnimation(.easeInOut(duration: 3.25).repeatForever(autoreverses: true)) {
                breath = true
            }
        }
        guard !reduceMotion else { reveal = 1; return }
        reveal = 0
        withAnimation(.easeOut(duration: 0.9)) { reveal = 1 }
        entryBeam = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            entryBeam = false
            // 切回这一页时扫描早就完了，没人会再触发 `onChange(of: scanning)`：
            // 入场那道光走完就得把常驻的反光交出去，否则这一屏留下的是一张没有光带的环。
            if !scanning { startSpin() }
        }
    }

    /// 一段 = 一块字节，段间只留一道发丝缝。切法在 Core 的 `ringArcs` 里（SelfTest 逐段断言），
    /// 这里只负责把弧配回它那一格的账。
    /// `arc` 原样留着：画的是 `from`/`to`，命中层比的是 `claimFrom`/`claimTo`，少一处都错。
    private struct Slice {
        var arc: RingArc
        var seg: GaugeSegment
        var from: CGFloat { CGFloat(arc.from) }
        var to: CGFloat { CGFloat(arc.to) }
        var span: CGFloat { CGFloat(arc.span) }
    }

    private var slices: [Slice] {
        let live = segments.filter { $0.value > 0 }
        return zip(live, ringArcs(values: live.map { $0.value })).map { seg, arc in
            Slice(arc: arc, seg: seg)
        }
    }

    /// 一条弧。`outer` = 弧的**外沿**离环外沿缩进多少（0 = 贴住外沿）。
    ///
    /// 描边压在路径中线上，所以内缩量是 `outer + w/2` 而不是 `outer`：少算半个线宽，
    /// 整条弧就往外越出半个带宽（39pt 的带越出 20pt），把卡片的边啃掉一口——
    /// 上一版的环「画出卡片外」就是这么来的，不是 padding 写错了符号。
    private func arcSlice(_ s: Slice, width w: CGFloat, style: AnyShapeStyle,
                          outer: CGFloat = 0, dashed: Bool = false,
                          span: CGFloat = 1) -> some View {
        // `span` < 1 只画这一段的前一截：样稿 `.seg .rec` 的宽度就是
        // `reclaim / value`，亮沿铺到哪儿，说到哪儿为止「这部分我收得走」。
        Circle()
            .trim(from: s.from * reveal,
                  to: (s.from + (s.to - s.from) * min(max(span, 0), 1)) * reveal)
            .stroke(style, style: StrokeStyle(lineWidth: w, lineCap: .butt,
                                              dash: dashed ? [6, 5] : []))
            .padding(outer + w / 2)
            .rotationEffect(.degrees(-90))
            .animation(theme.animation, value: s.to)
    }

    /// 一**段**环带的像素：底纹、段身、内侧暖沿、上膛描边。只管画，一律不接事件——
    /// 事件全在 `ringHitLayer` 那一层，因为「这段弧涂成什么样」和「这一点归谁」
    /// 是两件事（见 `ringHitLayer` 里 NSTrackingArea 那条说明）。
    @ViewBuilder private func visualBand(_ s: Slice, hov: Bool) -> some View {
        ZStack {
            if s.seg.dashed {
                // 斜纹底下先铺一层淡的。纯虚线在浅皮上是几条蓝纹夹着空洞，
                // 读起来像这一格漏画了——可这些字节明明**还占着盘**，
                // 空洞恰好说反了。淡底保住面积，斜纹只负责说「换了地方」。
                arcSlice(s, width: band,
                         style: AnyShapeStyle(s.seg.color.opacity(0.26)))
            }
            arcSlice(s, width: band, style: arcPaint(s), dashed: s.seg.dashed)
            // 可回收量：段身**内侧**的一道暖沿，铺多宽＝能收走的那部分占这段多大。
            // `reclaim` 为 0 就不画——画了收不走，那一格是在骗人点击。
            // 宽度取带宽的 44%、贴住内沿（原型 R0→R0+26 / 带 56）：上一版只有 22%
            // 且悬在带中间，读起来像三片脱离环体的标签，而不是「这一段亮」。
            if s.seg.reclaim > 0 {
                // `outer` 是「这条弧的外沿相对环外沿缩进多少」，所以贴住带的内沿
                // 要缩 band − 沿宽。上一版填了 1.06×band，沿整个掉进洞里，
                // 读起来是一枚脱离环体的黄色药片，而不是「这一段亮」。
                arcSlice(s, width: band * 0.42,
                         style: AnyShapeStyle(recEdge(s.seg)), outer: band * 0.58,
                         span: s.seg.value > 0 ? CGFloat(s.seg.reclaim) / CGFloat(s.seg.value) : 1)
            }
            if isArmed(s.seg) {
                // 上膛描的是整段的**轮廓**（外沿 + 内沿各一道），不是把弧盖住：
                // 盖住就把这块弧占多大抹掉了，而人此刻要看的正是那个数。
                Group {
                    arcSlice(s, width: 2, style: AnyShapeStyle(theme.palette.ink))
                    arcSlice(s, width: 2, style: AnyShapeStyle(theme.palette.ink),
                             outer: band - 2)
                }
                .shadow(color: theme.palette.tint.opacity(pulse ? 0.85 : 0.35),
                        radius: pulse ? 9 : 3)
            }
        }
        // `svg.pick .seg{opacity:.26}` / `.seg.on path{transform:scale(1.038)}`：
        // 悬停时其余段退到 .26，被指的这段往外弹 3.8%。弹的是整段轮廓，
        // 因为 ZStack 的坐标原点就是环心（每条弧都占满 diameter 那一格）。
        // **命中层不吃这个缩放**：它按静止那圈半径算，弹出去的那 3.8% 不会再把
        // 光标「让」给隔壁段——那样会在内沿上来回抖。
        .opacity(hovered == nil || hov ? 1 : 0.26)
        .scaleEffect(hov ? 1.038 : 1)
        .animation(theme.animation, value: hovered)
        .allowsHitTesting(false)
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
        Color.clear
            .frame(width: diameter, height: diameter)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let seg = segment(at: p)
                    // 只有**换段**时才回调。`mouseMoved` 每挪一个像素就来一次，上一版每次都
                    // 写页面那枚 `hovKey`，于是鼠标在环这 420×420 里划过＝每秒几十次整页
                    // body 重跑（环形账、右边那列、下面整列热点行、缓存目标全过一遍）。
                    // 他报的「鼠标放到右边的目录上经常卡顿」就是这个空转。
                    if seg?.label != hovered { onHover?(seg?.label) }
                    // 样稿 `.seg.hot{cursor:pointer}`：只有真收得走的段才配变手型，
                    // 动不了的段给个手型就是骗人来点。
                    setHand((seg?.reclaim ?? 0) > 0)
                case .ended:
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
                    if let seg = segment(at: CGPoint(x: Double(ev.location.x),
                                                     y: Double(ev.location.y))) { select?(seg) }
                }
            )
            .help(hovered.flatMap { label in
                slices.first { $0.seg.label == label }.map { segHelp($0.seg) }
            } ?? "")
    }

    /// 手型光标只在该变的时候变。每次 `mouseMoved` 都 `set()` 一遍是白刷，
    /// 而且这一层被拆掉时（切页、换皮肤）没人把箭头还回去。
    private func setHand(_ on: Bool) {
        guard cursorHand != on else { return }
        cursorHand = on
        (on ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// 环心坐标系里的一个落点归哪一段；带子以外一律 nil。数学在 Core，SelfTest 逐段断言。
    private func segment(at p: CGPoint) -> GaugeSegment? {
        let ss = slices
        guard let i = ringArcIndex(x: Double(p.x), y: Double(p.y),
                                   diameter: Double(diameter),
                                   rIn: Double(rIn), rOut: Double(rOut),
                                   arcs: ss.map(\.arc), reveal: Double(reveal))
        else { return nil }
        return ss[i].seg
    }

    /// 这一段到底涂什么。规矩只有一句：**彩色只给动得了的弧**。
    ///
    /// 动得了的那段涂"灯芯"渐变——上亮下沉，等于一盏灯立在环上，光从上头打下来。
    /// 其余三段都不参与配色：洗淡的主色说「系统腾得动、我按不动」，
    /// 中性灰说「这地方占着，但这一屏不解决」，深浅两档灰把量到和没量到分开。
    private func arcPaint(_ s: Slice) -> AnyShapeStyle {
        let seg = s.seg
        if seg.tone == .hot {
            let (top, bottom) = arcVerticalExtents(s)
            return AnyShapeStyle(LinearGradient(
                stops: [.init(color: seg.color.opacity(0.92), location: 0),
                        .init(color: shade(seg.color), location: 1)],
                startPoint: UnitPoint(x: 0.5, y: top), endPoint: UnitPoint(x: 0.5, y: bottom)))
        }
        return AnyShapeStyle(seg.color)
    }

    /// 这条弧在垂直方向占到的区间，换算成渐变用的单位坐标（0 = 框顶，1 = 框底）。
    ///
    /// 必须按弧自己算。SVG 的 `linearGradient` 默认走 `objectBoundingBox`，
    /// 也就是**每条弧自己的**包围盒——所以原型里下半圈的金色弧照样是上亮下沉。
    /// SwiftUI 的 `LinearGradient` 按整个环的框算，同一档渐变给到 6 点钟方向就是最暗那档：
    /// 实测那条 6.3 GB 的弧只有 (87,69,15)，比旁边的灰弧 (71,68,62) 还不起眼，
    /// 「彩色只给动得了的弧」这条规矩当场失效。
    private func arcVerticalExtents(_ s: Slice) -> (CGFloat, CGFloat) {
        let rf = (diameter / 2 - band / 2) / diameter      // 带中圈的半径 / 框宽
        let steps = max(2, Int((s.to - s.from) * 720))
        var lo = CGFloat.greatestFiniteMagnitude, hi = -CGFloat.greatestFiniteMagnitude
        for i in 0...steps {
            let a = (s.from + (s.to - s.from) * CGFloat(i) / CGFloat(steps)) * 2 * .pi
            let y = 0.5 - rf * cos(a)                      // from = 0 在正上方
            lo = min(lo, y); hi = max(hi, y)
        }
        return (max(0, lo), min(1, hi))
    }

    /// 灯芯渐变的下半截：同一条色相，往沉里走。
    ///
    /// 不能直接混黑——混黑会把饱和度一起洗掉，主色在深色皮肤上就成了一块泥。
    /// 走 HSB：明度砍到 0.57、饱和微微抬一点，色相原样不动（原型 #F2B45C→#8A5F22 就是这个走法）。
    private func shade(_ color: Color) -> Color {
        let ns = NSColor(color)
        guard let rgb = ns.usingColorSpace(.deviceRGB) else { return color.opacity(0.55) }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Color(hue: Double(h), saturation: Double(min(1, s * 1.22)),
                     brightness: Double(b * 0.57), opacity: 0.55)
    }

    /// 内侧那道暖沿：段身再提亮一档，永远跟段同色相。
    ///
    /// 不用主色画沿：晨雾皮肤的主色就是环上第一段的颜色（0x2A62D6 vs 0x0072B2），
    /// 沿和段撞成一块，读出来是「多了一条没人认领的弧」。
    private func recEdge(_ seg: GaugeSegment) -> Color {
        lit(seg.color).opacity(0.85)
    }

    /// 这一格算不算「已经上膛」。`armAll` 时动得了的弧一起描边：
    /// 主按钮那一下要动的是整圈里所有能搬的，只亮一条弧是在报假账。
    private func isArmed(_ seg: GaugeSegment) -> Bool {
        guard let armed, seg.reclaim > 0 else { return false }
        return armed == Self.armAll || armed == seg.armKey
    }

    /// 把弧自己的颜色提亮一档，用来画「搬得走」那道沿。
    ///
    /// 不用主色画沿：晨雾皮肤的主色就是环上第一段的颜色（0x2A62D6 vs 0x0072B2），
    /// 沿和段撞成一块，读出来是「多了一条没人认领的弧」，不是「这段会亮」。
    /// 提亮走的是同一条弧的色相，所以它永远长在段身上。
    ///
    /// 深浅两种底不能共用一个算法。浅底往白里并没问题；深底并白会把饱和度洗掉——
    /// 石墨黑上 58% 的白把黄弧提成了米白，反倒成了全画面最亮的东西，
    /// 读出来还是「多了一条弧」。所以深底改成只抬明度、微微收饱和，色相原样不动。
    private func lit(_ color: Color) -> Color {
        let ns = NSColor(color)
        if isDark {
            guard let rgb = ns.usingColorSpace(.deviceRGB) else { return color }
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: Double(h), saturation: Double(s * 0.72),
                         brightness: Double(min(1, b * 1.55 + 0.28)), opacity: Double(a))
        }
        guard let mixed = ns.blended(withFraction: 0.58, of: .white) else { return color }
        return Color(nsColor: mixed)
    }

    private func arcLabel(_ s: Slice) -> some View {
        let deg = Double((s.from + s.to) / 2 * 360 - 90)
        let rad = deg * .pi / 180
        // 落在带的正中偏外一点：内侧那道暖沿是「点我」，数字压上去就等于把这一屏
        // 唯一一处可点的东西盖住；太靠外又会戳出环的外沿。0.42 是两头都让开的位置。
        let r = diameter / 2 - band * 0.42
        return Text(arcValueText(s.seg.sizeShown))
            .font(theme.numeric(size: 11, weight: .regular)).monospacedDigit()
            .foregroundStyle(arcNumberColor(s.seg))
            .fixedSize()
            // 不加底。上一版给每个数垫一块卡片色的圆角底，于是六枚数变成六枚
            // 飘在环上的标签，环本身反倒成了背景——原型把底全去掉，数才长在弧上。
            // 去底之后唯一要补的是对比：动得了的那段是饱和色，数得用亮字压上去。
            .position(x: diameter / 2 + r * CGFloat(cos(rad)),
                      y: diameter / 2 + r * CGFloat(sin(rad)))
            .opacity(reveal >= 1 ? 1 : 0)
            .animation(.easeOut(duration: 0.5), value: reveal)
            .allowsHitTesting(false)
    }

    /// 弧上只写数、不写单位：圆心那格已经写了 GB，旁边那一列账每行都带单位，
    /// 环上再重复六遍会把六枚数挤成一片字。
    /// 但**不到 1 GB 的那段必须把单位写回来**——「512」放在 500 GB 的盘上会被读成 512 GB。
    private func arcValueText(_ shown: String) -> String {
        shown.hasSuffix(" GB") ? String(shown.dropLast(3)) : shown
    }

    /// 弧上那个数的颜色，跟着这一段的档走：亮段配亮字、灰段配灰字。
    private func arcNumberColor(_ seg: GaugeSegment) -> Color {
        switch seg.tone {
        case .hot:   return isDark ? Color(red: 1, green: 0.886, blue: 0.686).opacity(0.90)
                                   : Color.white.opacity(0.95)
        case .moved: return theme.palette.tint.opacity(isDark ? 0.9 : 1)
        case .washed: return theme.palette.inkSecondary
        case .neutral: return theme.palette.ink.opacity(isDark ? 0.46 : 0.60)
        }
    }

    /// 环上那两道光。原型里是两个元素：`.beam` 扫一次就 fade，`.orbit` 从此永远绕。
    ///
    /// 两道光的驱动**不一样**，这是 2026-09-25 查悬停卡顿时改的：
    /// 入场／扫描那道光束要读当下的时间与进度，仍走 `TimelineView`，但它只在头一秒和
    /// 扫描期间活着。常驻反光以前也挂在同一张 30 fps 的唤醒表上，于是它**每秒重画一整圈
    /// conic 渐变再糊一遍**（`blur` 压在 840×840 px 的层上），而鼠标进来那些帧正好在跟它
    /// 抢主线程。一整圈 conic 绕心转 = 把同一张图按同样角度转过去，形状一模一样，
    /// 所以这里只画一次、把角度交给 Core Animation 的线性 `repeatForever` 去转。
    @ViewBuilder private var lights: some View {
        if glint {
            orbitGlint(glintAngle)
                .allowsHitTesting(false)
        }
        if entryBeam || scanning {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0,
                                    paused: !entryBeam)) { tl in
                sweepBeam(beamAngle(tl.date))
                    .allowsHitTesting(false)
            }
        }
    }

    /// 扫描期间那道宽的：严格钉在量到的字节上，它是真数，不是走个样子。
    private func sweepBeam(_ angle: Double) -> some View {
        ZStack {
            Circle()
                .trim(from: 0, to: 1)
                .stroke(AngularGradient(gradient: beamGradient, center: .center,
                                        startAngle: .degrees(angle),
                                        endAngle: .degrees(angle + 360)),
                        style: StrokeStyle(lineWidth: band, lineCap: .butt))
                .padding(band / 2)      // 光束严格走环带，不许糊到环外
                .rotationEffect(.degrees(-90))
                .blendMode(isDark ? .screen : .normal)
            // 拖尾前面那道墨沿：渐变是一片洗，浅色纸上根本看不出它停在哪。
            // 这道窄沿才是「量到这儿了」的针——用墨不用主色，因为它要压在
            // 六色环带上还看得见，而环带里每一种颜色都可能跟主色撞。
            Circle()
                .trim(from: 0, to: 2.4 / 360)
                .stroke(theme.palette.ink.opacity(isDark ? 0.55 : 0.34),
                        style: StrokeStyle(lineWidth: band, lineCap: .butt))
                .padding(band / 2)
                .rotationEffect(.degrees(angle - 90))
        }
    }

    /// 扫完之后常驻的那道反光：只亮 36°（原型 conic 的 90%→100% 那一段），9 秒一圈。
    /// 亮头用近白不用主色——主色压在六色环带上必然跟某一段撞色，撞了就又读成「多了一条弧」。
    ///
    /// 渐变**恒定画在 0°**，绕环这件事整个交给 `rotationEffect`：那是一层仿射变换，
    /// 由合成器做，不重画内容。把角度写进 `AngularGradient.startAngle` 的话，
    /// 每一帧都要重新光栅化整圈渐变——那正是上一版悬停卡顿的开销来源。
    private func orbitGlint(_ angle: Double) -> some View {
        Circle()
            .trim(from: 0, to: 1)
            .stroke(AngularGradient(gradient: glintGradient, center: .center,
                                    startAngle: .degrees(0),
                                    endAngle: .degrees(360)),
                    style: StrokeStyle(lineWidth: band, lineCap: .butt))
            .padding(band / 2)
            .rotationEffect(.degrees(angle - 90))
            // 样稿那条遮罩带边缘有 1.1% 的羽化（≈5px），不是硬切。
            // 硬切在浅皮上读成「环上蹭了一道」，糊一分才像掠过表面的反光。
            .blur(radius: band * 0.07)
            .blendMode(isDark ? .screen : .normal)
    }

    private var glintGradient: Gradient {
        // 亮部只占一圈的 10%（原型 conic 的 90%→100%，峰在 96%）——
        // 这是一道**绕环走的反光**，不是一片洗过去的雾。上一版把坡道摊到 38% 圈、
        // 峰压到 0.16，绕到哪儿都看不出有东西在动，招牌画面里「流动的光」就这么没了。
        // 峰值 0.34 是原文的 rgba(255,240,214,.34)。
        // 浅皮这道反光**用白不用主色**：主色是蓝，而空闲那一段本来就几乎不画，
        // 蓝色坡道铺上去等于给「最该安静的那格」上了色（实测过，那段整块发蓝）。
        // 白的只会把灰提亮，不带色相；纸上够亮才给到 0.85，因为浅皮没有 screen 可用。
        let peak = isDark ? Color(red: 1, green: 0.941, blue: 0.839).opacity(0.34)
            : Color(red: 0.965, green: 0.976, blue: 1).opacity(0.62)
        return Gradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 0.90),
            .init(color: peak.opacity(0.40), location: 0.945),
            .init(color: peak, location: 0.962),
            .init(color: peak.opacity(0.30), location: 0.986),
            .init(color: .clear, location: 1),
        ])
    }

    private var beamGradient: Gradient {
        // 三个停靠点照抄原型：亮头 0%、拖尾 11%、26% 之后全透。
        let head = isDark ? 0.42 : 0.20
        return Gradient(stops: [
            .init(color: theme.palette.tint.opacity(head), location: 0),
            .init(color: theme.palette.tint.opacity(head * 0.35), location: 0.11),
            .init(color: .clear, location: 0.26),
            .init(color: .clear, location: 1),
        ])
    }

    private func beamAngle(_ now: Date) -> Double {
        if scanning { return min(1, max(0, scanProgress)) * 360 }
        let p = now.timeIntervalSince(spinStart) / 0.9
        return min(1, max(0, p)) * 360
    }

    /// 反光开始绕环：把 0→360° 一次性交给 Core Animation，9 秒一圈，与原型同速。
    /// 一圈量完了边界在正上方，所以起算点就是 0°，它正好接在入场那道光束停下的那一格上。
    /// 只在第一次启动时上发条（`spin == 0`）：这张动画本身永不停，重扫之后再「接上」
    /// 比把它搬回 0° 更连续——光带不会 teleport。
    /// 截图模式下不上发条，相位由 `DISKWISE_RING_GLINT` 钉住（见 `lights`）。
    private func startSpin() {
        spinStart = Date()
        glint = !reduceMotion
        guard canAnimate, spin == 0 else { return }
        withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) {
            spin = 360
        }
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
        let parts = segments.map { "\($0.label) \($0.sizeShown)" }
        return LF("磁盘占用环形图：%@", parts.joined(separator: L10n.isHanScript ? "，" : ", "))
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
    /// 鼠标停在**环上对应那条弧**或这一行上（样稿 `.row.lit`）。
    var lit: Bool = false
    /// 有别处在被指，这一行退到后面（样稿 `.row.dim{opacity:.32}`）。
    var dim: Bool = false
    /// 这一行上面要不要画那道分隔线（样稿 `.row+.row::before`，第一行没有）。
    var showRule: Bool = true
    var onHover: ((Bool) -> Void)? = nil
    /// 「点两次才收走」那一档。命中区是行尾那道 `›` 连同它管着的那个数（`armCluster`）；
    /// 没有下一级的行（`onExpand == nil`）整行左半块也落回这里，那一行本来没别的动作。
    var tap: (() -> Void)? = nil
    /// 这一段已经摊开了没有——只决定行首那个记号朝右还是朝下。
    var expanded: Bool = false
    /// 摊明细，**整行左半块**（记号 + 色块 + 名字 + 条子）都是它的命中区：2026-09-27 他
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

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
                    // 8×8 的圆角小方块，不是竖条。上一版画成 8×20 的竖条，六行排下来像
                    // 六根文本光标插在那儿；样稿用它只说一件事——「这一格是哪种档」，
                    // 靠颜色对位，不靠形状抢戏。
                    RoundedRectangle(cornerRadius: 3)
                        .fill(seg.color)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(seg.label)
                            .font(theme.bodyFont(.callout))
                            .foregroundStyle(theme.palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !seg.sub.isEmpty {
                            // 样稿 `.row .sub b`：小字里只有「还剩多少能搬走」这一个数染灯色，
                            // 后半句「已搬走 x」保持灰的。全染就没有重音了。
                            Text(lampRun(seg.sub, seg.reclaim > 0 ? human(seg.reclaim) : "",
                                         SweepRing.lamp(theme.palette.tint),
                                         base: theme.palette.inkTertiary))
                                .font(theme.bodyFont(.caption2))
                                // 只给一行，宁可让尾句收成省略号：2026-09-28 试过 `lineLimit(2)`，
                                // 三句长注解在 900/1080 档确实摊开了，代价是这本账高出约 40 pt，
                                // 把「把可回收的 x 移进废纸篓」那颗主钮顶到折线以下——招牌屏丢了
                                // 主行动，比丢半句解释贵。1440（商店配图画幅）两边都放得下，不受影响。
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        // 232 是「满幅」那一档，跟其余六页 `ItemRow` 那道条同一个尺寸，
                        // 换页时「一格的长度代表多少」不用重新学。区别只有一条：这一屏的
                        // 条子可以让到 `barFloor`，因为环和它住在同一行里——窗口收到最小那
                        // 一档时不让步的就是右边那列数被推出窗口边（2026-09-28 实拍）。
                        // 颜色走 `ItemRow` 那条老规矩（`DESIGN.md` §6 第 4 条）：灯色只给动得了的，
                        // 其余一律 `inkTertiary`。**不拿 `seg.color`**——档色是为环上那条大弧调的，
                        // 「没量到」「可清除」在浅皮下本来就只有 9%~16% 的不透明度，
                        // 压进 3 磅高的条里就等于没画，一格 42.6 GB 的行会看着像 0。
                        // 哪一档仍然认得出来：行首那颗 8×8 色块就是档色。
                        ProportionBar(fraction: fraction,
                                      color: seg.reclaim > 0 ? SweepRing.lamp(theme.palette.tint)
                                                             : theme.palette.inkTertiary,
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
        .background(rowBG, in: theme.controlShape())
        .contentShape(Rectangle())
        .onHover { onHover?($0) }
        .opacity(dim ? 0.32 : 1)
        .animation(theme.animation, value: lit)
        .animation(theme.animation, value: dim)
        .help(seg.hint ?? (seg.drill == nil ? seg.label
                                             : LF("点开摊开「%@」的明细", seg.label)))
        .accessibilityElement(children: .combine)
        .accessibilityHint(onExpand == nil ? ""
                        : LF("点这一行摊开「%@」的明细；带着那道记号的数点两次才收走", seg.label))
    }

    /// 上膛那一档的命中区：那道 `›` 连同它管着的那个数。
    ///
    /// 行身整个交给「摊明细」之后，同一处落点不能兼任两件事——「点两下收走」必须有个
    /// 比整行小的落点，否则浏览明细的手势和动手的手势是同一个。那道 `›` 本来就是标在
    /// 这个数上的（样稿 `.row.act::after`），命中区跟着它走，眼睛不用重新学位置。
    /// 环上那条弧仍然是第一个入口，摊开之后环收成 132 pt 参照盘时这里才是。
    @ViewBuilder private var armCluster: some View {
        let both = HStack(spacing: 12) {
            Text(seg.reclaim > 0 ? "›" : "")
                .font(theme.numeric(size: 15, weight: .regular))
                .foregroundStyle(SweepRing.lamp(theme.palette.tint).opacity(0.72))
                .frame(width: 8, alignment: .leading)
            // 数和单位分两档，见 `SizeNumber`。两档字重再加一档分档：样稿 `.row .gb`
            // 21px / `:not(.act)` 17px 且退到 ink-2。也就是「动得了的那几行」数更大、
            // 更亮，「只能看的」更小、更灰——上一版六行全是 17pt regular，
            // 这一列把所有段说成了同一件事。
            SizeNumber(shown: seg.sizeShown,
                       size: seg.reclaim > 0 ? 21 : 17,
                       color: numberColor)
        }
        .contentShape(Rectangle())
        .onTapGesture { tap?() }
        if seg.reclaim > 0 {
            both.help(LF("点两次把「%@」移进废纸篓", seg.label))
        } else {
            both
        }
    }

    /// 右侧那枚数的颜色，三档：悬停/上膛 > 动得了 > 只能看。
    ///
    /// 悬停那一档样稿写的是 `--lamp-hot`（近白的暖金）而不是 `--lamp`：这一档要跟
    /// `.row.lit` 那道 13% 的底光一起回答「就是这条」，用同一支灯的浅色才不会跟
    /// 下面小字里那个 `--lamp` 抢谁更亮。
    private var numberColor: Color {
        if lit || armed { return SweepRing.lampHot(theme.palette.tint) }
        return seg.reclaim > 0 ? theme.palette.ink : theme.palette.inkSecondary
    }

    /// 上膛那一行的底：一道从左边打进来的暖光，不是描边。
    /// 描边会在这一列里凭空多出两个矩形框，而这一屏的框只留给能真按的东西。
    ///
    /// 悬停走同一道光但只有 .13（样稿 `.row.lit` 就是 .13，`.row.armed` 是 .20）：
    /// 「我在看这条」和「再按一下就动手」不能长一个样，后者重一分才不至于让人误以为已经选中。
    private var rowBG: some ShapeStyle {
        let glow = armed ? 0.22 : (lit ? 0.13 : 0)
        if glow == 0 { return AnyShapeStyle(Color.clear) }
        // 样稿这道光在行宽 70% 处就已经透明：光是从左缘打进来然后灭掉，
        // 不是整行蒙一层。铺满的话六行会连成一条灰带子。
        return AnyShapeStyle(LinearGradient(stops: [
            .init(color: SweepRing.lamp(theme.palette.tint).opacity(glow), location: 0),
            .init(color: .clear, location: 0.7)
        ], startPoint: .leading, endPoint: .trailing))
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
    @ViewBuilder var trailing: () -> Trailing

    enum Variant { case compact, display }

    var body: some View {
        HStack(alignment: variant == .display ? .center : .top, spacing: 14) {
            IconTile(symbol: symbol, side: variant == .display ? 46 : 38, fill: tileFill)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(theme.display(variant == .display ? .title : .title3))
                    .tracking(theme.titleTracking)
                    .foregroundStyle(theme.palette.ink)
                Text(subtitle)
                    .font(theme.bodyFont(.callout))
                    .foregroundStyle(theme.palette.inkSecondary)
            }
            Spacer(minLength: 12)
            trailing()
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 2)
        .accessibilityElement(children: .contain)
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

struct LoadingRow: View {
    @Environment(\.theme) private var theme
    var text: String
    /// 给它就在下面多印两行现场读数：正在看哪个目录、已经检查了多少、走了多少字节、多久。
    ///
    /// 为什么值得占这三行：整盘范围一趟要走几分钟，而这段时间是用户判断「工具坏了」
    /// 还是「它真的在翻我的盘」的唯一窗口。只有一句「正在扫描…」等于没回答。
    /// 刻意不报百分比和剩余时间——沙盒里量不到整盘的文件总数，报出来的是编的。
    var progress: ScanProgress? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
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
                                    .frame(maxWidth: 380, alignment: .leading)
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
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .transition(reduceMotion ? .opacity
                                     : .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                   removal: .opacity))
        }
    }
}
