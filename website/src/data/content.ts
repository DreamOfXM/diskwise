// 多语言内容层：四个语言的全部文案集中在此维护。
// zh 为源语言（对照 site.ts 中的链接常量）；en/ja/ko 与 README 的四语保持同源口径。
// 新增语言：复制一份 zh 对象翻译，再在 LOCALES / routes / HTML 入口三处注册。
import demoGifEn from "@/assets/demo-overview-en.gif";
import demoGifZh from "@/assets/demo-overview-zh.gif";

export type Locale = "zh" | "en" | "ja" | "ko";

export const LOCALES: { code: Locale; label: string; short: string; path: string }[] = [
  { code: "zh", label: "简体中文", short: "中", path: "" },
  { code: "en", label: "English", short: "EN", path: "en" },
  { code: "ja", label: "日本語", short: "日", path: "ja" },
  { code: "ko", label: "한국어", short: "한", path: "ko" },
];

export interface SiteContent {
  htmlLang: string;
  demoGif: string;
  nav: { href: string; label: string }[];
  navStar: string;
  hero: {
    badge: string;
    title: string;
    subtitle: string;
    tagline: string;
    promise: string;
    brewTitle: string;
    dmgBtn: string;
    starBtn: string;
    watchLink: string;
    stats: { num: string; label: string }[];
    figcaption: string;
    fallbackTitle: string;
    fallbackNote: string;
  };
  why: { eyebrow: string; title: string };
  differentiators: { icon: string; title: string; desc: string }[];
  market: {
    eyebrow: string;
    title: string;
    claimLabel: string;
    headers: string[];
    rows: { name: string; kind: string; stars: string; price: string; strengths: string; weaknesses: string; ours?: boolean }[];
  };
  positioning: { claim: string; logic: [string, string][] };
  features: { eyebrow: string; title: string; intro: string; items: { title: string; desc: string }[] };
  install: { eyebrow: string; title: string; sub: string; channels: { name: string; desc: string; action: string }[]; note: string };
  cta: {
    eyebrow: string;
    title: string;
    body: string;
    starBtn: string;
    issueBtn: string;
    feedbackLead: string;
    copyEmail: string;
    copied: string;
    emailNote: string;
  };
  faq: { eyebrow: string; title: string; items: { q: string; a: string }[] };
  footer: {
    desc: string;
    meta: string;
    getLabel: string;
    links: { label: string }[];
    copyright: string;
    langLabel: string;
  };
}

const zh: SiteContent = {
  htmlLang: "zh-CN",
  demoGif: demoGifZh,
  nav: [
    { href: "#why", label: "为什么" },
    { href: "#market", label: "竞品" },
    { href: "#features", label: "功能" },
    { href: "#install", label: "安装" },
    { href: "#faq", label: "FAQ" },
  ],
  navStar: "Star",
  hero: {
    badge: "Free · Open Source · Apache-2.0",
    title: "DiskWise",
    subtitle: "免费开源的 Mac 磁盘清理工具",
    tagline: "原生 SwiftUI 磁盘清理器，专为被 node_modules、Xcode DerivedData、Docker 镜像和微信缓存吃掉硬盘的 Mac 而做。",
    promise: "任何文件都不会被真正删除 —— 全部进废纸篓，全程可撤销。",
    brewTitle: "点击复制安装命令",
    dmgBtn: "下载 DMG（~5MB）",
    starBtn: "GitHub Star",
    watchLink: "在 YouTube 上看 43 秒演示片",
    stats: [
      { num: "0", label: "遥测 / 后台守护进程" },
      { num: "~5MB", label: "DMG 体积，单文件通吃 Apple Silicon + Intel" },
      { num: "10", label: "种界面语言开箱即用" },
      { num: "100%", label: "功能全解锁，无订阅无内购" },
    ],
    figcaption: "Overview：每一段弧都是本次实测到的字节，两下点击即进废纸篓",
    fallbackTitle: "观看 Overview 环形扫描演示",
    fallbackNote: "当前网络无法加载演示动图，点击在仓库内查看 overview.gif",
  },
  why: { eyebrow: "Why DiskWise", title: "四个别的清理工具做不到的事" },
  differentiators: [
    {
      icon: "trash",
      title: "只进废纸篓，绝不 rm -rf",
      desc: "唯一删除路径是 FileManager.trashItem。清空废纸篓永远是 Finder 的决定，整个会话逐条可撤销。",
    },
    {
      icon: "code",
      title: "为开发者的机器而生",
      desc: "node_modules、DerivedData、Docker 用量、构建产物——这些「系统数据」里最大的元凶，普通清理工具根本不敢碰。",
    },
    {
      icon: "eye",
      title: "每一条缓存都讲得清",
      desc: "扫描结果带解释：这是什么、删了会怎样、多久长回来。微信、钉钉、企业微信单独覆盖——很多机器上这三个就占几十 GB。",
    },
    {
      icon: "shield",
      title: "零网络、零守护、零索取",
      desc: "没有 updater、没有 analytics、没有广告、没有后台守护。一个 .app 就是全部，代码 Apache-2.0 公开可审。",
    },
  ],
  market: {
    eyebrow: "竞品调研 · 2026-10",
    title: "市场上已有谁，空位在哪",
    claimLabel: "定位主张：",
    headers: ["工具", "形态", "热度", "价格", "强项", "弱点"],
    rows: [
      {
        name: "CleanMyMac", kind: "商业 GUI（MacPaw）", stars: "—",
        price: "订阅制 ~$40/年，另有更贵的一次性买断",
        strengths: "品牌认知度最高，功能大而全，恶意软件防护，媒体营销成熟",
        weaknesses: "贵且转订阅制；闭源不可审计；越来越多测评认为它「不如系统自带」",
      },
      {
        name: "Mole CLI (tw93)", kind: "开源 CLI", stars: "60k+",
        price: "CLI 免费开源；GUI 版一次性付费",
        strengths: "开发者圈口碑爆棚，一条病毒推文带火出圈；一条命令清出几十 GB",
        weaknesses: "纯命令行，对非终端用户有门槛；GUI 版闭源收费",
      },
      {
        name: "DaisyDisk", kind: "商业 GUI", stars: "—", price: "一次性 ~$10",
        strengths: "环形空间地图是行业标杆，交互优雅",
        weaknesses: "只做「看」不做「清」，没有缓存语义与应用残留管理",
      },
      {
        name: "OnyX", kind: "免费工具", stars: "—", price: "免费",
        strengths: "老牌深度维护，安全口碑好",
        weaknesses: "必须匹配 macOS 版本的专属发行，操作复杂，面向故障排查而非日常清理",
      },
      {
        name: "mac-cleaner-cli 等开源 CLI", kind: "开源 CLI", stars: "数百~数千", price: "免费",
        strengths: "透明、轻量",
        weaknesses: "删除即永久删除，误删风险高；无图形反馈，普通用户无法建立信任",
      },
      {
        name: "DiskWise（本项目）", kind: "开源 GUI（SwiftUI 原生）", stars: "新项目", price: "完全免费，全功能解锁",
        strengths: "DaisyDisk 式环形图 + Mole 式深度清理 + 「全进废纸篓可撤销」的安全模型，三者合一且开源",
        weaknesses: "—", ours: true,
      },
    ],
  },
  positioning: {
    claim: "DaisyDisk 的眼 + Mole 的手 + 绝对不删你文件的底线",
    logic: [
      ["市场空位", "CLI 阵营（Mole 60k★）证明了需求真实存在，但把普通用户挡在终端外；GUI 阵营最出名的 CleanMyMac 又贵又闭源。「开源 + 原生 GUI + 安全删除」这个格子至今没人占。"],
      ["一句话差异", "别的工具问你要不要「永久删除」，DiskWise 从架构上就没有永久删除这条代码路径。"],
      ["可信度来源", "Apache-2.0 可审计 + Developer ID 签名并经 Apple 公证（v1.7 起双击即开）+ 每个 release 附 SHA-256 + App Store 上架。"],
      ["为谁而做", "开发者自己装；也想帮爸妈、同事、设计师朋友清出几十 GB 的任何人。微信、钉钉等中文场景的缓存从第一天起就是一等公民。"],
    ],
  },
  features: {
    eyebrow: "What you get",
    title: "一眼看明白，两下清干净",
    intro: "「看清楚」和「敢动手」在同一页完成：找到占空间的元凶、看清里面是什么、确认无误后两下移进废纸篓——中间不用换页面。",
    items: [
      { title: "Overview 环形全景", desc: "整块磁盘画成一枚环：每一段都是本次实测到的字节，分段之和等于整盘。光带停在已测量边缘，扫到哪看到哪。" },
      { title: "账本式明细", desc: "点开任意一行就地展开子目录明细，环退居小表盘作参照，不用在页面间来回跳。" },
      { title: "两下点击进废纸篓", desc: "第一下武装、第二下移入废纸篓，Undo 原样放回。受保护路径（Home、~/Library 等）永远无法被整体移除。" },
      { title: "大文件与陈年文件", desc: "全盘找出最占空间的 Top 文件、以及 N 天没动过的大文件，开发目录可一键跳过。" },
      { title: "重复文件查重", desc: "大小 → 部分哈希 → 全量哈希三段式分组，每组最新一份自动上锁，你删不掉唯一那份；venv、DerivedData 里的孪生文件单独列示、不进比对。" },
      { title: "卸载残留清扫", desc: "对照本机全部已装 App 的 bundle ID 找孤儿数据，原则是宁可漏报、绝不过删。" },
      { title: "界面随你定制", desc: "六套主题皮肤换字体、圆角与动效，十种界面语言开箱即用，全部免费、无内购解锁。" },
    ],
  },
  install: {
    eyebrow: "Install",
    title: "三种装法，全都不花钱",
    sub: "macOS 13+ · Apple Silicon 与 Intel 共用一个 ~5MB 的通用 DMG",
    channels: [
      { name: "Homebrew", desc: "一行命令装好，后续 brew upgrade --cask 更新。", action: "brew install --cask dreamofxm/diskwise/diskwise" },
      { name: "GitHub Release", desc: "Developer ID 签名 + Apple 公证，下载后双击即开；每个 release 附 SHA-256 校验值。", action: "下载最新 DMG" },
      { name: "Mac App Store", desc: "经 App Store 审核上架，更新由商店自动推送，完全免费。", action: "在 App Store 获取" },
    ],
    note: "App Store 的每一版都要先过苹果审核，所以商店里的版本可能比 GitHub Release 慢一些。只想要最新那一版，用上面的 Homebrew 或直接下载 DMG。",
  },
  cta: {
    eyebrow: "Star & Feedback",
    title: "觉得有帮助？留一颗星",
    body: "DiskWise 是一个独立维护的开源项目。如果它帮你清出了几十 GB，欢迎去 GitHub 点一颗星——星越多，下一个被「磁盘空间不足」卡住的人就越容易找到它。",
    starBtn: "去 GitHub 留一颗星",
    issueBtn: "提一个 Issue",
    feedbackLead: "也希望听到你的意见——用得顺不顺手、缺什么功能、哪里可以更好，每一条我都会认真读，持续改进：",
    copyEmail: "复制邮箱",
    copied: "已复制",
    emailNote: "中英文来信都可以，也欢迎直接在 Issue 里聊。",
  },
  faq: {
    eyebrow: "FAQ",
    title: "常见疑问",
    items: [
      { q: "和 CleanMyMac 比到底差在哪？", a: "价格（0 vs 订阅制）、透明度（Apache-2.0 全开源 vs 闭源）、删除模型（一切进废纸篓可撤销 vs 直接删除）。它多了恶意软件查杀等模块，DiskWise 刻意只做磁盘这一件事做到底。" },
      { q: "会不会误删我的文件？", a: "架构上不存在永久删除路径：唯一删除动作是 FileManager.trashItem，清空废纸篓只能由你在 Finder 完成。Home、~/Library 等受保护路径无法被整体移除。" },
      { q: "为什么 Docker 镜像不能直接清？", a: "Docker 虚拟盘里没有按镜像拆分的文件路径，任何声称能逐个删的工具都在装懂。DiskWise 只读展示用量并指向 docker 官方清理命令。" },
      { q: "支持哪些机器？", a: "macOS 13+，Apple Silicon 与 Intel 共用一个 ~5MB 的 DMG；也可 brew cask 或 Mac App Store 安装。" },
      { q: "免费是真免费吗？", a: "是。所有功能与六套皮肤在本 build 全部解锁，无 telemetry、无广告、无订阅。App Store 版同样免费。" },
    ],
  },
  footer: {
    desc: "免费开源的 macOS 磁盘清理器。原生 SwiftUI，一切进废纸篓、全程可撤销，零遥测、零订阅、零守护进程。",
    meta: "Apache-2.0 · macOS 13+ · 10 languages",
    getLabel: "获取",
    links: [
      { label: "GitHub Release（附 SHA-256）" },
      { label: "Mac App Store" },
      { label: "源码 / Issue / PR" },
      { label: "简体中文 README" },
    ],
    copyright: "© 2026 DreamOfXM · DiskWise 为独立开源项目，与 MacPaw CleanMyMac、tw93 Mole 无隶属关系",
    langLabel: "语言",
  },
};

const en: SiteContent = {
  htmlLang: "en",
  demoGif: demoGifEn,
  nav: [
    { href: "#why", label: "Why" },
    { href: "#market", label: "Compare" },
    { href: "#features", label: "Features" },
    { href: "#install", label: "Install" },
    { href: "#faq", label: "FAQ" },
  ],
  navStar: "Star",
  hero: {
    badge: "Free · Open Source · Apache-2.0",
    title: "DiskWise",
    subtitle: "A free, open-source disk cleaner for Mac",
    tagline: "A native SwiftUI cleaner, built for Macs eaten alive by node_modules, Xcode DerivedData, Docker volumes and WeChat caches.",
    promise: "Nothing is ever truly deleted — everything goes to the Trash, undoable the whole way.",
    brewTitle: "Click to copy the install command",
    dmgBtn: "Download DMG (~5MB)",
    starBtn: "GitHub Star",
    watchLink: "Watch the 43-second film on YouTube",
    stats: [
      { num: "0", label: "telemetry / background daemons" },
      { num: "~5MB", label: "DMG — one file for Apple Silicon + Intel" },
      { num: "10", label: "UI languages out of the box" },
      { num: "100%", label: "unlocked — no subscription, no IAP" },
    ],
    figcaption: "Overview: every arc is bytes actually measured on this pass; two clicks send it to the Trash",
    fallbackTitle: "Watch the Overview ring scan demo",
    fallbackNote: "The demo GIF failed to load — click to view it in the repository",
  },
  why: { eyebrow: "Why DiskWise", title: "Four things other cleaners won't do" },
  differentiators: [
    {
      icon: "trash",
      title: "Trash only, never rm -rf",
      desc: "The only delete path in the code is FileManager.trashItem. Emptying the Trash stays Finder's call, and every removal this session can be undone, one by one.",
    },
    {
      icon: "code",
      title: "Built for developer Macs",
      desc: "node_modules, DerivedData, Docker usage, build artifacts — the biggest culprits hiding inside \"System Data\", which ordinary cleaners won't touch.",
    },
    {
      icon: "eye",
      title: "Every cache explained",
      desc: "Scan results come with an explanation: what it is, what happens if you delete it, how it comes back. WeChat, DingTalk and WeCom get dedicated coverage — on many machines those three alone hold tens of GB.",
    },
    {
      icon: "shield",
      title: "Zero network, zero daemon, zero ask",
      desc: "No updater, no analytics, no ads, no background agent. One .app is all there is — and the code is Apache-2.0, open to audit.",
    },
  ],
  market: {
    eyebrow: "Competitive landscape · 2026-10",
    title: "Who's out there, and where the gap is",
    claimLabel: "Positioning:",
    headers: ["Tool", "Form", "Traction", "Price", "Strengths", "Weaknesses"],
    rows: [
      {
        name: "CleanMyMac", kind: "Commercial GUI (MacPaw)", stars: "—",
        price: "Subscription ~$40/yr, pricier one-time buy",
        strengths: "Best brand recognition, broad feature set, malware protection, mature marketing",
        weaknesses: "Expensive and subscription-first; closed source; a growing chorus of reviews says you don't need it",
      },
      {
        name: "Mole CLI (tw93)", kind: "Open-source CLI", stars: "60k+",
        price: "CLI free and open; GUI is a paid one-time app",
        strengths: "Beloved by developers, went viral off a single tweet; one command frees tens of GB",
        weaknesses: "Command-line only — a barrier for non-terminal users; the GUI is closed-source and paid",
      },
      {
        name: "DaisyDisk", kind: "Commercial GUI", stars: "—", price: "One-time ~$10",
        strengths: "The industry benchmark for sunburst space maps, elegant interactions",
        weaknesses: "Shows but never cleans — no cache semantics, no app-leftover management",
      },
      {
        name: "OnyX", kind: "Free utility", stars: "—", price: "Free",
        strengths: "Veteran deep-maintenance tool with a strong safety reputation",
        weaknesses: "Requires a build matched to your exact macOS version; complex; built for troubleshooting, not daily cleaning",
      },
      {
        name: "mac-cleaner-cli & other OSS CLIs", kind: "Open-source CLI", stars: "hundreds–thousands", price: "Free",
        strengths: "Transparent, lightweight",
        weaknesses: "Deletion is permanent — one mistake and it's gone; no visual feedback, hard for regular users to trust",
      },
      {
        name: "DiskWise (this project)", kind: "Open-source GUI (native SwiftUI)", stars: "New", price: "Completely free, fully unlocked",
        strengths: "A DaisyDisk-style ring + Mole-style deep cleaning + the \"everything to the Trash, always undoable\" safety model — all three in one open-source app",
        weaknesses: "—", ours: true,
      },
    ],
  },
  positioning: {
    claim: "DaisyDisk's eyes + Mole's hands + a hard line against ever deleting your files",
    logic: [
      ["The market gap", "The CLI camp (Mole at 60k★) proves the demand is real but locks non-terminal users out; the most famous GUI, CleanMyMac, is pricey and closed. The \"open-source + native GUI + safe deletion\" cell is still empty."],
      ["The one-line difference", "Other tools ask whether to \"permanently delete\". DiskWise has no permanent-delete code path at all."],
      ["Why trust it", "Apache-2.0 auditable code + Developer ID signed and Apple-notarized since v1.7 (opens on a double-click) + SHA-256 with every release + on the Mac App Store."],
      ["Who it's for", "Developers installing it themselves — and anyone who'd like to free tens of GB for parents, colleagues or designer friends. Chinese-app caches (WeChat, DingTalk) are first-class citizens from day one."],
    ],
  },
  features: {
    eyebrow: "What you get",
    title: "See it clearly, clean it in two clicks",
    intro: "\"Seeing clearly\" and \"daring to act\" happen on the same page: find the space hogs, see what's inside, move them to the Trash in two clicks — no page-hopping in between.",
    items: [
      { title: "The Overview ring", desc: "The whole volume drawn as one ring: every segment is bytes actually measured on this pass, and the segments sum to the whole disk. The light band sits on the measured edge — you see exactly as far as it has scanned." },
      { title: "Ledger detail", desc: "Click any row and its subfolders unfold right there, the ring stepping back to a small reference dial. No jumping between pages." },
      { title: "Two clicks to the Trash", desc: "The first click arms, the second moves to the Trash; Undo puts it back. Protected paths (Home, ~/Library) can never be removed wholesale." },
      { title: "Large & old files", desc: "Top space hogs across the same roots, plus big files untouched for N days; dev directories skippable in one click." },
      { title: "Duplicate finder", desc: "Size → partial hash → full hash, grouped; the newest copy in each group is locked so you can't nuke the only one. Twins inside venv / DerivedData are listed separately and never compared." },
      { title: "Uninstall leftovers", desc: "Orphaned data matched against the bundle IDs of everything still installed. Under-reports rather than over-deletes." },
      { title: "Make it yours", desc: "Six theme skins changing typeface, radius and motion, ten UI languages — all free, no IAP unlocks." },
    ],
  },
  install: {
    eyebrow: "Install",
    title: "Three ways to install, all free",
    sub: "macOS 13+ · one ~5MB universal DMG for Apple Silicon and Intel",
    channels: [
      { name: "Homebrew", desc: "One command, then brew upgrade --cask keeps it fresh.", action: "brew install --cask dreamofxm/diskwise/diskwise" },
      { name: "GitHub Release", desc: "Developer ID signed and Apple-notarized — it opens on a double-click. Every release ships its SHA-256.", action: "Download the latest DMG" },
      { name: "Mac App Store", desc: "Apple-reviewed, auto-updating from the store, completely free.", action: "Get it on the Mac App Store" },
    ],
    note: "Every App Store release has to clear Apple's review first, so the store build can sit behind GitHub Releases for a while. For the newest version, use Homebrew or the DMG above.",
  },
  cta: {
    eyebrow: "Star & Feedback",
    title: "Found it helpful? Leave a star",
    body: "DiskWise is an independently maintained open-source project. If it freed tens of GB for you, consider leaving a star on GitHub — the more stars it has, the easier the next person crushed by \"Your disk is almost full\" can find it.",
    starBtn: "Star it on GitHub",
    issueBtn: "Open an Issue",
    feedbackLead: "I'd love to hear from you — what works, what doesn't, what's missing. Every message gets read, and the app keeps improving:",
    copyEmail: "Copy email",
    copied: "Copied",
    emailNote: "English, Chinese, Japanese or Korean are all fine — or just open an issue.",
  },
  faq: {
    eyebrow: "FAQ",
    title: "Common questions",
    items: [
      { q: "How does it really compare to CleanMyMac?", a: "Price (zero vs subscription), transparency (fully open Apache-2.0 vs closed source), and the deletion model (everything to the Trash, undoable vs direct deletion). CleanMyMac adds extras like malware scanning; DiskWise deliberately does one thing — the disk — and does it to the end." },
      { q: "Could it delete something I actually need?", a: "There is no permanent-delete path in the architecture: the only delete action is FileManager.trashItem, and only you can empty the Trash, in Finder. Home, ~/Library and other protected paths can't be removed wholesale." },
      { q: "Why can't Docker images be cleaned directly?", a: "Docker virtual disks expose no per-image file paths — any tool claiming to delete them one by one is pretending. DiskWise shows the usage read-only and points you to Docker's own prune commands." },
      { q: "Which machines are supported?", a: "macOS 13+, with one ~5MB universal DMG covering Apple Silicon and Intel; also installable via brew cask or the Mac App Store." },
      { q: "Is free actually free?", a: "Yes. Every feature and all six skins ship unlocked — no telemetry, no ads, no subscription. The App Store version is free too." },
    ],
  },
  footer: {
    desc: "A free, open-source disk cleaner for macOS. Native SwiftUI; everything goes to the Trash and stays undoable — zero telemetry, zero subscription, zero daemons.",
    meta: "Apache-2.0 · macOS 13+ · 10 languages",
    getLabel: "Get it",
    links: [
      { label: "GitHub Release (with SHA-256)" },
      { label: "Mac App Store" },
      { label: "Source · Issues · PRs" },
      { label: "README (English)" },
    ],
    copyright: "© 2026 DreamOfXM · DiskWise is an independent open-source project, not affiliated with MacPaw CleanMyMac or tw93's Mole",
    langLabel: "Language",
  },
};

const ja: SiteContent = {
  htmlLang: "ja",
  demoGif: demoGifEn,
  nav: [
    { href: "#why", label: "選ばれる理由" },
    { href: "#market", label: "競合比較" },
    { href: "#features", label: "機能" },
    { href: "#install", label: "インストール" },
    { href: "#faq", label: "FAQ" },
  ],
  navStar: "Star",
  hero: {
    badge: "Free · Open Source · Apache-2.0",
    title: "DiskWise",
    subtitle: "無料・オープンソースの Mac ディスククリーンツール",
    tagline: "node_modules、Xcode DerivedData、Docker ボリューム、WeChat のキャッシュにディスクを食い尽くされた Mac のために作られた、ネイティブ SwiftUI のクリーナー。",
    promise: "ファイルは一切本当に削除されません —— すべてゴミ箱へ、いつでも取り消せます。",
    brewTitle: "クリックでインストールコマンドをコピー",
    dmgBtn: "DMG をダウンロード（~5MB）",
    starBtn: "GitHub Star",
    watchLink: "YouTube で 43 秒の映像を見る",
    stats: [
      { num: "0", label: "テレメトリ / 常駐プロセス" },
      { num: "~5MB", label: "DMG 1 つで Apple Silicon + Intel 両対応" },
      { num: "10", label: "言語の UI を同梱" },
      { num: "100%", label: "全機能解放・サブスクなし・課金なし" },
    ],
    figcaption: "Overview：弧のひとつひとつが今回実際に計測されたバイト数。クリック 2 回でゴミ箱へ",
    fallbackTitle: "Overview リングスキャンのデモを見る",
    fallbackNote: "デモ GIF の読み込みに失敗しました —— リポジトリ内でご覧いただけます",
  },
  why: { eyebrow: "Why DiskWise", title: "他のクリーンツールがやらない 4 つのこと" },
  differentiators: [
    {
      icon: "trash",
      title: "ゴミ箱のみ、絶対に rm -rf しない",
      desc: "削除の経路は FileManager.trashItem 一本だけ。ゴミ箱を空にするのは常に Finder —— あなたの決断です。セッション中の操作はすべて取り消せます。",
    },
    {
      icon: "code",
      title: "開発者の Mac のために",
      desc: "node_modules、DerivedData、Docker の使用量、ビルド産物 —— 「システムデータ」の中で最も場所を食う張本人たち。普通のクリーンツールは手を出しません。",
    },
    {
      icon: "eye",
      title: "すべてのキャッシュに説明が付く",
      desc: "スキャン結果には「これは何か・消すとどうなるか・どう戻ってくるか」の説明が付きます。WeChat・DingTalk・WeCom は個別にカバー —— この 3 つだけで数十 GB を占めるマシンも珍しくありません。",
    },
    {
      icon: "shield",
      title: "ネットワークゼロ・常駐ゼロ・要求ゼロ",
      desc: "アップデータも analytics も広告もバックグラウンドエージェントもありません。.app 1 つがすべて。コードは Apache-2.0 で誰でも監査できます。",
    },
  ],
  market: {
    eyebrow: "競合調査 · 2026-10",
    title: "誰がいて、どこが空いているか",
    claimLabel: "ポジション：",
    headers: ["ツール", "形態", "人気", "価格", "強み", "弱み"],
    rows: [
      {
        name: "CleanMyMac", kind: "商用 GUI（MacPaw）", stars: "—",
        price: "サブスク ~$40/年、より高い買い切りもあり",
        strengths: "ブランド認知度最高、機能が広く揃う、マルウェア防御、マーケティングは成熟",
        weaknesses: "高額でサブスク主体；クローズドソース；「入れなくてもいい」というレビューが増加中",
      },
      {
        name: "Mole CLI (tw93)", kind: "オープンソース CLI", stars: "60k+",
        price: "CLI は無料公開；GUI 版は買い切り有料",
        strengths: "開発者に絶大な支持、1 本のツイートでバズ化；コマンド 1 本で数十 GB 解放",
        weaknesses: "CUI のみで一般人にハードル；GUI 版はクローズド＆有料",
      },
      {
        name: "DaisyDisk", kind: "商用 GUI", stars: "—", price: "買い切り ~$10",
        strengths: "サンバースト型の空間マップは業界標準、洗練されたインタラクション",
        weaknesses: "「見る」だけで「掃除」はしない —— キャッシュ解説もアンインストール残渣管理もない",
      },
      {
        name: "OnyX", kind: "無料ユーティリティ", stars: "—", price: "無料",
        strengths: "ベテラン級のメンテナンスツール、安全性の評判は確実",
        weaknesses: "macOS バージョンごとの専用ビルドが必要、操作は複雑、トラブルシュート向けで、日常のお掃除向けではない",
      },
      {
        name: "mac-cleaner-cli など OSS CLI", kind: "オープンソース CLI", stars: "数百〜数千", price: "無料",
        strengths: "透明・軽量",
        weaknesses: "削除したら即永久消失、誤削除リスク大；視覚的フィードバックがなく一般ユーザーは信用しづらい",
      },
      {
        name: "DiskWise（本プロジェクト）", kind: "オープンソース GUI（ネイティブ SwiftUI）", stars: "新着", price: "完全無料・全機能解放",
        strengths: "DaisyDisk 式リング + Mole 式ディープクリーニング + 「すべてゴミ箱・いつでも取り消し可能」の安全モデル、3 つを 1 つのオープンソースアプリに",
        weaknesses: "—", ours: true,
      },
    ],
  },
  positioning: {
    claim: "DaisyDisk の目 + Mole の手 + ファイルを絶対に消さないという一線",
    logic: [
      ["市場の空白", "CLI 陣営（Mole 60k★）は需要の実在を証明しましたが、端末を持たない人を締め出しています。GUI で最も有名な CleanMyMac は高額でクローズド。「オープンソース + ネイティブ GUI + 安全な削除」のマスはまだ空いたままです。"],
      ["ひとことで言うと", "他のツールは「完全に削除しますか？」と聞いてきます。DiskWise には永久削除というコードパス自体が存在しません。"],
      ["信頼の根拠", "Apache-2.0 で監査可能 + v1.7 から Developer ID 署名・Apple 公証済み（ダブルクリックで起動）+ リリースごとの SHA-256 + App Store で配信。"],
      ["誰のためか", "開発者自身はもちろん、両親や同僚、デザイナーの友達のために数十 GB を解放したい人まで。WeChat など中国発アプリのキャッシュは初日から第一級市民です。"],
    ],
  },
  features: {
    eyebrow: "What you get",
    title: "ひと目でわかり、2 クリックで綺麗に",
    intro: "「見る」と「動かす」が同じページで完結：容量を食う犯人を見つけ、中身を確かめ、問題なければ 2 クリックでゴミ箱へ —— ページを行き来する必要はありません。",
    items: [
      { title: "Overview リング", desc: "ボリューム全体を 1 つのリングに。各セグメントは今回のパスで実際に計測されたバイト数で、合計はディスク全体と一致します。光る帯は計測済みの縁に止まり、スキャンした分だけ見えます。" },
      { title: "台帳式リスト", desc: "行をクリックすればサブフォルダがその場で展開し、リングは小さな参照ダイヤルへ退きます。ページ間を行き来しません。" },
      { title: "2 クリックでゴミ箱へ", desc: "1 回目で武装、2 回目でゴミ箱へ移動。Undo で元の場所に戻ります。保護パス（Home、~/Library など）はまとめて削除できません。" },
      { title: "大きいファイル & 放置ファイル", desc: "同じルート群から容量上位と N 日触っていない大ファイルを抽出。開発ディレクトリはワンクリックでスキップできます。" },
      { title: "重複ファイル検出", desc: "サイズ → 部分ハッシュ → 全量ハッシュの 3 段階でグループ化。各グループの最新コピーは自動ロックされ、唯一の 1 枚は削除できません。venv / DerivedData 内の複製は別掲載で比較対象外。" },
      { title: "アンインストール残渣", desc: "インストール済み全アプリの bundle ID と照合して孤児データを検出。方針は「過剰に削らない」—— 見逃しはあっても濫削はありません。" },
      { title: "自分好みに", desc: "書体・角丸・動きまで変わる 6 つのスキンと、10 言語の UI。すべて無料、課金ロックなし。" },
    ],
  },
  install: {
    eyebrow: "Install",
    title: "インストール方法は 3 つ、すべて無料",
    sub: "macOS 13+ · Apple Silicon と Intel が共通の ~5MB ユニバーサル DMG",
    channels: [
      { name: "Homebrew", desc: "コマンド 1 本で導入、以降は brew upgrade --cask で更新。", action: "brew install --cask dreamofxm/diskwise/diskwise" },
      { name: "GitHub Release", desc: "Developer ID 署名 + Apple 公証済み、ダブルクリックで起動。各リリースに SHA-256 を同梱。", action: "最新 DMG をダウンロード" },
      { name: "Mac App Store", desc: "Apple 審査を経て配信、自動更新、ストア内は完全無料。", action: "App Store で入手" },
    ],
    note: "App Store 版はリリースごとに Apple の審査が必要なため、ストア版は GitHub Release より少し遅れて届きます。いちばん新しい版が必要なら Homebrew か DMG を使ってください。",
  },
  cta: {
    eyebrow: "Star & Feedback",
    title: "役に立ったら、スターを",
    body: "DiskWise は個人が保守するオープンソースプロジェクトです。数十 GB を解放できたなら、GitHub にスターをお願いします —— スターが増えるほど、「ディスクの空き容量がありません」に困っている次の人が見つけやすくなります。",
    starBtn: "GitHub でスターを付ける",
    issueBtn: "Issue を立てる",
    feedbackLead: "ご意見もお待ちしています —— 使い勝手、足りない機能、改善点。すべて目を通し、改善を続けます：",
    copyEmail: "メールアドレスをコピー",
    copied: "コピーしました",
    emailNote: "日本語・英語・中国語・韓国語のどれでも構いません。Issue でも歓迎です。",
  },
  faq: {
    eyebrow: "FAQ",
    title: "よくある質問",
    items: [
      { q: "CleanMyMac と比べてどこが違う？", a: "価格（0 円 vs サブスク）、透明性（Apache-2.0 全公開 vs クローズド）、削除モデル（すべてゴミ箱・取り消し可能 vs 直接削除）。CleanMyMac にはマルウェアスキャン等の追加モジュールがありますが、DiskWise は意図的にディスクということだけを極めています。" },
      { q: "必要なファイルを誤削除しない？", a: "アーキテクチャ上、永久削除の経路が存在しません。削除アクションは FileManager.trashItem のみで、ゴミ箱を空にできるのは Finder のあなただけ。Home や ~/Library などの保護パスはまとめて削除できません。" },
      { q: "Docker イメージは直接削除できないの？", a: "Docker の仮想ディスクにはイメージごとのファイルパスがなく、個別削除を謳うツールはすべて「見せかけ」です。DiskWise は使用量を読み取り専用で示し、Docker 公式の prune コマンドへ案内します。" },
      { q: "どのマシンに対応？", a: "macOS 13+。Apple Silicon と Intel が共通の ~5MB ユニバーサル DMG で、brew cask や Mac App Store からも導入できます。" },
      { q: "無料は本当に無料？", a: "はい。全機能と 6 つのスキンが最初から解放済み。テレメトリ・広告・サブスクなし。App Store 版も無料です。" },
    ],
  },
  footer: {
    desc: "無料・オープンソースの macOS ディスククリーナー。ネイティブ SwiftUI、すべてゴミ箱へ・いつでも取り消し可能、テレメトリゼロ・サブスクゼロ・常駐ゼロ。",
    meta: "Apache-2.0 · macOS 13+ · 10 languages",
    getLabel: "入手",
    links: [
      { label: "GitHub Release（SHA-256 付き）" },
      { label: "Mac App Store" },
      { label: "ソース · Issue · PR" },
      { label: "日本語 README" },
    ],
    copyright: "© 2026 DreamOfXM · DiskWise は独立したオープンソースプロジェクトで、MacPaw CleanMyMac および tw93 の Mole とは関係ありません",
    langLabel: "言語",
  },
};

const ko: SiteContent = {
  htmlLang: "ko",
  demoGif: demoGifEn,
  nav: [
    { href: "#why", label: "왜 DiskWise" },
    { href: "#market", label: "경쟁 비교" },
    { href: "#features", label: "기능" },
    { href: "#install", label: "설치" },
    { href: "#faq", label: "FAQ" },
  ],
  navStar: "Star",
  hero: {
    badge: "Free · Open Source · Apache-2.0",
    title: "DiskWise",
    subtitle: "무료 오픈소스 Mac 디스크 정리 도구",
    tagline: "node_modules, Xcode DerivedData, Docker 볼륨, WeChat 캐시에 디스크를 잠식당한 Mac을 위한 네이티브 SwiftUI 클리너입니다.",
    promise: "어떤 파일도 실제로 삭제되지 않습니다 — 모두 휴지통으로 보내고, 언제든 되돌릴 수 있습니다.",
    brewTitle: "클릭하면 설치 명령이 복사됩니다",
    dmgBtn: "DMG 다운로드 (~5MB)",
    starBtn: "GitHub Star",
    watchLink: "YouTube에서 43초 영상 보기",
    stats: [
      { num: "0", label: "텔레메트리 / 백그라운드 데몬" },
      { num: "~5MB", label: "DMG 하나로 Apple Silicon + Intel 동시 지원" },
      { num: "10", label: "가지 UI 언어 즉시 사용 가능" },
      { num: "100%", label: "모든 기능 개방 — 구독·인앱결제 없음" },
    ],
    figcaption: "Overview: 모든 호는 이번에 실제 측정된 바이트이며, 두 번 클릭하면 휴지통으로 갑니다",
    fallbackTitle: "Overview 링 스캔 데모 보기",
    fallbackNote: "데모 GIF를 불러오지 못했습니다 — 저장소에서 직접 보실 수 있습니다",
  },
  why: { eyebrow: "Why DiskWise", title: "다른 클리너가 하지 않는 네 가지" },
  differentiators: [
    {
      icon: "trash",
      title: "휴지통만 사용, 절대 rm -rf 않음",
      desc: "삭제 경로는 FileManager.trashItem 단 하나뿐입니다. 휴지통 비우기는 언제나 Finder의 몫 — 당신의 결정입니다. 세션 중 모든 작업은 항목별로 되돌릴 수 있습니다.",
    },
    {
      icon: "code",
      title: "개발자의 Mac을 위해 설계",
      desc: "node_modules, DerivedData, Docker 사용량, 빌드 산출물 — \"시스템 데이터\" 속 공간을 가장 많이 잡아먹는 주범들입니다. 일반 클리너는 건드리지 않습니다.",
    },
    {
      icon: "eye",
      title: "모든 캐시에 설명이 따릅니다",
      desc: "스캔 결과에는 이게 무엇인지, 지우면 어떻게 되는지, 어떻게 다시 생기는지 설명이 붙습니다. WeChat·DingTalk·WeCom은 별도 커버 — 이 세 개만으로 수십 GB를 차지하는 머신도 흔합니다.",
    },
    {
      icon: "shield",
      title: "네트워크 0, 데몬 0, 요구 0",
      desc: "업데이터도 analytics도 광고도 백그라운드 에이전트도 없습니다. .app 하나가 전부이며, 코드는 Apache-2.0으로 누구나 감사할 수 있습니다.",
    },
  ],
  market: {
    eyebrow: "경쟁 현황 · 2026-10",
    title: "누가 있고, 어디가 비어 있는가",
    claimLabel: "포지셔닝:",
    headers: ["도구", "형태", "인기", "가격", "강점", "약점"],
    rows: [
      {
        name: "CleanMyMac", kind: "상용 GUI (MacPaw)", stars: "—",
        price: "구독 ~$40/년, 더 비싼 일회구매도 있음",
        strengths: "최고의 브랜드 인지도, 포괄적 기능, 멀웨어 방지, 성숙한 마케팅",
        weaknesses: "비싸고 구독 중심; 폐쇄 소스; \"굳이 필요 없다\"는 리뷰가 늘어나는 중",
      },
      {
        name: "Mole CLI (tw93)", kind: "오픈소스 CLI", stars: "60k+",
        price: "CLI 무료 공개; GUI는 유료 일회구매",
        strengths: "개발자들에게 폭발적 호평, 트윗 한 번으로 바이럴; 명령 한 줄로 수십 GB 확보",
        weaknesses: "커맨드라인 전용이라 일반 사용자에게 진입장벽; GUI는 폐쇄 소스·유료",
      },
      {
        name: "DaisyDisk", kind: "상용 GUI", stars: "—", price: "일회구매 ~$10",
        strengths: "선버스트 공간 맵의 업계 표준, 우아한 인터랙션",
        weaknesses: "\"보기\"만 하고 \"청소\"는 안 함 — 캐시 설명도 앱 잔여물 관리도 없음",
      },
      {
        name: "OnyX", kind: "무료 유틸리티", stars: "—", price: "무료",
        strengths: "베테랑급 정비 도구, 안전성 평판 좋음",
        weaknesses: "macOS 버전에 맞는 전용 빌드 필요, 조작 복잡, 문제 해결용이지 일상 정리용 아님",
      },
      {
        name: "mac-cleaner-cli 등 OSS CLI", kind: "오픈소스 CLI", stars: "수백~수천", price: "무료",
        strengths: "투명, 가벼움",
        weaknesses: "삭제 즉시 영구 삭제 — 실수하면 끝; 시각적 피드백 없어 일반 사용자가 신뢰하기 어려움",
      },
      {
        name: "DiskWise (이 프로젝트)", kind: "오픈소스 GUI (네이티브 SwiftUI)", stars: "신규", price: "완전 무료, 전 기능 개방",
        strengths: "DaisyDisk식 링 + Mole식 딥 클리닝 + \"모두 휴지통으로, 항상 되돌리기 가능\" 안전 모델 — 세 가지를 하나의 오픈소스 앱으로",
        weaknesses: "—", ours: true,
      },
    ],
  },
  positioning: {
    claim: "DaisyDisk의 눈 + Mole의 손 + 당신의 파일을 절대 지우지 않는 마지노선",
    logic: [
      ["시장 공백", "CLI 진영(Mole 60k★)은 수요가 실재함을 증명했지만 터미널 없는 사용자를 가로막습니다. 가장 유명한 GUI인 CleanMyMac은 비싸고 폐쇄적입니다. \"오픈소스 + 네이티브 GUI + 안전한 삭제\" 칸은 여전히 비어 있습니다."],
      ["한 줄 차이", "다른 도구는 \"영구 삭제하시겠습니까?\"라고 묻습니다. DiskWise에는 영구 삭제 코드 경로 자체가 없습니다."],
      ["신뢰의 근거", "Apache-2.0 감사 가능 + v1.7부터 Developer ID 서명·Apple 공증(더블클릭으로 바로 실행) + 릴리스마다 SHA-256 제공 + Mac App Store 출시."],
      ["누구를 위한 것", "직접 설치하는 개발자부터, 부모님·동료·디자이너 친구의 수십 GB를 돌려주고 싶은 모두까지. WeChat 등 중국 앱 캐시는 첫날부터 일급 시민입니다."],
    ],
  },
  features: {
    eyebrow: "What you get",
    title: "한눈에 보고, 두 번 클릭해 깨끗하게",
    intro: "\"보는 것\"과 \"실행하는 것\"이 같은 페이지에서 끝납니다: 공간을 잡아먹는 범인을 찾고, 내용을 확인하고, 두 번 클릭으로 휴지통으로 — 중간에 페이지를 오가지 않습니다.",
    items: [
      { title: "Overview 링", desc: "볼륨 전체를 하나의 링으로: 각 조각은 이번 패스에서 실제 측정된 바이트이며, 합계는 디스크 전체와 일치합니다. 빛의 띠는 측정된 경계에 머물러 스캔한 만큼만 보여줍니다." },
      { title: "원장식 상세", desc: "행을 클릭하면 하위 폴더가 그 자리에서 펼쳐지고, 링은 작은 참조 다이얼로 물러납니다. 페이지를 오가지 않습니다." },
      { title: "두 번 클릭으로 휴지통", desc: "첫 클릭으로 무장, 두 번째 클릭으로 휴지통 이동. Undo로 제자리로. 보호 경로(Home, ~/Library 등)는 통째로 지울 수 없습니다." },
      { title: "큰 파일 & 방치된 파일", desc: "같은 루트에서 용량 상위 파일과 N일간 열지 않은 큰 파일을 찾아줍니다. 개발 디렉터리는 한 번에 건너뛸 수 있습니다." },
      { title: "중복 파일 검색", desc: "크기 → 부분 해시 → 전체 해시 3단계 그룹화. 각 그룹의 최신 사본은 자동 잠금되어 유일한 복사본을 지울 수 없습니다. venv / DerivedData 내 중복은 별도 표시되어 비교 대상이 아닙니다." },
      { title: "삭제 앱 잔여물", desc: "설치된 모든 앱의 bundle ID와 대조해 고아 데이터를 찾습니다. 원칙은 \"덜 찾더라도 절대 과잉 삭제 않음\"." },
      { title: "나만의 인터페이스", desc: "서체·모서리·모션이 바뀌는 6가지 스킨과 10가지 UI 언어 — 모두 무료, 인앱결제 잠금 없음." },
    ],
  },
  install: {
    eyebrow: "Install",
    title: "세 가지 설치 방법, 모두 무료",
    sub: "macOS 13+ · Apple Silicon과 Intel이 공유하는 ~5MB 범용 DMG",
    channels: [
      { name: "Homebrew", desc: "명령 한 줄로 설치, 이후 brew upgrade --cask로 업데이트.", action: "brew install --cask dreamofxm/diskwise/diskwise" },
      { name: "GitHub Release", desc: "Developer ID 서명 + Apple 공증 완료, 더블클릭으로 바로 실행됩니다. 모든 릴리스에 SHA-256이 함께 제공됩니다.", action: "최신 DMG 다운로드" },
      { name: "Mac App Store", desc: "Apple 심사를 통과해 출시, 자동 업데이트, 스토어에서 완전 무료.", action: "App Store에서 받기" },
    ],
    note: "App Store 버전은 릴리스마다 Apple 심사를 통과해야 해서, 한동안 GitHub Release보다 뒤처진 버전으로 표시됩니다. 가장 최신 버전이 필요하면 Homebrew나 DMG를 사용해 주세요.",
  },
  cta: {
    eyebrow: "Star & Feedback",
    title: "도움이 되었다면, 별 하나를",
    body: "DiskWise는 개인이 독립적으로 유지 관리하는 오픈소스 프로젝트입니다. 수십 GB를 확보하는 데 도움이 되었다면 GitHub에 별을 남겨주세요 — 별이 많아질수록 \"디스크 공간이 부족합니다\"에 막힌 다음 사람이 더 쉽게 찾을 수 있습니다.",
    starBtn: "GitHub에서 별 남기기",
    issueBtn: "Issue 열기",
    feedbackLead: "여러분의 의견이 듣고 싶습니다 — 잘 되는 점, 안 되는 점, 빠진 기능. 모두 읽고 계속 개선하겠습니다:",
    copyEmail: "이메일 복사",
    copied: "복사됨",
    emailNote: "한국어·영어·중국어·일본어 모두 환영합니다. Issue로 남겨주셔도 좋습니다.",
  },
  faq: {
    eyebrow: "FAQ",
    title: "자주 묻는 질문",
    items: [
      { q: "CleanMyMac과 비교하면 어떤가요?", a: "가격(0원 vs 구독), 투명성(Apache-2.0 전체 공개 vs 폐쇄 소스), 삭제 모델(모두 휴지통·되돌리기 가능 vs 직접 삭제)입니다. CleanMyMac에는 멀웨어 스캔 등 추가 모듈이 있지만, DiskWise는 의도적으로 디스크 한 가지에만 집중합니다." },
      { q: "필요한 파일을 잘못 지울 수 있나요?", a: "아키텍처에 영구 삭제 경로가 존재하지 않습니다. 삭제 동작은 FileManager.trashItem뿐이며, 휴지통을 비울 수 있는 건 Finder의 당신뿐입니다. Home, ~/Library 등 보호 경로는 통째로 지울 수 없습니다." },
      { q: "Docker 이미지는 왜 직접 정리하지 못하나요?", a: "Docker 가상 디스크에는 이미지별 파일 경로가 없어서, 하나씩 지울 수 있다고 주장하는 도구는 모두 가장입니다. DiskWise는 사용량을 읽기 전용으로 보여주고 Docker 공식 prune 명령으로 안내합니다." },
      { q: "어떤 머신을 지원하나요?", a: "macOS 13+이며, Apple Silicon과 Intel이 공유하는 ~5MB 범용 DMG 하나로 배포됩니다. brew cask나 Mac App Store로도 설치할 수 있습니다." },
      { q: "무료가 진짜 무료인가요?", a: "네. 모든 기능과 6가지 스킨이 처음부터 개방되어 있고, 텔레메트리·광고·구독이 없습니다. App Store 버전도 무료입니다." },
    ],
  },
  footer: {
    desc: "무료 오픈소스 macOS 디스크 클리너. 네이티브 SwiftUI, 모든 것은 휴지통으로·항상 되돌리기 가능 — 텔레메트리 0, 구독 0, 데몬 0.",
    meta: "Apache-2.0 · macOS 13+ · 10 languages",
    getLabel: "받기",
    links: [
      { label: "GitHub Release (SHA-256 포함)" },
      { label: "Mac App Store" },
      { label: "소스 · Issue · PR" },
      { label: "한국어 README" },
    ],
    copyright: "© 2026 DreamOfXM · DiskWise는 독립적인 오픈소스 프로젝트이며 MacPaw CleanMyMac 및 tw93의 Mole과 무관합니다",
    langLabel: "언어",
  },
};

export const CONTENT: Record<Locale, SiteContent> = { zh, en, ja, ko };
