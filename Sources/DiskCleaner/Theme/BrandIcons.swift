import SwiftUI
import AppKit

// MARK: - 只有命令行、这台机器上没有 .app 的工具：行首挂各家官方品牌标
//
// 为什么不能"取不到就算了"：`~/.ollama/models`、`~/.cache/uv`、12 行 node_modules 这些目录，
// 系统给的就是那只通用蓝文件夹（实测与空目录的 PNG 逐字节相同），整列画下来是一排
// 一模一样的文件夹——比不画更认不出东西。而这些工具的身份本来各有一张大家都认得的标，
// 标不依赖这台机器装了什么：命令行工具往往正是 brew / npm 装的，压根没有 .app 可查。
//
// 标从哪来：各家公布的官方单色 SVG，栅格成 32/64 两档 PNG 随包发（26 个工具共 64 KB）。
// 铺法沿用 `IconTile(muted: true)` 那条已定的规矩：浅底同色，不铺实心彩块——
// 一整排实心块会抢过右边数字那一列，而且和主按钮撞形。
enum BrandIcons {
    /// slug → 各家 brand / press 页公布的官方色（simple-icons `_data/simple-icons.json` 逐条对过）
    ///
    /// 这一张表就是清单本身：`Resources/BrandIcons/` 里每个 slug 都要有 ` slug.png` 与
    /// `slug@2x.png`，反过来也是——多发的标等于替各家商标白占包体积。
    static let colors: [String: String] = [
        "ollama":       "000000",   // ~/.ollama/models
        "openai":       "412991",   // Codex CLI、Whisper 模型缓存
        "uv":           "DE5FE9",   // ~/.cache/uv
        "gradle":       "02303A",   // ~/.gradle/caches、wrapper
        "huggingface":  "FFD21E",   // ~/.cache/huggingface
        "rust":         "000000",   // ~/.cargo/registry
        "npm":          "CB3837",   // ~/.npm、package-lock.json 的项目
        "pnpm":         "F69220",   // pnpm store、pnpm-lock.yaml 的项目
        "yarn":         "2C8EBB",   // ~/Library/Caches/Yarn
        "bun":          "000000",   // ~/.bun/install/cache
        "nodedotjs":    "5FA04E",   // node_modules（项目里没有 lockfile 时）
        "apachemaven":  "C71A36",   // ~/.m2/repository
        "googlechrome": "4285F4",   // ~/.cache/chrome-devtools-mcp
        "homebrew":     "FBB040",   // ~/Library/Caches/Homebrew
        "go":           "00ADD8",   // ~/go/pkg/mod、~/Library/Caches/go-build
        "anaconda":     "44A833",   // ~/.conda/pkgs
        "python":       "3776AB",   // ~/Library/Caches/pip
        "nvm":          "F4DD4B",   // ~/.nvm/.cache
        "xcode":        "147EFB",   // CoreSimulator/Devices
        "swift":        "F05138",   // ~/Library/Caches/org.swift.swiftpm
        "cocoapods":    "EE3322",   // ~/Library/Caches/CocoaPods
        "intellijidea": "000000",   // ~/Library/Caches/JetBrains/IntelliJIdea*
        "pycharm":      "000000",   // ~/Library/Caches/JetBrains/PyCharm*
        "androidstudio": "3DDC84",  // ~/Library/Caches/Google/AndroidStudio*、~/.android/avd、Android SDK
    ]

    private static let cache = NSCache<NSString, NSImage>()

    /// 取标。打包版在 `Contents/Resources/BrandIcons`，`swift run` 回落到源码树——
    /// 跟 safety_db 同一个口径：刻意不用 `Bundle.module`，它找不到 .bundle 就 fatalError，
    /// 而且回退路径是构建机的绝对路径。
    static func image(_ slug: String) -> NSImage? {
        let key = slug as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "BrandIcons")
            ?? Bundle.main.url(forResource: slug, withExtension: "png")
            ?? {
                let p = "Sources/DiskCleaner/Resources/BrandIcons/\(slug).png"
                return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
            }()
        guard let url, let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true   // 颜色由皮肤和深浅档决定，标本身只出形状
        cache.setObject(img, forKey: key)
        return img
    }

    // MARK: 配色

    private static func components(_ hex: String) -> (Double, Double, Double) {
        let v = UInt32(hex, radix: 16) ?? 0
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    private static func luminance(_ c: (Double, Double, Double)) -> Double {
        0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    }

    private static func mix(_ c: (Double, Double, Double), toward t: Double, by k: Double) -> Color {
        let f = { (v: Double) in min(max(v + (t - v) * k, 0), 1) }
        return Color(.sRGB, red: f(c.0), green: f(c.1), blue: f(c.2), opacity: 1)
    }

    /// 官方色在这套皮肤上看不看得见。Ollama、Rust、IntelliJ 的官方标就是纯黑，
    /// 铺在深色档上等于没有；Hugging Face 的黄、uv 的粉反过来会在浅色档上糊掉。
    /// 所以只往"看得见"的方向调：深色档提亮、浅色档压暗，调到那个亮度就停，
    /// 色相与饱和度原样保留（改色相就不是人家的标了）。
    static func tint(_ slug: String, dark: Bool) -> Color {
        guard let hex = colors[slug] else { return .primary }
        let c = components(hex)
        let lum = luminance(c)
        if dark {
            guard lum < 0.30 else { return mix(c, toward: 1, by: 0) }
            return mix(c, toward: 1, by: (0.62 - lum) / max(0.001, 1 - lum))
        }
        guard lum > 0.60 else { return mix(c, toward: 0, by: 0) }
        return mix(c, toward: 0, by: 1 - 0.34 / max(0.001, lum))
    }
}

/// 行首那一格的官方标那一档。铺法与 `IconTile(muted: true)` 一致，两者要改一起改。
struct BrandTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    var slug: String
    var side: CGFloat = 26

    var body: some View {
        let isDark = (theme.scheme ?? colorScheme) == .dark
        let color = BrandIcons.tint(slug, dark: isDark)
        ZStack {
            theme.tileShape(side).fill(color.opacity(theme.tileWash(dark: isDark)))
            if let img = BrandIcons.image(slug) {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .renderingMode(.template)
                    .foregroundStyle(color)
                    .frame(width: side * 0.62, height: side * 0.62)
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
