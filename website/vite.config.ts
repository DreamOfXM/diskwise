import { TanStackRouterVite } from "@tanstack/router-plugin/vite";
import tailwindcss from "@tailwindcss/vite";
import viteReact from "@vitejs/plugin-react";
import { defineConfig } from "vite";
import tsConfigPaths from "vite-tsconfig-paths";
import { resolve } from "path";

/**
 * React + Vite 构建配置（多语言多页入口）。
 *
 * base 默认按 GitHub Pages 项目站路径（https://dreamofxm.github.io/diskwise/）生成，
 * 若绑定自定义域名或部署到根路径，把 base 改为 "/" 即可。
 * 四个语言入口：/（中文）、/en/、/ja/、/ko/，与 README 的四语一一对应。
 * 另加两张对比页（只做 zh / en，与商店元数据的语言覆盖一致）：/vs/cleanmymac/、/vs/daisydisk/。
 */
export default defineConfig({
  base: process.env.VITE_BASE ?? "/diskwise/",
  plugins: [tailwindcss(), TanStackRouterVite(), viteReact(), tsConfigPaths()],
  build: {
    outDir: "dist",
    assetsDir: "assets",
    emptyOutDir: true,
    rollupOptions: {
      input: {
        main: resolve(__dirname, "index.html"),
        en: resolve(__dirname, "en/index.html"),
        ja: resolve(__dirname, "ja/index.html"),
        ko: resolve(__dirname, "ko/index.html"),
        "vs-cleanmymac": resolve(__dirname, "vs/cleanmymac/index.html"),
        "vs-daisydisk": resolve(__dirname, "vs/daisydisk/index.html"),
        "en-vs-cleanmymac": resolve(__dirname, "en/vs/cleanmymac/index.html"),
        "en-vs-daisydisk": resolve(__dirname, "en/vs/daisydisk/index.html"),
      },
      output: {
        entryFileNames: "assets/[name]-[hash].js",
        chunkFileNames: "assets/[name]-[hash].js",
        assetFileNames: "assets/[name]-[hash][extname]",
      },
    },
  },
});
