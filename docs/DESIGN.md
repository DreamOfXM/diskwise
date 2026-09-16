# 设计规则

> 中文优先。代码里的 token 定义在 `Sources/DiskCleaner/Theme/`，本文只写**为什么**这么定。
> 改任何视觉之前先读这一页——这里的每条规则都对应过一次返工。
>
> **English.** Design rules, Chinese-first. The two that never bend: body text is never colored
> (only `palette.ink` / `inkSecondary` — color belongs to icon tiles, the ring chart, buttons and
> badges), and page headers never sit on a fully saturated block. Premium skins sell on
> *structural* differences (typeface, radius, elevation, motion), not on a different color scheme.

---

## 1. 两条跨皮肤铁律

1. **正文禁用染色。** 主文字只用 `palette.ink`，次要文字只用 `palette.inkSecondary`（每套皮肤各自定义）。
   彩色只出现在图标块、环形图、徽章、按钮、数据强调上。
   理由：这是 DaisyDisk / CleanMyMac 那一类工具的通行纪律——正文一旦开始变色，界面立刻从"工具"掉进"海报"。
2. **页头 / banner 禁止整块高饱和底色。** 用卡片 + 描边，色彩只留在小面积元素里。
   整块高饱和头图会把视觉重心钉在页面上沿，下面的数据反而没人看。

## 2. 皮肤阵容：免费 3 + 付费 3

| 皮肤 | 档位 | 价格 | 结构身份（不是配色身份） |
|---|---|---|---|
| 晨雾 `dawn` | 免费·默认 | — | 系统字 + 软阴影 + squircle，中性纸 + 克制蓝，深色模式一等公民 |
| 石墨 `graphite` | 免费 | — | 同上骨架，深色 |
| 薄荷 `mint` | 免费 | — | 圆体 + 大圆角 + 圆形图标块，绿 |
| 极夜黑金 `midnight` | 付费 | ¥12 | **衬线 + 直角（radius 2–4）+ 零阴影 + 零动效** → 克制的贵 |
| 极光玻璃 `aurora` | 付费 | ¥18 | **圆体 + radius 22 + 真 `.thinMaterial` + 弹性动画 + 光斑背景** → 外放的炫 |
| 水墨宣纸 `inkwash` | 付费 | ¥15 | **衬线 + 纸纹纤维 + 方印章 + 静止** → 有文化的慢 |

## 3. 三条卖货铁律

1. **付费皮肤靠骨架差异卖，不靠颜色差异卖。** 只换色的皮肤没人买——所以三套付费在字体面、圆角、
   阴影/材质、动效签名上**互不相同，且都不同于免费三套**。加新付费皮肤先问：它的骨架差异在哪？
   答不上来就别加。
2. **免费三套要好看但不够炫耀**——够留住人，不够拿去截图传播。
3. **货架必须渲染真实缩略图。** 早期货架是三个色块，看不出贵在哪，所以没人买；现在每张卡直接渲该皮肤下的
   迷你侧边栏 + 环形图 + 列表行 + 按钮。商店在 `AppearanceView`，试穿（`tryingID`）先穿上身、
   顶部横幅一键还原，不自动扣费。

## 4. 架构约束

- `Theme` = 纯数据；`ThemeManager` 单例 + UserDefaults 三个 key（选中的皮肤 / 已解锁数组 / 明暗开关）；
  视图通过 `@Environment(\.theme)` 拿，`.themed()` 注入。
- **不要**再往 `ContentView` 上加 `.id(skin.id)` 强制重建子树——那个写法每换一次肤就把全盘扫描重跑一遍。
- 视图层只准引用 `theme.*` token，禁止手写色值、禁止假设浅色。
- 明暗：皮肤自带 `scheme`（可为 nil = 跟随系统），App 级 `forcedScheme` 优先于皮肤。
- 付费接缝只有两处：`ThemeManager.canUse` 和 `unlock`。接 StoreKit 时只换这两处 + `PaywallSheet`，
  **视图零改动**。
- 每个页面只有**一个**滚动容器，列表行用 `LazyVStack` 自绘卡片。macOS 13 的 `ScrollView` 会把内容的完整
  高度当成自己的理想尺寸上报，套两层会让 detail 列胀到一千多磅、整个界面被顶出窗口。

## 5. 图标块与图表配色

- 侧边栏/列表图标块**不再全皮肤通用**：形状跟 `tileShape`（squircle / circle / rounded），配色跟
  `tileStrategy`——免费三套 `.spectrum`（`Theme.spectrumLight` / `spectrumDark` 两条 10 色品牌光谱，
  与侧边栏条目一一对应，靠颜色认路），两套衬线克制皮肤（黑金 / 水墨）`.duotone`
  （`palette.tint` 与 `palette.ink` 交替，靠形状和位置认路）。
  理由：**满屏彩虹会毁掉贵气**——水墨宣纸本身是浅色纸面、并不是深色皮肤，照样不该出彩虹，
  所以分档看的是气质不是明暗。图标前景：深色 + spectrum 用 `palette.paper`，其余纯白。
- `chart[]` 有位置语义，**不要当成随机色板取用**：
  - `chart[0..3]`：环形图前 4 大分段和主要数据强调（要饱和）；
  - `chart[4]`：固定是**退让色**——"其他已用"分段、次要条，任何"不想被注意"的数据都用它。
    它常年是环形仪表最大的一段，抢色就把整张图糊了；每套皮肤的 `chart[4]` 都刻意选成低饱和灰调，
    加皮肤时保持这个约定；
  - `chart[5]`：留给 node_modules / Docker 的进度条。

## 6. 文案语气

界面文案是产品的一部分，不是占位符。中文写"人话"（"空间都去哪了""哪些缓存敢删"），英文按英文重写而不是
逐句对译（"Where did the space go" → "Gone, but still here" 这类）。两条约束：

- 英文一律美式拼写（recognize / color / summarize），不混英式。
- 数量词交给 `cnt()`：中文直接拼量词，英文查单复数表。模板里**不要再写一遍量词**，
  否则会出 "27 items items listed"。
