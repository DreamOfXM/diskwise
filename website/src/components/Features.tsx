import { useContent } from "@/locale";

export function Features() {
  const { t } = useContent();

  return (
    <section id="features" className="mx-auto max-w-6xl px-6 py-20">
      <header className="max-w-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-emerald-400">
          {t.features.eyebrow}
        </p>
        <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
          {t.features.title}
        </h2>
        <p className="mt-4 text-base leading-relaxed text-muted-foreground">
          {t.features.intro}
        </p>
      </header>

      <div className="mt-12 grid gap-x-10 gap-y-8 sm:grid-cols-2 lg:grid-cols-3">
        {t.features.items.map((f, i) => (
          <div key={f.title} className="reveal-up group relative pl-10">
            <span className="absolute left-0 top-0 font-mono text-sm text-muted-foreground/60">
              {String(i + 1).padStart(2, "0")}
            </span>
            <span className="absolute left-0 top-7 h-px w-6 bg-border transition-all duration-300 group-hover:w-8 group-hover:bg-emerald-400/60" />
            <h3 className="text-base font-semibold tracking-tight">{f.title}</h3>
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{f.desc}</p>
          </div>
        ))}
      </div>
    </section>
  );
}
