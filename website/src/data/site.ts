// DiskWise 宣传页链接常量（与语言无关）；全部文案见 src/data/content.ts
// 涨星推广路线属内部策略，不放对外页面：完整打法见仓库 plans/plan_2026-10-01_star-growth.md（不入库目录）。

export const REPO = "https://github.com/DreamOfXM/diskwise";
export const RELEASES = "https://github.com/DreamOfXM/diskwise/releases/latest";
// 钉死 /us/ 商店：应用目前只在美国区上架，无地区码链接会按访客所属商店解析，
// 中国区访客会被甩到商店首页。其它地区上架后可改回无地区码形式。
export const APP_STORE = "https://apps.apple.com/us/app/diskwise-storage-cleaner/id6813265402";
export const BREW_CMD = "brew install --cask dreamofxm/diskwise/diskwise";
// 反馈渠道与 README 保持同源：邮件 + GitHub Issue（中英文都行）
export const ISSUES = "https://github.com/DreamOfXM/diskwise/issues";
export const FEEDBACK_EMAIL = "hnyxgxm2009@163.com";
// 各语言 README（与仓库根目录文件一一对应）
export const READMES: Record<string, string> = {
  zh: `${REPO}/blob/main/README.zh-CN.md`,
  en: `${REPO}/blob/main/README.md`,
  ja: `${REPO}/blob/main/README.ja.md`,
  ko: `${REPO}/blob/main/README.ko.md`,
};
