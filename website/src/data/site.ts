// DiskWise 宣传页链接常量（与语言无关）；全部文案见 src/data/content.ts
// 涨星推广路线属内部策略，不放对外页面：完整打法见仓库 plans/plan_2026-10-01_star-growth.md（不入库目录）。

export const REPO = "https://github.com/DreamOfXM/diskwise";
export const RELEASES = "https://github.com/DreamOfXM/diskwise/releases/latest";
// 无地区码商店链接：中美两区均已上架（2026-10-25 复核，两区商店版都是 1.7，比 DMG 的 2.0 慢一拍），
// 各区访客自动落到所属商店；若某区未上架，该区访客会被甩到商店首页，届时再钉死地区码。
export const APP_STORE = "https://apps.apple.com/app/id6813265402";
// cask 在主仓库的 Casks/diskwise.rb 里，Homebrew 按名字找不到它（那是 homebrew-* 仓库的规则），
// 所以 tap 必须先按 URL 跑一次；之后完全限定名照旧可用。
export const BREW_TAP = "brew tap DreamOfXM/diskwise https://github.com/DreamOfXM/diskwise";
export const BREW_INSTALL = "brew install --cask dreamofxm/diskwise/diskwise";
export const BREW_CMD = `${BREW_TAP} && ${BREW_INSTALL}`;
// 演示片：仓库与产品页都指向同一条 YouTube 视频，链接以视频 ID 为准
export const VIDEO = "https://www.youtube.com/watch?v=0RfXNwNdzFg";
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
