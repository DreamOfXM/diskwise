import SwiftUI
import AppKit
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
            .overlay(tint.opacity(strength * 0.6).blendMode(.multiply))
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

struct ThemedCard<Content: View>: View {
    @Environment(\.theme) private var theme
    var padding: CGFloat? = nil
    var tintBorder: Color? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        let p = padding ?? theme.metric.cardPadding
        let shape = theme.cardShape()
        content()
            .padding(p)
            .background(cardBackground(shape))
            .overlay(cardStroke(shape))
            .modifier(ShadowModifier(shape: shape))
    }

    @ViewBuilder
    private func cardBackground(_ shape: some Shape) -> some View {
        switch theme.elevation {
        case .glass:
            shape.fill(.ultraThinMaterial)
            shape.fill(theme.palette.surface.opacity(0.72))
        case .flat, .soft, .hard:
            shape.fill(theme.palette.surface)
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

    func body(content: Content) -> some View {
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

// MARK: - 按钮

struct ThemeButton: View {
    enum Kind { case primary, secondary, ghost, danger, compact }

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
        isCompact ? theme.bodyFont(.caption).weight(.semibold)
                  : theme.bodyFont(.callout).weight(.semibold)
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
            .opacity(isEnabled || kind == .primary || kind == .danger ? 1 : 0.55)
            .animation(theme.pressAnimation, value: pressed)
            .animation(theme.pressAnimation, value: hovering)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in if !pressed { pressed = true } }
                    .onEnded { _ in pressed = false }
            )
    }

    private var shape: RoundedRectangle { theme.controlShape() }

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
        case .primary: return theme.palette.onTint
        case .danger: return theme.palette.onDanger
        case .secondary, .compact: return theme.palette.ink
        case .ghost: return theme.palette.tint
        }
    }

    private var stroke: some View {
        shape.stroke(
            kind == .primary || kind == .danger ? Color.clear : theme.palette.separator,
            lineWidth: theme.metric.stroke
        )
    }

    private var shadowColor: Color {
        if kind == .primary { return theme.palette.tint.opacity(theme.elevation == .flat ? 0 : 0.26) }
        if kind == .danger { return theme.palette.danger.opacity(theme.elevation == .flat ? 0 : 0.22) }
        return theme.palette.shadow
    }
    private var shadowRadius: CGFloat { theme.elevation == .flat ? 0 : (pressed ? 2 : 7) }
    private var shadowY: CGFloat { theme.elevation == .flat ? 0 : (pressed ? 1 : 3) }
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
    var height: CGFloat = 4
    var trackWidth: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            let w = max(0, min(1, fraction)) * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(theme.palette.separator)
                Capsule()
                    .fill(color ?? theme.palette.tint)
                    .frame(width: max(w, height))
            }
        }
        .frame(width: trackWidth, height: height, alignment: .leading)
        .accessibilityHidden(true)
    }
}

// MARK: - 环形用量仪表
//
// 磁盘清理类产品的招牌画面。设计约束（来自图表规范）：
//   分段 ≤6，每段直接标注数值，不靠颜色单独传达——下面的图例就是无障碍兜底。

struct GaugeSegment: Identifiable {
    var id = UUID()
    var label: String
    var value: Int64
    var color: Color
    /// 点这条图例要跳到哪儿（值是页面里那个视图的 id）。nil = 这块弧落不到任何一行上，
    /// 比如「空闲」「系统可清除」——它们本来就不是「谁占了地方」的答案。
    var jumpTo: String? = nil
}

struct RingGauge: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var segments: [GaugeSegment]
    var centerValue: String
    var centerLabel: String
    var diameter: CGFloat = 168
    /// 给了宽度就把图例排在圆环右侧——总览页靠这个把英雄卡压扁
    var legendWidth: CGFloat? = nil
    /// 点带 `jumpTo` 的图例行时回调。环形上每一块都得能问到「是谁、在哪、动得了吗」，
    /// 光有一条弧加一个数不算回答。
    var select: ((String) -> Void)? = nil

    @State private var progress: CGFloat = 0
    @State private var hovered: UUID? = nil

    private var total: Int64 { max(1, segments.reduce(0) { $0 + max(0, $1.value) }) }
    private var lineWidth: CGFloat { diameter * 0.13 }

    var body: some View {
        Group {
            if let w = legendWidth {
                HStack(alignment: .center, spacing: 22) {
                    dial
                    legend.frame(width: w)
                }
            } else {
                VStack(spacing: 18) {
                    dial
                    legend
                }
            }
        }
        .onAppear { run() }
        // 不按 segments.count 重放：总览是边扫边填的，段数一路 2→3→4→5，
        // 每次变化都把整圈打回零重扫，看着像坏了几次。
    }

    private var dial: some View {
        ZStack {
            Circle()
                .stroke(theme.palette.surfaceAlt, lineWidth: lineWidth)
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                Circle()
                    .trim(from: slice.from * progress, to: slice.to * progress)
                    .stroke(slice.color,
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(centerValue)
                    .font(theme.numeric(.title)).monospacedDigit()
                    .foregroundStyle(theme.palette.ink)
                Text(centerLabel)
                    .font(theme.bodyFont(.caption))
                    .foregroundStyle(theme.palette.inkSecondary)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func run() {
        guard !reduceMotion else { progress = 1; return }
        progress = 0
        withAnimation(.easeOut(duration: 0.85)) { progress = 1 }
    }

    /// 段间留 1.5° 缝，视觉上分得清
    private var slices: [(from: CGFloat, to: CGFloat, color: Color)] {
        let gap = 1.5 / 360
        var cursor: CGFloat = 0
        var out: [(CGFloat, CGFloat, Color)] = []
        for seg in segments {
            let span = CGFloat(max(0, seg.value)) / CGFloat(total)
            if span <= 0 { continue }
            out.append((cursor + gap / 2, cursor + span - gap / 2, seg.color))
            cursor += span
        }
        return out
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(segments) { seg in
                if let target = seg.jumpTo, let select {
                    Button { select(target) } label: {
                        legendCell(seg)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(hovered == seg.id ? theme.palette.tintSoft : Color.clear,
                                in: theme.controlShape())
                    .onHover { inside in hovered = inside ? seg.id : nil }
                    .help(LF("跳到下面的「%@」", seg.label))
                    .accessibilityHint(LF("跳到「%@」那一行", seg.label))
                } else {
                    legendCell(seg)
                }
            }
        }
    }

    private func legendCell(_ seg: GaugeSegment) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(seg.color)
                .frame(width: 9, height: 9)
            Text(seg.label)
                .font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(human(seg.value))
                .font(theme.bodyFont(.callout).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkSecondary)
                .frame(width: 72, alignment: .trailing)
            Text("\(Int((Double(max(0, seg.value)) / Double(total) * 100).rounded()))%")
                .font(theme.bodyFont(.caption))
                .monospacedDigit()
                .foregroundStyle(theme.palette.inkTertiary)
                .frame(width: 34, alignment: .trailing)
            // 只有点得动的行才有这个箭头：整列都标的话就等于没标，
            // 而「空闲」「系统可清除」确实没有「下面哪一行」可跳。
            Image(systemName: "arrow.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.palette.inkTertiary)
                .opacity(seg.jumpTo == nil ? 0 : 1)
                .frame(width: 11)
        }
        .padding(.horizontal, 5)
    }

    private var accessibilitySummary: String {
        let parts = segments.map { "\($0.label) \(human($0.value))" }
        return LF("磁盘占用环形图：%@", parts.joined(separator: L10n.isChinese ? "，" : ", "))
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

/// 扫描中的占位，跟空态同量级。
///
/// 整盘范围要把每个目录走一遍，可能要几分钟，而列表是扫完才一次性回来的——
/// 这段时间什么都不画，用户看到的就是一大片白，只会以为程序卡住了。
struct ScanningState: View {
    @Environment(\.theme) private var theme
    var title: String
    var hint: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 40)
            ZStack {
                Circle().fill(theme.palette.tintSoft)
                    .frame(width: 76, height: 76)
                ProgressView().controlSize(.large)
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

    var body: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(text).font(theme.bodyFont(.callout))
                .foregroundStyle(theme.palette.inkSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.controlShape().fill(theme.palette.surface))
        .overlay(theme.controlShape().stroke(theme.palette.separator,
                                            lineWidth: theme.metric.stroke))
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
