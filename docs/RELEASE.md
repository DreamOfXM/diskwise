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

两条路线两张证书，`build.sh` 按 `CHANNEL` 决定去钥匙串里找哪一张：

| 渠道 | 找的身份 | 找不到时 |
| --- | --- | --- |
| `CHANNEL=oss`（默认） | `Developer ID Application: ...` | 退回 ad-hoc（`codesign --sign -`），产物照出，用户首次打开要右键 → 打开 |
| `CHANNEL=appstore` | `Apple Distribution: ...` | 退回 ad-hoc，但这样的 `.pkg` 传不上去，只能本地验构建链 |

想强制走 ad-hoc 测回退路径：`SIGN_IDENTITY=none`。两边都带 `--options runtime --timestamp`
（hardened runtime + 安全时间戳），entitlements 各用各的文件（下一节）。

直链分发只能用它自己的那种证书：**Developer ID Application**。Apple Distribution 签出来的
东西不能拿到 Mac App Store 外面装，反过来 Developer ID 的包也进不了商店——这两张不是
「新旧版本」关系，是两条渠道各自的入口。拿证书的步骤（换成另一种只是选择的类型不同）：

1. 钥匙串访问 → 证书助理 → 从证书颁发机构请求证书 → 只存到磁盘（`.certSigningRequest`）；
   私钥留在钥匙串里，别把 CSR 提交进仓库。
2. developer.apple.com → Certificates, Identifiers & Profiles → Certificates → `+` →
   选 **Developer ID Application**（商店则选 **Apple Distribution**）→ 上传 CSR →
   下载 `.cer` → 双击装进登录钥匙串。
3. 验一下：`security find-identity -v -p codesigning`，能看到
   `"Developer ID Application: <名字> (<TEAMID>)"` 就对了。

### 两套 entitlements，各自为什么长这样

`build_app/entitlements.plist`（直链版）是**空的**，这是刻意的：这个 App 不进沙箱、不加载
第三方动态库、不注入代码、不用 JIT，hardened runtime 的几条默认限制一条都碰不到，开 flags
就够了。两个容易误加的键也别加回去——`com.apple.security.app-sandbox` 和
`com.apple.security.automation.apple-events` 是沙盒专用，在非沙盒包里写了不生效；「清空废纸篓」
的自动化授权走 `Info.plist` 的 `NSAppleEventsUsageDescription` + TCC 弹窗。「将来要加键，
先在这里写清为什么非加不可。」

`build_app/entitlements-appstore.plist`（商店版）三条，是实测出来的最小集：

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

商店路线比直链多三样东西：**Apple Distribution 证书**、一张 **Mac App Store 描述文件**、
**App Store Connect 里那条 App 记录**。构建链本身不碰账号——缺描述文件也照样出 `.pkg`
（退回 ad-hoc 签名），只是传不上去，所以本地验构建不需要账号。

### 4.1 账号侧一次性准备（产物都不进仓库）

1. 证书：按第 2 节流程拿 **Apple Distribution**（跟 Developer ID 是两张，不能互相顶替）。
2. Identifiers → App ID `com.dreamofxm.diskcleaner` → 不用勾任何 Capability：不联网、
   不用推送、不用 Keychain 共享组。
3. Profiles → `+` → 模板选 **Mac App Store** → 选上面这个 App ID + 上面那张证书 →
   下载 `.provisionprofile`。默认放 `build_app/diskwise-appstore.provisionprofile`
   （`.gitignore` 已经挡掉了：描述文件里带着账号的 App ID 前缀和团队名，不该公开），
   换路径给 `PROVISION_PROFILE=<路径>`。
4. App Store Connect → 我的 App → 新建 macOS App，Bundle ID 选第 2 步那个，SKU 定了就别改。

### 4.2 出包并上传

```bash
CHANNEL=appstore ARCH=universal bash build_app/build.sh
# → dist/DiskWise-<版本>-universal-appstore.pkg
```

`build.sh` 在签名前把描述文件拷成 `Contents/embedded.provisionprofile`，再用
`productbuild --component … /Applications` 打成 `.pkg`。上传用 **Transporter**（把 `.pkg`
拖进去，勾「上传后校验」）；`altool --upload-app` 那条命令行 Apple 已经停更，别再写进脚本。

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
| 隐私政策 URL | App Store Connect 必填 | 不能 404，也不能指到仓库首页了事 |
| 数据收集声明 | Data Not Collected | App 不联网、不写分析；一旦选了收集就得逐项补标签 |
| 截图 | 13" 与 16" 各一张，真窗口截图 | 用假家目录截（第 6 节那条命令），别把真实目录晒出去 |
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
