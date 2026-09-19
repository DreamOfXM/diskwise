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
│   │   ├── Product.swift          # 品牌常量 + 反馈入口 Contact + 编译期开关 Channel（isAppStore / showsPricing）
│   │   ├── L10n.swift             # L() / LF() / cnt()：中文原文即 key
│   │   ├── HomeGrant.swift        # 商店版首启授权：NSOpenPanel + 授权页（Core 不含 AppKit，所以在这层）
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
│   │   ├── HomeAccess.swift       # ★家目录唯一入口：真实家目录、是否沙盒、授权书签（见 4.7）
│   │   ├── Models.swift           # 知识库解析、路径展开、保护规则、home/applications 锚点、human()
│   │   ├── Scanner.swift          # 占盘统计、通配展开、移废纸篓 + 撤销、访达清空
│   │   ├── ScanScope.swift        # ★扫描范围：用户区 / 整盘的根清单、系统白名单、卷号（见 4.8）
│   │   └── ScanJobs.swift         # 遍历、重复检测、卸载残留、node_modules、Docker
│   └── SelfTest/main.swift        # 自检程序（没有 XCTest 环境时的替代，见 §3）
├── build_app/
│   ├── build.sh                   # 七步：对账 → 图标 → 编译自检 → 组装 .app → 签名 → DMG/.pkg → 公证
│   │                              #   两个渠道两张证书：CHANNEL=oss 找 Developer ID，appstore 找 Apple Distribution
│   ├── entitlements.plist         # 直链版：刻意留空（见 docs/RELEASE.md §2）
│   ├── entitlements-appstore.plist # 商店版：沙盒 + 用户选择读写 + 访达自动化，三条实测最小集
│   ├── l10n_tool.swift            # 双语覆盖率对账：缺译文 / 占位符不匹配 / Int 喂给 %@ 都拦下
│   ├── make_icon.swift            # App 图标参数化生成（CoreGraphics 画一把扫帚）
│   └── make_demo_home.sh          # 造一棵演示用假家目录，给截图和界面自查用
├── docs/
│   ├── ARCHITECTURE.md            # 本文件
│   ├── DESIGN.md                  # 两条跨皮肤铁律 + 皮肤阵容与配色语义 + 文案语气
│   ├── PRIVACY.md                 # 零收集声明（中英双语）——App Store Connect 的隐私政策 URL 指向它
│   └── screenshots/               # README 用图（双语 × 多皮肤，由 SnapshotMode 拍出）
├── README.md                      # 双语首页
├── CONTRIBUTING.md                # 安全铁律 + 知识库怎么加条目 + 翻译规矩
└── LICENSE                        # Apache-2.0
```

---

## 2. 环境要求

- macOS 13+。发布包是通用二进制（arm64 + x86_64 两个切片），本机开发只用 arm64 也够；
  要出发布那份就 `ARCH=universal bash build_app/build.sh`
- **只需要 Xcode 命令行工具，不需要完整 Xcode**（`xcodebuild` 不可用是正常的）
- CLT 里**没有 XCTest**，所以没有 `swift test`——回归靠独立的 `SelfTest` target

## 3. 常用命令（都在项目根目录执行）

```bash
swift build                  # debug 编译
swift run SelfTest           # ★全量逻辑自检，全绿是打包前提
swift run DiskCleaner        # 直跑 App（调试用）

swift build_app/l10n_tool.swift check      # 双语覆盖率对账（build.sh 会自动跑）
bash build_app/build.sh      # 完整打包：对账 → 编译 → 自检 → .app → 签名 → DMG + SHA256
                             # 图标变体：ICON_VARIANT=b bash build_app/build.sh
                             # 商店版（进沙盒 + 出 .pkg）：CHANNEL=appstore ARCH=universal bash build_app/build.sh

# 演示数据 + 截图（README 的图就是这么来的，不需要录屏权限）
# DISKWISE_ONLY=overview,dup 只拍某几页；DISKWISE_WIN=1280x920 换画幅（皮肤页那种长页，
#   窗口得整扇放得下屏幕，超出屏幕的那一截拍不到）
# DISKWISE_DRILL='~/Library' 拍完总览再摊开那一行的下一级（补一张 01-overview-drill.png）
# DISKWISE_DEMO_USAGE=96:16 把盘容量钉死（仅假家目录生效）。不带也行——假家目录一定自带
#   兜底容量，绝不读真盘；这组数就是跟 make_demo_home.sh 那棵树相配的那一档
bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome
DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome DISKWISE_SHOTS=/tmp/shots \
  DISKWISE_DEMO_USAGE=96:16 \
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
- `Channel.showsPricing`（`Product.swift`）是编译期常量，两个渠道都是 false：六套皮肤一律可用，不渲染分区标题、试穿横幅和 `PaywallSheet`。此时「这套皮肤能不能用」只由 `ThemeManager.canUse` / `unlock` 两处判定，视图不感知开关。`-DAPPSTORE` 与它是两回事，只决定沙盒、签名身份和产物格式（见 4.7）。
- `palette.chart` 约定：**下标 4 恒为兜底色**，必须是整套里最弱的一支（灰 / 低饱和）——总览环形的
  「其他已统计」用它，那一段可以很大，抢色就把前三名的柱子糊了。「没量到的地方」用 `inkTertiary`，
  因为它不是量出来的东西，不该占一个真实色相。
- macOS 13 的 `ScrollView` 会把**内容的完整高度**当成自己的理想尺寸上报。页面里再套 `ScrollView`/`List`，detail 列会胀到一千多磅、整页被顶出窗口。规矩：**每页只有一个滚动容器**，列表行用 `LazyVStack` 自绘卡片。

### 4.3 安全铁律（产品立身之本，任何需求不得违反）

- 全 App 唯一删除路径是 `trashItem()`（`FileManager.trashItem`，只进废纸篓）；
- `isProtected()` 路径（家目录本体、`~/Library` 等）整体不可删，里面的子项可以；
- `isDeletable()` 划出能动手的位置（家目录 + 装 App 的目录）。整盘扫描会把系统区摆上列表，
  但那些行只算账不伸手：勾选框锁死、带「系统区」标记，展开还有一句为什么不动它（见 4.8）；
- 清空废纸篓必须走访达（`emptyTrashViaFinder`，AppleScript，系统再确认一次）；
- Docker 页只读不删（镜像/卷活在虚拟盘里，没有独立路径，只指路）。

### 4.4 双语（i18n）

- **中文原文就是 key**：视图里写 `L("正在比对…")`，`en.lproj/Localizable.strings` 提供英文。没有 zh 侧文件——漏译只会静默退回中文，所以覆盖率靠工具卡。
- `LF()` 带 `%@` / `%1$@` 参数；`cnt(n, "个文件")` 处理英文单复数；`errList()` 拼多条失败原因。
- ⚠️ `String(format:)` 的 `%@` 只接受对象：直接把 `Int` 喂给 `%@` 是 `EXC_BAD_ACCESS`，debug 跑不崩、英文界面一点就崩。`l10n_tool.swift` 会把这种写法拦成构建失败。
- 位置参数两侧的 `%1$@` / `%2$@` 集合必须一致，工具同样会查。
- ⚠️ **一条串里不能混用带序号和不带序号的参数**：写了 `%1$d` 就不许再有 `%@`。这种串解析时直接
  `EXC_BAD_ACCESS`，而且只在走到那条分支时才炸——演示树只有 16 个热点，永远凑不出「展开其余 N 处」
  那一行，于是崩在真机上。`l10n_tool.swift check` 现在把这条也拦下来（key 和译文各查一遍）。
- 切语言**当次生效**：`L10n.apply()` 换掉 `active` 与词表，`AppStore.setLanguage` 再发布一次选择状态让整棵树重画。
  只写 `AppleLanguages` 是不够的——那只影响下次启动，而商店版不允许自己起子进程重启。
  选「自动」用的是启动那一刻的系统语言快照（`systemResolved`），本会话写进的覆盖不会让「自动」在运行中变卦。
- 品牌名不进词表：`Product.name` 在两种语言里都写作 DiskWise。bundle id 保持 `com.dreamofxm.diskcleaner`——它是钥匙串、自动化授权、UserDefaults 的锚点，改名等于让老用户的授权和购买记录作废。

### 4.5 演示数据与截图

- `homeDir()` 是家目录的唯一入口。设了 `DISKWISE_HOME_SHIM` 就整棵树换到演示目录（`applicationsDir()` 跟着搬进演示树），扫描、统计、废纸篓全在假树里跑。
- 为什么不用真家目录截图：总览页会把 `~/Desktop`、`~/Documents` 连同体积原样晒出去，那是隐私不是演示。
- `make_demo_home.sh` 只写零 + 给每个文件首字节盖唯一标记（块分配是真的，内容哈希又是唯一的，不会被误判成一整组重复）；`dup()` 才用 `cp` 造真正的逐字节副本。脚本从不删任何东西，重跑幂等。
- `SnapshotMode.swift` 开一扇真窗口逐页出图。主路径是问窗口服务器要这一扇窗的合成像素（`CGWindowListCreateImage` 配 `optionIncludingWindow`，只取自己那一张，别的窗口压上来也混不进去，所以不需要录屏权限）。**侧边栏非走这条路不可**：它的列表由 `_NSCoreHostingView` 画，像素只存在于服务器端那份合成里，离线 `layer.render(in:)` 拍出来是一片纯白（导航项全丢，还不报错）。问不到才退回离线画 layer 树，那条路径下系统材质（`NSVisualEffectView` 那一类）会成一条黑带，拍之前得先摘掉。
- `DISKWISE_DRILL='~/Library'`：拍完总览再往那一行上走一次「就地摊开下一级」，补一张 `01-overview-drill.png`。
  它调的就是行上那颗箭头调的同一个方法（经 `AppStore.overviewDrill` 递进去，读完即清空），不是为截图另画的假界面。
  为什么要这条：**锁屏状态下 AX 点不动按钮**，而展开态恰恰是这屏最需要留证的部分。
- `DISKWISE_JUMP=rest|restnote|gap|<某行完整路径>`：滚到「其他已统计」那块弧的落点（有「展开其余」
  就落到它上面，一行都没被封顶切掉时落到列表尾巴那句对账）、直接落到那句对账（`restnote`）、
  或「没量到的地方」那一段、或某一行本身，补 `01-overview-jump.png`。走的是点环形图例那一格的
  同一条路径（先摊开再滚）。
  这两个钩子合起来才拍得到「摊开后的下一级 + 列表底下那几行总账」——它们都在固定画幅之外，
  而这两处正是「其他已统计那块弧到底回答了没有」的证据所在。
- 演示树拍不到的东西别当 bug 查，也别拿演示图宣称验过了：热点封顶 20 行，假树只有 16 个够格的目录，
  所以「展开其余 N 处」那一行、以及里面混着「只能看」的那一堆，只有真机能拍到（整盘档下 `/Library`、
  `/usr/local` 这些都在家目录之外）。同理，可清除空间在演示树里恒为 0，环形就不画那条弧。

### 4.6 页面状态与跨页跳转

- **扫描结果是 App 级状态，不是视图状态**。侧边栏是 `switch` 切分支，页面视图随导航销毁——所以模型
  一旦写成 `@StateObject`，每切一次 tab 就把全盘遍历重跑一遍（切来切去卡的就是这个）。八个扫描页的
  模型现在统归 `ScanStore`（`DiskCleanerApp.swift`，由 `ContentView` 持有）所有，页面只接 `@ObservedObject var model`。
- 因此每页的规矩是：**首次进入自动扫一次**（`if !model.started`），结果留下；之后再进来直接用缓存；
  要新结果由用户点工具条右侧的 `ScanControl`（扫描中是「停止」，扫完是「重新扫描」）。
  **离开页面不再取消任务**——取消了结果就作废，下次进来还是重跑，等于白折腾。
- 遍历的内存上界在 `walkFiles`：`top` 只保留最大的前 N 条（攒到 4N 收缩一次），`olderThan` 把日期过滤
  下推进遍历。命中总数走 `WalkResult.matched`，所以「共扫到 N 个文件」的口径不因为截断而变。
  大文件页的「前 N」因此不重扫：候选集（≤200）留着，`applyLimit()` 只重切显示，勾选按下标写回。
- 删完不重扫：大文件 / 重复 / node_modules 三页改为就地剔除已消失的条目。整库重哈希留给用户主动点。
- `AppStore.jumpTo` + `bigScanDir`：总览点「深挖」→ 大文件页带定向范围扫描，一次性消费。

### 4.7 沙盒与家目录授权（商店版）

商店包必须 `com.apple.security.app-sandbox`，而这个 App 的每件事都发生在家目录里。危险不在于读不到，
在于**读错了还像读对了**：

- 沙盒里 `NSHomeDirectory()` 和 `FileManager.default.homeDirectoryForCurrentUser` 都会返回
  `~/Library/Containers/<bundle id>/Data`。拿它当扫描根不报错、不弹窗，只是那棵树几乎为空——
  总览页会显示「你的盘很干净」。**这是本 App 最坏的一种错**，所以宁可什么都不显示。

三层设计（`Sources/DiskCleanerCore/HomeAccess.swift`，全 AppKit-free）：

1. `realHomeDir()` 从 `getpwuid(getuid())->pw_dir` 取，不经 Foundation，拿到的永远是真实家目录；
2. `HomeAccess.runsSandboxed` **运行时**判定（看 Foundation 的家目录是不是容器路径），不看编译开关——
   同一个二进制在两环境下都该表现正确，`-DAPPSTORE` 只影响签名不影响这套逻辑；
3. `HomeAccess.granted` 有值才允许扫描。没值时 `DiskWiseApp` 的 `ContentView` 把侧边栏禁用、
   detail 换成 `HomeGrantView`（`Sources/DiskCleaner/HomeGrant.swift`），扫描作业一次都不发。

`grant()` 存的是一条 security-scoped bookmark，`init()` 里 `HomeAccess.restore()` 把它解回来续上，
所以授权是一次性的、重启仍在。解不开（换机器 / 重新签名换了容器身份）就**清档回授权页**，
不拿着读不到的路径继续跑——所有失败分支都朝「回到授权页」收，没有一处朝「当作成功」收。

实测出来的三条，别重新推一遍：

- `startAccessingSecurityScopedResource()` 只认**从书签解析回来的那个 URL 实例**。把 `NSOpenPanel`
  返回的 URL 直接拿去调用会返回 false（`grant()` 里先写书签再解析回来 adopt，就是在绕这条）。
- `/Applications` 在沙盒里可枚举 → 卸载残留页一行没改。
- `com.apple.security.temporary-exception.files.home-relative-path.read-write` 能把真实家目录整条
  放开（实测可用），但**商店包不能用**：temporary exception 是审核红线，写了等于给自己找拒。
- **沙盒读不到 `~/.Trash`**，而且有了家目录书签也读不到（废纸篓在沙盒的禁读名单里）。真值实测：同一段
  统计代码在沙盒外枚举到 65 项 / 368 MB，在商店包里 `contentsOfDirectory` 直接抛错。所以
  `trashInfo()` 返回 `nil` 表示「读不到」，界面把「未知」和「0」分开——把 `try?` 吞掉的错误当成
  「废纸篓是空的」，后果是清空按钮永久禁用。按钮只在**确知条目数为 0** 时才禁，读不到照样可点：
  清空一个空废纸篓本来就没后果，而那一步本来就必须经过访达。

约束：Core 不许 `import AppKit`，所以弹面板、按钮、状态提示全在 `DiskWise` 那层的 `HomeGrant`
（`@MainActor` 单例，UI 只读它的 `needsGrant` / `failure`）；反馈页留了「重新授权」出口，
用户改主意或书签失效都能就地重来，不用删 App。`DISKWISE_HOME_SHIM` 的优先级仍高于授权结果
（见 4.5），截图链路不受沙盒改造影响。

### 4.8 扫描范围：算账的范围和动手的范围是两件事

这产品卖的是「大文件」，那只看 `~/Downloads` 就是虚假承诺：在一台 434 GB 的盘上，以前写死的六个
家目录子夹只覆盖约 20 GB，用户照着列表清完盘还是满的。所以范围是一等公民，`ScanScope.swift` 一处定义：

- `ScanScope.user` 家目录（含隐藏项）+ 装 App 的目录 —— 沙盒版能稳定拿到的最大范围，也是商店版默认。
- `ScanScope.disk` 再加 `systemScanRoots()` 白名单：`/Applications`、`/Library`、`/opt`、`/private`、
  `/usr/local`、`/System/Volumes/Data/System`，外加 `otherHomeRoots()` 列出的**别人家目录**
  （`/Users/<每个非当前用户>`，`/Users/Shared` 就在其中）。**白名单不是从 `/` 往下爬**：`/System`
  是只读密封卷（SIP，扫它等于白跑十几 GB）、`/Volumes` 会挂进外置盘和时间机器备份盘、`/dev` 是设备
  结点的家。root-only 的目录不用列黑名单——`dirSizeReport()` 打不开目录时按 errno 分类记下来（见 4.9），
  **读不到不等于 0**，这类路径只能进「没量到」，不能进「已统计」。
- 那两条后来补的根各治一个具体的漏：`/System/Volumes/Data/System` 路径长得像系统卷，其实挂在**数据卷**
  底下，装着 `AssetsV2`（App Store 与系统更新的下载缓存），一台机器上实测 18.9 GB；别人的家目录则
  是「整盘」这个词字面上就该包含的东西。两处漏掉时「整盘」比真实值少报 20.6 GB，而差额会滑进环形
  「没量到的地方」那块——等于把我们自己的疏漏说成盘的账。算到 ≠ 删得动：这两处只进账，
  `isDeletable()` 不认它们（见本节「算到 ≠ 删得动」）。
- **界面上没有范围开关**：`ScanScope.effective` 一处定死——沙盒版 `.user`，非沙盒 `.disk`，
  也就是「这一版物理上扫得到的最大范围」。以前这里有两档可选，实测一台机器上就出了事：环形的
  「其他已统计」按用户区的账画，下面的列表按整盘的账列，同一屏两套口径，谁都对不上谁，而「对不上」
  是直接砸信任的。留着开关还有第二种坏法：沙盒里点「整盘」只会扫一堆读不到的路径，等于摆一颗没反应的钮。
  所以 `AppStore.scope` 现在只是 `ScanScope.effective` 的只读别名，没有存盘键、没有切换、没有重扫信号。
  「这一轮到底扫了哪些地方」由 `scopeNote` 一句话交代清楚（见 4.9）。
- 每页页头贴本次范围（`范围：用户区` / `范围：整盘`）。总览**不贴**范围标：它这一屏只有一套账，
  再挂一枚范围徽章反而像「还有另一套没给你看」。node_modules 与 Docker 两页**不吃**这个范围
  （理由写在 `findNodeModules` 的注释里）：前者标死「范围：用户区」，后者只对着一个数据目录，没有范围可谈。
- **跨卷守卫按根算**：`dirSize` 和 `walkFiles` 都先取根的 `st_dev`，遇到卷号不同的目录就停。
  APFS 上 `/`、`/Applications`、`/Users` 因 firmlink 共享同一个 `st_dev`，所以这条守卫不会把
  整盘切成一堆碎片，只挡住真正挂载在别处的卷。
- **根套根要剪掉**：`walkFiles` 开走前算好「哪些别的根就在我底下」，走到就跳过，那块由它自己
  当根去扫。演示树把整盘根全挪进假家目录，不剪的话同一份文件走两遍：列表按 path 作 `ForEach`
  的 id，第二条只占行高不画字，重复文件页还会把一份内容算成两组（实测一次整盘扫描多报 29 条）。
- **算到 ≠ 删得动**：`isDeletable()` 只认家目录与装 App 的目录。整盘扫出来的系统区条目照样列
  （那是账），但勾选框锁死 + 「系统区」标记 + 展开说明。重复文件页更硬：候选先 `filter(\.deletable)`，
  因为对 root 文件做一次全量哈希再告诉用户「删不了」是纯浪费。
- **全选不越权，而且只有一颗**：批量勾选的入口只有底部清理条那颗「全选」，页头不再放第二颗
  （重复文件页原先那颗「全选多余」就是漏网的，五页两种位置）。它只勾这一页勾得动的行——系统区的、
  体积还没统计出来的、卸载残留里标「留意」的都不在内（那页的立脚点是宁可漏报不可误删，一键带走「留意」
  等于把这页存在的理由按掉）。差额写在按钮提示里；一行都勾不动时按钮不画，画一颗点了没反应的比没有更糟。
- **全选必须能按回去**：勾得动就得取消得动，`SelectAll.allSelected` 决定那颗按钮变成「取消全选」，
  两态走同一个 `toggle(Bool)`。重复文件页曾经只能勾不能撤，一页 170 项、10.1 GB 挂在废纸篓按钮上
  没有回头路——这种状态不能上线。截图链路用 `DISKWISE_PICK=<页名>` 真按两次，
  拍出 `-selected` 与 `-deselected` 两张，后者必须跟原始那张一模一样。

### 4.9 容量数字的口径：单位、差额、演示数据

这屏上每一个数字都会被拿去跟「关于本机」对。对不上，用户就认定工具算错了账——数字小一点没人管，
单位错一次这产品就不值得信了。

- **单位一律十进制**（1 GB = 10⁹ B），跟访达「显示简介」、「关于本机」、`diskutil` 同口径。
  以前 `human()` 按 1024 算数却标 GB：同一块 494.4 GB 的盘报成 460.4 GB，比系统界面少 7%，
  而且列表里所有体积一起缩水。界面上出现的阈值（`sizeFloor`、「可用不足 20GB」、重复文件的
  `≥ N MB`）统一用 `Models.swift` 里的 `kB/MB/GB/TB` 常量，不再手写 `1024 * 1024 * 1024`。
  唯一例外：`parseDockerSize` 解的是 Docker CLI 自己的输出，按它的单位读。
- **盘容量取 `attributesOfFileSystem(forPath: "/")` 的 `.systemSize/.systemFreeSize`**，也就是整个
  APFS 容器（含系统卷、Preboot、VM 卷）。所以「已用 − 已扫到的」天然包含用户读不到的那一块，
  差额不是 bug，但必须交代清楚，见下条。
- **差额必须点名，不能只是一块灰**：`dirSizeReport()` 在目录打不开时按 errno 分类返回
  （`EPERM` = 缺「完全磁盘访问权限」；`EACCES` = 只有管理员能读，只能说明）。但 **errno 计数不能拿来
  当授权状态**：TCC 的授权只在进程启动那一刻挂上，所以「刚勾完还没重启」和「压根没勾」在扫描里长得
  一模一样，拿它决定按钮就会对着一个已经授权过的人喊「去授权」——真机上就是这么错过一次。授权与否改由
  `fullDiskAccessGranted()`（`Scanner.swift`）实测：直接 `open()` 两个 0644 的金丝雀
  （`/Library/Application Support/com.apple.TCC/TCC.db` 和 `~/Library/Safari/Bookmarks.plist`），
  读得动才算已授权，`ENOENT`/`ENOTDIR` 换下一个，其余 errno 即未授权。这颗按钮（`canGrantFDA`）只在
  「非沙盒 ＋ 探针说没授权 ＋ 确实有 EPERM 目录」三条同时成立时才画；已授权仍读不到的那几处，
  标签换成「已授权仍读不到」并明说重启提权都换不回来。沙盒版另一套话术：那条出路是给非沙盒渠道的，
  在容器里按下去没有可核对的效果，所以只报「沙盒读不到的目录 N 处」，不指门也不摆按钮。
  总览环形下面常驻一行，把整块盘的账一路减到底：「整块盘 T：可用 A（空闲 F ＋ 系统可清除 P），已用 U。
  已用里这一轮量到 C（p%），剩下的 G 在下面逐块点名。」**可清除为 0 时那半句整段不写**，改成
  「可用 A（全是空闲）」：环形本来就不画 0 字节的弧，句子照抄模板就会拍出一张「系统可清除 0 B」的图，
  那是在演示一个不存在的东西。只报「已量到 C」是不够的——人手里记的是「我这盘 500 G」，
  看到三百多就以为工具宣称整块盘只有三百多，那一瞬间这屏就成了骗人。实测一台 500 GB 的机器：
  整盘扫一轮量到已用的 85%，剩下的分在密封系统卷、引导与恢复分区、root-only 目录三处。
- **可用那个数跟系统「储存空间」页对齐，但必须拆成两段写**：`volumeUsage()` 的可用取
  `volumeAvailableCapacityForImportantUsageKey`（系统界面报的就是它），`statvfs` 的真空闲单列成
  `free`，两者之差就是 `purgeable`（快照、缓存那一类，系统记作可用、此刻还占着盘）。
  `available = free + purgeable`、`used = total − available`，而卷账 `volumeSplit` 必须喂
  `usedPhysical = total − free`：拿系统口径的已用去减卷账，会凭空少算 10 GB 那一坨可清除。
  自检钉的是这三条等式，任何一条挪账都会红。
- **环形每一段都要能对回已用**：`ringSplit(covered:used:topSum:)`（`Scanner.swift`，纯函数）把账拆成
  「前 3 大 + 其余量到的 + 这一轮没量到的」三块，三块加起来不等于已用就返回 nil，界面回落到单块灰。
  自检直接喂假表钉住这条，因为这块的错法是「图看着挺满、数字全是编的」。
- **「其他已统计」那块弧必须能在下面的列表里逐段对上**，这是它的验收线（一块一百多 G 的弧只写一个
  名字，等于让人拿放大镜找不着北）。两头一起落地：
  - 列表里第 3 行与第 4 行之间画一条分界线（`restGroupDivider()`），当场报「这条弧的 221.9 GB 里，
    大头在下面这 17 行、合计 200.1 GB」。前三名各占一条弧、第四名往后合占一条弧，这条线就是那条弧
    在列表里的边界。真机上缺过它一次：弧上的 221.9 GB 点下去只看得见「展开其余」那 21.2 GB，
    200 GB 停在屏幕上方没人框，用户读到的结论是「大头你一直找不到」。
  - 列表尾巴那句 `restArcNote()` 收口：把 `restMeasured` 拆成「上面那 N 行」＋「『展开其余』里那 N 处」
    ＋「N 处不到 `sizeFloor` 的小目录」三段，逐段带数相加。
  这个恒等式是**构造出来的**而不是巧合：`covered` 就是这几处的总和，`unlistedBytes = covered − Σ列出过的`，
  所以余数永远有归属，不会出现「凑不出那个数」。任何一段变了（阈值、封顶行数、展开与否），这两句跟着变。
  分界线只准当 `LazyVStack` 的直接子节点：写在 `ForEach` 的内容闭包里时，SwiftUI 会把扫到第 4 行那一刻
  算出的旧值一路留着不刷新，摊开的数当场变成假账（演示树实测：13 行 24.8 GB 渲染成 1 行 398.5 MB）。
- **环形上每一块弧都得回答三问：是什么、在哪、能不能删**。这一条是这屏的验收线：占大空间又不是系统级
  受保护的东西，用户却看不见也动不了，等于工具不合格。落地成四件事：
  1. 图例可点（`GaugeSegment.jumpTo`）——前三名的弧落到列表里那一行，「其他已统计」落到上面那条分界线上
     （也就是那一组的第一行，先展开「其余」再滚），「没量到的地方」落到下面那张明细卡。
     只有「空闲」「系统可清除」不给跳转：它们本来就不是「谁占了地方」的答案。
  2. 热点行能就地摊开下一级（`childDirSizes`，`Scanner.swift`）：点开才量，只量一级、不跨卷、
     符号链接不算第二格（跟 `dirSizeReport` 同规矩，否则共享字节会被数两遍），并发掐在 6，
     否则 `~/Library` 一级四十多个目录会跟主扫描抢工作线程。封顶 12 格，摊不开的余额单独报数，
     不许悄悄对不上父行那一格。重扫时 `dropChildren()` 把旧的下级账整体作废。
  3. 每一行（父行和摊出来的子行都一样）常驻一颗「访达显示」，`.help` 里给全路径——这是「在哪」。
  4. 每一行带一枚 `ActionBadge`：`能删` / `只能看`，判据是 `isDeletable(路径)`（只有家目录与
     /Applications 动手得了，见 4.3）。**两态都要画出来**：缺一枚徽章会被读成「大概能删」，
     而这一屏最不该含糊的就是这个。列表底下再收一次总账：「列出的 N 项里：能进废纸篓 X，只能看不能删 Y」。
- **卷账来自 `diskutil apfs list -plist`**：`volumeSplit()` 按角色点出密封系统卷、引导与恢复分区、
  虚拟内存与休眠镜像、卷间元数据残差，扣完剩下的才是「数据卷里没量到的部分」。全 App 只有两处
  读外部命令的输出（另一处是 Docker CLI，见上面单位那条），都走 `runTool()` 且只解析 plist 不解析
  文本。演示模式一定返回 nil：一棵几十 G 的假树跟真机的卷账混在一张图上，正是 4.9 开头要避免的事。
- **演示树一定自带盘容量、也一定自报是演示**：`DISKWISE_HOME_SHIM` 生效时 `volumeUsage()` 只走
  `demoVolume()`，没给 `DISKWISE_DEMO_USAGE` 就用兜底数（96:16，跟 `make_demo_home.sh` 那棵树相配），
  绝不回落到真盘。曾经少带一个变量，界面上就画出了「一棵几十 G 的假树 + 一台真机的已用总量」，
  没量到的那一块占到 81%——那不是扫描失败，是两本账混在了一张图上。现在只要 `homeIsDemo`，
  总览页头就整条挂着「演示数据：这一屏的目录、文件和整块盘的容量都是造的」那条横幅，
  谁看都知道这屏不是真机；真机那一屏不会出现它。演示树里还固定造了一个 `chmod 000` 的目录，
  否则「另有 N 处只有管理员能读」那半句在截图里永远拍不到（假家目录整棵都属于当前用户）。

---

## 5. 功能清单（侧边栏 10 + 1 页）

| 页 | 后端 | 说明 |
|---|---|---|
| 空间总览 | `volumeUsage` + TaskGroup 并行 | 英雄卡是 `RingGauge` 环形仪表（分段 + 图例 + 已用量居中，各段加起来正好等于整块盘，见 4.9）；**图例每一点就滚到它对应的那一行/那一段**，跳过去前先把目标摊开；页头只有扫描控件，没有范围开关（范围由 `ScanScope.effective` 一处定，见 4.8），演示树额外挂一条横幅；环形下方常驻一句覆盖范围说明＋一路减到底的「整块盘 = 可用（空闲＋可清除）+ 已用，已用 = 量到 + 量不到」；再下面是可折叠的「没量到的地方」明细卡，逐块给多大、为什么、动得了动不了，只有探针确认没授权时才带跳系统设置的入口；「最占地方的文件夹」每行可就地摊开下一级（`childDirSizes`），行行带「能删 / 只能看」徽章和常驻「访达显示」，列表底下先收一次两堆总账、再给「其他已统计」那句逐段对账（见 4.9 的三问）；「深挖」跳大文件页带定向范围。再进来只刷余量，热点体积用缓存（见 4.6） |
| 大文件 | `walkFiles(top: 200)` | 按范围根遍历（见 4.8），可跳开发目录，支持总览定向范围；「前 N」只在候选集上重切，不重扫 |
| 很久没动 | `walkFiles(olderThan:)` | 与大文件同一批范围根，天数可调；日期过滤在遍历里做，不收全量数组 |
| 重复文件 | 大小 → 部分哈希 → 全量哈希 | 每组最早一份锁定保留；候选先过 `isDeletable`，系统区的重复不进这一页 |
| node_modules | 用户区两段式 | 按项目聚合；刻意只走用户区那一档范围（见 4.8）；大盘很慢，无流式快照（见 §7） |
| Docker | 只读 CLI / 目录回退 | 无删除键 |
| 缓存清理 | `safety_db.json` + glob | 每项四元组解释（这是什么 / 删了会怎样 / 怎么恢复 / 风险等级）；**条目重叠不可加总**，UI 已不加总 |
| 卸载残留 | Info.plist 基准 + denylist | 以已装 App 为基准找孤儿，宁可漏报 |
| 废纸篓 | `trashInfo` / undo / empty | 撤销栈在 `AppStore`；读不到体积时不判空（见 4.7） |
| 外观皮肤 | `ThemeManager` | 六套皮肤全部可选：每张卡带实时缩略微组件；进阶组靠结构差异不靠配色；明暗三选；界面语言当次生效（见 4.4） |
| 问题反馈 | 无（纯静态） | 邮箱 / QQ 群 / GitHub 三条渠道，地址只在 `Product.swift` 的 `Contact` 定义一处；二维码走 `Contents/Resources` + 源码树兜底，同 `safety_db.json` 套路 |

---

## 6. 已知缺口（按建议顺序修）

1. **node_modules 无流式快照**：大盘要等几分钟才出结果。修法：`findNodeModules` 改 `AsyncStream`。
2. 扫描期内存会冲高后回落到 ~115MB idle（不是泄漏）。列表页的候选集已封顶（`walkFiles(top:)`），
   剩下的冲高来自并行 `dirSize`/哈希；低端机可做并发限流（`withTaskGroup` 目前全部无上限）。
3. DMG 卷图标仍是系统默认：`Icon\r` + `SetFile -a C` 的标志位在 `hdiutil create` 后会丢，未解。
4. **商店包的授权闭环只能真点一次验证**：`NSOpenPanel` 选中目录这个动作本身才是 powerbox 交出访问权
   的时机，无头环境里造不出来说「用户选过了」的东西。已用探针量清的部分见 4.7（容器改写、书签解析、
   失败分支一律回授权页）；剩下「面板 → 存书签 → 重启后 `restore()` 仍能读到」这一条要靠人点。

---

## 7. 设计资产

- `docs/DESIGN.md`：皮肤设计规则（阵容、「差异写在骨架上不写在配色上」、图标块 `tileStrategy`、`chart[]` 位语义）+ 两条跨皮肤铁律：**正文禁染色**（只用 `palette.ink` / `inkSecondary`，彩色只给图标块、环形图、按钮、徽章）；**页头 / banner 禁整块高饱和底色**。token 的权威定义始终在代码：`Sources/DiskCleaner/Theme/Skins.swift`。
- `docs/PRIVACY.md`：对外隐私政策，中英各一段，口径必须和代码一致——不联网、不收集、只写本机偏好、删除只进废纸篓。App Store Connect 的「隐私政策 URL」填指向它的仓库公开页。
- `docs/RELEASE.md`：发布流程的唯一权威说明 —— `build.sh` 七步各做什么、两条发行路线两张不能互换的证书（Developer ID / Apple Distribution）、两套 entitlements 各自为什么长这样、公证凭据怎么存、CI 的五个 secrets、商店路线的出包上传与提审前清单、发版前七项自查。签名与公证的逻辑别在别处再写一遍。
- **App 图标**：`build_app/make_icon.swift` 用 CoreGraphics 现画一把斜着的扫帚——柄在左上、发亮的刷头在右下，刷梢前面推着几粒被扫出去的灰点。三层：macOS 圆角底板（竖向渐变 + 两团氛围光）→ 浮灰和灰点 → 扫帚本体（渐变柄 + 亮色箍 + 五束在根部相连、往梢部外扩收圆的刷毛）。配色取自皮肤：变体 a 用「极光玻璃」那组深底冷光（默认出厂），变体 b 用「晨雾 + 薄荷」的浅底。走 macOS 图标栅格（图形居中 824×1024、圆角 185.4），≤64px 自动加粗整把扫帚、刷毛收成四束。`AppIcon.icns` 和 `docs/icon.png` 都是生成物，改样式改脚本，别改图。

---

## 8. 接手第一步

1. `swift run SelfTest` —— ALL PASS 是红线；
2. `bash build_app/build.sh` —— 三道闸门（双语覆盖、自检、资源断言）任一失败不出包，记下 DMG 的 SHA256；
3. `bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome` 造演示数据，开截图模式逐页点一遍「勾选 → 删除 → 撤销 → 文件回来」（尤其重复文件和卸载残留）；
4. 再碰皮肤和新功能。改 token 前先读 §7 的两条铁律，并用两种语言各看一遍图——英文比中文长 30%，很多宽度问题只有拍出来才看得见。
