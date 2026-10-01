import { Eye, ShieldCheck, Sparkles, Trash2, type LucideIcon } from "lucide-react";
import { useContent } from "@/locale";

const ICONS: Record<string, LucideIcon> = {
  trash: Trash2,
  code: Sparkles,
  eye: Eye,
  shield: ShieldCheck,
};

export function Differentiators() {
  const { t } = useContent();

  return (
    <section id="why" className="mx-auto max-w-6xl px-6 py-20">
      <header className="max-w-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-400">
          {t.why.eyebrow}
        </p>
        <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
          {t.why.title}
        </h2>
      </header>

      <div className="mt-12 grid gap-5 sm:grid-cols-2">
        {t.differentiators.map((d) => {
          const Icon = ICONS[d.icon] ?? Sparkles;
          return (
            <article
              key={d.title}
              className="reveal-up group rounded-2xl border border-border/60 bg-card/50 p-6 transition duration-300 hover:-translate-y-1 hover:border-sky-400/40 hover:bg-card/80 hover:shadow-xl hover:shadow-sky-950/40"
            >
              <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-sky-400/12 text-sky-400 transition group-hover:bg-sky-400/20">
                <Icon className="h-5 w-5" />
              </div>
              <h3 className="mt-4 text-lg font-semibold tracking-tight">{d.title}</h3>
              <p className="mt-2 text-sm leading-relaxed text-muted-foreground">{d.desc}</p>
            </article>
          );
        })}
      </div>
    </section>
  );
}
