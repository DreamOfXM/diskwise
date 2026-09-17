# DiskWise · 架构与约定

> 一句话：macOS 磁盘清理工具，SwiftUI 原生重写——不依赖 Python、不起本地服务、无端口，双击即用。
>
> **English.** A native SwiftUI disk cleaner for macOS: no Python, no local server, no ports.
> Everything you delete goes to the Trash and can be undone. This document describes the module
> layout, the three hard constraints (one delete path, protected paths, Finder-only empty),
> the theming engine, the bilingual pipeline, and the build/release commands.

---

## 1. 目录结构

```
diskwise/
├── Package.swift                  # SPM，tools 5.9，macOS 13+，三个 target
├── Sources/
│   ├── DiskCleaner/               # App 层（UI + 打包资源）
│   │   ├── DiskCleanerApp.swift   # 入口、侧边栏、AppStore（跨页跳转 + 撤销栈）
│   │   ├── Product.swift          # 品牌常量 + 反馈入口 Contact + 编译期开关 Channel.showsPricing
│   │   ├── L10n.swift             # L() / LF() / cnt()：中文原文即 key
│   │   ├── SnapshotMode.swift     # 截图模式：逐页把窗口拍成 PNG（README 用图靠它）
│   │   ├── Theme/                 # ★皮肤引擎 v2，四个文件分工：
│   │   │   ├── Theme.swift        #   纯数据类型：Theme / ThemePalette / 结构化 token / Environment key
│   │   │   ├── Skins.swift        #   6 套皮肤数据（基础 3 + 进阶 3），加皮肤只加这里
│   │   │   ├── ThemeManager.swift #   单例：持久化 + 试穿 + canUse/unlock
│   │   │   └── Components.swift   #   自绘组件库：卡片/按钮/徽章/环形仪表/背景/图标块
│   │   ├── Views/                 # 11 个页面 + SharedViews.swift（themedRow/ItemRow/CleanBar 等共用件）
│   │   └── Resources/
│   │       ├── safety_db.json     # 缓存知识库（路径写成 ~ 可移植格式）
│   │       └── en.lproj/Localizable.strings   # 唯一需要维护的译文
│   ├── DiskCleanerCore/           # 无 UI 纯逻辑（跨 target 符号必须 public）
│   │   ├── Models.swift           # 知识库解析、路径展开、保护规则、home/applications 锚点、human()
│   │   ├── Scanner.swift          # 占盘统计、通配展开、移废纸篓 + 撤销、访达清空
│   │   └── ScanJobs.swift         # 遍历、重复检测、卸载残留、node_modules、Docker
│   └── SelfTest/main.swift        # 自检程序（没有 XCTest 环境时的替代，见 §3）
├── build_app/
│   ├── build.sh                   # 三道闸门 + 组装 .app + ad-hoc 签名 + DMG + SHA256
│   ├── l10n_tool.swift            # 双语覆盖率对账：缺译文 / 占位符不匹配 / Int 喂给 %@ 都拦下
│   ├── make_icon.swift            # App 图标参数化生成（CoreGraphics 画环形仪表）
│   └── make_demo_home.sh          # 造一棵演示用假家目录，给截图和界面自查用
├── docs/
│   ├── ARCHITECTURE.md            # 本文件
│   ├── DESIGN.md                  # 两条跨皮肤铁律 + 皮肤阵容与配色语义 + 文案语气
│   └── screenshots/               # README 用图（双语 × 多皮肤，由 SnapshotMode 拍出）
├── README.md                      # 双语首页
├── CONTRIBUTING.md                # 安全铁律 + 知识库怎么加条目 + 翻译规矩
└── LICENSE                        # Apache-2.0
```

---

## 2. 环境要求

- macOS 13+，Apple Silicon（发布包只出 arm64）
- **只需要 Xcode 命令行工具，不需要完整 Xcode**（`xcodebuild` 不可用是正常的）
- CLT 里**没有 XCTest**，所以没有 `swift test`——回归靠独立的 `SelfTest` target

## 3. 常用命令（都在项目根目录执行）

```bash
swift build                  # debug 编译
swift run SelfTest           # ★21 项自检，全绿是打包前提
swift run DiskCleaner        # 直跑 App（调试用）

swift build_app/l10n_tool.swift check      # 双语覆盖率对账（build.sh 会自动跑）
bash build_app/build.sh      # 完整打包：对账 → 编译 → 自检 → .app → 签名 → DMG + SHA256
                             # 图标变体：ICON_VARIANT=b bash build_app/build.sh

# 演示数据 + 截图（README 的图就是这么来的，不需要录屏权限）
# DISKWISE_ONLY=overview,dup 只拍某几页；DISKWISE_WIN=1280x1543 换画幅（皮肤页那种长页）
bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome
DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome DISKWISE_SHOTS=/tmp/shots \
  DISKWISE_SKIN=dawn ./build_app/DiskWise.app/Contents/MacOS/DiskCleaner -diskcleaner.language en
```

发版流程：`SelfTest 全绿 → build.sh → 记下 DMG 的 SHA256 → 传 GitHub Releases`。

---

## 4. 架构要点（改代码前必读）

### 4.1 分层与资源加载

- `DiskCleanerCore` 是纯逻辑库（不依赖 SwiftUI；`Scanner.swift` 用到 AppKit 的 NSWorkspace / NSAppleScript）。跨层符号必须标 `public`——SPM 多 target 下 `internal` 默认不可见。
- **禁止使用 `Bundle.module`。** SPM 生成的 resource accessor 只在 `.app` 根目录找 `<Target>_<Target>.bundle`，找不到就回退到构建机绝对路径——那等于只有开发者自己的机器能用，还会把个人路径烧进发布二进制。
  规矩：`Package.swift` 里 `exclude: ["Resources"]`，资源由 `build.sh` 平铺拷进 `Contents/Resources`，运行时走 `Bundle.main`；`swift run` 的裸二进制靠包根目录相对路径兜底。`build.sh` 有存在性断言，漏拷直接构建失败。

### 4.2 皮肤引擎 v2

- `Theme` 是纯数据，但**不只颜色**：`face`（圆体/衬线/几何）、`elevation`（浮起/描边/玻璃）、`backdrop`（纯色/渐变/极光/宣纸纹）、`metric`（圆角/行高/间距）、`motion`（动效签名）、`tileShape` + `tileStrategy`（图标块形状与取色策略）。进阶皮肤靠这些**结构差异**立住，只换色的皮肤没有存在必要。
- 注入走 Environment：App 根 `.themed(themeManager.effective)`，视图里 `@Environment(\.theme) private var theme`。不要用 `.id("skin-…")` 强制重建子树——那样每换一次肤就把全盘扫描重跑一遍。
- 视图层只准引用 `theme.*`，禁止手写色值、禁止用系统控件色。
- `ThemeManager` 单例（刻意不标 `@MainActor`）。持久化三个键：`diskcleaner.theme.id` / `diskcleaner.theme.premium.unlocked` / `diskcleaner.theme.forcedScheme`。
- 现有 6 套：`dawn` 晨雾（默认）· `graphite` 石墨 · `mint` 薄荷 · `midnight` 极夜黑金 · `aurora` 极光玻璃 · `inkwash` 水墨宣纸。
- 试穿 `startTrying/stopTrying` 只改 `effective`，不写偏好，切走即还原。
- `Channel.showsPricing`（`Product.swift`）是编译期常量，默认 false：六套皮肤一律可用，不渲染分区标题、试穿横幅和 `PaywallSheet`。`-DAPPSTORE` 编译时为 true，此时「这套皮肤能不能用」只由 `ThemeManager.canUse` / `unlock` 两处判定，视图不感知开关。
- `palette.chart` 约定：**下标 4 恒为「其他已用」兜底色**，必须是整套里最弱的一支（灰 / 低饱和）——它常年是环形仪表最大的一段，抢色就把整张图糊了。
- macOS 13 的 `ScrollView` 会把**内容的完整高度**当成自己的理想尺寸上报。页面里再套 `ScrollView`/`List`，detail 列会胀到一千多磅、整页被顶出窗口。规矩：**每页只有一个滚动容器**，列表行用 `LazyVStack` 自绘卡片。

### 4.3 安全铁律（产品立身之本，任何需求不得违反）

- 全 App 唯一删除路径是 `trashItem()`（`FileManager.trashItem`，只进废纸篓）；
- `isProtected()` 路径（家目录本体、`~/Library` 等）整体不可删，里面的子项可以；
- 清空废纸篓必须走访达（`emptyTrashViaFinder`，AppleScript，系统再确认一次）；
- Docker 页只读不删（镜像/卷活在虚拟盘里，没有独立路径，只指路）。

### 4.4 双语（i18n）

- **中文原文就是 key**：视图里写 `L("正在比对…")`，`en.lproj/Localizable.strings` 提供英文。没有 zh 侧文件——漏译只会静默退回中文，所以覆盖率靠工具卡。
- `LF()` 带 `%@` / `%1$@` 参数；`cnt(n, "个文件")` 处理英文单复数；`errList()` 拼多条失败原因。
- ⚠️ `String(format:)` 的 `%@` 只接受对象：直接把 `Int` 喂给 `%@` 是 `EXC_BAD_ACCESS`，debug 跑不崩、英文界面一点就崩。`l10n_tool.swift` 会把这种写法拦成构建失败。
- 位置参数两侧的 `%1$@` / `%2$@` 集合必须一致，工具同样会查。
- 切语言写 `AppleLanguages` + 重启生效（SwiftUI 树不重建会留半屏旧文案）。
- 品牌名不进词表：`Product.name` 在两种语言里都写作 DiskWise。bundle id 保持 `com.dreamofxm.diskcleaner`——它是钥匙串、自动化授权、UserDefaults 的锚点，改名等于让老用户的授权和购买记录作废。

### 4.5 演示数据与截图

- `homeDir()` 是家目录的唯一入口。设了 `DISKWISE_HOME_SHIM` 就整棵树换到演示目录（`applicationsDir()` 跟着搬进演示树），扫描、统计、废纸篓全在假树里跑。
- 为什么不用真家目录截图：总览页会把 `~/Desktop`、`~/Documents` 连同体积原样晒出去，那是隐私不是演示。
- `make_demo_home.sh` 只写零 + 给每个文件首字节盖唯一标记（块分配是真的，内容哈希又是唯一的，不会被误判成一整组重复）；`dup()` 才用 `cp` 造真正的逐字节副本。脚本从不删任何东西，重跑幂等。
- `SnapshotMode.swift` 开一个真窗口逐页渲染成 PNG。注意：SwiftUI 的内容在 layer 树里，得用 `layer.render(in:)`；系统材质（`NSVisualEffectView` 那一类）离屏渲染会成一条黑带，拍之前先摘掉；侧边栏必须是自绘滚动列表，`List(.sidebar)` 的 vibrant 内容离屏拍出来是一片白。

### 4.6 跨页跳转

`AppStore.jumpTo` + `bigScanDir`：总览点「深挖」→ 大文件页带定向范围扫描，一次性消费。

---

## 5. 功能清单（侧边栏 10 + 1 页）

| 页 | 后端 | 说明 |
|---|---|---|
| 空间总览 | `volumeUsage` + TaskGroup 并行 | 英雄卡是 `RingGauge` 环形仪表（分段 + 图例 + 已用量居中）；只读定位，每行「访达显示 / 深挖」 |
| 大文件 | `walkFiles` | TOP 可调，可跳开发目录，支持总览定向范围 |
| 很久没动 | `walkFiles` + mtime | 只看下载 + 桌面，天数可调 |
| 重复文件 | 大小 → 部分哈希 → 全量哈希 | 每组最早一份锁定保留 |
| node_modules | 全盘两段式 | 按项目聚合；大盘很慢，无流式快照（见 §7） |
| Docker | 只读 CLI / 目录回退 | 无删除键 |
| 缓存清理 | `safety_db.json` + glob | 每项四元组解释（这是什么 / 删了会怎样 / 怎么恢复 / 风险等级）；**条目重叠不可加总**，UI 已不加总 |
| 卸载残留 | Info.plist 基准 + denylist | 以已装 App 为基准找孤儿，宁可漏报 |
| 废纸篓 | trashSize / undo / empty | 撤销栈在 `AppStore` |
| 外观皮肤 | `ThemeManager` | 六套皮肤全部可选：每张卡带实时缩略微组件；进阶组靠结构差异不靠配色；明暗三选 |
| 问题反馈 | 无（纯静态） | 邮箱 / QQ 群 / GitHub 三条渠道，地址只在 `Product.swift` 的 `Contact` 定义一处；二维码走 `Contents/Resources` + 源码树兜底，同 `safety_db.json` 套路 |

---

## 6. 已知缺口（按建议顺序修）

1. **node_modules 无流式快照**：大盘要等几分钟才出结果。修法：`findNodeModules` 改 `AsyncStream`。
2. **Intel 包**：本机 arm64，只能出 Apple Silicon。修法：CI 的 macos-13 runner 跑同样的 `build.sh`。
3. **未签名**：ad-hoc 签名，首次打开要右键确认。修法：Apple 开发者账号签名 + 公证。
4. 扫描期内存会冲高后回落到 ~115MB idle（不是泄漏）；低端机可做并发限流。
5. DMG 卷图标仍是系统默认：`Icon\r` + `SetFile -a C` 的标志位在 `hdiutil create` 后会丢，未解。

---

## 7. 设计资产

- `docs/DESIGN.md`：皮肤设计规则（阵容、「差异写在骨架上不写在配色上」、图标块 `tileStrategy`、`chart[]` 位语义）+ 两条跨皮肤铁律：**正文禁染色**（只用 `palette.ink` / `inkSecondary`，彩色只给图标块、环形图、按钮、徽章）；**页头 / banner 禁整块高饱和底色**。token 的权威定义始终在代码：`Sources/DiskCleaner/Theme/Skins.swift`。
- **App 图标**：`build_app/make_icon.swift` 用 CoreGraphics 现画，画的就是总览页那个分段环形仪表（三段彩弧 ≈264°，余下露浅色轨道 = 「已用 73%」）。配色取自皮肤：变体 a 用「晨雾」图例色（默认），变体 b 用「午夜」的。走 macOS 图标栅格（图形居中 824×1024、圆角 185.4），≤64px 自动加粗环、去掉弧间缝隙。`AppIcon.icns` 是生成物，改样式改脚本，别改图。

---

## 8. 接手第一步

1. `swift run SelfTest` —— 21 项 ALL PASS 是红线；
2. `bash build_app/build.sh` —— 三道闸门（双语覆盖、自检、资源断言）任一失败不出包，记下 DMG 的 SHA256；
3. `bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome` 造演示数据，开截图模式逐页点一遍「勾选 → 删除 → 撤销 → 文件回来」（尤其重复文件和卸载残留）；
4. 再碰皮肤和新功能。改 token 前先读 §7 的两条铁律，并用两种语言各看一遍图——英文比中文长 30%，很多宽度问题只有拍出来才看得见。
