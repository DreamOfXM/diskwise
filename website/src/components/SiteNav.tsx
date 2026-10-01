import { useEffect, useRef, useState } from "react";
import { Check, ChevronDown, Github, Globe, HardDrive } from "lucide-react";
import { APP_STORE, READMES, REPO, RELEASES } from "@/data/site";
import { useContent, localeHref } from "@/locale";
import { LOCALES } from "@/data/content";

function LangSwitcher() {
  const { locale, t } = useContent();
  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (rootRef.current && !rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setOpen(false);
    };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  return (
    <div ref={rootRef} className="relative">
      <button
        type="button"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-label={t.footer.langLabel}
        title={t.footer.langLabel}
        onClick={() => setOpen((v) => !v)}
        className="flex h-8 items-center gap-1.5 rounded-lg border border-border/70 bg-card/60 px-2.5 text-muted-foreground transition hover:border-foreground/30 hover:text-foreground"
      >
        <Globe className="h-4 w-4" />
        <span className="text-xs font-medium">{LOCALES.find((l) => l.code === locale)?.label}</span>
        <ChevronDown
          className={`h-3 w-3 transition-transform duration-200 ${open ? "rotate-180" : ""}`}
        />
      </button>

      {open && (
        <div
          role="listbox"
          className="absolute right-0 top-full z-50 mt-2 min-w-40 overflow-hidden rounded-xl border border-border/70 bg-popover/95 p-1 shadow-xl shadow-black/40 backdrop-blur-xl"
        >
          {LOCALES.map((l) => (
            <a
              key={l.code}
              role="option"
              aria-selected={l.code === locale}
              href={localeHref(l.path)}
              className={`flex items-center gap-2 rounded-lg px-3 py-2 text-sm transition ${
                l.code === locale
                  ? "font-medium text-foreground"
                  : "text-muted-foreground hover:bg-card hover:text-foreground"
              }`}
            >
              <span className="w-4 shrink-0">
                {l.code === locale && <Check className="h-3.5 w-3.5 text-sky-400" />}
              </span>
              {l.label}
            </a>
          ))}
        </div>
      )}
    </div>
  );
}

export function SiteNav() {
  const { t } = useContent();
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 12);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <header
      className={`fixed inset-x-0 top-0 z-50 transition-all duration-300 ${
        scrolled
          ? "border-b border-border/60 bg-background/80 backdrop-blur-xl"
          : "border-b border-transparent"
      }`}
    >
      <div className="mx-auto flex h-16 max-w-6xl items-center gap-6 px-6">
        <a href="#top" className="flex items-center gap-2 font-semibold tracking-tight">
          <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary/90 text-primary-foreground">
            <HardDrive className="h-4 w-4" />
          </span>
          DiskWise
        </a>
        <nav className="ml-auto hidden items-center gap-1 md:flex">
          {t.nav.map((n) => (
            <a
              key={n.href}
              href={n.href}
              className="rounded-lg px-3 py-2 text-sm text-muted-foreground transition hover:bg-card hover:text-foreground"
            >
              {n.label}
            </a>
          ))}
        </nav>
        <div className="ml-auto flex items-center gap-2 md:ml-3">
          <LangSwitcher />
          <a
            href={REPO}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-2 rounded-lg border border-border/70 bg-card/60 px-3 py-2 text-xs font-semibold transition hover:border-foreground/30"
          >
            <Github className="h-4 w-4" />
            {t.navStar}
          </a>
        </div>
      </div>
    </header>
  );
}

export function SiteFooter() {
  const { locale, t } = useContent();
  const footerLinks = [RELEASES, APP_STORE, REPO, READMES[locale] ?? READMES.zh];

  return (
    <footer className="border-t border-border/60 bg-card/30">
      <div className="mx-auto grid max-w-6xl gap-8 px-6 py-14 sm:grid-cols-[1.4fr_1fr]">
        <div>
          <div className="flex items-center gap-2 font-semibold tracking-tight">
            <span className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary/90 text-primary-foreground">
              <HardDrive className="h-4 w-4" />
            </span>
            DiskWise
          </div>
          <p className="mt-4 max-w-md text-sm leading-relaxed text-muted-foreground">{t.footer.desc}</p>
          <p className="mt-4 font-mono text-xs text-muted-foreground/70">{t.footer.meta}</p>
        </div>
        <div className="sm:justify-self-end">
          <h4 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">
            {t.footer.getLabel}
          </h4>
          <ul className="mt-4 space-y-2.5 text-sm">
            {t.footer.links.map((l, i) => (
              <li key={l.label}>
                <a className="transition hover:text-sky-400" href={footerLinks[i]} target="_blank" rel="noreferrer">
                  {l.label}
                </a>
              </li>
            ))}
          </ul>
        </div>
      </div>
      <div className="border-t border-border/40 py-5 text-center text-xs text-muted-foreground/70">
        {t.footer.copyright}
      </div>
    </footer>
  );
}
