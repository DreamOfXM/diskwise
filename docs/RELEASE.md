# 发布流程（Release）

一条命令出包，剩下的都是「怎么让这条命令有条件跑」。产物只有一个：`dist/DiskWise-<版本>-universal.dmg`。

```bash
ARCH=universal NOTARIZE=1 bash build_app/build.sh
```

---

## 1. build.sh 干了什么

| 步 | 做什么 | 失败会怎样 |
| --- | --- | --- |
| 1 | 双语覆盖率对账（`build_app/l10n_tool.swift check`） | 少一条英文译文就停，不会静默退回中文出包 |
| 2 | 现画 App 图标 → `AppIcon.icns` | 生成物，改样式改 `make_icon.swift`，别改图 |
| 3 | release 编译 + `SelfTest` 自检（21 项） | 任一 FAIL 不出包；通用包还要求两个切片各自过一遍 |
| 4 | 组装 `.app` + 资源到位断言 | 知识库 / 图标 / 译文 / 二维码少一个就停 |
| 5 | 签名（Developer ID 或 ad-hoc）+ `codesign --verify --strict` | 签名断了不出厂 |
| 6 | 生成 DMG | — |
| 7 | 公证 + 钉票据（仅 `NOTARIZE=1`） | 没身份 / 没凭据直接硬失败，不会出一个「以为公证了其实没有」的包 |

架构开关：`ARCH=arm64`（默认，快）、`ARCH=x86_64`、`ARCH=universal`。
通用包走**两个 `--triple` 各编一次再 `lipo -create`**——`swift build --arch arm64 --arch x86_64`
需要 `xcbuild`，只有完整 Xcode 里有，命令行工具跑不了。

---

## 2. 签名

`build.sh` 在钥匙串里找 `Developer ID Application: ...`：

- 找到 → `codesign --options runtime --timestamp --entitlements build_app/entitlements.plist`
- 没找到 → 退回 ad-hoc（`codesign --sign -`），产物照出，但用户首次打开要右键 → 打开
- 想强制 ad-hoc 测回退路径：`SIGN_IDENTITY=none`

证书只有一种能用：**Developer ID Application**（不是 Apple Distribution，也不是 App Store 的
Development 证书——那些签出来的包不能拿到 Mac App Store 外面装）。拿它的步骤：

1. 钥匙串访问 → 证书助理 → 从证书颁发机构请求证书 → 只存到磁盘（`.certSigningRequest`）；
   私钥留在钥匙串里，别把 CSR 提交进仓库。
2. developer.apple.com → Certificates, Identifiers & Profiles → Certificates → `+` →
   选 **Developer ID Application** → 上传 CSR → 下载 `.cer` → 双击装进登录钥匙串。
3. 验一下：`security find-identity -v -p codesigning`，能看到
   `"Developer ID Application: <名字> (<TEAMID>)"` 就对了。

### entitlements.plist 为什么是空的

这个 App 不进沙箱、不加载未签名的可执行代码、不用 JIT，所以 hardened runtime 下不需要任何
entitlement。`com.apple.security.app-sandbox` / `com.apple.security.automation.apple-events`
这类是沙箱专用键，加了也不生效。「清空废纸篓」的自动化授权走的是 `NSAppleEventsUsageDescription`
+ TCC 弹窗，跟 entitlement 无关。**将来要加键，先在这里写清为什么非加不可。**

---

## 3. 公证（notarization）

需要三样：Developer ID 身份（上一节）、Apple ID、**App 专用密码**
（appleid.apple.com → 登录与安全 → App 专用密码，不是账号密码）。

推荐把凭据存进钥匙串，一次即可，之后命令行里不再出现明文：

```bash
xcrun notarytool store-credentials diskwise \
    --apple-id 你的邮箱 --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
NOTARIZE=1 NOTARY_PROFILE=diskwise bash build_app/build.sh
```

也可以直接给环境变量：`APPLE_ID` / `APPLE_TEAM_ID` / `APP_SPECIFIC_PASSWORD`。
**这三样加证书密码都不许进仓库**，CI 上放 secrets。

`NOTARIZE=1` 这一段做的事：签 DMG → `notarytool submit --wait` → `stapler staple` →
`stapler validate` → `spctl --assess --type open --context context:primary-signature -vv`。
钉票据的意义：用户机器不联网也能验，证书将来过期了票据还在。

DMG 里那份 `README.txt` 的「首次打开」文案由 `SIGNED` 和 `NOTARIZE` 两个开关推出三种状态：
ad-hoc（未签名）、已签名但未公证、已签名且已公证——只有最后一种写「双击即可」，前两种都给
右键 → 打开。签名 ≠ 公证，缺票据的包照样被 Gatekeeper 拦，文案不能写反。

---

## 4. CI

`.github/workflows/release.yml`：打 `v*` tag 触发（也可手动跑一次只出构建产物）。
它只调同一个 `build.sh`，不另写一套打包逻辑。secrets 齐（下表五项）就走签名 + 公证，
缺任何一项就退回 ad-hoc 并在摘要里写明，构建本身不会失败。

| Secret | 内容 |
| --- | --- |
| `DEVELOPER_ID_CERT_P12` | 第 2 节那张证书导出的 `.p12`，base64 单行 |
| `CERT_PASSWORD` | 导出 `.p12` 时设的密码 |
| `APPLE_ID` | 开发者账号邮箱 |
| `APPLE_TEAM_ID` | 团队 ID |
| `APP_SPECIFIC_PASSWORD` | App 专用密码 |

tag 名必须等于 `build_app/build.sh` 里的 `VERSION`，否则第一步就对账失败——发出去的包版本号
写错是最难查的那种错。

---

## 5. 发布检查清单

1. `VERSION` 改了吗？DMG 文件名、`Info.plist` 的 `CFBundleShortVersionString` 都跟着它走。
2. README 里的截图还是当前界面吗？界面改过就得重截——用假家目录，别拿真 `~`：
   ```bash
   DISKWISE_HOME_SHIM=/tmp/dw_home DISKWISE_SHOTS=/tmp/dw_shots swift run DiskCleaner
   ```
3. 发布物自查：图标不是系统通用白纸、DMG 里的 `README.txt` 版本号和首次打开措辞跟实际签名状态
   一致（签了没公证 / 没签，文案不能写反）、Release 正文里的 SHA256 是**这一版**的。
4. 泄露扫描（仓库是公开的，push 之后收不回来）：
   ```bash
   git grep --cached -nI -e "/Users/" -e "<真实用户名>" -e "<邮箱>"
   ```
   路径出现在 `expandHome()` 这类通用代码里是正常的，逐条判断；顺手确认没有 `.p12`、
   `.certSigningRequest`、App 专用密码。
5. 提交身份用 GitHub 的 noreply 邮箱，别把个人邮箱写进公开历史。
6. 推 tag → CI 出包 → Release 挂 DMG → 把 `DreamOfXM/homebrew-diskwise` 的 cask 版本和
   SHA256 钉成同一个值。

---

## 6. 用户侧怎么验自己下的包

```bash
shasum -a 256 DiskWise-<版本>-universal.dmg          # 跟 Release 正文对
spctl --assess --type open --context context:primary-signature -vv DiskWise-<版本>-universal.dmg
codesign -dv --verbose=4 /Applications/DiskWise.app | grep -E "Authority|TeamIdentifier|Runtime"
lipo -archs /Applications/DiskWise.app/Contents/MacOS/DiskCleaner    # 应输出 x86_64 arm64
```
