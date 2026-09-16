#!/bin/bash
# ============================================================
# DiskWise（SwiftUI 原生版）一键打包
# 用法：bash build.sh                      （图标默认「晨雾」变体 a）
#       ICON_VARIANT=b bash build.sh       （换「午夜」深色图标，见 make_icon.swift）
# 产物：dist/DiskWise-<版本>.dmg（Apple Silicon，macOS 13+）
# 前提：Xcode 命令行工具（含 swift 编译器）即可，不需要完整 Xcode。
# 未签名版：首次打开用右键 → 打开；清空废纸篓需授权控制访达。
#
# 三道构建闸门，任一失败即不出包：
#   1. 双语覆盖率（少一条英文译文就构建失败，漏译只会静默退回中文）
#   2. swift run SelfTest（21 项逻辑自检）
#   3. 资源到位断言（知识库 + 图标 + 译文目录）
# ============================================================
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BUILD_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING="$BUILD_DIR/staging"

APP_NAME="DiskWise"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
VERSION="1.0"
# Bundle ID 不随产品名改：它是钥匙串、自动化授权、UserDefaults 的锚点，
# 改了等于让老用户的「允许控制访达」授权和皮肤购买记录全部作废。
BUNDLE_ID="com.dreamofxm.diskcleaner"
VOLNAME="DiskWise"
DMG_NAME="DiskWise-$VERSION.dmg"
RES_DIR="$ROOT_DIR/Sources/DiskCleaner/Resources"

echo "==> [1/6] 双语覆盖率对账"
cd "$ROOT_DIR"
swift "$ROOT_DIR/build_app/l10n_tool.swift" check | sed 's/^/    /'

echo "==> [2/6] 应用图标（参数化生成，无外部素材）"
ICONSET="$BUILD_DIR/AppIcon.iconset"
ICNS="$BUILD_DIR/AppIcon.icns"
if [ ! -f "$ICNS" ] || [ "$BUILD_DIR/make_icon.swift" -nt "$ICNS" ]; then
	rm -rf "$ICONSET"
	swift "$BUILD_DIR/make_icon.swift" "$ICONSET" "${ICON_VARIANT:-a}" | sed 's/^/    /'
	iconutil -c icns -o "$ICNS" "$ICONSET"
	echo "    AppIcon.icns：$(du -h "$ICNS" | cut -f1)（变体 ${ICON_VARIANT:-a}）"
else
	echo "    复用已有 AppIcon.icns（改过 make_icon.swift 会自动重生成）"
fi

echo "==> [3/6] release 编译 + 自检"
swift build -c release 2>&1 | tail -n 3
BIN="$ROOT_DIR/.build/release/DiskCleaner"
[ -x "$BIN" ] || { echo "错误：找不到编译产物 $BIN" >&2; exit 1; }
echo "    二进制：$(du -h "$BIN" | cut -f1)"
swift run SelfTest 2>&1 | tail -n 3

echo "==> [4/6] 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/DiskCleaner"
cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$RES_DIR/safety_db.json" "$APP_DIR/Contents/Resources/"
cp -R "$RES_DIR/en.lproj" "$APP_DIR/Contents/Resources/"
# 缓存清理页整页内容都来自这份知识库；丢了不会崩，但会静默变空白页
[ -f "$APP_DIR/Contents/Resources/safety_db.json" ] \
	|| { echo "错误：safety_db.json 没进 .app，缓存清理页会是空的" >&2; exit 1; }
# 图标丢了不报错，Dock 就退回那张通用白纸——正是这次要消灭的「裸打包」
[ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ] \
	|| { echo "错误：AppIcon.icns 没进 .app，Dock 会显示通用图标" >&2; exit 1; }
# 译文目录丢了不报错，只是英文界面整体退回中文——静默发布等于没做双语
[ -f "$APP_DIR/Contents/Resources/en.lproj/Localizable.strings" ] \
	|| { echo "错误：en.lproj/Localizable.strings 没进 .app，英文界面会退回中文" >&2; exit 1; }

cat > "$APP_DIR/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>DiskCleaner</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleLocalizations</key>
	<array>
		<string>zh-Hans</string>
		<string>en</string>
	</array>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSAppleEventsUsageDescription</key>
	<string>DiskWise asks Finder to empty the Trash. The app never deletes files permanently on its own.</string>
</dict>
</plist>
PLIST_EOF

# Dock / 权限弹窗里显示的名字：跟着界面语言走，不靠单一语言打包
mkdir -p "$APP_DIR/Contents/Resources/en.lproj" "$APP_DIR/Contents/Resources/zh-Hans.lproj"
cat > "$APP_DIR/Contents/Resources/en.lproj/InfoPlist.strings" <<EN_EOF
"CFBundleDisplayName" = "DiskWise";
"CFBundleName" = "DiskWise";
"NSAppleEventsUsageDescription" = "DiskWise asks Finder to empty the Trash. The app never deletes files permanently on its own.";
EN_EOF
cat > "$APP_DIR/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" <<ZH_EOF
"CFBundleDisplayName" = "DiskWise";
"CFBundleName" = "DiskWise";
"NSAppleEventsUsageDescription" = "「清空废纸篓」这一步由访达执行，需要你的授权。工具本身从不永久删除文件。";
ZH_EOF

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
codesign --force --deep -s - "$APP_DIR" 2>&1 | tail -n 1 || true
codesign -dv "$APP_DIR" 2>&1 | grep -E "Identifier|Signature" | sed 's/^/    /'

echo "==> [5/6] 组装 DMG 暂存目录"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cat > "$STAGING/README.txt" <<README_EOF
DiskWise v$VERSION (native SwiftUI, unsigned)
============================================================

[ What this is ]
A native macOS app — no Python, no local server, no ports.
It shows where your disk space went, explains every item
("what is this / what happens if I delete it / how do I get it back"),
and only ever moves things to the Trash. Undo anytime.
No network, no telemetry, no ads.

[ Install ]
1. Open this DMG.
2. Drag "DiskWise.app" into the Applications folder.
3. Eject the DMG.

[ First launch (unsigned, once only) ]
Right-click (or Control-click) the app in Applications -> Open -> Open.
Or: after double-click is blocked, go to
System Settings -> Privacy & Security -> "Open Anyway".

[ Emptying the Trash ]
That step is handed to Finder, which asks for automation permission the
first time. Click OK. (Change it later in
System Settings -> Privacy & Security -> Automation.)

[ Switch language ]
Skins page -> globe control -> English / 中文. Restart required.

[ Uninstall ]
Drag the app to the Trash. No leftovers, no background agents.

------------------------------------------------------------

DiskWise v$VERSION（SwiftUI 原生 · 未签名）
============================================================

【这是什么】
不依赖 Python、不起本地服务、没有端口——双击就是原生 App。
扫描占空间的东西，每一项解释「这是什么 / 删了会怎样 / 怎么恢复」，
删除只进废纸篓，随时撤销。不联网、无遥测、无广告。

【安装】
1. 双击打开本 DMG；
2. 把「DiskWise」拖进「应用程序」文件夹；
3. 推出 DMG。

【首次打开（未签名，只需一次）】
在「应用程序」里按住 Control 点按 App → 选「打开」→ 再点「打开」。
或：双击被拦后，到 系统设置 → 隐私与安全性 → 点「仍要打开」。

【清空废纸篓的授权】
“清空废纸篓”交给访达执行，首次点击时系统弹窗问一次，点「好」即可
（系统设置 → 隐私与安全性 → 自动化 里可改）。

【切换语言】
外观皮肤页 → 地球图标 → English / 中文，切换后需重启。

【卸载】
把 App 拖进废纸篓即可，无残留、无后台常驻。
README_EOF

echo "==> [6/6] 生成 DMG"
mkdir -p "$DIST_DIR"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DIST_DIR/$DMG_NAME"
echo "---- 完成 ----"
ls -lh "$DIST_DIR/$DMG_NAME"
shasum -a 256 "$DIST_DIR/$DMG_NAME"
