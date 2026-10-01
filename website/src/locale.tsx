import { createContext, useContext } from "react";
import { CONTENT, type Locale, type SiteContent } from "@/data/content";

interface LocaleCtx {
  locale: Locale;
  t: SiteContent;
}

const Ctx = createContext<LocaleCtx>({ locale: "zh", t: CONTENT.zh });

export function LocaleProvider({
  locale,
  children,
}: {
  locale: Locale;
  children: React.ReactNode;
}) {
  return <Ctx.Provider value={{ locale, t: CONTENT[locale] }}>{children}</Ctx.Provider>;
}

export function useContent(): LocaleCtx {
  return useContext(Ctx);
}

// 语言切换目标地址：把构建 base（/diskwise/）与语言路径拼成完整 URL
export function localeHref(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "");
  return path ? `${base}/${path}/` : `${base}/`;
}
