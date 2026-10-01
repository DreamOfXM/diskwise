import {
  Accordion,
  AccordionContent,
  AccordionItem,
  AccordionTrigger,
} from "@/components/ui/accordion";
import { useContent } from "@/locale";

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

      <Accordion type="single" collapsible className="mt-8">
        {t.faq.items.map((item, i) => (
          <AccordionItem key={item.q} value={`item-${i}`} className="border-border/60">
            <AccordionTrigger className="text-left text-base font-medium hover:no-underline">
              {item.q}
            </AccordionTrigger>
            <AccordionContent className="text-sm leading-relaxed text-muted-foreground">
              {item.a}
            </AccordionContent>
          </AccordionItem>
        ))}
      </Accordion>
    </section>
  );
}
