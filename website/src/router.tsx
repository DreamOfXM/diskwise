/**
 * TanStack Router 实例。
 *
 * 路由约定：
 * - 页面文件放 src/routes/，用 createFileRoute 定义
 * - src/routeTree.gen.ts 由 Vite 插件（@tanstack/router-plugin）在 dev/build 时自动更新（勿手改）
 * - 根布局见 src/routes/__root.tsx；首页占位见 src/routes/index.tsx（须整体替换）
 */
import { QueryClient } from '@tanstack/react-query';
import { createRouter } from '@tanstack/react-router';
import { routeTree } from './routeTree.gen';

export const getRouter = () => {
  const queryClient = new QueryClient();

  const router = createRouter({
    routeTree,
    // 站点部署在 GitHub Pages 项目路径 /diskwise/ 下，路由必须感知这个 base，
    // 否则 /en/ 会被当成 404 兜底回中文首页
    basepath: import.meta.env.BASE_URL.replace(/\/$/, ""),
    context: { queryClient },
    scrollRestoration: true,
    defaultPreloadStaleTime: 0,
  });

  return router;
};
