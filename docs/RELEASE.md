# 发布流程（Release）

一条命令出包，剩下的都是「怎么让这条命令有条件跑」。两条发行路线，两个产物：

| 路线 | 命令 | 产物 | 谁做公证 |
| --- | --- | --- | --- |
| 直链分发（GitHub Release / Homebrew） | `ARCH=universal NOTARIZE=1 bash build_app/build.sh` | `dist/DiskWise-<版本>-universal.dmg` | 我们自己送公证并钉票据 |
| Mac App Store | `CHANNEL=appstore ARCH=universal bash build_app/build.sh` | `dist/DiskWise-<版本>-universal-appstore.pkg` | 上传后 Apple 顺手做，我们不钉票据 |

两条线共用同一套构建闸门和同一份源码，区别只在**沙盒、签名身份、产物格式**三处。

---

## 1. build.sh 干了什么

| 步 | 做什么 | 失败会怎样 |
| --- | --- | --- |
| 1 | 双语覆盖率对账（`build_app/l10n_tool.swift check`） | 少一条英文译文就停，不会静默退回中文出包 |
| 2 | 现画 App 图标 → `AppIcon.icns` | 生成物，改样式改 `make_icon.swift`，别改图 |
| 3 | release 编译 + `SelfTest` 自检（27 项） | 任一 FAIL 不出包；通用包还要求两个切片各自过一遍 |
| 4 | 组装 `.app` + 资源到位断言 | 知识库 / 图标 / 译文 / 二维码少一个就停 |
| 5 | 签名（Developer ID 或 ad-hoc）+ `codesign --verify --strict` | 签名断了不出厂 |
| 6 | 组装发布物：直链包出 DMG，商店包出 `productbuild` 的 `.pkg` | — |
| 7 | 公证 + 钉票据（仅 `NOTARIZE=1` 的直链包） | 没身份 / 没凭据直接硬失败，不会出一个「以为公证了其实没有」的包；商店包这一步跳过，公证由 Apple 上传后自己做 |

架构开关：`ARCH=arm64`（默认，快）、`ARCH=x86_64`、`ARCH=universal`。
通用包走**两个 `--triple` 各编一次再 `lipo -create`**——`swift build --arch arm64 --arch x86_64`
需要 `xcbuild`，只有完整 Xcode 里有，命令行工具跑不了。

---

## 2. 签名

直链一张证书，商店两张——`.app` 和 `.pkg` 由不同的证书签，这是 Apple 证书分工表里写死的：

| 渠道 | `build.sh` 找的身份 | 找不到时 |
| --- | --- | --- |
| `CHANNEL=oss`（默认） | `Developer ID Application: ...`（签 `.app`） | 退回 ad-hoc（`codesign --sign -`），产物照出，用户首次打开要右键 → 打开 |
| `CHANNEL=appstore` | `Apple Distribution: ...`（签 `.app`）+ `Mac Installer Distribution: ...`（`productbuild` 签 `.pkg`） | 退回 ad-hoc，但这样的 `.pkg` 传不上去，只能本地验构建链 |

想强制走 ad-hoc 测回退路径：`SIGN_IDENTITY=none`。两边都带 `--options runtime --timestamp`
（hardened runtime + 安全时间戳），entitlements 各用各的文件（下一节）。

三种身份不能互相顶替：Developer ID 的包进不了商店，Apple Distribution 的包装不到商店外面，
而 `productbuild --sign` 只认 Installer 那张——拿 Apple Distribution 去签 `.pkg` 会直接失败。
拿证书的步骤（三种只是选的模板不同，同一份 CSR 可以复用给多张证书）：

1. 钥匙串访问 → 证书助理 → 从证书颁发机构请求证书 → 只存到磁盘（`.certSigningRequest`）；
   私钥留在钥匙串里，别把 CSR 提交进仓库。
2. developer.apple.com → Certificates, Identifiers & Profiles → Certificates → `+` →
   选 **Developer ID Application**（商店则选 **Apple Distribution** 和 **Mac Installer
   Distribution**）→ 上传 CSR → 下载 `.cer` → 双击装进登录钥匙串。
   门户那张列表是单选的，一张一次，商店两张要走两遍；**同一份 CSR 可以重复上传**，
   私钥不用重新生成。
3. 验一下。两类身份要用两条命令，`-p codesigning` 这个过滤器**看不到 Installer 身份**
   （Apple 打包文档专门提醒过），拿它去查 installer 证书会得到「没有」的错误结论：
   ```bash
   security find-identity -v -p codesigning   # Developer ID Application / Apple Distribution
   security find-identity -v                  # 再加一张：Mac Installer Distribution
   ```
   只有 CSR 是钥匙串访问的证书助理生成的，双击 `.cer` 才会把私钥和证书配成一条身份；
   私钥在钥匙串外（比如 openssl 生成的 `.key.pem`）就得先把 `.cer` + 私钥合成 `.p12` 再导入，
   否则证书装进去了、`find-identity` 里依然查不到。

### 两套 entitlements，各自为什么长这样

`build_app/entitlements.plist`（直链版）是**空的**，这是刻意的：这个 App 不进沙箱、不加载
第三方动态库、不注入代码、不用 JIT，hardened runtime 的几条默认限制一条都碰不到，开 flags
就够了。两个容易误加的键也别加回去——`com.apple.security.app-sandbox` 和
`com.apple.security.automation.apple-events` 是沙盒专用，在非沙盒包里写了不生效；「清空废纸篓」
的自动化授权走 `Info.plist` 的 `NSAppleEventsUsageDescription` + TCC 弹窗。「将来要加键，
先在这里写清为什么非加不可。」

`build_app/entitlements-appstore.plist`（商店版）三条，是实测出来的最小集
（另外两条 App ID 标识键不在仓库这份里，是构建期从描述文件里读出来追加的，见 4.2）：

| 键 | 少了会怎样 |
| --- | --- |
| `com.apple.security.app-sandbox` | 商店包必须有 |
| `com.apple.security.files.user-selected.read-write` | 授权面板选中的家目录读不到，删除也移不进废纸篓 |
| `com.apple.security.automation.apple-events` | 指挥访达清空废纸篓直接被 TCC 拒掉 |

一条网络权限都没有——这个 App 不联网，多给一条都是审核问题。
`com.apple.security.temporary-exception.files.home-relative-path.read-write` 这种「一步登天」
的豁免键**不能出现在商店包里**（审核不接受 temporary exception 绕过沙盒），所以商店版走的是
首启授权 + security-scoped bookmark，细节见 `docs/ARCHITECTURE.md` 的沙盒一节。

---

## 3. 公证（notarization）

> 本节只适用于直链包。商店包不在这条链路里——上传后 Apple 自己公证，我们既不用 SubmitRequest
> 也不钉票据（`build.sh` 在 `CHANNEL=appstore` 时跳过这一步并打印原因）。

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

## 4. 上 Mac App Store

商店路线比直链多四样东西：**Apple Distribution 证书**（签 `.app`）、**Mac Installer Distribution
证书**（签 `.pkg`）、一张 **Mac App Store 描述文件**、**App Store Connect 里那条 App 记录**。
构建链本身不碰账号——缺证书和描述文件也照样出 `.pkg`（退回 ad-hoc 签名），只是传不上去，
所以本地验构建不需要账号。

### 4.1 账号侧一次性准备（产物都不进仓库）

1. 证书：按第 2 节流程拿 **Apple Distribution** 和 **Mac Installer Distribution** 两张
   （同一份 CSR 可以复用，两张都要；Developer ID 是第三种，互相顶替不了）。
2. Identifiers → App ID `com.dreamofxm.diskcleaner` → 不用勾任何 Capability：不联网、
   不用推送、不用 Keychain 共享组。
3. Profiles → `+` → Distribution 组里选 **Mac App Store Connect**（不是它上面那格
   `App Store Connect`，那格是 iOS/iPadOS 的，选错的话下一步根本列不出 macOS 的 App ID）→
   选上面这个 App ID + **Apple Distribution 那张**证书（描述文件只绑签 `.app` 的证书，
   Installer 那张不参与）→ 下载 `.provisionprofile`。默认放
   `build_app/diskwise-appstore.provisionprofile`
   （`.gitignore` 已经挡掉了：描述文件里带着账号的 App ID 前缀和团队名，不该公开），
   换路径给 `PROVISION_PROFILE=<路径>`。
4. App Store Connect → 我的 App → 新建 macOS App，Bundle ID 选第 2 步那个，SKU 定了就别改。

### 4.2 出包并上传

```bash
CHANNEL=appstore ARCH=universal bash build_app/build.sh
# → dist/DiskWise-<版本>-universal-appstore.pkg
```

`build.sh` 在签名前把描述文件拷成 `Contents/embedded.provisionprofile`，再用
`productbuild --component … /Applications --sign "Mac Installer Distribution: …"` 打成 `.pkg`。
上传用 **Transporter**（把 `.pkg` 拖进去，勾「上传后校验」）；`altool --upload-app` 那条命令行
Apple 已经停更，别再写进脚本。

商店包的 entitlements 是**构建期从描述文件里派生**出来的，不是仓库里那份：
`com.apple.application-identifier` 和 `com.apple.developer.team-identifier` 得由 `.app` 自己声明
（TN3125：App Store 重签前先验「签名 + 描述文件是否配对」，macOS 上这条键带 `com.` 前缀，
iOS 才是不带前缀那个），值从描述文件读、Team ID 不进仓库，派生结果留在 `build_app/derived/`。
少了它签名照过、`--verify --strict` 照过，只有上传那关才暴露。

**这份包在本机跑不起来，是 Apple 的规则不是包坏了**：商店 profile 签的 App 一 exec 就被
SIGKILL（TN3125：「you can't run an App Store distribution signed app locally」）。
对照实验——同一份二进制同一个身份，把 App ID 那条 entitlement 去掉就能跑，所以别为了
「本机能双击」把它删了再上传。要验沙盒授权流就出 ad-hoc 那份（`SIGN_IDENTITY=none`），
要验用户真正会装到的那份就走 **TestFlight**（Apple 重签过的才跑得起来）。

上传前把包整个读一遍，别只看构建脚本最后那行「完成」：

```bash
pkgutil --check-signature dist/DiskWise-*-appstore.pkg   # 签署链是不是商店那张 installer 证书
pkgutil --expand-full dist/DiskWise-*-appstore.pkg /tmp/chk
A="$(find /tmp/chk -name DiskWise.app -print -quit)"     # 在 <bundle id>.pkg/Payload/ 下面
codesign --verify --strict --verbose=2 "$A"
codesign -d --entitlements :- "$A"                       # 三条沙盒键 + 两条 App ID 标识都在
```

要核对的是「entitlement 里的 App ID ↔ 描述文件授权的 App ID ↔ `CFBundleIdentifier`」三者一致，
不一致时签名依然有效，只有上传或运行才暴露。
注意 `spctl -a` 对商店 pkg 必然 rejected——Gatekeeper 只认 Developer ID，判 pkg 只能看
`pkgutil --check-signature` 的输出。

上传被拒「重复的 version + build 组合」时用 `BUILD_NUMBER=2` 重出——`CFBundleShortVersionString`
管对外版本号，`CFBundleVersion` 管这条对账，商店要求后者在同一条版本线上单调递增。

### 4.3 沙盒改造动了什么

商店包必须进沙盒，而这个 App 每一件事都发生在家目录里，所以改造集中在「到底拿得到哪些路径」。
原理写在 `docs/ARCHITECTURE.md` 的沙盒一节，这里是待办清单：

| 事项 | 结论 |
| --- | --- |
| 真实家目录 | 只能从 `getpwuid(getuid())->pw_dir` 取（`realHomeDir()`）。`NSHomeDirectory()` 和 `homeDirectoryForCurrentUser` 在沙盒里都会返回 `~/Library/Containers/<bundle id>/Data` |
| 首启授权 | 没有授权就停在授权页，侧边栏禁用，**不出任何扫描结果**。扫容器路径不会报错，只会给出一套看着很合理的错数字，这比崩掉难查得多 |
| 书签 | 只有把书签**解析回来的那个 URL** 才认 `startAccessingSecurityScopedResource()`；直接拿面板返回值调用会返回 false（实测） |
| Docker 页 | 不再 shell 出去调 CLI，沙盒里走子目录统计那条回退路径 |
| 卸载残留页 | `/Applications` 在沙盒里可枚举，一行没改 |
| 清空废纸篓 | 仍然指挥访达做，靠 `automation.apple-events` + TCC 弹窗 |
| 换机器 / 重新签名 | 书签解不开就清档回授权页；反馈页留了「重新授权」出口 |

### 4.4 提审前必须填对的东西

| 项 | 值 / 位置 | 为什么 |
| --- | --- | --- |
| 出口合规 | `Info.plist` 已写 `ITSAppUsesNonExemptEncryption=false` | 少了它每次上传都要手答问卷，漏答会卡在「等待出口合规信息」 |
| 隐私政策 URL | `docs/PRIVACY.md` 的公开页：`https://github.com/DreamOfXM/diskwise/blob/main/docs/PRIVACY.md` | 不能 404，所以这条要等那个提交推上去再填；口径和代码一致——不联网、不收集 |
| 数据收集声明 | Data Not Collected | App 不联网、不写分析；一旦选了收集就得逐项补标签 |
| 截图 | 16:10 一套通吃全部 Mac（1280×800 / 1440×900 / 2560×1600 / 2880×1800 四选一），真窗口截图 | 商店不要 13"/16" 分开的两套。Retina 下要 2560×1600 就把**内容区**设成 1280×**768**，按 800 设会算上标题栏截出 2560×1664 被判尺寸不符。用假家目录截（第 6 节那条命令），别把真实目录晒出去 |
| 年龄分级 | 「不受限的网页访问」选**否** | 那格问的是能不能打开任意 URL / 内嵌浏览器。本 App 只有 `NSWorkspace.open` 开自家固定链接和在访达里定位 `~/.Trash`，不算。选成「是」会把分级拉高，而且不会报错 |
| 字段都在哪儿 | 名称/副标题/类别/年龄分级在 **App 信息**；隐私政策 URL 和数据收集问卷在 **App 隐私**；描述/关键词/技术支持与营销 URL/版权/截图/构建版本在**版本页** | 隐私政策 URL 不在 App 信息页，页内搜「隐私」搜到的那格也不是要填的字段 |
| 权限用途文案 | `NSAppleEventsUsageDescription`（`Info.plist` 已有） | 控制访达清空废纸篓要用 |
| 付费墙 | `Channel.showsPricing = false`，不渲染 | 挂着「解锁」按钮却直接放行是审核指南 2.1 的明确拒点 |

---

## 5. CI

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

CI 只跑直链这条线（`CHANNEL` 保持默认 `oss`）。商店包不进 CI：描述文件不入库，上传又是
Transporter 的手动一步，自动化了等于把账号侧的东西搬进公开仓库的流水线。本地要复现同一条
链路就直接 `CHANNEL=appstore bash build_app/build.sh`。

---

## 6. 发布检查清单

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
   `.certSigningRequest`、`.provisionprofile`、App 专用密码。
5. 提交身份用 GitHub 的 noreply 邮箱，别把个人邮箱写进公开历史。
6. 推 tag → CI 出包 → Release 挂 DMG → 把 `DreamOfXM/homebrew-diskwise` 的 cask 版本和
   SHA256 钉成同一个值。
7. 走商店那条线时额外三项：`VERSION` / `BUILD_NUMBER` 这一对比上次上传的更大；**在本机真点一次
   授权面板**，确认授权页解开后总览页有数字、重启一次仍能读到（书签恢复那条路径只能真点验证）；
   第 4.4 节那张表逐条填完再提审。

---

## 7. 用户侧怎么验自己下的包

```bash
shasum -a 256 DiskWise-<版本>-universal.dmg          # 跟 Release 正文对
spctl --assess --type open --context context:primary-signature -vv DiskWise-<版本>-universal.dmg
codesign -dv --verbose=4 /Applications/DiskWise.app | grep -E "Authority|TeamIdentifier|Runtime"
lipo -archs /Applications/DiskWise.app/Contents/MacOS/DiskCleaner    # 应输出 x86_64 arm64
```
