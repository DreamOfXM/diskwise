import { Competitors } from "@/components/Competitors";
import { Differentiators } from "@/components/Differentiators";
import { Faq } from "@/components/Faq";
import { Features } from "@/components/Features";
import { Hero } from "@/components/Hero";
import { Install } from "@/components/Install";
import { SiteFooter, SiteNav } from "@/components/SiteNav";
import { StarCta } from "@/components/StarCta";
import type { Locale } from "@/data/content";
import { LocaleProvider } from "@/locale";

export function HomePage({ locale }: { locale: Locale }) {
  return (
    <LocaleProvider locale={locale}>
      <div id="top" className="min-h-screen bg-background text-foreground antialiased">
        <SiteNav />
        <main>
          <Hero />
          <Differentiators />
          <Competitors />
          <Features />
          <Install />
          <Faq />
          <StarCta />
        </main>
        <SiteFooter />
      </div>
    </LocaleProvider>
  );
}
