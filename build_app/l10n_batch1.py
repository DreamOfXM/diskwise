#!/usr/bin/env python3
# 第 1 批（顶栏新鲜度 / 「这本账」小节头 / 盘心扫描读数）的 9 张译文表对账。
# 做两件事：删掉源码已不用的 `已读 %1$@ / %2$@`，在表尾补 8 条新 key。
import os, re, sys

RES = "/tmp/dw-v19/Sources/DiskCleaner/Resources"
DROP = '"已读 %1$@ / %2$@"'
HEAD = "// ── 第 1 批：顶栏量盘新鲜度 / 「这本账」小节头 / 盘心扫描读数（2026-10-22，8 条）──────\n"

# key 就是中文原文；顺序与 check 报缺的顺序一致。
NEW = {
    "de": [
        ("%1$d 天前", "vor %1$d Tagen"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d Kategorien · %2$d jetzt reinigbar"),
        ("上一轮量完于 %@", "Letzte vollständige Messung um %@"),
        ("今天", "Heute"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "%1$d/%2$d Orte gemessen · %3$@ gelesen"),
        ("昨天", "Gestern"),
        ("这本账", "Diese Bilanz"),
        ("量完 · %@", "Gemessen · %@"),
    ],
    "en": [
        ("%1$d 天前", "%1$d days ago"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d types · %2$d cleanable now"),
        ("上一轮量完于 %@", "Last full scan finished at %@"),
        ("今天", "Today"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "Measured %1$d/%2$d places · %3$@ read"),
        ("昨天", "Yesterday"),
        ("这本账", "This ledger"),
        ("量完 · %@", "Measured · %@"),
    ],
    "es": [
        ("%1$d 天前", "hace %1$d días"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d categorías · %2$d se pueden limpiar ya"),
        ("上一轮量完于 %@", "Última lectura completa a las %@"),
        ("今天", "Hoy"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "Medidos %1$d/%2$d · %3$@ leídos"),
        ("昨天", "Ayer"),
        ("这本账", "Este registro"),
        ("量完 · %@", "Medido · %@"),
    ],
    "fr": [
        ("%1$d 天前", "il y a %1$d jours"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d catégories · %2$d nettoyables maintenant"),
        ("上一轮量完于 %@", "Dernière mesure complète à %@"),
        ("今天", "Aujourd'hui"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "%1$d/%2$d mesurés · %3$@ lus"),
        ("昨天", "Hier"),
        ("这本账", "Ce relevé"),
        ("量完 · %@", "Mesuré · %@"),
    ],
    "ja": [
        ("%1$d 天前", "%1$d日前"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d 種 · %2$d 種はクリーン可"),
        ("上一轮量完于 %@", "前回の計測完了 %@"),
        ("今天", "今日"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "%1$d/%2$d カウント済み · %3$@ 読み取り"),
        ("昨天", "昨日"),
        ("这本账", "この内訳"),
        ("量完 · %@", "計測完了 · %@"),
    ],
    "ko": [
        ("%1$d 天前", "%1$d일 전"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d개 항목 · %2$d개는 지금 정리 가능"),
        ("上一轮量完于 %@", "이전 측정 완료 %@"),
        ("今天", "오늘"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "%1$d/%2$d 측정 · %3$@ 읽음"),
        ("昨天", "어제"),
        ("这本账", "이 내역"),
        ("量完 · %@", "측정 완료 · %@"),
    ],
    "pt-BR": [
        ("%1$d 天前", "há %1$d dias"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d categorias · %2$d podem ser limpas agora"),
        ("上一轮量完于 %@", "Última leitura completa às %@"),
        ("今天", "Hoje"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "Medidos %1$d/%2$d · %3$@ lidos"),
        ("昨天", "Ontem"),
        ("这本账", "Este extrato"),
        ("量完 · %@", "Medido · %@"),
    ],
    "ru": [
        ("%1$d 天前", "%1$d дн. назад"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d категорий · %2$d можно очистить сейчас"),
        ("上一轮量完于 %@", "Прошлый замер завершён в %@"),
        ("今天", "Сегодня"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "Замерено %1$d/%2$d · прочитано %3$@"),
        ("昨天", "Вчера"),
        ("这本账", "Этот отчёт"),
        ("量完 · %@", "Замерено · %@"),
    ],
    "zh-Hant": [
        ("%1$d 天前", "%1$d 天前"),
        ("%1$d 类 · %2$d 类现在能清", "%1$d 類 · %2$d 類現在能清"),
        ("上一轮量完于 %@", "上一輪量完於 %@"),
        ("今天", "今天"),
        ("已量 %1$d/%2$d 处 · 已读 %3$@", "已量 %1$d/%2$d 處 · 已讀 %3$@"),
        ("昨天", "昨天"),
        ("这本账", "這本帳"),
        ("量完 · %@", "量完 · %@"),
    ],
}

for lang, rows in NEW.items():
    path = os.path.join(RES, lang + ".lproj", "Localizable.strings")
    if not os.path.exists(path):
        sys.exit("no table: " + path)
    text = open(path, encoding="utf-8").read()
    kept = [ln for ln in text.splitlines(True) if not ln.startswith(DROP)]
    removed = len(text.splitlines()) - len(kept)
    if removed != 1:
        sys.exit("%s: expected to drop 1 line, dropped %d" % (lang, removed))
    body = "".join(kept)
    if not body.endswith("\n"):
        body += "\n"
    block = ""
    for key, val in rows:
        if re.search(r'^"%s" =' % re.escape(key), body, re.M):
            continue
        block += '"%s" = "%s";\n' % (key, val)
    if block:
        body += HEAD + block
    open(path, "w", encoding="utf-8").write(body)
    print("%-7s 删 %d 补 %d" % (lang, removed, block.count(';\n')))
