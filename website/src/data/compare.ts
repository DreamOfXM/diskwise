// 对比页内容层（vs CleanMyMac / vs DaisyDisk）。
// 口径纪律：竞品那一栏只写它自己官网或指南里能点开的说法，并给出出处；
// 我们这一栏写架构事实，不写形容词。对自己不利的行（空间何时释放、功能广度）照实标 edge:"theirs"。
import type { Locale } from "@/data/content";

export type CompareSlug = "cleanmymac" | "daisydisk" | "puremac" | "mole";

export interface CompareRow {
  dim: string;
  ours: string;
  theirs: string;
  edge: "ours" | "theirs" | "even";
}

export interface CompareContent {
  rival: string;
  /** 商标与无隶属声明：拿竞品名做对比属于指示性合理使用，但这句话必须写在页面上。 */
  disclaimer: string;
  nav: { href: string; label: string }[];
  hero: { eyebrow: string; title: string; sub: string; verdict: string };
  quickAnswer: { q: string; a: string };
  table: { headers: [string, string, string]; rows: CompareRow[] };
  theirsStronger: { title: string; items: { t: string; d: string }[] };
  differences: { title: string; items: { t: string; d: string }[] };
  switchGuide: { title: string; note: string; steps: string[] };
  faq: { q: string; a: string }[];
  sources: { label: string; href: string }[];
  backHome: string;
  otherCompare: { slug: CompareSlug; label: string };
  updated: string;
}

export const COMPARE: Record<CompareSlug, Partial<Record<Locale, CompareContent>>> = {
  cleanmymac: {
    zh: {
      rival: "CleanMyMac",
      disclaimer:
        "DiskWise 是独立的开源项目，与 MacPaw 无任何隶属、授权或赞助关系，也不代表其立场。CleanMyMac 名称与商标归其权利人所有，本页提及仅用于说明两个产品的功能差异。价格与描述取自对方公开页面，可能已经变动。",
      nav: [
        { href: "#diff", label: "差异" },
        { href: "#table", label: "逐项对比" },
        { href: "#switch", label: "怎么换过去" },
        { href: "#install", label: "安装" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "对比 · 2026-10",
        title: "DiskWise vs CleanMyMac",
        sub: "同样是清磁盘，真正的分歧只有两处：删除模型，和能不能被审计。",
        verdict:
          "要「什么都不用想」的省心，CleanMyMac 模块更多、品牌更响、有客服。要知道到底删了什么、而且每一步都能反悔，DiskWise 是免费开源的那一个——它刻意不做恶意软件查杀和一键优化。",
      },
      quickAnswer: {
        q: "CleanMyMac 有免费的替代品吗？",
        a: "有。DiskWise 免费、开源（Apache-2.0），原生 SwiftUI、约 5MB、无遥测无订阅，App Store 版不申请任何网络权限。分歧在两点：DiskWise 唯一的删除路径是移入废纸篓、清空前逐条可撤销；而 CleanMyMac 闭源，你无法从外部验证某一次清理具体动了哪些文件。功能面上 CleanMyMac 更宽，DiskWise 只做磁盘这一件事。",
      },
      table: {
        headers: ["维度", "DiskWise", "CleanMyMac"],
        rows: [
          {
            dim: "价格",
            ours: "免费，全功能解锁，无内购无广告",
            theirs: "订阅制（约 $40/年），另有更贵的一次性买断",
            edge: "ours",
          },
          {
            dim: "源码",
            ours: "Apache-2.0 全开源，删除逻辑可以自己读完",
            theirs: "闭源",
            edge: "ours",
          },
          {
            dim: "删除模型",
            ours: "唯一出口是 FileManager.trashItem：全部进废纸篓，整个会话逐条 Undo，清空由你在 Finder 决定",
            theirs: "官方未把「逐条可撤销」作为公开的设计约束；闭源，无法从外部审计",
            edge: "ours",
          },
          {
            dim: "空间何时真正释放",
            ours: "要等你清空废纸篓。这是拿确定性换来的可反悔，我们不藏这个代价",
            theirs: "清理完成即释放",
            edge: "theirs",
          },
          {
            dim: "功能广度",
            ours: "只做磁盘：环形全景、账本式明细、大文件与陈年文件、重复文件、卸载残留、开发者缓存",
            theirs: "清理 + 恶意软件防护 + 隐私擦除 + 系统维护 + 优化建议，模块齐全",
            edge: "theirs",
          },
          {
            dim: "后台组件",
            ours: "无 updater、无 analytics、无守护进程；App Store 版 entitlements 里没有任何网络权限",
            theirs: "含自动更新与许可相关组件",
            edge: "ours",
          },
          {
            dim: "每一条缓存讲不讲得清",
            ours: "65 条本地知识库：这是什么、删了代价多大、多久长回来，全部随包分发",
            theirs: "以分类和总量呈现，不逐条解释代价",
            edge: "ours",
          },
          {
            dim: "开发者目录",
            ours: "node_modules、Xcode DerivedData、Docker 用量、构建产物是一等公民",
            theirs: "通用缓存视角",
            edge: "ours",
          },
        ],
      },
      theirsStronger: {
        title: "CleanMyMac 确实更强的地方",
        items: [
          {
            t: "功能面宽得多",
            d: "恶意软件查杀、隐私擦除、系统维护、优化建议——DiskWise 一个都没有，而且是刻意不做：磁盘清理这件事没做到底之前，加模块只会摊薄可靠性。",
          },
          {
            t: "清完立刻见效",
            d: "它的模型是清理即释放。DiskWise 要等你清空废纸篓，空间才真的回来。你如果就是要马上腾出几十 GB，这是它的优势。",
          },
          {
            t: "品牌、文档与客服",
            d: "多年口碑、成体系的帮助文档和人工支持。DiskWise 是一个独立维护的开源项目，沟通渠道是 GitHub Issue 和邮箱。",
          },
        ],
      },
      differences: {
        title: "分歧其实只有两个",
        items: [
          {
            t: "架构上没有「永久删除」这条路径",
            d: "不是「我们建议谨慎删除」，是代码里不存在那个调用。误删的恢复手段是 Finder，不是数据恢复服务。",
          },
          {
            t: "可审计不是一句承诺",
            d: "源码公开、每个 release 附 SHA-256、App Store 版可以直接在 .plist 里查它没有网络权限。你不需要相信我们。",
          },
          {
            t: "逐条解释，而不是一个总数",
            d: "「本次可释放 38.2 GB」这种数字不告诉你风险。DiskWise 给每一行配一条语义：能重新下载的、和没有第二份的，不该长一样。",
          },
          {
            t: "0 元",
            d: "CleanMyMac 最好的功能不一定收费最贵，但 DiskWise 全部功能都不要钱，也没有「解锁深度清理」这种按钮。",
          },
        ],
      },
      switchGuide: {
        title: "从 CleanMyMac 换到 DiskWise",
        note: "两者不必二选一：DiskWise 不接管系统，也不会和已装的商业清理工具冲突。",
        steps: [
          "先别只把 .app 拖进废纸篓——用 CleanMyMac 自带的卸载流程，否则会留下助手与登录项组件。",
          "装好 DiskWise，用「卸载残留」对照本机已装 App 的 bundle ID 扫一遍孤儿数据。这一步宁可漏报也不会过删。",
          "打开 Overview 环形全景：如果之前已经被清理过，这次占头部的通常是开发者缓存和微信/钉钉这类 IM 缓存。",
          "确认每一行都读得懂再动手。第一下武装、第二下进废纸篓，Undo 原样放回；决定清空废纸篓的那一刻才真正释放空间。",
        ],
      },
      faq: [
        {
          q: "DiskWise 能完全替代 CleanMyMac 吗？",
          a: "不能。你要恶意软件查杀、隐私擦除、一键系统优化，CleanMyMac 的模块是齐的，DiskWise 没有。在「看清磁盘占用并安全地清掉」这一件事上，DiskWise 可以替代，而且不要钱。",
        },
        {
          q: "为什么不直接删除，非要经过废纸篓？",
          a: "因为清理工具判断错的代价是不可逆的。移入废纸篓把最后一步交给你：只要没清空，一切都还能放回原处。代价也说清楚——不清空就不释放空间。",
        },
        {
          q: "CleanMyMac 安全吗？",
          a: "我们不做这种判断。能说的是：它闭源，外部无法审计某一次清理具体动了哪些文件，这也是 DiskWise 选择把全部逻辑放进可读源码的原因。",
        },
        {
          q: "不联网的话 DiskWise 怎么更新？",
          a: "App Store 版由商店推送；Homebrew 用 brew upgrade --cask；直接下载的话每个 release 都附 SHA-256。应用自身不会主动联网。",
        },
      ],
      sources: [
        { label: "CleanMyMac 官网（定价与模块列表）", href: "https://macpaw.com/cleanmymac" },
      ],
      backHome: "返回 DiskWise 首页",
      otherCompare: { slug: "daisydisk", label: "vs DaisyDisk" },
      updated: "2026 年 10 月",
    },
    en: {
      rival: "CleanMyMac",
      disclaimer:
        "DiskWise is an independent open-source project. It is not affiliated with, authorised by, or sponsored by MacPaw, and does not speak for them. The CleanMyMac name and marks belong to their owner and are used here only to describe how the two products differ. Prices and descriptions come from their public pages and may have changed.",
      nav: [
        { href: "#diff", label: "Differences" },
        { href: "#table", label: "Side by side" },
        { href: "#switch", label: "Switching" },
        { href: "#install", label: "Install" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "Comparison · Oct 2026",
        title: "DiskWise vs CleanMyMac",
        sub: "Both clear disk space. The real disagreement is two things: the deletion model, and whether you can audit it.",
        verdict:
          "If you want not to think about it at all, CleanMyMac has more modules, a bigger brand and support. If you want to know exactly what was removed, with every step reversible, DiskWise is the free and open-source one — and it deliberately ships no malware scan or one-click tune-up.",
      },
      quickAnswer: {
        q: "Is there a free alternative to CleanMyMac?",
        a: "Yes. DiskWise is free and open source (Apache-2.0): a native SwiftUI disk cleaner, about 5 MB, no telemetry, no subscription, and its Mac App Store build requests no network entitlement at all. Two structural differences: the only deletion path in DiskWise moves items to the Trash and stays undoable until you empty it, and CleanMyMac is closed source, so you cannot verify from outside which files a given scan touched.",
      },
      table: {
        headers: ["", "DiskWise", "CleanMyMac"],
        rows: [
          {
            dim: "Price",
            ours: "Free. Every feature unlocked, no upsell, no ads",
            theirs: "Subscription (~$40/yr), plus a pricier one-time licence",
            edge: "ours",
          },
          {
            dim: "Source",
            ours: "Apache-2.0 — you can read the deletion code itself",
            theirs: "Closed source",
            edge: "ours",
          },
          {
            dim: "Deletion model",
            ours: "The only exit is FileManager.trashItem: everything goes to the Trash, every row undoable for the whole session, emptying stays your call in Finder",
            theirs: "Doesn't publish per-item reversibility as a design constraint; closed source, so it can't be audited",
            edge: "ours",
          },
          {
            dim: "When space is actually freed",
            ours: "Only after you empty the Trash. That is the price of reversibility and we won't hide it",
            theirs: "Freed immediately on cleanup",
            edge: "theirs",
          },
          {
            dim: "Breadth",
            ours: "Disk only: ring overview, ledger detail, large & stale files, duplicates, uninstall leftovers, developer caches",
            theirs: "Cleanup + malware protection + privacy erasure + maintenance + tune-up",
            edge: "theirs",
          },
          {
            dim: "Background components",
            ours: "No updater, no analytics, no daemon; the App Store build declares no network entitlement",
            theirs: "Ships auto-update and licensing components",
            edge: "ours",
          },
          {
            dim: "Does it explain each cache",
            ours: "65 local knowledge-base entries shipped in the app: what it is, what removing it costs, how it grows back",
            theirs: "Shows categories and totals, not per-item cost",
            edge: "ours",
          },
          {
            dim: "Developer directories",
            ours: "node_modules, Xcode DerivedData, Docker usage and build artefacts are first-class",
            theirs: "Generic cache view",
            edge: "ours",
          },
        ],
      },
      theirsStronger: {
        title: "Where CleanMyMac genuinely is stronger",
        items: [
          {
            t: "Far more features",
            d: "Malware detection, privacy erasure, maintenance, tune-ups. DiskWise has none of those, deliberately: until disk cleanup is fully solved, adding modules only dilutes reliability.",
          },
          {
            t: "Space comes back instantly",
            d: "Its model frees bytes as it cleans. DiskWise waits for you to empty the Trash. If you need tens of GB back right now, that is their advantage.",
          },
          {
            t: "Brand, docs and support",
            d: "Years of reputation, real documentation, human support. DiskWise is a solo-maintained open-source project; the channels are GitHub Issues and email.",
          },
        ],
      },
      differences: {
        title: "There are really only two disagreements",
        items: [
          {
            t: "No permanent-delete code path exists",
            d: "Not \"we advise caution\" — the call simply isn't in the code. If the app misjudges a folder, your recovery is Finder, not a data-recovery service.",
          },
          {
            t: "Auditable, as a fact rather than a promise",
            d: "Public source, SHA-256 published per release, and the App Store build's entitlements visibly contain no network permission. You don't have to trust us.",
          },
          {
            t: "Per-row explanation, not one big number",
            d: "\"38.2 GB reclaimable\" tells you nothing about risk. A cache you re-download in a minute and a file with no second copy should not look the same in the list.",
          },
          {
            t: "$0",
            d: "There is no \"unlock deep cleaning\" button in DiskWise, and no tier. CleanMyMac's best features are not necessarily its priciest, but they are behind a licence.",
          },
        ],
      },
      switchGuide: {
        title: "Moving from CleanMyMac to DiskWise",
        note: "You don't have to pick one: DiskWise doesn't take over the system and won't conflict with an installed commercial cleaner.",
        steps: [
          "Don't just drag CleanMyMac to the Trash — use its own uninstall flow, or helper and login items stay behind.",
          "Install DiskWise and run uninstall-leftover detection against the bundle IDs of everything actually installed on the machine. It is built to miss orphans rather than over-delete.",
          "Open the Overview ring. If the Mac was already cleaned recently, the top segments will usually be developer caches and IM caches (WeChat, DingTalk and the like).",
          "Read each row before acting. One click arms it, the next moves it to the Trash; Undo puts it back exactly. Space returns the moment you empty the Trash.",
        ],
      },
      faq: [
        {
          q: "Can DiskWise fully replace CleanMyMac?",
          a: "No. If you want malware scanning, privacy erasure or one-click tune-ups, CleanMyMac has those modules and DiskWise does not. For \"see what is using the disk and remove it safely\", it replaces it — for free.",
        },
        {
          q: "Why route deletions through the Trash instead of just deleting?",
          a: "Because a cleaner that misjudges is an irreversible cost. Going through the Trash hands the last step back to you: until you empty it, everything can go home. The trade-off is stated plainly — no space comes back until you do.",
        },
        {
          q: "Is CleanMyMac safe?",
          a: "We won't make that call. What we can say is that it is closed source, so you cannot verify from outside which files a particular cleanup removed. That is exactly why DiskWise puts all of its logic in readable source.",
        },
        {
          q: "How does it update without network access?",
          a: "The App Store build updates through the store; Homebrew uses brew upgrade --cask; direct downloads publish a SHA-256 per release. The app itself never reaches out.",
        },
      ],
      sources: [
        { label: "CleanMyMac product page (pricing and modules)", href: "https://macpaw.com/cleanmymac" },
      ],
      backHome: "Back to the DiskWise home page",
      otherCompare: { slug: "daisydisk", label: "vs DaisyDisk" },
      updated: "October 2026",
    },
  },

  daisydisk: {
    zh: {
      rival: "DaisyDisk",
      disclaimer:
        "DiskWise 是独立的开源项目，与 DaisyDisk 的开发者无任何隶属、授权或赞助关系。DaisyDisk 名称与商标归其权利人所有，本页提及仅用于说明两个产品的功能差异；关于其删除方式的描述来自它自己的官方指南（见下方出处），价格与功能可能已经变动。两个产品可以并存，本页不是劝你退掉 DaisyDisk。",
      nav: [
        { href: "#diff", label: "差异" },
        { href: "#table", label: "逐项对比" },
        { href: "#switch", label: "怎么并用" },
        { href: "#install", label: "安装" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "对比 · 2026-10",
        title: "DiskWise vs DaisyDisk",
        sub: "环形图这一项我们认输。分歧在删除：它按设计绕过废纸篓，我们只有废纸篓这一条路。",
        verdict:
          "DaisyDisk 的地图交互是行业标杆，看磁盘它更顺手。DiskWise 免费开源，多做的是「这一行能不能删、删了代价多大」，以及一个结构上无法永久删除的删除模型。",
      },
      quickAnswer: {
        q: "DaisyDisk 有免费替代品吗？",
        a: "DiskWise 免费且开源（Apache-2.0），同样有环形空间全景，并在此之上加了缓存语义和清理流程。最关键的区别：DaisyDisk 官方指南写明它「不会把文件移到系统废纸篓，因为那样实际上不会释放任何磁盘空间」，删除不可撤销；DiskWise 唯一的删除路径就是移入废纸篓，清空前逐条可撤销——代价是空间要等你清空废纸篓才回来。",
      },
      table: {
        headers: ["维度", "DiskWise", "DaisyDisk"],
        rows: [
          {
            dim: "价格",
            ours: "免费，全功能解锁",
            theirs: "$9.99 一次性买断（非订阅）",
            edge: "ours",
          },
          {
            dim: "删除模型",
            ours: "唯一出口是移入废纸篓，整个会话逐条 Undo，清空由你决定",
            theirs: "官方指南：不把文件移到系统废纸篓，直接从磁盘移除，因此无法「撤销删除」",
            edge: "ours",
          },
          {
            dim: "为什么这么选",
            ours: "清理工具判断错的代价不可逆，所以把最后一步交给人",
            theirs: "官方理由：不进废纸篓才真正回收空间（同一卷上的废纸篓不省空间）",
            edge: "even",
          },
          {
            dim: "空间何时真正释放",
            ours: "清空废纸篓之后",
            theirs: "删除瞬间",
            edge: "theirs",
          },
          {
            dim: "回答「能不能删」",
            ours: "65 条本地知识库逐条解释：这是什么、代价多大、多久长回来",
            theirs: "按体积与层级展示，可删性由你自己判断",
            edge: "ours",
          },
          {
            dim: "空间可视化",
            ours: "环形全景 + 就地展开的账本式明细",
            theirs: "环形地图打磨多年，交互与预览更成熟",
            edge: "theirs",
          },
          {
            dim: "字节口径",
            ours: "实测占盘 st_blocks × 512：稀疏文件和 APFS clone 不会虚报你能拿回的空间",
            theirs: "以文件大小视角呈现",
            edge: "ours",
          },
          {
            dim: "源码",
            ours: "Apache-2.0 全开源；App Store 版 entitlements 里没有任何网络权限",
            theirs: "闭源",
            edge: "ours",
          },
        ],
      },
      theirsStronger: {
        title: "DaisyDisk 确实更强的地方",
        items: [
          {
            t: "地图更好用",
            d: "环形地图、预览、聚合与筛选打磨了很多年。如果你只想「看清磁盘」，DaisyDisk 的体验更顺。",
          },
          {
            t: "删除立刻生效",
            d: "它绕过废纸篓，所以空间当场回来。DiskWise 走废纸篓，所以你要多做一步、并且真的能反悔。这是取舍，不是谁疏忽。",
          },
          {
            t: "一次买断",
            d: "$9.99 终身，不是订阅。在商业工具里这已经算厚道——只是 DiskWise 是 0 元。",
          },
        ],
      },
      differences: {
        title: "分歧在哪",
        items: [
          {
            t: "一个结构上删不掉东西的清理器",
            d: "DiskWise 的代码里不存在永久删除的调用。DaisyDisk 的指南明确说它不进系统废纸篓，所以删错只能靠数据恢复。",
          },
          {
            t: "从「看」到「敢动手」",
            d: "知道哪个文件夹 28 GB，和知道那 28 GB 是不是能删、删了要多久长回来，是两个问题。DiskWise 把第二条做成随包分发的数据。",
          },
          {
            t: "字节数对得上账",
            d: "实测占盘而非表观大小：APFS clone 和稀疏文件不会让你以为自己拿回了其实拿不回来的空间。分段之和等于整盘。",
          },
          {
            t: "免费且可审计",
            d: "源码公开、release 附 SHA-256、商店版无网络权限。你不需要相信任何宣传语。",
          },
        ],
      },
      switchGuide: {
        title: "两个一起用，还是换过来",
        note: "DaisyDisk 是一次性买断，不存在「不用的话白付了订阅费」的问题，所以并存完全合理。",
        steps: [
          "并存：DaisyDisk 用来看，DiskWise 用来动手。两边都不接管系统。",
          "已经用 DaisyDisk 删过的部分不可逆。之后要清同类的东西，可以先在 DiskWise 里走一遍废纸篓，确认没问题再清空。",
          "DiskWise 的 Overview 环按本次实测字节分段，分段之和等于整盘，可以直接和 DaisyDisk 的读数对账。",
          "重复文件、卸载残留、node_modules / DerivedData / Docker 这些 DaisyDisk 不判断可删性的部分，交给 DiskWise 的语义列表。",
        ],
      },
      faq: [
        {
          q: "DaisyDisk 会把文件删掉吗？",
          a: "会，而且是按设计的。它的官方指南写着删除不经过系统废纸篓，因为文件留在同一卷的废纸篓里并不会释放空间；代价是这样删除无法撤销，指南给出的恢复建议是立刻停用这台 Mac 以免覆写、或找专业数据恢复。",
        },
        {
          q: "DiskWise 为什么不学它？",
          a: "因为「腾出空间」和「不弄丢文件」冲突时，我们选择后者，并且把代价写在页面上：不清空废纸篓，空间就不回来。",
        },
        {
          q: "两者的环形图谁准？",
          a: "口径不同。DiskWise 统计实际占盘（st_blocks × 512），所以稀疏文件和 APFS clone 不会虚报；每一段都是本次实测到的字节，分段之和等于整盘。",
        },
        {
          q: "DiskWise 能当免费的 DaisyDisk 用吗？",
          a: "看磁盘这一项可以，而且它更偏开发者：node_modules、DerivedData、Docker 用量、构建产物、微信/钉钉这类缓存都在语义列表里。地图交互我们不如它成熟，这点不粉饰。",
        },
      ],
      sources: [
        { label: "DaisyDisk 官方指南 · Deleting files", href: "https://daisydiskapp.com/guide/4/en/DeletingFiles/" },
        { label: "DaisyDisk 官方指南 · Undeleting files", href: "https://daisydiskapp.com/guide/4/en/Undelete/" },
      ],
      backHome: "返回 DiskWise 首页",
      otherCompare: { slug: "cleanmymac", label: "vs CleanMyMac" },
      updated: "2026 年 10 月",
    },
    en: {
      rival: "DaisyDisk",
      disclaimer:
        "DiskWise is an independent open-source project. It is not affiliated with, authorised by, or sponsored by the developers of DaisyDisk. The DaisyDisk name and marks belong to their owner and are used here only to describe how the two products differ; statements about how it removes files come from its own official guide (linked below). Pricing and features may have changed, and the two tools work fine side by side — this page is not a pitch to give yours up.",
      nav: [
        { href: "#diff", label: "Differences" },
        { href: "#table", label: "Side by side" },
        { href: "#switch", label: "Using both" },
        { href: "#install", label: "Install" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "Comparison · Oct 2026",
        title: "DiskWise vs DaisyDisk",
        sub: "We lose on the map. The disagreement is deletion: by design it bypasses the Trash, and the Trash is the only path we have.",
        verdict:
          "DaisyDisk's ring is the benchmark for looking at a disk, and it's nicer for that. DiskWise is free and open source and answers the next question — \"can I delete this row, and what does it cost\" — with a deletion model that cannot permanently delete.",
      },
      quickAnswer: {
        q: "Is there a free alternative to DaisyDisk?",
        a: "DiskWise is free and open source (Apache-2.0), has its own ring overview, and adds cache semantics plus a cleanup flow on top. The decisive difference is documented by DaisyDisk itself: its guide states it does not move files to the system Trash \"because in that case, no disk space would actually be recovered\", so removals can't be undone. DiskWise's only deletion path is the Trash, undoable until you empty it — and the cost is that space returns only when you do.",
      },
      table: {
        headers: ["", "DiskWise", "DaisyDisk"],
        rows: [
          {
            dim: "Price",
            ours: "Free, every feature unlocked",
            theirs: "$9.99 one-time (not a subscription)",
            edge: "ours",
          },
          {
            dim: "Deletion model",
            ours: "The only exit is a move to the Trash; every row undoable for the session; emptying is your call",
            theirs: "Its guide: files are not moved to the system Trash, they are removed from disk, so undelete isn't possible",
            edge: "ours",
          },
          {
            dim: "Why they chose it",
            ours: "A cleaner that misjudges shouldn't be irreversible, so the last step stays with the human",
            theirs: "Their stated reason: a file parked in Trash on the same volume frees nothing",
            edge: "even",
          },
          {
            dim: "When space is actually freed",
            ours: "After you empty the Trash",
            theirs: "The instant you delete",
            edge: "theirs",
          },
          {
            dim: "Does it answer \"safe to delete?\"",
            ours: "65 shipped knowledge entries: what it is, what it costs, how it grows back",
            theirs: "Shows size and hierarchy; you judge what's safe",
            edge: "ours",
          },
          {
            dim: "Visualisation",
            ours: "Ring overview plus ledger-style in-place drill-down",
            theirs: "Years of polish; preview, grouping and filtering are smoother",
            edge: "theirs",
          },
          {
            dim: "How bytes are counted",
            ours: "Real on-disk usage (st_blocks × 512), so sparse files and APFS clones can't overstate what you'd reclaim",
            theirs: "File-size view",
            edge: "ours",
          },
          {
            dim: "Source",
            ours: "Apache-2.0, fully open; the App Store build declares no network entitlement",
            theirs: "Closed source",
            edge: "ours",
          },
        ],
      },
      theirsStronger: {
        title: "Where DaisyDisk genuinely is stronger",
        items: [
          {
            t: "The map is better",
            d: "Ring, preview, grouping and filtering have had years of polish. If all you want is to see a disk, DaisyDisk is the more comfortable tool.",
          },
          {
            t: "Deletions take effect at once",
            d: "It skips the Trash, so space comes back immediately. DiskWise routes through the Trash, so you do one more step — and genuinely get to change your mind. That's a trade, not an oversight.",
          },
          {
            t: "One-time purchase",
            d: "$9.99 for life, not a subscription. For commercial software that's fair; DiskWise is just $0.",
          },
        ],
      },
      differences: {
        title: "Where they part ways",
        items: [
          {
            t: "A cleaner that structurally can't delete",
            d: "There is no permanent-delete call in DiskWise's code. DaisyDisk's own guide says removals skip the system Trash, so a mistake leaves data recovery as the only exit.",
          },
          {
            t: "From \"see it\" to \"dare to act\"",
            d: "Knowing a folder is 28 GB and knowing whether those 28 GB are safe to remove — and how long they take to grow back — are different questions. DiskWise ships the second answer as data.",
          },
          {
            t: "The numbers reconcile",
            d: "Measured on-disk usage rather than apparent size, so APFS clones and sparse files don't report space you can't actually reclaim. Segments sum to the whole disk.",
          },
          {
            t: "Free and auditable",
            d: "Open source, SHA-256 per release, no network permission in the store build. You don't need to believe any of this.",
          },
        ],
      },
      switchGuide: {
        title: "Use both, or move over",
        note: "DaisyDisk is a one-time purchase, so there's no \"paying for a subscription I'm not using\" problem. Running both is reasonable.",
        steps: [
          "Side by side: DaisyDisk to look, DiskWise to act. Neither takes over the system.",
          "Anything already removed with DaisyDisk is gone. For the next sweep, run it through DiskWise's Trash first and empty it once you're satisfied.",
          "DiskWise's ring is segmented by bytes measured in this scan, summing to the whole disk — you can reconcile it against DaisyDisk's reading.",
          "Duplicates, uninstall leftovers, node_modules / DerivedData / Docker: the parts DaisyDisk doesn't judge for safety are the rows DiskWise carries semantics for.",
        ],
      },
      faq: [
        {
          q: "Does DaisyDisk permanently delete?",
          a: "Yes, by design. Its guide states it doesn't move files to the system Trash because that would free no space, and that removed items cannot be undeleted — its recovery advice is to stop using the Mac immediately to avoid overwriting, or hire a data-recovery service.",
        },
        {
          q: "Why doesn't DiskWise do the same?",
          a: "Because when \"free up space\" and \"don't lose a file\" conflict, we pick the second — and we print the cost: until you empty the Trash, the space isn't back.",
        },
        {
          q: "Whose ring is more accurate?",
          a: "Different measurement. DiskWise counts real on-disk usage (st_blocks × 512), so sparse files and APFS clones can't overstate the reclaimable amount; every arc is bytes measured in the current scan and the segments sum to the whole disk.",
        },
        {
          q: "Can DiskWise be a free DaisyDisk?",
          a: "For looking at a disk, yes, and it leans developer: node_modules, DerivedData, Docker usage, build artefacts and WeChat/DingTalk-style caches are all in the semantic list. Its map interaction is less polished than DaisyDisk's, and we won't pretend otherwise.",
        },
      ],
      sources: [
        { label: "DaisyDisk official guide · Deleting files", href: "https://daisydiskapp.com/guide/4/en/DeletingFiles/" },
        { label: "DaisyDisk official guide · Undeleting files", href: "https://daisydiskapp.com/guide/4/en/Undelete/" },
      ],
      backHome: "Back to the DiskWise home page",
      otherCompare: { slug: "cleanmymac", label: "vs CleanMyMac" },
      updated: "October 2026",
    },
  },
  puremac: {
    zh: {
      rival: "PureMac",
      disclaimer:
        "DiskWise 是独立的开源项目，与 PureMac 及其作者无任何隶属、授权或赞助关系。PureMac 名称与商标归其权利人所有，本页提及仅用于说明两个产品的功能差异。描述取自对方公开仓库页面，可能已经变动。",
      nav: [
        { href: "#diff", label: "差异" },
        { href: "#table", label: "逐项对比" },
        { href: "#switch", label: "怎么换过去" },
        { href: "#install", label: "安装" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "对比 · 2026-10",
        title: "DiskWise vs PureMac",
        sub: "两个都是免费开源的 SwiftUI 清理器，真正的分歧只有一行：有没有「绝不永久删除」的架构承诺。",
        verdict:
          "要功能面更宽的套装（十级匹配卸载、系统检查、定时清理、CLI），PureMac 半年 30 个 release，走得很快。要「任何清理动作都进废纸篓、全部可撤销」的确定性，DiskWise 是把这条写进架构的那一个——定时清理、分类一键清理这些场景，我们宁可少做，也不引入永久删除路径。",
      },
      quickAnswer: {
        q: "PureMac 和 DiskWise 有什么区别？",
        a: "两个都是免费、开源、原生 SwiftUI、签名公证、零遥测的 Mac 清理器。核心分歧在删除模型：PureMac 在自己的 README 里写明，应用卸载等操作走废纸篓，但定时自动清理、分类一键清理、清空废纸篓、Docker/Xcode runtime 清理等六类操作「可以永久删除数据」；DiskWise 的唯一删除路径是移入废纸篓，整个会话逐条可撤销，没有任何类别的操作会绕过它。反过来，PureMac 的功能面更宽，还有 CLI。",
      },
      table: {
        headers: ["维度", "DiskWise", "PureMac"],
        rows: [
          { dim: "价格", ours: "免费，Apache-2.0，无内购无广告", theirs: "免费，MIT，无内购无广告", edge: "even" },
          {
            dim: "删除模型",
            ours: "唯一出口是 FileManager.trashItem：全部操作进废纸篓，整个会话逐条 Undo，清空由你在 Finder 决定",
            theirs: "README 的 Our promise 写明：应用卸载/孤儿/重复文件走废纸篓；定时自动清理、分类清理、清空废纸篓、Docker/Xcode runtime 清理、快照删除、CLI 清理等类别可以永久删除",
            edge: "ours",
          },
          {
            dim: "功能宽度",
            ours: "刻意只做磁盘：环形总览、缓存知识库、重复文件、卸载残留、大文件",
            theirs: "套装：Smart Care、十级匹配应用卸载、存储浏览、系统检查、定时自动清理、CLI",
            edge: "theirs",
          },
          {
            dim: "每条缓存的解释",
            ours: "知识库逐条写明：这是什么、删了会怎样、多久长回来；微信/钉钉/企业微信单独覆盖",
            theirs: "承诺诚实扫描与中性呈现，未把逐条缓存解释列为特性",
            edge: "ours",
          },
          { dim: "成熟度", ours: "2026-09 发布，v1.7", theirs: "2026-04 发布，半年 30 个 release、6900+ star", edge: "theirs" },
          { dim: "界面语言", ours: "10 种 UI 语言，README 四语", theirs: "README 八语（含阿拉伯语）", edge: "even" },
          { dim: "签名与分发", ours: "Developer ID 签名 + 公证；brew cask / DMG / App Store", theirs: "签名 + 公证；GitHub Release", edge: "even" },
        ],
      },
      theirsStronger: {
        title: "PureMac 更强的地方",
        items: [
          { t: "功能更宽", d: "十级匹配的应用卸载、系统检查、存储浏览、定时自动清理，DiskWise 刻意不做这么宽。" },
          { t: "迭代更快更成熟", d: "半年 30 个 release，6900+ star、380+ fork，社区验证更充分。" },
          { t: "有 CLI", d: "命令行清理适合脚本化和远程场景，DiskWise 目前是纯 GUI。" },
        ],
      },
      differences: {
        title: "真正的分歧",
        items: [
          { t: "删除模型", d: "DiskWise 把「一切进废纸篓」做成架构级约束——包括定时清理这类「没人盯着」的场景，要么不存在，要么也进废纸篓。PureMac 把它做成按类别区分的承诺，自动清理类别会永久删除。" },
          { t: "产品哲学", d: "PureMac 做「Mac care 套装」，一个工具管更多事；DiskWise 只做磁盘，把「敢不敢让它自动删」这个问题的答案做成永远不需要问。" },
        ],
      },
      switchGuide: {
        title: "从 PureMac 换到 DiskWise",
        note: "两个都免费，可以同时装着试，不需要先卸载。",
        steps: [
          "brew install --cask dreamofxm/diskwise/diskwise，或从 App Store 装 DiskWise",
          "打开 Overview 看整盘环形图，点开任意一行看子目录明细",
          "试着删一个缓存：两下点击进废纸篓，⌘Z 撤销，清空废纸篓仍是 Finder 的事",
          "对比两边的清理结果口径，留下你更信的那个",
        ],
      },
      faq: [
        { q: "两个都是开源清理器，选哪个？", a: "要定时自动清理和更宽的功能面，选 PureMac；要「任何动作都可反悔」的确定性，选 DiskWise。两个都免费，装着对比成本为零。" },
        { q: "DiskWise 会做定时自动清理吗？", a: "只有在「清理动作也进废纸篓」的前提下才会做——否则就与我们的架构承诺冲突。没有时间表。" },
      ],
      sources: [
        { label: "PureMac 仓库（Our promise / How it compares）", href: "https://github.com/momenbasel/PureMac" },
        { label: "DiskWise 仓库", href: "https://github.com/DreamOfXM/diskwise" },
      ],
      backHome: "回 DiskWise 主页",
      otherCompare: { slug: "mole", label: "vs Mole" },
      updated: "2026-10",
    },
    en: {
      rival: "PureMac",
      disclaimer:
        "DiskWise is an independent open-source project with no affiliation, endorsement, or sponsorship from PureMac or its author. All descriptions come from PureMac's public repository page and may have changed.",
      nav: [
        { href: "#diff", label: "Differences" },
        { href: "#table", label: "Head-to-head" },
        { href: "#switch", label: "Switching" },
        { href: "#install", label: "Install" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "Compare · 2026-10",
        title: "DiskWise vs PureMac",
        sub: 'Both are free, open-source SwiftUI cleaners. The real disagreement is a single row: whether "never permanently deletes" is an architectural constraint.',
        verdict:
          "If you want the wider suite (10-level app uninstaller, system checks, scheduled cleaning, a CLI), PureMac ships fast — 30 releases in six months. If you want the certainty that every cleanup action lands in the Trash and stays undoable, DiskWise is the one that wrote that into the architecture. We would rather ship fewer features than introduce a permanent-delete path.",
      },
      quickAnswer: {
        q: "What is the difference between PureMac and DiskWise?",
        a: 'Both are free, open-source, native SwiftUI, signed and notarized, zero telemetry. The core difference is the deletion model: PureMac\'s own README states that app uninstalls go through the Trash, but scheduled auto-clean, category cleanup, Trash emptying, Docker/Xcode runtime cleanup, snapshot deletion and CLI cleanup "can permanently delete data". DiskWise\'s only delete path moves everything to the Trash, undoable per item for the whole session — no category of operation bypasses it. In exchange, PureMac has a wider feature set and a CLI.',
      },
      table: {
        headers: ["Dimension", "DiskWise", "PureMac"],
        rows: [
          { dim: "Price", ours: "Free, Apache-2.0, no IAP, no ads", theirs: "Free, MIT, no IAP, no ads", edge: "even" },
          {
            dim: "Deletion model",
            ours: "One exit only — FileManager.trashItem: every operation lands in the Trash, per-item Undo for the whole session, emptying stays Finder's job",
            theirs: 'Per its README\'s "Our promise": app uninstalls/orphans/duplicates use the Trash; scheduled auto-clean, category cleanup, Trash emptying, Docker/Xcode runtime cleanup, snapshot deletion and CLI cleanup can permanently delete data',
            edge: "ours",
          },
          {
            dim: "Feature breadth",
            ours: "Deliberately disk-only: ring overview, cache knowledge base, duplicates, leftovers, large files",
            theirs: "A suite: Smart Care, 10-level app uninstaller, storage exploration, system checks, scheduled auto-clean, CLI",
            edge: "theirs",
          },
          {
            dim: "Per-cache explanations",
            ours: "Knowledge base states what each cache is, what deletion costs, how it comes back; WeChat/DingTalk/WeCom covered",
            theirs: "Promises honest scans and neutral presentation; per-entry explanations not listed as a feature",
            edge: "ours",
          },
          { dim: "Maturity", ours: "Released 2026-09, v1.7", theirs: "Released 2026-04, 30 releases in six months, 6,900+ stars", edge: "theirs" },
          { dim: "Languages", ours: "10 UI languages, 4-language README", theirs: "8-language README (Arabic first)", edge: "even" },
          { dim: "Signing & distribution", ours: "Developer ID signed + notarized; brew cask / DMG / App Store", theirs: "Signed + notarized; GitHub Release", edge: "even" },
        ],
      },
      theirsStronger: {
        title: "Where PureMac is stronger",
        items: [
          { t: "Wider feature set", d: "10-level matching uninstaller, system checks, storage exploration, scheduled cleaning — DiskWise deliberately stays narrower." },
          { t: "Faster iteration, more mature", d: "30 releases in six months, 6,900+ stars and 380+ forks of community validation." },
          { t: "Has a CLI", d: "Command-line cleaning suits scripting and remote workflows; DiskWise is GUI-only for now." },
        ],
      },
      differences: {
        title: "The real disagreement",
        items: [
          { t: "Deletion model", d: 'DiskWise makes "everything to the Trash" an architectural constraint — including unattended scenarios like scheduled cleaning: either it does not exist, or it also goes through the Trash. PureMac makes it a per-category promise, and the automated categories permanently delete.' },
          { t: "Product philosophy", d: 'PureMac builds a "Mac care suite"; DiskWise does one thing — the disk — so you never have to ask whether it is safe to let it clean unattended.' },
        ],
      },
      switchGuide: {
        title: "Switching from PureMac",
        note: "Both are free — you can install DiskWise alongside and compare, no uninstall needed.",
        steps: [
          "brew install --cask dreamofxm/diskwise/diskwise, or get DiskWise from the App Store",
          "Open Overview to see the whole-volume ring; click any row for its subfolder ledger",
          "Delete one cache: two taps to the Trash, ⌘Z to undo; emptying stays Finder's job",
          "Compare what each reports, keep the one you trust",
        ],
      },
      faq: [
        { q: "Both are open-source cleaners — which one?", a: "Scheduled auto-clean and a wider suite: PureMac. The certainty that every action is reversible: DiskWise. Both are free, so comparing costs nothing." },
        { q: "Will DiskWise add scheduled auto-clean?", a: "Only if the cleaning action itself goes to the Trash — otherwise it conflicts with our architectural promise. No timeline." },
      ],
      sources: [
        { label: "PureMac repository (Our promise / How it compares)", href: "https://github.com/momenbasel/PureMac" },
        { label: "DiskWise repository", href: "https://github.com/DreamOfXM/diskwise" },
      ],
      backHome: "Back to DiskWise",
      otherCompare: { slug: "mole", label: "vs Mole" },
      updated: "October 2026",
    },
  },
  mole: {
    zh: {
      rival: "Mole",
      disclaimer:
        "DiskWise 是独立的开源项目，与 Mole 及其作者无任何隶属、授权或赞助关系。Mole 名称与商标归其权利人所有，本页提及仅用于说明两个产品的功能差异。描述取自对方公开页面，可能已经变动。",
      nav: [
        { href: "#diff", label: "差异" },
        { href: "#table", label: "逐项对比" },
        { href: "#switch", label: "怎么换过去" },
        { href: "#install", label: "安装" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "对比 · 2026-10",
        title: "DiskWise vs Mole",
        sub: "同一条起跑线上的两种形态：命令行的效率，和看得见的确定性。",
        verdict:
          "你天天泡终端、要一条命令解决问题，Mole 的 CLI 免费开源、开发者口碑极好，是正路。你想要的是「看见整块盘、两下点击、随时反悔」的图形界面，而且免费开源——这一格此前是空的，DiskWise 就是为此做的。",
      },
      quickAnswer: {
        q: "Mole 的免费开源 CLI 和 DiskWise 怎么选？",
        a: "看交互形态。Mole 的强项是终端：一条命令、脚本化、远程可跑，CLI 免费开源；它的原生 GUI 应用另收费且闭源。DiskWise 是纯 GUI：整盘环形图、两下点击进废纸篓、逐条 Undo，全功能免费开源（Apache-2.0）。删除模型上，DiskWise 把「一切进废纸篓」做成架构级约束；命令行工具的删除行为以它的官方文档为准。",
      },
      table: {
        headers: ["维度", "DiskWise", "Mole"],
        rows: [
          { dim: "价格", ours: "免费，全功能开源（Apache-2.0）", theirs: "CLI 免费开源；原生 GUI 应用一次性付费、闭源", edge: "ours" },
          { dim: "交互形态", ours: "原生 SwiftUI GUI：环形图 + 账本明细，两下点击", theirs: "终端 TUI：一条命令，脚本化友好", edge: "even" },
          { dim: "删除模型", ours: "唯一出口是 FileManager.trashItem：全部进废纸篓，整个会话逐条 Undo", theirs: "以命令行方式直接执行清理（详见其文档）", edge: "ours" },
          { dim: "适合谁", ours: "想看清楚再动手的人；给爸妈同事装也放心的那类", theirs: "天天在终端里的开发者", edge: "even" },
          { dim: "社区成熟度", ours: "2026-09 发布，新项目", theirs: "60k+ star，开发者社区验证充分", edge: "theirs" },
          { dim: "知识库解释", ours: "每条缓存写明是什么、删了会怎样、多久长回来", theirs: "以清理能力著称，未把逐条解释列为特性", edge: "ours" },
        ],
      },
      theirsStronger: {
        title: "Mole 更强的地方",
        items: [
          { t: "终端效率", d: "一条命令清出几十 GB，可脚本化、可自动化，GUI 给不了这个。" },
          { t: "社区与口碑", d: "60k+ star、病毒式传播的口碑，久经考验。" },
          { t: "监测能力", d: "除清理外还做分析与监控，覆盖面更广。" },
        ],
      },
      differences: {
        title: "真正的分歧",
        items: [
          { t: "形态决定信任模型", d: "终端工具的信任来自「命令是透明的」；GUI 工具的信任必须来自「界面没骗你」。DiskWise 用环形图的实测字节和废纸篓级可撤销来挣后一种信任。" },
          { t: "免费 GUI 这一格", d: "Mole 的 GUI 收费闭源；DiskWise 的 GUI 免费开源——这是我们存在的直接理由。" },
        ],
      },
      switchGuide: {
        title: "从 Mole CLI 到 DiskWise",
        note: "不是替代关系：终端党可以两个都留，DiskWise 补上「看得见」的那一半。",
        steps: [
          "brew install --cask dreamofxm/diskwise/diskwise",
          "打开 Overview，看整盘环形图和账本——这是 Mole 输出数字的图形对应物",
          "两下点击把一个缓存送进废纸篓，⌘Z 撤销试试",
          "需要脚本化时继续用 Mole，没问题",
        ],
      },
      faq: [
        { q: "Mole 那么强，为什么还做 DiskWise？", a: "因为「免费 + 开源 + 原生 GUI」这一格空着：Mole 的 GUI 收费闭源，CleanMyMac 贵且闭源。DiskWise 把这条产品等式补齐了。" },
        { q: "DiskWise 会有 CLI 吗？", a: "在规划里：scan 输出 JSON 一类。不会为了 CLI 引入绕过废纸篓的删除路径。" },
      ],
      sources: [
        { label: "Mole 仓库", href: "https://github.com/tw93/Mole" },
        { label: "DiskWise 仓库", href: "https://github.com/DreamOfXM/diskwise" },
      ],
      backHome: "回 DiskWise 主页",
      otherCompare: { slug: "puremac", label: "vs PureMac" },
      updated: "2026-10",
    },
    en: {
      rival: "Mole",
      disclaimer:
        "DiskWise is an independent open-source project with no affiliation, endorsement, or sponsorship from Mole or its author. All descriptions come from Mole's public pages and may have changed.",
      nav: [
        { href: "#diff", label: "Differences" },
        { href: "#table", label: "Head-to-head" },
        { href: "#switch", label: "Switching" },
        { href: "#install", label: "Install" },
        { href: "#faq", label: "FAQ" },
      ],
      hero: {
        eyebrow: "Compare · 2026-10",
        title: "DiskWise vs Mole",
        sub: "Two shapes on the same starting line: terminal efficiency versus visible certainty.",
        verdict:
          "If you live in the terminal and want one command to fix things, Mole's free, open-source CLI is the real deal with a stellar reputation. If what you want is a GUI where you see the whole disk, delete in two clicks, and undo everything — free and open-source — that cell sat empty, and DiskWise is what fills it.",
      },
      quickAnswer: {
        q: "Mole's free CLI or DiskWise?",
        a: "It is about the shape of the interaction. Mole's strength is the terminal: one command, scriptable, remote-friendly — the CLI is free and open source; its native GUI app is a separate paid, closed-source product. DiskWise is a pure GUI: whole-volume ring, two taps to the Trash, per-item undo, every feature free and open source (Apache-2.0). On deletion, DiskWise makes \"everything to the Trash\" an architectural constraint; for the CLI tool's behavior, its official docs are the source of truth.",
      },
      table: {
        headers: ["Dimension", "DiskWise", "Mole"],
        rows: [
          { dim: "Price", ours: "Free, fully open source (Apache-2.0)", theirs: "CLI free and open source; native GUI app is paid and closed source", edge: "ours" },
          { dim: "Interaction", ours: "Native SwiftUI GUI: ring map + ledger, two clicks", theirs: "Terminal TUI: one command, script-friendly", edge: "even" },
          { dim: "Deletion model", ours: "One exit only — FileManager.trashItem: everything to the Trash, per-item Undo for the session", theirs: "Cleans by executing commands directly (see its docs)", edge: "ours" },
          { dim: "Best for", ours: "People who want to see before they delete; safe to install for parents and colleagues", theirs: "Developers who live in the terminal", edge: "even" },
          { dim: "Community maturity", ours: "Released 2026-09, new project", theirs: "60k+ stars, thoroughly community-validated", edge: "theirs" },
          { dim: "Knowledge base", ours: "Every cache entry explains what it is, what deletion costs, how it comes back", theirs: "Known for cleaning power; per-entry explanations not listed as a feature", edge: "ours" },
        ],
      },
      theirsStronger: {
        title: "Where Mole is stronger",
        items: [
          { t: "Terminal efficiency", d: "One command frees tens of GB — scriptable and automatable in a way a GUI never is." },
          { t: "Community and reputation", d: "60k+ stars and viral word of mouth, battle-tested." },
          { t: "Monitoring", d: "Beyond cleaning it analyzes and monitors — wider coverage." },
        ],
      },
      differences: {
        title: "The real disagreement",
        items: [
          { t: "Form decides the trust model", d: "A terminal tool earns trust through transparent commands; a GUI has to earn it by not lying to you. DiskWise earns it with measured-bytes ring mapping and Trash-level undoability." },
          { t: "The free-GUI cell", d: "Mole's GUI is paid and closed; DiskWise's GUI is free and open — that is the direct reason DiskWise exists." },
        ],
      },
      switchGuide: {
        title: "From Mole CLI to DiskWise",
        note: "Not a replacement: terminal people can keep both — DiskWise adds the visible half.",
        steps: [
          "brew install --cask dreamofxm/diskwise/diskwise",
          "Open Overview — the ring and ledger are the graphical counterpart of Mole's numbers",
          "Send one cache to the Trash with two clicks, then ⌘Z it back",
          "Keep using Mole when you need scripting — that's fine",
        ],
      },
      faq: [
        { q: "Mole is so good — why build DiskWise?", a: 'Because the "free + open source + native GUI" cell was empty: Mole\'s GUI is paid and closed, CleanMyMac is pricey and closed. DiskWise completes that equation.' },
        { q: "Will DiskWise have a CLI?", a: "Planned: things like scan-to-JSON. It will never introduce a delete path that bypasses the Trash." },
      ],
      sources: [
        { label: "Mole repository", href: "https://github.com/tw93/Mole" },
        { label: "DiskWise repository", href: "https://github.com/DreamOfXM/diskwise" },
      ],
      backHome: "Back to DiskWise",
      otherCompare: { slug: "puremac", label: "vs PureMac" },
      updated: "October 2026",
    },
  },
};

/** 对比页只出 zh / en 两语：ja、ko 回落英文，与商店元数据的语言覆盖一致。 */
export function compareContent(slug: CompareSlug, locale: Locale): CompareContent {
  const entry = COMPARE[slug];
  return (entry[locale] ?? entry.en) as CompareContent;
}

export function compareHref(locale: Locale, slug: CompareSlug): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "");
  const path = locale === "zh" ? `vs/${slug}` : `en/vs/${slug}`;
  return `${base}/${path}/`;
}

/** 首页竞品表里的名字 → 对比页。四种语言里竞品名都是同一串拉丁字符，所以按名字映射即可。 */
export const COMPARE_SLUG_BY_NAME: Record<string, CompareSlug> = {
  CleanMyMac: "cleanmymac",
  DaisyDisk: "daisydisk",
  PureMac: "puremac",
  "Mole CLI (tw93)": "mole",
  "mac-cleaner-cli 等开源 CLI": "mole",
};
