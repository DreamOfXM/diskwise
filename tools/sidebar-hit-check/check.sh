#!/bin/zsh
# 侧栏命中自检：把「画出来的字」和「听点击的格子」放到同一把尺上逐行对，报差值。
# 只旁听系统辅助功能 + 窗口截图，不依赖被测 App 里任何埋点 → 装好的正式版也能查。
# 何时跑：每次新系统 beta、或改过侧栏布局后，看「点上面选中下面」有没有回归。
# 前提：跑它的终端要有「辅助功能」+「屏幕录制」权限（要量别的窗口）。
# 用法：zsh tools/sidebar-hit-check/check.sh [App路径]   # 默认量 build_app/DiskWise.app
set -e
DIR="${0:A:h}"
REPO="${DIR:h:h}"
APP="${1:-$REPO/build_app/DiskWise.app}"
[ -d "$APP" ] || { echo "找不到 App：$APP"; exit 1; }

# 1) 备两个小工具（首次或源码更新后重编）
for t in axtree winsall; do
  { [ -x "$DIR/$t" ] && [ "$DIR/$t.swift" -ot "$DIR/$t" ]; } || swiftc -O "$DIR/$t.swift" -o "$DIR/$t"
done

# 2) 起 App（默认皮肤、跳过首启授权）
pkill -x DiskCleaner 2>/dev/null || true
sleep 1
open -n "$APP" --args -diskcleaner.firstRun.done YES >/dev/null 2>&1
sleep 7
PID=$(pgrep -x DiskCleaner | head -1)
[ -z "$PID" ] && { echo "App 没起来"; exit 1; }

# 3) 找主窗（高 >500），拿窗口号与窗口顶 y
LINE=$("$DIR/winsall" "$PID" | awk '$11+0>500 {print $2" "$5" "$7; exit}')
WIN=$(echo "$LINE" | cut -d' ' -f1)
WX=$(echo "$LINE" | cut -d' ' -f2)
WY=$(echo "$LINE" | cut -d' ' -f3)
[ -z "$WIN" ] && { echo "没找到主窗"; pkill -x DiskCleaner || true; exit 1; }
SHOT=/tmp/dw_sidebar_check.png
screencapture -x -o -l"$WIN" "$SHOT" 2>/dev/null

# 4) 命中框（只取侧栏那一列）
"$DIR/axtree" "$PID" $((WX+240)) > /tmp/dw_sidebar_ax.txt 2>/dev/null

# 5) 对账：像素亮带（画）vs AX 中心（格子）
WY="$WY" python3 - "$SHOT" <<'PY'
import sys,re,os,statistics
from PIL import Image
WY=float(os.environ['WY'])
im=Image.open(sys.argv[1]); W,H=im.size; px=im.load()
def rowfrac(i,thr,bright):
    n=0;s=0
    for x in range(24,400,2):
        r,g,b=px[x,i][:3]; lum=(r*299+g*587+b*114)/1000
        if (lum>thr if bright else lum<thr): n+=1
        s+=1
    return n/max(s,1)
def bands(thr,bright):
    out=[];i=120
    while i<H and len(out)<40:
        if rowfrac(i,thr,bright)>0.02:
            j=i
            while j+1<H and (rowfrac(j+1,thr,bright)>0.02 or (j+2<H and rowfrac(j+2,thr,bright)>0.02)): j+=1
            if j-i>=6: out.append(round((i+j)/4,1))  # 像素中点 /2 = 窗口顶下 pt
            i=j+1
        else: i+=1
    return out
b=bands(170,True)
if len(b)<3: b=bands(120,False)   # 浅色皮肤：暗字
rows=[]
for ln in open('/tmp/dw_sidebar_ax.txt'):
    m=re.search(r'AXButton 「(.+?)」.*中心 (\d+)',ln)
    if m and m.group(1).strip(): rows.append((m.group(1),float(m.group(2))-WY))
rows.sort(key=lambda r:r[1])
print("行              格子(pt)    画(pt)    差(pt)")
deltas=[]
for label,hit in rows:
    if not b: print(f"{label:<14}{'':>10}{hit:>9.1f}{'—':>9}"); continue
    cand=min(b,key=lambda p:abs(p-hit)); d=cand-hit
    if abs(d)<=50:
        deltas.append(d); print(f"{label:<14}{'':>10}{hit:>9.1f}{cand:>9.1f}{d:>+9.1f}")
    else:
        print(f"{label:<14}{'':>10}{hit:>9.1f}{'无对应':>9}")
if deltas:
    med=statistics.median(deltas); mx=max(abs(x) for x in deltas)
    print(f"\n对上 {len(deltas)}/{len(rows)} 行；中位差 {med:+.1f}pt，最大差 {mx:.1f}pt")
    if abs(med)<=3:
        print("→ 字和格子重合，无错位回归。")
    else:
        print(f"→ 错位约 {abs(med):.0f}pt：画出来的字比能按的格子低了这么多，"
              f"疑似标题栏让位被加了两遍（macOS 27 那个 bug 回来了）。")
else:
    print("\n→ 没量到可对比的行，检查权限/皮肤/窗口。")
PY

pkill -x DiskCleaner 2>/dev/null || true
