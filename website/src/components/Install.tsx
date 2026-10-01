import { useState } from "react";
import { Check, Copy, Download, Apple, Terminal } from "lucide-react";
import { APP_STORE, BREW_CMD, RELEASES } from "@/data/site";
import { useContent } from "@/locale";

const CHANNEL_ICONS = [Terminal, Download, Apple];
const CHANNEL_HREFS = [null, RELEASES, APP_STORE];

export function Install() {
  const { t } = useContent();
  const [copied, setCopied] = useState(false);

  const copyBrew = async () => {
    try {
      await navigator.clipboard.writeText(BREW_CMD);
      setCopied(true);
      setTimeout(() => setCopied(false), 1800);
    } catch {
      setCopied(false);
    }
  };

  return (
    <section id="install" className="mx-auto max-w-6xl px-6 py-20">
      <header className="max-w-2xl">
        <p className="text-xs font-semibold uppercase tracking-[0.18em] text-sky-400">
          {t.install.eyebrow}
        </p>
        <h2 className="mt-3 text-3xl font-semibold tracking-tight sm:text-4xl">
          {t.install.title}
        </h2>
        <p className="mt-4 text-sm text-muted-foreground">{t.install.sub}</p>
      </header>

      <div className="mt-10 grid gap-5 md:grid-cols-3">
        {t.install.channels.map((c, i) => {
          const Icon = CHANNEL_ICONS[i];
          const href = CHANNEL_HREFS[i];
          return (
            <div
              key={c.name}
              className="flex flex-col rounded-2xl border border-border/60 bg-card/50 p-6 transition hover:border-sky-400/40 hover:bg-card/80"
            >
              <div className="flex items-center gap-3">
                <div className="flex h-9 w-9 items-center justify-center rounded-lg bg-sky-400/12 text-sky-400">
                  <Icon className="h-4.5 w-4.5" />
                </div>
                <h3 className="font-semibold tracking-tight">{c.name}</h3>
              </div>
              <p className="mt-3 flex-1 text-sm leading-relaxed text-muted-foreground">{c.desc}</p>

              {href ? (
                <a
                  href={href}
                  target="_blank"
                  rel="noreferrer"
                  className="mt-5 inline-flex items-center justify-center gap-1.5 rounded-lg bg-primary/90 px-3 py-2.5 text-xs font-semibold text-primary-foreground transition hover:bg-primary active:scale-[0.98]"
                >
                  {c.action}
                </a>
              ) : (
                <button
                  type="button"
                  onClick={copyBrew}
                  className="mt-5 flex items-center gap-2 rounded-lg border border-border/70 bg-background/60 px-3 py-2.5 font-mono text-xs transition hover:border-sky-400/50"
                >
                  <span className="truncate">{c.action}</span>
                  <span className="ml-auto shrink-0 text-muted-foreground">
                    {copied ? (
                      <Check className="h-3.5 w-3.5 text-emerald-400" />
                    ) : (
                      <Copy className="h-3.5 w-3.5" />
                    )}
                  </span>
                </button>
              )}
            </div>
          );
        })}
      </div>
    </section>
  );
}
