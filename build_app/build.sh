#!/bin/bash
# ============================================================
# DiskWise（SwiftUI 原生版）一键打包
#
# 用法：
#   bash build.sh                        默认：arm64 + 自动探测签名身份
#   ARCH=universal bash build.sh         arm64 + x86_64 通用包（两个 triple 各编一次再 lipo）
#   ICON_VARIANT=b bash build.sh         换浅底版图标（默认 a 深底冷光，见 make_icon.swift）
#   CHANNEL=appstore bash build.sh       商店版：进沙盒 + 出 .pkg + 找 Apple Distribution 签名
#                                        （收费展示是另一个开关，见 Sources/DiskCleaner/Product.swift）
#   NOTARIZE=1 bash build.sh             出包后送 Apple 公证并钉票据（需要下面的凭据，商店包不用）
#
# 签名身份：两个渠道两张证书，钥匙串里有对应那张就自动用——
# 直链分发找 "Developer ID Application: ..."，商店找 "Apple Distribution: ..."；
# 探测不到就退回 ad-hoc，产物照出，但用户首次打开要右键 → 打开，且商店包传不上去。
# 想强制 ad-hoc 用 SIGN_IDENTITY=none。
#
# 公证凭据（三选一，都不落盘进仓库）：
#   NOTARY_PROFILE=<name>        推荐：先跑一次
#                              xcrun notarytool store-credentials diskwise --apple-id ... --team-id ...
#   或 APPLE_ID + APPLE_TEAM_ID + APP_SPECIFIC_PASSWORD 三个环境变量
#   或 CI secrets：APPLE_ID / APPLE_TEAM_ID / APP_SPECIFIC_PASSWORD
#
# 前提：Xcode 命令行工具即可。注意 `swift build --arch arm64 --arch x86_64`
# 需要 xcbuild（只有完整 Xcode 里有），所以通用包走 --triple 两遍 + lipo。
#
# 构建闸门，任一失败即不出包：
#   1. 双语覆盖率（少一条英文译文就构建失败，漏译只会静默退回中文）
#   2. swift run SelfTest（27 项逻辑自检）
#   3. 资源到位断言（知识库 + 图标 + 译文目录 + 反馈二维码）
#   4. 通用包：两个切片都在，且 x86_64 那个真能跑起来
#   5. codesign --verify --strict（签名断了不能出厂）
# ============================================================
set -euo pipefail

BUILD_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$BUILD_DIR/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STAGING="$BUILD_DIR/staging"

APP_NAME="DiskWise"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
VERSION="1.3"
MIN_MACOS="13.0"
# Bundle ID 不随产品名改：它是钥匙串、自动化授权、UserDefaults 的锚点，
# 改了等于让老用户的「允许控制访达」授权和皮肤解锁记录全部作废。
BUNDLE_ID="com.dreamofxm.diskcleaner"
VOLNAME="DiskWise"
# 编译期开关 -DAPPSTORE：商店版进沙盒、出 .pkg、用 Apple Distribution 签名。
# 它不决定收费展示——那是 `Channel.showsPricing`，见 Sources/DiskCleaner/Product.swift。
CHANNEL="${CHANNEL:-oss}"
SWIFT_FLAGS=""
ARTIFACT_SUFFIX=""
ENTITLEMENTS="$BUILD_DIR/entitlements.plist"
# 上传被拒「重复的 version + build 组合」时，用 BUILD_NUMBER=2 重出一版
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
if [ "$CHANNEL" = "appstore" ]; then
	SWIFT_FLAGS="-Xswiftc -DAPPSTORE"
	ARTIFACT_SUFFIX="-appstore"
	ENTITLEMENTS="$BUILD_DIR/entitlements-appstore.plist"
fi

# ── 架构 ────────────────────────────────────────────────────────────────
# universal 时产物名带 -universal；arm64 保持老命名（历史下载链接不失效）。
ARCH="${ARCH:-arm64}"
case "$ARCH" in
	arm64)    ARCH_SUFFIX="" ;            ARCH_TRIPLE="arm64-apple-macos$MIN_MACOS" ;;
	x86_64)   ARCH_SUFFIX="-intel" ;      ARCH_TRIPLE="x86_64-apple-macos$MIN_MACOS" ;;
	universal) ARCH_SUFFIX="-universal" ; ARCH_TRIPLE="" ;;
	*) echo "错误：ARCH 只能是 arm64 / x86_64 / universal，当前是 '$ARCH'" >&2; exit 1 ;;
esac
DMG_NAME="DiskWise-$VERSION${ARCH_SUFFIX}${ARTIFACT_SUFFIX}.dmg"
PKG_NAME="DiskWise-$VERSION${ARCH_SUFFIX}${ARTIFACT_SUFFIX}.pkg"

RES_DIR="$ROOT_DIR/Sources/DiskCleaner/Resources"
# 二维码放 docs/contact：README 和 App 用同一张图，不复制两份。
# 运行时先查 Contents/Resources，查不到回落到这个仓库相对路径（见 FeedbackView）。
QR_SRC="$ROOT_DIR/docs/contact/qq-group.png"

echo "==> [1/7] 双语覆盖率对账"
cd "$ROOT_DIR"
swift "$ROOT_DIR/build_app/l10n_tool.swift" check | sed 's/^/    /'

echo "==> [2/7] 应用图标（参数化生成，无外部素材）"
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

# 按 triple 编一次，stdout 只回产物目录（编译进度走 stderr，否则被 $(...) 一起吞进来）
build_for_triple() {
	local triple="$1"
	swift build -c release --triple "$triple" $SWIFT_FLAGS 2>&1 | tail -n 2 >&2
	swift build --show-bin-path -c release --triple "$triple" 2>/dev/null | tail -n 1
}

echo "==> [3/7] release 编译（架构 $ARCH，渠道 $CHANNEL）"
BIN="$ROOT_DIR/.build/release/DiskCleaner"          # 进包的那个二进制
if [ -n "$ARCH_TRIPLE" ]; then
	SINGLE="$(build_for_triple "$ARCH_TRIPLE")"
	BIN="$SINGLE/DiskCleaner"
	[ -x "$BIN" ] || { echo "错误：找不到编译产物 $BIN" >&2; exit 1; }
	lipo -info "$BIN" | sed 's/^/    /'
	"$SINGLE/SelfTest" 2>&1 | tail -n 1 | sed 's/^/    /'
else
	# --arch 双值要 xcbuild（CLT 没有），所以两个 triple 各编一遍再手动合。
	ARM_BIN_DIR="$(build_for_triple "arm64-apple-macos$MIN_MACOS")"
	X86_BIN_DIR="$(build_for_triple "x86_64-apple-macos$MIN_MACOS")"
	ARM_BIN="$ARM_BIN_DIR/DiskCleaner"
	X86_BIN="$X86_BIN_DIR/DiskCleaner"
	for f in "$ARM_BIN" "$X86_BIN"; do
		[ -x "$f" ] || { echo "错误：通用包缺一刀，$f 不存在" >&2; exit 1; }
	done
	# 各自薄切片先自检：合完再验就查不出是哪一刀坏了
	"$ARM_BIN_DIR/SelfTest" 2>&1 | tail -n 1 | sed 's/^/    arm64   /'
	if X86_LOG="$("$X86_BIN_DIR/SelfTest" 2>&1)"; then
		printf '%s\n' "    x86_64  $(printf '%s' "$X86_LOG" | tail -n 1)"
	elif printf '%s' "$X86_LOG" | grep -q "Bad CPU type"; then
		echo "    x86_64  跳过自检：本机没装 Rosetta（CI 的 arm64 runner 上会跑）"
	else
		echo "错误：x86_64 切片自检没过，不能出厂" >&2
		printf '%s\n' "$X86_LOG" | tail -n 6 >&2
		exit 1
	fi
	lipo -create -output "$BUILD_DIR/DiskCleaner.universal" "$ARM_BIN" "$X86_BIN"
	BIN="$BUILD_DIR/DiskCleaner.universal"
	lipo -info "$BIN" | sed 's/^/    /'
	ARCHS_IN="$(lipo -archs "$BIN")"
	printf '%s\n' "$ARCHS_IN" | grep -qw arm64 \
		|| { echo "错误：合并后没有 arm64 切片，实际是 '$ARCHS_IN'" >&2; exit 1; }
	printf '%s\n' "$ARCHS_IN" | grep -qw x86_64 \
		|| { echo "错误：合并后没有 x86_64 切片，实际是 '$ARCHS_IN'" >&2; exit 1; }
fi
echo "    二进制：$(du -h "$BIN" | cut -f1)"

echo "==> [4/7] 组装 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/DiskCleaner"
cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$RES_DIR/safety_db.json" "$APP_DIR/Contents/Resources/"
cp -R "$RES_DIR/en.lproj" "$APP_DIR/Contents/Resources/"
cp "$QR_SRC" "$APP_DIR/Contents/Resources/qq-group.png"
# 缓存清理页整页内容都来自这份知识库；丢了不会崩，但会静默变空白页
[ -f "$APP_DIR/Contents/Resources/safety_db.json" ] \
	|| { echo "错误：safety_db.json 没进 .app，缓存清理页会是空的" >&2; exit 1; }
# 图标丢了不报错，Dock 就退回那张通用白纸——正是这次要消灭的「裸打包」
[ -f "$APP_DIR/Contents/Resources/AppIcon.icns" ] \
	|| { echo "错误：AppIcon.icns 没进 .app，Dock 会显示通用图标" >&2; exit 1; }
# 译文目录丢了不报错，只是英文界面整体退回中文——静默发布等于没做双语
[ -f "$APP_DIR/Contents/Resources/en.lproj/Localizable.strings" ] \
	|| { echo "错误：en.lproj/Localizable.strings 没进 .app，英文界面会退回中文" >&2; exit 1; }
# 反馈页没图不会崩，但只剩一行群号——用户找到人的入口不能这么静默丢掉
[ -f "$APP_DIR/Contents/Resources/qq-group.png" ] \
	|| { echo "错误：qq-group.png 没进 .app，反馈页的二维码会是空的" >&2; exit 1; }

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
	<string>$BUILD_NUMBER</string>
	<key>ITSAppUsesNonExemptEncryption</key>
	<false/>
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
	<string>$MIN_MACOS</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.utilities</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSHumanReadableCopyright</key>
	<string>DiskWise — Apache-2.0</string>
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
plutil -lint "$ENTITLEMENTS" >/dev/null

echo "==> [5/7] 签名"
# 两个渠道两张证书：直链分发要 Developer ID Application，商店要 Apple Distribution。
# 拿错证书签出来的东西传不上去，也装不到对应的地方。
if [ "$CHANNEL" = "appstore" ]; then
	IDENT_PATTERN="Apple Distribution:"
else
	IDENT_PATTERN="Developer ID Application:"
fi
# SIGN_IDENTITY=none 强制走 ad-hoc（用来测回退路径）
IDENTITY="${SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
	IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
		| awk -F'"' -v pat="$IDENT_PATTERN" 'index($2, pat) == 1 {print $2; exit}')" || true
fi
if [ "$IDENTITY" = "none" ]; then IDENTITY=""; fi

# 商店包：描述文件必须在签名之前就位，它把沙盒 entitlements 绑到 App ID 上。
PROFILE="${PROVISION_PROFILE:-$BUILD_DIR/diskwise-appstore.provisionprofile}"
if [ "$CHANNEL" = "appstore" ]; then
	if [ -f "$PROFILE" ]; then
		cp "$PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
		echo "    描述文件：$(basename "$PROFILE")（$(du -h "$APP_DIR/Contents/embedded.provisionprofile" | cut -f1)）"
	else
		echo "    没有描述文件（$PROFILE 不存在）——本地能跑，但这份包传不上 App Store Connect"
	fi
fi

SIGNED=0
if [ -n "$IDENTITY" ]; then
	SIGNED=1
	echo "    身份：$IDENTITY"
	# --deep 是 Apple 明确不推荐的写法；这个 .app 里没有嵌套代码，直接签整包。
	# hardened runtime + 安全时间戳是公证的硬门槛，少一个 notarytool 直接拒。
	codesign --force --options runtime --timestamp \
		--entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP_DIR"
else
	echo "    钥匙串里没有 $IDENT_PATTERN → ad-hoc 签名"
	if [ "$CHANNEL" = "appstore" ]; then
		echo "    沙盒照样生效（能本地验授权流），但这份包不能上传，只用于测试。"
	else
		echo "    产物照出，但用户首次打开要右键 → 打开；不能送公证。"
	fi
	codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi
codesign --verify --strict --verbose=2 "$APP_DIR" 2>&1 | tail -n 1 | sed 's/^/    /'
# 直链版的 entitlements 是空 dict，grep 不中会带着 set -e 把整个构建掀了，所以先落变量。
ENT_SUMMARY="$(plutil -p "$ENTITLEMENTS" | grep -E 'app-sandbox|user-selected|apple-events' || true)"
if [ -n "$ENT_SUMMARY" ]; then
	echo "$ENT_SUMMARY" | sed 's/^/    /'
else
	echo "    entitlements：空 dict（直链版 hardened runtime 不需要任何键）"
fi
codesign -dv --verbose=4 "$APP_DIR" 2>&1 \
	| grep -E "^(Identifier|Format|CodeDirectory)|Signature=|TeamIdentifier|Runtime" \
	| sed 's/^/    /'

echo "==> [6/7] 组装发布物"
mkdir -p "$DIST_DIR"
if [ "$CHANNEL" = "appstore" ]; then
	# 商店只收 .pkg（Transporter / altool 都不接 DMG），所以这一支不出 DMG，
	# 也不写 README.txt——那份首次打开说明是直链分发才有的东西。
	ARTIFACT="$DIST_DIR/$PKG_NAME"
	if [ "$SIGNED" = 1 ] && productbuild --component "$APP_DIR" /Applications \
			--sign "$IDENTITY" "$ARTIFACT" >/dev/null 2>&1; then
		echo "    pkg 已用商店证书签名"
	else
		productbuild --component "$APP_DIR" /Applications "$ARTIFACT"
		echo "    pkg 未签名（没有可用的 Installer 身份）：只能本地验授权流，不能上传"
	fi
	echo "    $PKG_NAME：$(du -h "$ARTIFACT" | cut -f1)"
else
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if [ "${NOTARIZE:-0}" = 1 ]; then
	# 敢提前写这行，是因为第 7 步在没身份/没凭据时会硬失败，不会出一个「写着公证其实没有」的包
	LAUNCH_EN='[ First launch ]
Double-click it. The build is signed by a Developer ID identity and notarized by
Apple, so Gatekeeper lets it open with no extra step.'
	LAUNCH_ZH='【首次打开】
双击即可。这个包用 Developer ID 证书签名并经 Apple 公证，Gatekeeper 不会拦。'
	HEADER_EN="signed + notarized"
	HEADER_ZH="已签名 · 已公证"
else
	# 签名不等于公证：从网上下来的包缺了票据照样被 Gatekeeper 拦，所以文案不能写反
	if [ "$SIGNED" = 1 ]; then
		HEADER_EN="signed, NOT notarized"
		HEADER_ZH="已签名 · 未公证"
	else
		HEADER_EN="unsigned"
		HEADER_ZH="未签名"
	fi
	LAUNCH_EN="[ First launch ($HEADER_EN) ]
Right-click (or Control-click) the app in Applications -> Open -> Open.
Or: after double-click is blocked, go to
System Settings -> Privacy & Security -> \"Open Anyway\"."
	LAUNCH_ZH="【首次打开（$HEADER_ZH，只需一次）】
在「应用程序」里按住 Control 点按 App → 选「打开」→ 再点「打开」。
或：双击被拦后，到 系统设置 → 隐私与安全性 → 点「仍要打开」。"
fi

cat > "$STAGING/README.txt" <<README_EOF
DiskWise v$VERSION (native SwiftUI, $HEADER_EN)
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

$LAUNCH_EN

[ Emptying the Trash ]
That step is handed to Finder, which asks for automation permission the
first time. Click OK. (Change it later in
System Settings -> Privacy & Security -> Automation.)

[ Switch language ]
Skins page -> globe control -> English / 中文. Restart required.

[ Uninstall ]
Drag the app to the Trash. No leftovers, no background agents.

------------------------------------------------------------

DiskWise v$VERSION（SwiftUI 原生 · $HEADER_ZH）
============================================================

【这是什么】
不依赖 Python、不起本地服务、没有端口——双击就是原生 App。
扫描占空间的东西，每一项解释「这是什么 / 删了会怎样 / 怎么恢复」，
删除只进废纸篓，随时撤销。不联网、无遥测、无广告。

【安装】
1. 双击打开本 DMG；
2. 把「DiskWise」拖进「应用程序」文件夹；
3. 推出 DMG。

$LAUNCH_ZH

【清空废纸篓的授权】
“清空废纸篓”交给访达执行，首次点击时系统弹窗问一次，点「好」即可
（系统设置 → 隐私与安全性 → 自动化 里可改）。

【切换语言】
外观皮肤页 → 地球图标 → English / 中文，切换后需重启。

【卸载】
把 App 拖进废纸篓即可，无残留、无后台常驻。
README_EOF

hdiutil create -volname "$VOLNAME" -srcfolder "$STAGING" -ov -format UDZO "$DIST_DIR/$DMG_NAME" >/dev/null
ARTIFACT="$DIST_DIR/$DMG_NAME"
echo "    $DMG_NAME：$(du -h "$ARTIFACT" | cut -f1)"
fi

echo "==> [7/7] 公证"
if [ "$CHANNEL" = "appstore" ]; then
	echo "    跳过：商店包由 Apple 上传后自己公证，我们 staple 是多余动作（钉了票据的 pkg 反而是拒点）"
	ART_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
elif [ "${NOTARIZE:-0}" != 1 ]; then
	if [ "$SIGNED" = 1 ]; then
		echo "    已签名但没送公证（要出双击即开的包：NOTARIZE=1 bash build.sh）"
	else
		echo "    跳过：ad-hoc 包送不了公证，先装 Developer ID 证书"
	fi
	ART_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
else
	[ "$SIGNED" = 1 ] || {
		echo "错误：公证需要 Developer ID Application 身份，现在只有 ad-hoc。" >&2
		echo "      先在 钥匙串访问 里建好证书，再重跑；或 export SIGN_IDENTITY=\"Developer ID Application: ...\"" >&2
		exit 1
	}
	# DMG 本身也要签，公证的是这个容器
	codesign --force --timestamp --sign "$IDENTITY" "$ARTIFACT"

	if [ -n "${NOTARY_PROFILE:-}" ]; then
		xcrun notarytool submit "$ARTIFACT" --keychain-profile "$NOTARY_PROFILE" --wait
	elif [ -n "${APPLE_ID:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
		xcrun notarytool submit "$ARTIFACT" \
			--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APP_SPECIFIC_PASSWORD" --wait
	else
		echo "错误：没有公证凭据。三选一：" >&2
		echo "      1) 存一次到钥匙串，之后只带 NOTARY_PROFILE：export NOTARY_PROFILE=diskwise" >&2
		echo "         xcrun notarytool store-credentials diskwise --apple-id 你的邮箱 --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx" >&2
		echo "      2) export APPLE_ID / APPLE_TEAM_ID / APP_SPECIFIC_PASSWORD（app 专用密码在 appleid.apple.com 建）" >&2
		echo "      3) CI 上把这三项配成 secrets" >&2
		exit 1
	fi

	xcrun stapler staple "$ARTIFACT"
	xcrun stapler validate "$ARTIFACT" 2>&1 | tail -n 1 | sed 's/^/    /'
	# 这一步就是用户双击时 Gatekeeper 走的那条判定
	spctl --assess --type open --context context:primary-signature -vv "$ARTIFACT" 2>&1 | sed 's/^/    /'
	ART_SHA="$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')"
fi

echo "---- 完成 ----"
ls -lh "$ARTIFACT"
echo "SHA256: $ART_SHA"
