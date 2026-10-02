// 构建后静态预渲染：把四语言首页渲成 HTML 源码，塞回各自入口的 <div id="root">。
// 浏览器仍然走 client render，这一步只服务不执行 JS 的抓取器（搜索引擎、AI 检索）。
// 判据：跑完后 dist/*/index.html 里 body 的文本长度应 ≈ 页面渲染后的文本长度。
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { renderToStaticMarkup } from "react-dom/server";
import { HomePage } from "@/components/HomePage";
import type { Locale } from "@/data/content";

const DIST = resolve(dirname(fileURLToPath(import.meta.url)), "..", "dist");

const ENTRIES: Record<Locale, string> = {
  zh: "index.html",
  en: "en/index.html",
  ja: "ja/index.html",
  ko: "ko/index.html",
};

const ROOT_SLOT = '<div id="root"></div>';

let failed = false;
for (const [locale, file] of Object.entries(ENTRIES) as [Locale, string][]) {
  const path = resolve(DIST, file);
  const html = readFileSync(path, "utf-8");
  if (!html.includes(ROOT_SLOT)) {
    console.error(`[prerender] ${file} 里没有空的 #root 插槽，跳过`);
    failed = true;
    continue;
  }
  // 预渲产物里的资源 URL 不带部署前缀（Vite 对 SSR 侧资源的做法），
  // 从入口 HTML 已经打好的资源引用反推 base 再补进去，否则源码里那张 GIF 是 404
  const ref = html.match(/(?:src|href)="([^"]+assets\/[^"]+)"/);
  const base = ref ? ref[1].slice(0, ref[1].lastIndexOf("assets/")) : "/";
  let markup = renderToStaticMarkup(<HomePage locale={locale} />).replaceAll(
    '"/assets/',
    `"${base}assets/`,
  );
  if (base !== "/" && markup.includes('"/assets/')) {
    console.error(`[prerender] ${file} 仍有未加 base(${base}) 的资源地址，中止`);
    failed = true;
    continue;
  }
  // 可见正文 = 去掉标签后的文本；抓取器拿到的就是这一段
  const text = markup.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
  writeFileSync(path, html.replace(ROOT_SLOT, `<div id="root">${markup}</div>`));
  console.log(`[prerender] ${file}: 静态正文 ${text.length} 字，HTML ${html.length} → ${html.length - ROOT_SLOT.length + markup.length} 字节`);
}
process.exit(failed ? 1 : 0);
