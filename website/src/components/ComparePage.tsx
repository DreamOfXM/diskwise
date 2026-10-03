import { ArrowLeft, ArrowRight, Check, ShieldAlert } from "lucide-react";
import { Install } from "@/components/Install";
import { SiteFooter, SiteNav } from "@/components/SiteNav";
import { StarCta } from "@/components/StarCta";
import type { Locale } from "@/data/content";
import { REPO } from "@/data/site";
import { compareContent, compareHref, type CompareSlug } from "@/data/compare";
import { LocaleProvider } from "@/locale";

export function ComparePage({ slug, locale }: { slug: CompareSlug; locale: Locale }) {
  const c = compareContent(slug, locale);
  const homeHref = `${import.meta.env.BASE_URL.replace(/\/$/, "")}/${locale === "zh" ? "" : `${locale}/`}`;

  return (
    <LocaleProvider locale={locale}>
      <div id="top" className="min-h-screen bg-background text-foreground antialiased">
        <SiteNav links={c.nav} homeHref={homeHref} />
        <main>
          <header className="mx-auto max-w-4xl px-6 pb-8 pt-28">
            <p className="text-xs font-semibold uppercase tracking-[0.18em] text-violet-400">
              {c.hero.eyebrow}
            </p>
            <h1 className="mt-4 text-4xl font-semibold tracking-tight sm:text-5xl">{c.hero.title}</h1>
            <p className="mt-5 text-lg leading-relaxed text-muted-foreground">{c.hero.sub}</p>
            <p className="mt-6 rounded-2xl border border-sky-400/25 bg-sky-400/[0.06] p-5 text-base leading-relaxed">
              {c.hero.verdict}
            </p>
            <div className="mt-7 flex flex-wrap items-center gap-3">
              <a
                href="#install"
                className="inline-flex items-center gap-2 rounded-xl bg-primary px-5 py-2.5 text-sm font-semibold text-primary-foreground transition hover:opacity-90"
              >
                {locale === "en" ? "Get DiskWise free" : "免费获取 DiskWise"}
              </a>
              <a
                href={REPO}
                target="_blank"
                rel="noreferrer"
                className="inline-flex items-center gap-2 rounded-xl border border-border/70 bg-card/60 px-5 py-2.5 text-sm font-semibold transition hover:border-foreground/30"
              >
                GitHub
              </a>
            </div>
          </header>

          <section className="mx-auto max-w-4xl px-6 pb-14">
            <div className="reveal rounded-2xl border border-border/60 bg-card/40 p-6">
              <h2 className="text-base font-semibold">{c.quickAnswer.q}</h2>
              <p className="mt-3 text-sm leading-relaxed text-muted-foreground">{c.quickAnswer.a}</p>
            </div>
          </section>

          <section id="table" className="mx-auto max-w-5xl px-6 pb-20">
            <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">
              {locale === "en" ? "Side by side" : "逐项对比"}
            </h2>
            <div className="mt-8 overflow-x-auto rounded-2xl border border-border/60">
              <table className="w-full min-w-[640px] text-left text-sm">
                <thead className="bg-card/80 text-xs uppercase tracking-wide text-muted-foreground">
                  <tr>
                    <th scope="col" className="px-5 py-4 font-medium">
                      {c.table.headers[0]}
                    </th>
                    <th scope="col" className="px-5 py-4 font-medium text-sky-300">
                      {c.table.headers[1]}
                    </th>
                    <th scope="col" className="px-5 py-4 font-medium">
                      {c.table.headers[2]}
                    </th>
                  </tr>
                </thead>
                <tbody className="divide-y divide-border/50">
                  {c.table.rows.map((r) => (
                    <tr key={r.dim} className="bg-card/20 align-top">
                      <th
                        scope="row"
                        className="w-36 px-5 py-4 text-left text-xs font-semibold text-foreground/80 sm:w-44"
                      >
                        {r.dim}
                      </th>
                      <td
                        className={`px-5 py-4 ${
                          r.edge === "ours"
                            ? "bg-sky-400/[0.05] text-foreground"
                            : "text-muted-foreground"
                        }`}
                      >
                        {r.ours}
                      </td>
                      <td
                        className={`px-5 py-4 ${
                          r.edge === "theirs"
                            ? "bg-amber-400/[0.05] text-foreground/90"
                            : "text-muted-foreground"
                        }`}
                      >
                        {r.theirs}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
            <p className="mt-4 text-xs text-muted-foreground/70">
              {c.updated} ·{" "}
              {c.sources.map((s) => (
                <a
                  key={s.href}
                  href={s.href}
                  target="_blank"
                  rel="noreferrer"
                  className="mr-3 underline underline-offset-2 transition hover:text-foreground"
                >
                  {s.label} ↗
                </a>
              ))}
            </p>
          </section>

          <section id="diff" className="mx-auto max-w-5xl px-6 pb-20">
            <div className="grid gap-10 lg:grid-cols-2">
              <div>
                <h2 className="text-2xl font-semibold tracking-tight">{c.differences.title}</h2>
                <div className="mt-6 space-y-4">
                  {c.differences.items.map((it) => (
                    <div key={it.t} className="rounded-xl border border-border/50 bg-card/40 p-5">
                      <h3 className="flex items-center gap-2 text-sm font-semibold text-sky-300">
                        <Check className="h-4 w-4 shrink-0" />
                        {it.t}
                      </h3>
                      <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{it.d}</p>
                    </div>
                  ))}
                </div>
              </div>
              <div>
                <h2 className="text-2xl font-semibold tracking-tight">{c.theirsStronger.title}</h2>
                <div className="mt-6 space-y-4">
                  {c.theirsStronger.items.map((it) => (
                    <div
                      key={it.t}
                      className="rounded-xl border border-amber-400/25 bg-amber-400/[0.05] p-5"
                    >
                      <h3 className="flex items-center gap-2 text-sm font-semibold text-amber-200/90">
                        <ShieldAlert className="h-4 w-4 shrink-0" />
                        {it.t}
                      </h3>
                      <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{it.d}</p>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </section>

          <section id="switch" className="mx-auto max-w-4xl px-6 pb-20">
            <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">
              {c.switchGuide.title}
            </h2>
            <p className="mt-3 text-sm leading-relaxed text-muted-foreground">
              {c.switchGuide.note}
            </p>
            <ol className="mt-7 space-y-4">
              {c.switchGuide.steps.map((s, i) => (
                <li key={i} className="flex gap-4 rounded-xl border border-border/50 bg-card/30 p-5">
                  <span className="flex h-7 w-7 shrink-0 items-center justify-center rounded-lg bg-primary/90 text-xs font-semibold text-primary-foreground">
                    {i + 1}
                  </span>
                  <span className="text-sm leading-relaxed text-muted-foreground">{s}</span>
                </li>
              ))}
            </ol>
          </section>

          <section id="faq" className="mx-auto max-w-3xl px-6 pb-20">
            <h2 className="text-2xl font-semibold tracking-tight sm:text-3xl">
              {locale === "en" ? "Questions" : "常见疑问"}
            </h2>
            <div className="mt-8 space-y-4">
              {c.faq.map((f) => (
                <div key={f.q} className="rounded-xl border border-border/50 bg-card/40 p-5">
                  <h3 className="text-sm font-semibold">{f.q}</h3>
                  <p className="mt-2.5 text-sm leading-relaxed text-muted-foreground">{f.a}</p>
                </div>
              ))}
            </div>
          </section>

          <Install />
          <StarCta />

          <section className="mx-auto max-w-4xl px-6 pb-20">
            <div className="flex flex-wrap items-center gap-4 rounded-2xl border border-border/60 bg-card/30 p-5 text-sm">
              <a
                href={homeHref}
                className="inline-flex items-center gap-2 text-muted-foreground transition hover:text-foreground"
              >
                <ArrowLeft className="h-4 w-4" />
                {c.backHome}
              </a>
              <span className="text-muted-foreground/40">·</span>
              <a
                href={compareHref(locale, c.otherCompare.slug)}
                className="inline-flex items-center gap-2 font-medium text-sky-300 transition hover:text-sky-200"
              >
                {c.otherCompare.label}
                <ArrowRight className="h-4 w-4" />
              </a>
            </div>
            <p className="mt-4 text-xs leading-relaxed text-muted-foreground/60">
              {c.disclaimer}
            </p>
          </section>
        </main>
        <SiteFooter />
        <FaqJsonLd slug={slug} locale={locale} />
      </div>
    </LocaleProvider>
  );
}

function FaqJsonLd({ slug, locale }: { slug: CompareSlug; locale: Locale }) {
  const c = compareContent(slug, locale);
  const data = {
    "@context": "https://schema.org",
    "@type": "FAQPage",
    mainEntity: c.faq.map((f) => ({
      "@type": "Question",
      name: f.q,
      acceptedAnswer: { "@type": "Answer", text: f.a },
    })),
  };
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data) }}
    />
  );
}
