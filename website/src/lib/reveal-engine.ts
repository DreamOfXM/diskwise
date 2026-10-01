// Reveal Engine：全局滚动渐入运行时（模板预置，业务代码请勿修改）
//
// 业务组件只需给元素加 class（reveal / reveal-up / reveal-left / reveal-right /
// reveal-zoom / animate-on-scroll）或 data-reveal 属性，本引擎自动完成：
// 1. 门控隐藏：隐藏样式由本文件运行时注入（<style> + html.reveal-ready 前缀），
//    引擎未运行时隐藏规则不存在，内容默认可见（fail-visible）。
// 2. 自动接管：MutationObserver 监听全文档，匹配元素自动送入共享
//    IntersectionObserver，入视口加 .visible 触发动画。无需 hook / ref / import。
//
// 交错延迟：data-reveal-delay="120"（毫秒，仅影响 transition-delay）。

const REVEAL_SELECTOR = ".reveal, .reveal-up, .reveal-left, .reveal-right, .reveal-zoom, .animate-on-scroll, [data-reveal]";
const READY_CLASS = "reveal-ready";
const VISIBLE_CLASS = "visible";
const STYLE_ID = "reveal-engine-style";

// 隐藏/显示规则全部由引擎注入，且以 html.reveal-ready 作用域门控：
// styles.css 被整文件重写也不影响；引擎不运行则没有任何元素被隐藏。
const ENGINE_CSS = `
html.${READY_CLASS} :is(${REVEAL_SELECTOR}) {
  opacity: 0;
  transition: opacity 0.6s ease-out, transform 0.6s ease-out;
  transition-delay: var(--reveal-delay, 0ms);
}
html.${READY_CLASS} :is(.reveal, .reveal-up, .animate-on-scroll, [data-reveal]:not([class*="reveal-"])) { transform: translateY(24px); }
html.${READY_CLASS} .reveal-left { transform: translateX(-32px); }
html.${READY_CLASS} .reveal-right { transform: translateX(32px); }
html.${READY_CLASS} .reveal-zoom { transform: scale(0.94); }
html.${READY_CLASS} :is(${REVEAL_SELECTOR}).${VISIBLE_CLASS} {
  opacity: 1;
  transform: none;
}
@media (prefers-reduced-motion: reduce) {
  html.${READY_CLASS} :is(${REVEAL_SELECTOR}) {
    opacity: 1;
    transform: none;
    transition: none;
  }
}
`;

function markVisible(el: Element): void {
  el.classList.add(VISIBLE_CLASS);
}

function applyDelay(el: Element): void {
  const delay = el.getAttribute("data-reveal-delay");
  if (delay && el instanceof HTMLElement) {
    const ms = Number.parseInt(delay, 10);
    if (Number.isFinite(ms) && ms > 0) {
      el.style.setProperty("--reveal-delay", `${Math.min(ms, 2000)}ms`);
    }
  }
}

function startEngine(): void {
  if (document.getElementById(STYLE_ID)) return; // 幂等，防 HMR 重复注入

  const styleEl = document.createElement("style");
  styleEl.id = STYLE_ID;
  styleEl.textContent = ENGINE_CSS;
  document.head.appendChild(styleEl);
  document.documentElement.classList.add(READY_CLASS);

  const revealObserver = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (entry.isIntersecting) {
          markVisible(entry.target);
          revealObserver.unobserve(entry.target);
        }
      }
    },
    { threshold: 0.1, rootMargin: "0px 0px -10% 0px" }
  );

  const observed = new WeakSet<Element>();
  const observeElement = (el: Element): void => {
    if (observed.has(el) || el.classList.contains(VISIBLE_CLASS)) return;
    observed.add(el);
    applyDelay(el);
    revealObserver.observe(el);
  };

  const scan = (root: ParentNode): void => {
    if (root instanceof Element && root.matches(REVEAL_SELECTOR)) observeElement(root);
    for (const el of root.querySelectorAll(REVEAL_SELECTOR)) observeElement(el);
  };

  scan(document);

  // React 渲染 / 路由切换后新增的节点自动接管
  const mutationObserver = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      for (const node of mutation.addedNodes) {
        if (node instanceof Element) scan(node);
      }
      if (mutation.type === "attributes" && mutation.target instanceof Element) {
        scan(mutation.target);
      }
    }
  });
  mutationObserver.observe(document.body, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class", "data-reveal"],
  });

  window.addEventListener("pagehide", () => {
    revealObserver.disconnect();
    mutationObserver.disconnect();
  });
}

export function initRevealEngine(): void {
  if (typeof window === "undefined" || typeof document === "undefined") return;
  try {
    if (typeof IntersectionObserver === "undefined") {
      // 不支持的环境：不隐藏任何内容（不加 ready class 即全部可见）
      return;
    }
    if (document.body) {
      startEngine();
    } else {
      document.addEventListener("DOMContentLoaded", () => startEngine(), { once: true });
    }
  } catch (e: unknown) {
    // 引擎自身异常时移除门控 class，确保所有内容可见
    document.documentElement.classList.remove(READY_CLASS);
    const message = e instanceof Error ? e.message : String(e);
    console.warn("[reveal-engine] 初始化失败，已降级为全部可见：", message);
  }
}
