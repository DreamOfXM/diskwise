import viteReact from "@vitejs/plugin-react";
import tsConfigPaths from "vite-tsconfig-paths";
import { defineConfig } from "vite";
import { resolve } from "path";

/**
 * 预渲染专用构建配置（主构建配置见 vite.config.ts，那份是四入口 HTML）。
 *
 * 单独一份的原因：主配置里 rollupOptions.input 是四个 HTML、output 带 hash 文件名，
 * 直接加 --ssr 会把预渲染脚本也打成 assets/prerender-[hash].js，node 无法稳定执行。
 */
export default defineConfig({
  plugins: [viteReact(), tsConfigPaths()],
  build: {
    ssr: resolve(__dirname, "src/prerender.tsx"),
    outDir: ".prerender",
    emptyOutDir: true,
    minify: false,
    target: "node20",
  },
});
