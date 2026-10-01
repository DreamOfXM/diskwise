# DiskWise 宣传页

`website/` 是 DiskWise 的产品宣传单页（React 19 + Vite 7 + Tailwind v4 + TanStack Router，纯深色设计）。

## 本地开发

```bash
cd website
pnpm install
pnpm dev        # http://localhost:5173/diskwise/
```

## 构建与预览

```bash
pnpm build      # 产物输出到 website/dist
pnpm preview    # 本地预览构建产物
```

## 改文案

全部产品事实、竞品调研结论、推广策略集中在 `src/data/site.ts`，改文案只动这一个文件；
区块组件（Hero / Differentiators / Competitors / Features / Install / GrowthPlan / Faq）在 `src/components/` 下。

## 部署

推送到 main 后 `.github/workflows/website.yml` 会自动构建并发布到 GitHub Pages
（需在仓库 Settings → Pages 把 Source 设为 **GitHub Actions**）。
站点地址：`https://dreamofxm.github.io/diskwise/`，发布后建议填入仓库 About 的 website 字段。

`vite.config.ts` 的 `base` 默认为 `/diskwise/`（GitHub Pages 项目站路径）；若绑定自定义域名，改为 `"/"`。
