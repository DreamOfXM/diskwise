<div align="center">

# DiskWise

**A native macOS disk cleaner that never deletes anything.**
Every removal goes to the Trash and stays undoable until *you* empty it.
SwiftUI, no Electron, no Python sidecar, no local server, no telemetry. 1.6 MB.

[English](#english) · [中文](#中文)

![platform](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
![swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)
![license](https://img.shields.io/badge/License-Apache%202.0-4c8f52)
![size](https://img.shields.io/badge/DMG-1.6%20MB-blue)

</div>

---

<a name="english"></a>

## Why this exists

Disk cleaners ask for a lot of trust: they walk your whole home folder, then offer to delete things.
Most of them are closed-source, ship a background daemon, and treat `rm -rf` as a feature.

DiskWise takes the opposite bet:

| | DiskWise |
|---|---|
| Delete path | **One** — `FileManager.trashItem`. Everything lands in the Trash. |
| Undo | Yes, per operation, for the whole session. |
| Protected paths | Home itself, `~/Library`, and friends can never be removed wholesale. |
| Emptying the Trash | Handed to **Finder**, so macOS asks you once more. |
| Docker images | Read-only. Virtual disks have no per-image path, so the app points instead of pretending. |
| Network | None. No updater, no analytics, no ads. |
| Runtime | A single `.app`. No Python, no port, no daemon. |

It is built for machines that have been used by a developer for a few years — the ones where
`node_modules`, Docker volumes, Xcode `DerivedData`, and ten GB of caches quietly took over.

## What you get

**See the space**
- **Overview** — a segmented ring gauge of what actually occupies the volume, plus the fattest folders, each with *Reveal* and *Dig in*.
- **Large Files** — top N across any folder, dev directories skippable.
- **Long Untouched** — files in Downloads and Desktop you haven't opened in N days.
- **Duplicates** — size → partial hash → full hash, grouped, oldest copy locked so you can't nuke the only one.

**Dev machine specials**
- **node_modules** — whole-disk sweep grouped per project, so you see "these 3 checkouts cost 4.7 GB".
- **Docker Usage** — read-only breakdown of the Docker Desktop data store, with the pointer on where to prune.

**Clean up**
- **Caches** — a curated knowledge base (Homebrew, npm, yarn, Maven, Gradle, conda, Xcode, simulators, WeChat / DingTalk / WeCom / QQ …). Every entry explains *what it is*, *what happens if you delete it*, and *how to get it back*, with a Safe / Careful badge.
- **Leftovers** — data orphaned by apps you already uninstalled, matched against the bundle IDs of everything still installed. Under-reports rather than over-deletes.
- **Trash** — session stats, undo stack, and an *Empty* button that routes through Finder.

**Personalize**
- **Skins** — 6 themes, and the interesting part is that they are not color swaps: each one changes typeface, corner radius, elevation, motion signature and chart palette. Free: Morning Fog, Graphite, Mint. Premium: Polar Night, Aurora Glass, Ink & Paper. Try-on lets you wear a premium skin before deciding.

## Screenshots

| Overview | Duplicates |
|---|---|
| ![Overview](docs/screenshots/en/01-overview.png) | ![Duplicates](docs/screenshots/en/04-duplicates.png) |

| Caches | Leftovers |
|---|---|
| ![Caches](docs/screenshots/en/07-caches.png) | ![Leftovers](docs/screenshots/en/08-leftovers.png) |

The skin store renders a **live thumbnail** of each theme — mini sidebar, ring gauge, rows and
buttons, all drawn with that skin's real tokens — so you can see the skeleton before you wear it:

![Skins](docs/screenshots/en/10-skins.png)

Six skins, six skeletons. Same page, three of them:

| Graphite (free, dark) | Mint (free) | Polar Night (premium) |
|---|---|---|
| ![graphite](docs/screenshots/skins/graphite.png) | ![mint](docs/screenshots/skins/mint.png) | ![midnight](docs/screenshots/skins/midnight.png) |

The UI is bilingual — English and Simplified Chinese, switchable in-app (Skins → language), and it
follows the system language by default. Same screens in Chinese:

| 空间总览 | 缓存清理 |
|---|---|
| ![总览](docs/screenshots/zh/01-overview.png) | ![缓存](docs/screenshots/zh/07-caches.png) |

## Install

1. Download `DiskWise-<version>.dmg` from [Releases](https://github.com/DreamOfXM/diskwise/releases).
2. Open it and drag **DiskWise.app** to *Applications*.
3. First launch: **right-click → Open → Open**. The build is ad-hoc signed, so Gatekeeper wants a
   human once. (See [Known limits](#known-limits).)

Apple Silicon (arm64) only for now. Checksums are published next to each release asset.

## Build from source

You need the Xcode Command Line Tools — **not** full Xcode.

```bash
swift build                    # debug
swift run SelfTest             # 21 checks; all green is the precondition for shipping
swift run DiskCleaner          # run the app
bash build_app/build.sh        # localize check → build → self-test → .app → sign → dist/*.dmg + SHA256
```

`build.sh` refuses to produce a package if any of the three gates fails: missing translations,
a failing self-test, or an unpacked resource.

Contributing? Start with [CONTRIBUTING.md](CONTRIBUTING.md), then
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) and [docs/DESIGN.md](docs/DESIGN.md) — both encode
rules that were learned the expensive way. The most useful first PR is a
[cache knowledge base](CONTRIBUTING.md#the-easiest-useful-contribution-cache-knowledge-base) entry.

## Known limits

Honest list, because a cleanup tool earns trust by admitting what it can't do:

- **Not signed or notarized by Apple.** First launch needs a right-click. Developer identity is on the roadmap.
- **Apple Silicon only.** Intel images need a CI runner.
- **In-app purchase is a stub.** Premium skins unlock for free today; StoreKit 2 is not wired up.
- **Large `node_modules` sweeps are slow** and don't stream results yet.
- **It will not find every orphan.** Leftover detection is deliberately conservative.

## Roadmap

- [ ] StoreKit 2 for premium skins
- [ ] Developer ID signing + notarization, Intel + arm64
- [ ] Streaming snapshots for slow scans
- [ ] More cache knowledge base entries (open a PR — this is the easiest way to contribute)

## License

Apache License 2.0 — see [LICENSE](LICENSE).

---

<a name="中文"></a>

## DiskWise 是什么

一个**不会真正删除任何东西**的 macOS 磁盘清理工具。所有删除只进废纸篓，本次会话内随时可撤销；
SwiftUI 原生实现，没有 Electron、不依赖 Python、不起本地服务、没有端口、不联网、无遥测。安装包 1.6 MB。

## 它凭什么值得信任

清理工具天然要信任：它扫遍你的家目录，然后劝你删东西。多数同类产品闭源、常驻后台进程、把 `rm -rf` 当卖点。
DiskWise 押的是反面：

| | DiskWise |
|---|---|
| 删除路径 | **全 App 只有一条** —— `FileManager.trashItem`，一律进废纸篓 |
| 撤销 | 支持，按操作、整会话可退 |
| 保护路径 | 家目录本体、`~/Library` 等整体不可删，子项可以 |
| 清空废纸篓 | 交给**访达**执行，系统会再问你一次 |
| Docker 镜像 | 只读。虚拟盘没有独立路径，App 只指路不代删 |
| 联网 | 无。不自动更新、不统计、无广告 |
| 运行形态 | 一个 `.app`，没有 Python、没有端口、没有守护进程 |

它服务的是被开发者用了几年的那类机器——`node_modules`、Docker 虚拟盘、Xcode `DerivedData`、
十几 GB 缓存悄悄把盘吃掉的那种。

## 功能

**看清空间**
- **空间总览**：分段环形仪表 + 最占地方的文件夹，每行「访达显示 / 深挖」
- **大文件**：TOP 可调，可跳过开发目录
- **很久没动**：下载 + 桌面里 N 天没打开的文件
- **重复文件**：大小 → 部分哈希 → 全量哈希，分组展示，每组最早一份锁定保留

**开发机专项**
- **node_modules**：全盘扫描按项目聚合，直接告诉你「这几个仓库共 4.7 GB」
- **Docker 占用**：Docker Desktop 数据目录只读明细 + 清理指路

**清理**
- **缓存清理**：知识库覆盖 Homebrew、npm、yarn、Maven、Gradle、conda、Xcode、模拟器、微信 / 钉钉 / 企业微信 / QQ 等。
  每项都写明「这是什么 / 删了会怎样 / 怎么恢复」，并给安全 / 留意分级
- **卸载残留**：以「还装着的 App 的 bundle id」为基准找孤儿，宁可漏报不误删
- **废纸篓**：体积统计、撤销栈、走访达的清空按钮

**个性化**
- **外观皮肤**：6 套。关键点是它们**不是换色**——每套各自改字体面、圆角、材质分层、动效签名、图表配色。
  免费：晨雾 / 石墨 / 薄荷；付费：极夜黑金 / 极光玻璃 / 水墨宣纸。付费皮肤可以先试穿再决定。

## 界面截图

中英文双语，可在「外观皮肤」页顶部切换，默认跟随系统。

| 空间总览 | 重复文件 |
|---|---|
| ![总览](docs/screenshots/zh/01-overview.png) | ![重复文件](docs/screenshots/zh/04-duplicates.png) |

| 缓存清理 | 卸载残留 |
|---|---|
| ![缓存](docs/screenshots/zh/07-caches.png) | ![残留](docs/screenshots/zh/08-leftovers.png) |

皮肤商店里每张卡都实时渲染该皮肤下的迷你侧边栏 + 环形图 + 列表行 + 按钮，看得懂骨架再决定穿不穿：

![外观皮肤](docs/screenshots/zh/10-skins.png)

同一页，三套皮肤三种骨架（默认「晨雾」见上方总览图）：

| 石墨（免费·深色） | 极夜黑金（付费） |
|---|---|
| ![石墨](docs/screenshots/zh/12-overview-graphite.png) | ![黑金](docs/screenshots/zh/11-overview-midnight.png) |

## 下载与安装

1. 到 [Releases](https://github.com/DreamOfXM/diskwise/releases) 下载 `DiskWise-<版本号>.dmg`
2. 打开后把 **DiskWise.app** 拖进「应用程序」
3. 首次打开请**右键 → 打开 → 打开**：当前是 ad-hoc 签名，Gatekeeper 需要人确认一次

目前只出 Apple Silicon（arm64）包。每个 Release 都会附 DMG 的 SHA256。

## 从源码构建

只需要 Xcode 命令行工具，**不需要完整 Xcode**。

```bash
swift build                    # debug 编译
swift run SelfTest             # 21 项自检，全绿是打包前提
swift run DiskCleaner          # 直跑 App
bash build_app/build.sh        # 双语对账 → 编译 → 自检 → .app → 签名 → dist/*.dmg + SHA256
```

三道闸门任一失败就不出包：缺译文、自检不过、资源没拷进去。

想提 PR 请先读 [CONTRIBUTING.md](CONTRIBUTING.md)、[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
和 [docs/DESIGN.md](docs/DESIGN.md)——里面每条规则都是踩过坑定下来的。
最受欢迎的第一个 PR 是往[缓存知识库](CONTRIBUTING.md#the-easiest-useful-contribution-cache-knowledge-base)里加一条真实条目。

## 已知不足

- **未经 Apple 签名与公证**，首次打开要右键确认
- **只有 Apple Silicon 包**，Intel 需要 CI runner
- **内购是桩**：现在点「解锁」直接放行，StoreKit 2 尚未接入
- **node_modules 大盘扫描慢**，且还没有流式快照
- **卸载残留刻意保守**，会漏报

## 路线图

- [ ] 接入 StoreKit 2（付费皮肤）
- [ ] Developer ID 签名 + 公证，出 Intel + arm64 通用包
- [ ] 慢扫描的流式快照
- [ ] 扩充缓存知识库（提 PR 最受欢迎的方式）

## 许可

Apache License 2.0，见 [LICENSE](LICENSE)。
