import { ChevronDown } from "lucide-react";
import { useContent } from "@/locale";

// 用原生 details/summary 而不是手风琴组件：答案始终在 HTML 源码里，
// 抓取器（和不执行 JS 的检索）能读到全部问答，浏览器仍然原生折叠展示。
export function Faq() {
  const { t } = useContent();

  return (
    <section id="faq" className="mx-auto max-w-3xl px-6 py-20">
      <header>
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-400">
          {t.faq.eyebrow}
        </p>
        <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">{t.faq.title}</h2>
      </header>

      <div className="mt-8">
        {t.faq.items.map((item) => (
          <details key={item.q} className="group border-b border-border/60">
            <summary className="flex cursor-pointer list-none items-center justify-between gap-4 py-4 text-left text-base font-medium [&::-webkit-details-marker]:hidden">
              {item.q}
              <ChevronDown className="h-4 w-4 shrink-0 text-muted-foreground transition-transform duration-200 group-open:rotate-180" />
            </summary>
            <p className="pb-4 text-sm leading-relaxed text-muted-foreground">{item.a}</p>
          </details>
        ))}
      </div>
    </section>
  );
}
