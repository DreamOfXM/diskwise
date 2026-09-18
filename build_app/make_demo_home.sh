#!/bin/bash
# ============================================================
# 造一棵「演示用假家目录」，给 README 截图和界面自查用。
#
#   bash build_app/make_demo_home.sh /tmp/DiskWiseDemoHome
#   DISKWISE_HOME_SHIM=/tmp/DiskWiseDemoHome swift run DiskCleaner
#
# 为什么不用真的家目录截图：总览页会把 ~/Desktop、~/Documents
# 连同体积原样晒出去，那是隐私不是演示。
#
# 只写零 + 每个文件首个字节盖上不同标记：块分配是真的（占盘统计看得见），
# 内容哈希又是唯一的（不会被当成一整组重复文件）。
# 目标目录要么是空的、要么带本脚本留下的 .diskwise-demo 标记；
# 重跑只补少的文件，且从不删任何东西——所以没有误删别人数据的余地。
# ============================================================
set -euo pipefail

TARGET="${1:-/tmp/DiskWiseDemoHome}"

H="${TARGET}"
MARKER="$H/.diskwise-demo"

# 只认两种目录：全新的，和这个脚本以前造过的（靠标记文件认领）。
# 重跑是幂等的：mk 见文件就跳过，dup 只 cp 覆盖自己造的那几份。
if [ -d "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ] && [ ! -f "$MARKER" ]; then
	echo "错误：$TARGET 已有别的东西，且不是本脚本造的（缺 $MARKER）。换个空目录。" >&2
	exit 1
fi

echo "==> 在 $H 造演示数据（约 55GB 实际占盘）"
mkdir -p "$H"
: > "$MARKER"

# mk <文件> <MB>：写 MB 兆的零，再用首字节盖上唯一标记
n=0
mk() {
	local path="$1" mb="$2"
	mkdir -p "$(dirname "$path")"
	if [ -e "$path" ]; then return 0; fi
	dd if=/dev/zero of="$path" bs=1m count="$mb" 2>/dev/null
	n=$((n + 1))
	# 标记取「路径的校验和」而不是计数器：计数器在重跑时从 0 重新开始，
	# 补出来的新文件会跟首跑留下的旧文件撞进同一个标记，于是造出一对内容真相同的
	# 「假重复」（实测撞出一组 2.3GB 的，而重复文件页的截图正是拿这棵树拍的）。
	local tag
	tag=$(printf '%s' "${path#"$H"/}" | cksum | awk '{print $1}')
	printf '@%010d' "$tag" | dd of="$path" bs=1 count=10 conv=notrunc 2>/dev/null
	echo "    $(du -h "$path" | cut -f1)	${path#"$H"/}"
}

# dup <母本> <副本一> <副本二>：cp 出内容逐字节相同的副本——mk 会盖唯一标记，
# 用它做「重复文件」会一份都不重复。
dup() {
	local src="$1" a="$2" b="$3"
	mkdir -p "$(dirname "$a")" "$(dirname "$b")"
	cp "$src" "$a"; cp "$src" "$b"
	echo "    $(du -h "$a" | cut -f1)	x3  ${a#"$H"/}"
}

# touch <文件> <YYYYMMDDHHMM>：改出「很久没动」的年代感
old() {
	local path="$1" stamp="$2"
	if [ -e "$path" ]; then touch -t "$stamp" "$path"; fi
}

# app <名字> <包标识> <MB>：造一个真装了 App 的样子（有 Info.plist 才认得出包名）。
# 卸载残留页拿「已装 App」当基准，所以这几个必须和残留的包名对不上。
app() {
	local name="$1" bid="$2" mb="$3"
	local dir="$H/Applications/$name.app"
	mkdir -p "$dir/Contents/MacOS"
	if [ ! -f "$dir/Contents/Info.plist" ]; then
		cat > "$dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleExecutable</key><string>$name</string>
	<key>CFBundleIdentifier</key><string>$bid</string>
	<key>CFBundleName</key><string>$name</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
</dict></plist>
PLIST
	fi
	mk "$dir/Contents/MacOS/$name" "$mb"
	mk "$dir/Contents/Resources/assets.bin" $((mb / 3))
}

# ── 包管理器与构建缓存（缓存清理页）──
mk "$H/.npm/_cacache/index-v5/blob-00.bin" 1700
mk "$H/.gradle/caches/modules-2/files-2.1/android-all.jar" 2400
mk "$H/.m2/repository/com/example/platform/artifacts.jar" 1100
mk "$H/Library/Caches/Homebrew/download-cache.tar.gz" 1300
mk "$H/Library/Caches/Yarn/v6/npm-packages.bin" 700
mk "$H/Library/Caches/pip/http-v2/store.bin" 420
mk "$H/Library/Caches/com.alibaba.DingTalkMac/media-cache.bin" 880
mk "$H/Library/pnpm/store/v3/files.bin" 640
mk "$H/.npminstall_tarball/pkgs.tgz" 380
mk "$H/.nvm/.cache/bin/node-v20.bin" 460
mk "$H/.bun/install/cache/packages.bin" 520
mk "$H/.conda/pkgs/scipy-1.11.tar.bz2" 900

# ── Xcode 三件套 ──
mk "$H/Library/Developer/Xcode/DerivedData/WebApp-abc123/Build/Products/app.o" 1800
mk "$H/Library/Developer/Xcode/DerivedData/WebApp-abc123/Index/DataStore.idx" 1400
mk "$H/Library/Developer/Xcode/iOS DeviceSupport/16.4 (20E247)/Symbols.bin" 1800
mk "$H/Library/Developer/Xcode/Archives/2025-11-02/WebApp.xcarchive" 900
mk "$H/Library/Developer/CoreSimulator/Caches/dyld.bin" 700
mk "$H/Library/Application Support/MobileSync/Backup/00008030-001A/full.bin" 1600

# ── 国产 App 专区（按账号存放的那类路径）──
mk "$H/Library/Containers/com.tencent.xinWeChat/Data/Library/Caches/thumbnail.bin" 1200
mk "$H/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/wxid_demo1/Message/MessageTemp/photo-video.bin" 2100
mk "$H/Library/Containers/com.tencent.qq/Data/Library/Caches/qq-pic.bin" 640
mk "$H/Library/Containers/com.tencent.WeWork/Data/Library/Caches/wework.bin" 760

# ── Docker（未运行时的粗粒度回退：按容器目录子项列）──
mk "$H/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw" 4600
mk "$H/Library/Containers/com.docker.docker/Library/Preferences/settings.json" 4

# ── 崩溃转储与日志 ──
mk "$H/Library/Application Support/Google/Chrome/Crashpad/pending/report-1.dmp" 260
mk "$H/Library/Application Support/Google/Chrome/Crashpad/pending/report-2.dmp" 180
mk "$H/Library/Logs/DiagnosticReports/backupd-2026-08-11.ips" 240
mk "$H/Library/Logs/com.example.dailyclean/run.log" 320

# ── 用户目录：总览页的热点行 + 大文件页 ──
mk "$H/Movies/Screen Recording 2021-04-18 at 14.32.05.mov" 5600
mk "$H/Movies/Screen Recording 2026-03-02 at 09.14.22.mov" 2400
mk "$H/Downloads/ubuntu-24.04-desktop-amd64.iso" 2600
mk "$H/Downloads/design-assets-final.zip" 900
mk "$H/Documents/Reference/legacy-dataset.csv" 1600
mk "$H/Desktop/Working/Set/photos-export.tar" 900

# ── 重复文件：一份母本 + cp 出来的副本（首字节标记必须一致，否则测不出重复）──
mkdir -p "$H/Documents/Backups" "$H/Desktop" "$H/Pictures/RAW" "$H/Downloads"
mk "$H/Downloads/kitchen-renovation.zip" 380
dup "$H/Downloads/kitchen-renovation.zip" "$H/Documents/Backups/kitchen-renovation.zip" "$H/Desktop/kitchen-renovation.zip"
mk "$H/Pictures/RAW/import-batch-07.dng" 220
dup "$H/Pictures/RAW/import-batch-07.dng" "$H/Downloads/import-batch-07.dng" "$H/Downloads/import-batch-07 (copy).dng"
mk "$H/Desktop/Working/quarterly-report.pdf" 96
dup "$H/Desktop/Working/quarterly-report.pdf" "$H/Documents/Reports/quarterly-report.pdf" "$H/Downloads/quarterly-report(1).pdf"
mk "$H/Movies/family-clip-2019.mov" 640
dup "$H/Movies/family-clip-2019.mov" "$H/Desktop/family-clip-2019.mov" "$H/Documents/Backups/family-clip-2019.mov"
mk "$H/Downloads/installer-sdk-2.7.pkg" 480
dup "$H/Downloads/installer-sdk-2.7.pkg" "$H/Documents/Backups/installer-sdk-2.7.pkg" "$H/Desktop/installer-sdk-2.7.pkg"

# ── node_modules（开发机专项页）──
mk "$H/Projects/web-dashboard/node_modules/.cache/bundle.bin" 2800
mk "$H/Projects/admin-console/node_modules/.cache/bundle.bin" 1400
mk "$H/Projects/mobile-app/node_modules/.cache/bundle.bin" 600
for p in web-dashboard admin-console mobile-app; do
	printf '{"name":"%s","version":"1.0.0"}\n' "$p" > "$H/Projects/$p/package.json"
done

# ── 很久没动：把年代推到上个十年 ──
old "$H/Movies/Screen Recording 2021-04-18 at 14.32.05.mov" 202104181432
old "$H/Downloads/ubuntu-24.04-desktop-amd64.iso" 202209120815
old "$H/Documents/Reference/legacy-dataset.csv" 201911031720
old "$H/Downloads/kitchen-renovation.zip" 202007261130
old "$H/Desktop/Working/Set/photos-export.tar" 201805091955

# ── 已装 App（演示树内的 /Applications：总览页那一行 + 残留页的基准）──
app "Demo Notes" com.demo.notes 780
app "PixelForge" com.pixelforge.editor 1450
app "SamplePlayer" com.sample.player 620
app "TermDeck" com.termside.termdeck 340

# ── 卸载残留：App 没了、数据还在的那些包名 ──
mk "$H/Library/Application Support/com.example.legacyeditor/data.bin" 420
mk "$H/Library/Application Support/com.oldapp.filemagnet/state.bin" 260
mk "$H/Library/Preferences/com.example.legacyeditor.plist" 4
mk "$H/Library/Saved Application State/com.oldapp.filemagnet.savedState/window.bin" 90
mk "$H/Library/Caches/com.example.legacyeditor/tiles.bin" 300

# ── 废纸篓（Trash 页 + 环形图一角）──
mk "$H/.Trash/old-build-artifacts.zip" 620
mk "$H/.Trash/2023-invoices-scan.pdf" 340
mk "$H/.Trash/duplicate-exports" 260

# ── 读不动的目录（总览页「只有管理员能读」那一行）──
# 环形图旁边那行「没量到的是谁的地盘」只在真撞上 EACCES 时才出现，而假家目录
# 整棵都属于当前用户——不造这一格，这条说明在截图里就是结构性拍不到的。
# 权限只收在目录本身：里面的体积因此不进统计，跟真机上的行为一致。
locked="$H/Desktop/locked-admin-only"
mkdir -p "$locked"
chmod 700 "$locked"          # 重跑时先开回来，否则 mk 看不见里面那个文件会再写一遍
mk "$locked/system-data.bin" 512
chmod 000 "$locked"

# 末尾那格读不动的目录会让 du 报一句 Permission denied——正是要的效果，别说成脚本坏了
echo "---- 完成：$(du -sh "$H" 2>/dev/null | cut -f1)，共 $n 个文件 ----"
echo "跑起来看（不带 DISKWISE_DEMO_USAGE 也行，假家目录自带 96:16 这档容量）："
echo "    DISKWISE_HOME_SHIM=\"$H\" DISKWISE_DEMO_USAGE=96:16 swift run DiskCleaner"
