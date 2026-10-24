#!/usr/bin/env python3
# 盘心扫描读数收尾：`已读 %3$@` 撤掉（同一屏已有「已读 x / y · 只读」），换成样稿那句。
import os

RES = "/tmp/dw-v19/Sources/DiskCleaner/Resources"
OLD_KEY = "已量 %1$d/%2$d 处 · 已读 %3$@"
NEW_KEY = "已量 %1$d/%2$d 处 · 这一圈还没量完"
VALS = {
    "de": "%1$d/%2$d Orte gemessen · dieser Ring ist noch nicht fertig",
    "en": "Measured %1$d/%2$d places · this ring isn't finished yet",
    "es": "Medidos %1$d/%2$d lugares · este anillo aún no está completo",
    "fr": "%1$d/%2$d endroits mesurés · ce cercle n'est pas terminé",
    "ja": "%1$d/%2$d カウント済み · このリングはまだ途中です",
    "ko": "%1$d/%2$d 측정 · 이 링은 아직 끝나지 않았음",
    "pt-BR": "%1$d/%2$d locais medidos · este anel ainda não terminou",
    "ru": "Замерено %1$d/%2$d · этот круг ещё не завершён",
    "zh-Hant": "已量 %1$d/%2$d 處 · 這一圈還沒量完",
}

for lang, val in VALS.items():
    path = os.path.join(RES, lang + ".lproj", "Localizable.strings")
    lines = open(path, encoding="utf-8").read().splitlines(True)
    hit = 0
    out = []
    for ln in lines:
        if ln.startswith('"%s"' % OLD_KEY):
            out.append('"%s" = "%s";\n' % (NEW_KEY, val))
            hit += 1
        else:
            out.append(ln)
    assert hit == 1, "%s: %d hits" % (lang, hit)
    open(path, "w", encoding="utf-8").write("".join(out))
    print("%-7s 换 1" % lang)
