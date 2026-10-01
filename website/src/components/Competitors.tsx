import { useContent } from "@/locale";

export function Competitors() {
  const { t } = useContent();

  return (
    <section id="market" className="mx-auto max-w-6xl px-6 py-20">
      <header className="max-w-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-violet-400">
          {t.market.eyebrow}
        </p>
        <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
          {t.market.title}
        </h2>
        <p className="mt-4 text-base leading-relaxed text-muted-foreground">
          {t.market.claimLabel}
          <span className="font-medium text-foreground">{t.positioning.claim}</span>
        </p>
      </header>

      {/* 表格（桌面） */}
      <div className="mt-10 hidden overflow-hidden rounded-2xl border border-border/60 md:block">
        <table className="w-full text-left text-sm">
          <thead className="bg-card/80 text-xs uppercase tracking-wide text-muted-foreground">
            <tr>
              {t.market.headers.map((h) => (
                <th key={h} className="px-5 py-4 font-medium">{h}</th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-border/50">
            {t.market.rows.map((c) => (
              <tr
                key={c.name}
                className={
                  c.ours
                    ? "bg-sky-400/[0.07] ring-1 ring-inset ring-sky-400/30"
                    : "bg-card/30 transition hover:bg-card/60"
                }
              >
                <td className="px-5 py-4">
                  <span className={c.ours ? "font-semibold text-sky-300" : "font-medium"}>
                    {c.name}
                  </span>
                </td>
                <td className="px-5 py-4 text-muted-foreground">{c.kind}</td>
                <td className="px-5 py-4 whitespace-nowrap text-muted-foreground">{c.stars}</td>
                <td className="px-5 py-4 whitespace-nowrap text-muted-foreground">{c.price}</td>
                <td className="px-5 py-4 text-muted-foreground">{c.strengths}</td>
                <td className="px-5 py-4 text-muted-foreground">{c.weaknesses}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {/* 卡片（移动端） */}
      <div className="mt-10 grid gap-4 md:hidden">
        {t.market.rows.map((c) => (
          <div
            key={c.name}
            className={
              c.ours
                ? "rounded-2xl border border-sky-400/40 bg-sky-400/[0.07] p-5"
                : "rounded-2xl border border-border/60 bg-card/50 p-5"
            }
          >
            <div className="flex items-baseline justify-between gap-3">
              <h3 className={c.ours ? "font-semibold text-sky-300" : "font-semibold"}>{c.name}</h3>
              <span className="text-xs text-muted-foreground">{c.kind}</span>
            </div>
            <dl className="mt-3 space-y-1.5 text-xs leading-relaxed text-muted-foreground">
              <div><dt className="inline font-medium text-foreground/80">{t.market.headers[2]}：</dt><dd className="inline">{c.stars}</dd></div>
              <div><dt className="inline font-medium text-foreground/80">{t.market.headers[3]}：</dt><dd className="inline">{c.price}</dd></div>
              <div><dt className="inline font-medium text-foreground/80">{t.market.headers[4]}：</dt><dd className="inline">{c.strengths}</dd></div>
              <div><dt className="inline font-medium text-foreground/80">{t.market.headers[5]}：</dt><dd className="inline">{c.weaknesses}</dd></div>
            </dl>
          </div>
        ))}
      </div>

      {/* 定位逻辑 */}
      <div className="mt-12 grid gap-4 sm:grid-cols-2">
        {t.positioning.logic.map(([title, body]) => (
          <div key={title} className="rounded-xl border border-border/50 bg-card/40 p-5">
            <h4 className="text-sm font-semibold text-violet-300">{title}</h4>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{body}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
