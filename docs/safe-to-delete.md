# 这些占空间的东西，删了会怎样

macOS 上 80 个常见的占空间位置，每一条都写清楚三件事：它是什么、删掉会怎样、删错的代价。这就是 DiskWise 扫描时读的那份数据，不是宣传文案——App 里每一行旁边显示的就是这里的原文。

*What follows is the safety knowledge base DiskWise reads at scan time: 80 locations that eat disk space on macOS, each with what it is, what deleting it does, and what it costs if you were wrong. The table is in Chinese because that is the language of the source data; `Sources/DiskCleaner/Resources/safety_db.json` is the machine-readable original.*

代价分三级：

- **安全** — 删掉不影响任何功能，程序会自己重新生成。
- **重下** — 删掉要重新下载或重装才能回来，数据本身不丢。
- **不可恢复** — 删掉就真没了，重下也回不来。会话记录、历史对话属于这一级。

路径不存在时不会出现在扫描结果里，所以下面的条数不等于你机器上的条数。

## AI 编程工具留下的东西

Codex、Claude Code、Qoder、Ollama 这类工具会把缓存、运行日志和会话记录混在同一棵目录树下。日志删了没事，会话记录往往是历史对话仅存的一份——下面按这个区别列出来。

| 名称 | 路径 | 这是什么 | 删了会怎样 | 代价 |
| --- | --- | --- | --- | --- |
| ChatGPT 桌面版崩溃转储 | `~/Library/Application Support/Codex/Crashpad/pending` | ChatGPT 桌面版崩溃时生成的 .dmp 报告，只用于上报诊断（目录叫 Codex 是因为这个 App 的包名就是 com.openai.codex） | 删掉不影响任何功能<br>恢复：无需恢复；下次程序崩溃会自动生成新的报告 | **安全** |
| Qoder 崩溃转储 | `~/Library/Application Support/Qoder/Crashpad/pending` | Qoder 崩溃时生成的报告文件堆积 | 删掉不影响任何功能<br>恢复：无需恢复；下次程序崩溃会自动生成新的报告 | **安全** |
| [Ollama 模型](https://docs.ollama.com/) | `~/.ollama/models` | Ollama 拉取的大模型权重，单个模型常常几十 GB | 删掉的模型要重新联网下载才能再用<br>恢复：无需恢复；ollama pull 模型名 重新下载 | **重下** |
| [Codex CLI 运行时装机](https://developers.openai.com/codex/cli) | `~/.cache/codex-runtimes` | Codex CLI 自己下载的 Node 运行时与依赖 | 删掉后 codex 下次启动要重新拉一遍运行时<br>恢复：无需恢复；再次运行 codex 会自动装回 | **重下** |
| Qoder 运行日志 | `~/.qoder/logs` | Qoder 每次会话与后台任务的运行日志，用得越久堆得越大 | 删掉只影响事后翻日志排查问题，编辑器本身不受影响<br>恢复：无需恢复；下次启动自动重建 | **安全** |
| Qoder 会话记录 | `~/.qoder/projects` | Qoder 按项目保存的对话与任务记录（一个项目一个目录，单个 jsonl 能到几百 MB） | 删掉后这些项目里 Agent 的历史对话不可再查<br>恢复：无法恢复；历史对话只此一份 | **不可恢复** |
| [Codex 会话记录](https://developers.openai.com/codex/cli) | `~/.codex/sessions` | Codex CLI 按日期存下的会话回放记录，一轮对话一个 rollout-*.jsonl | 删掉后这些历史对话在 codex 里不可再查<br>恢复：无法恢复；历史对话只此一份 | **不可恢复** |
| [Codex 运行日志](https://developers.openai.com/codex/cli) | `~/.codex/log` | Codex CLI 终端界面写下的运行日志，用得越久堆得越大 | 删掉只影响事后翻日志排查问题，codex 本身不受影响<br>恢复：无需恢复；下次运行自动重新写入 | **安全** |
| [Codex 插件与市场检出](https://developers.openai.com/codex/cli) | `~/.codex/.tmp` | Codex CLI 为插件和技能市场临时检出的 Git 仓库副本，连同 .git 一起存 | 删掉后插件和市场要重新拉取一遍，config.toml 与已装的运行时不受影响<br>恢复：无需恢复；下次启动 codex 会重新检出 | **重下** |
| Claude Code 会话记录 | `~/.claude/projects` | Claude Code 按项目路径存的对话记录，一个项目一个目录，里面是一轮轮 jsonl | 删掉后这些项目里的历史对话不可再查<br>恢复：无法恢复；历史对话只此一份 | **不可恢复** |
| Qoder 会话工作区 | `~/.qoder/tmp` | Qoder 每个会话的临时工作区：工具调用的输出、抓下来的截图与图片附件、会话日志 | 删掉后旧会话里的截图和工具输出打不开，对话正文不受影响<br>恢复：无法恢复；正在跑的会话会另建自己那份 | **不可恢复** |
| Qoder 文件历史 | `~/.qoder/file-history` | Qoder 给 Agent 改过的文件留的版本快照，一个会话一个目录，每个文件按 @v1 @v2 逐版存 | 删掉后没法再逐版比对或回滚 Agent 改过的文件<br>恢复：无法恢复；此后 Agent 再改文件才会存新版本 | **不可恢复** |

## 开发工具

| 名称 | 路径 | 这是什么 | 删了会怎样 | 代价 |
| --- | --- | --- | --- | --- |
| [nvm 下载缓存](https://github.com/nvm-sh/nvm) | `~/.nvm/.cache` | nvm 下载过的 Node 安装包缓存 | 删掉后已安装的 Node 版本不受影响<br>恢复：无需恢复；需要时 nvm install 会重新下载 | **安全** |
| [npm 缓存目录](https://docs.npmjs.com/) | `~/.npm` | npm 的整个缓存目录，含 _cacache 那份内容寻址下载缓存 | 删掉后已装的全局包不受影响，下次安装会重新下载依赖<br>恢复：无需恢复；npm install 自动重建 | **安全** |
| tnpm 缓存 | `~/.tnpm` | 集团 npm 镜像（tnpm）的缓存目录 | 删掉后下次安装会重新下载<br>恢复：无需恢复；下次安装自动重建 | **安全** |
| npminstall 安装包 | `~/.npminstall_tarball` | npminstall 下载的 .tgz 安装包缓存 | 删掉后下次安装会重新下载<br>恢复：无需恢复；下次安装自动重建 | **安全** |
| [pnpm store](https://pnpm.io/) | `~/Library/pnpm/store` | pnpm 的全局包仓库，各项目通过硬链接复用 | 删掉后各项目 node_modules 里已链接的文件本体仍在，只是仓库清空<br>恢复：无需恢复；pnpm install 会重新下载缺失的包 | **安全** |
| [yarn 缓存](https://yarnpkg.com/) | `~/Library/Caches/Yarn` | yarn 的下载缓存 | 删掉后下次安装会重新下载<br>恢复：无需恢复；yarn install 自动重建 | **安全** |
| [bun 缓存](https://bun.sh/) | `~/.bun/install/cache` | bun 的安装缓存 | 删掉后下次安装会重新下载<br>恢复：无需恢复；bun install 自动重建 | **安全** |
| [Gradle 缓存](https://gradle.org/) | `~/.gradle/caches` | Gradle 的构建缓存与依赖仓库 | 删掉后下次构建要全量重新下载依赖（首次构建明显变慢）<br>恢复：无需恢复；下次构建自动重新下载，离线环境请先确认依赖仓库可用 | **安全** |
| [Maven 依赖仓库](https://maven.apache.org/) | `~/.m2/repository` | Maven 本地依赖仓库 ~/.m2/repository | 删掉后首次构建会全量重新下载（可能较慢）<br>恢复：无需恢复；构建时 Maven 按需重新下载，离线机器需先配置好镜像仓库 | **重下** |
| [pip 缓存](https://pip.pypa.io/) | `~/Library/Caches/pip` | pip 下载的源码包/轮子缓存 | 删掉后下次安装会重新下载<br>恢复：无需恢复；pip install 自动重建 | **安全** |
| [Homebrew 缓存](https://brew.sh/) | `~/Library/Caches/Homebrew` | brew 下载的安装包缓存 | 删掉不影响已安装的软件<br>恢复：无需恢复；重装时 brew 会重新下载 | **安全** |
| [conda 包缓存](https://docs.conda.io/) | `~/.conda/pkgs` | conda 的包缓存目录 pkgs | 删掉后已创建的环境不受影响<br>恢复：无需恢复；conda 会按需重新下载 | **安全** |
| [Xcode DerivedData](https://developer.apple.com/xcode/) | `~/Library/Developer/Xcode/DerivedData` | Xcode 每个项目的构建中间产物与索引 | 删掉后首次构建/索引会慢一次<br>恢复：无需恢复；下次打开项目 Xcode 自动重建 | **安全** |
| [Xcode 归档文件](https://developer.apple.com/xcode/) | `~/Library/Developer/Xcode/Archives` | Xcode 打包上传时生成的历史归档（.xcarchive） | 删掉后对应版本的归档没了，无法再导出该次打包的 ipa<br>恢复：无法直接恢复；如有上架/留存需求请先备份，或用同一代码提交重新打包 | **不可恢复** |
| [Xcode iOS DeviceSupport](https://developer.apple.com/xcode/) | `~/Library/Developer/Xcode/iOS DeviceSupport` | 真机调试时拷贝的旧系统版本调试符号 | 删掉后连旧系统真机调试要重新生成<br>恢复：无需恢复；连接对应系统的真机时 Xcode 会自动重新生成 | **重下** |
| [Xcode 模拟器设备](https://developer.apple.com/xcode/) | `~/Library/Developer/CoreSimulator/Devices` | 每台 iOS 模拟器的整机镜像，连同里面已装的 App 数据与登录态 | 删掉的模拟器下次启动是台空机器，里面的 App 和数据一起没了<br>恢复：无法直接恢复；需在 Xcode 里重新创建模拟器 | **不可恢复** |
| [模拟器内的系统资产](https://developer.apple.com/xcode/) | `~/Library/Developer/CoreSimulator/Devices/*/data/private/var/MobileAsset` | 模拟器按需下载的系统资产（Siri、语音识别等的 dmg），装在每台设备的 MobileAsset 里 | 删掉后对应功能在模拟器里首次使用时重新下载，模拟器和里面的 App 数据不受影响<br>恢复：无需恢复；系统需要时按需重新下载 | **重下** |
| [模拟器内的共享缓存](https://developer.apple.com/xcode/) | `~/Library/Developer/CoreSimulator/Devices/*/data/var/db/uuidtext` | 模拟器内各 App 共用的动态链接共享缓存与符号数据（uuidtext），由系统生成 | 删掉后模拟器下次启动会重新生成，首次启动稍慢<br>恢复：无需恢复；系统启动时自动重建 | **重下** |
| iOS 设备备份 | `~/Library/Application Support/MobileSync/Backup` | iPhone/iPad 通过这台电脑做的整机备份 | 删掉后这些历史备份没了，设备本身不受影响<br>恢复：已删的备份无法恢复；重新用数据线连接设备可再做一次全新备份 | **不可恢复** |
| [uv 下载缓存](https://docs.astral.sh/uv/reference/cli/#uv-cache-clean) | `~/.cache/uv` | uv 为 Python 依赖下载的包与预编译轮子 | 删掉后下次装环境会重新下载，慢一次<br>恢复：无需恢复；uv 下次运行自动重建 | **安全** |
| [Gradle 版本下载](https://docs.gradle.org/current/userguide/gradle_wrapper.html) | `~/.gradle/wrapper` | gradlew 按项目声明的版本下载下来的 Gradle 发行包 | 删掉后下次构建会重新下载对应版本<br>恢复：无需恢复；下次执行 ./gradlew 自动重下 | **安全** |
| [chrome-devtools-mcp 浏览器内核](https://github.com/ChromeDevTools/chrome-devtools-mcp) | `~/.cache/chrome-devtools-mcp` | chrome-devtools-mcp 为驱动浏览器下载的 Chrome for Testing | 删掉后这个 MCP 下次启动会重新下载浏览器<br>恢复：无需恢复；下次启动自动重新下载 | **安全** |
| [Hugging Face 模型缓存](https://huggingface.co/docs/huggingface_hub/guides/manage-cache) | `~/.cache/huggingface` | transformers / datasets 下载的模型与数据集，单个可达几十 GB | 删掉的模型要重新下载才能再用，受限模型还得再登录一次<br>恢复：无需恢复；按模型仓库名重新下载 | **重下** |
| [Whisper 模型缓存](https://github.com/openai/whisper) | `~/.cache/whisper` | openai-whisper 下载的语言模型权重 | 删掉后下次转写会重新下载模型<br>恢复：无需恢复；再次调用 whisper 自动下载 | **安全** |
| [cargo 注册表](https://doc.rust-lang.org/cargo/guide/why-cargo-directory.html) | `~/.cargo/registry` | cargo 拉取的 crates.io 索引与依赖源码 | 删掉后下次构建 Rust 项目要重新下载依赖<br>恢复：无需恢复；cargo build 自动重建 | **安全** |
| [IntelliJ IDEA 缓存](https://www.jetbrains.com/help/idea/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html) | `~/Library/Caches/JetBrains/IntelliJIdea*` | IntelliJ IDEA 建的索引、本地历史与编译缓存 | 删掉后首次打开项目要重建索引，工程配置不在这里<br>恢复：无需恢复；IDE 打开项目自动重建 | **安全** |
| [PyCharm 缓存](https://www.jetbrains.com/help/pycharm/directories-used-by-the-ide-to-store-settings-caches-plugins-and-logs.html) | `~/Library/Caches/JetBrains/PyCharm*` | PyCharm 建的索引、本地历史与编译缓存 | 删掉后首次打开项目要重建索引，工程配置不在这里<br>恢复：无需恢复；IDE 打开项目自动重建 | **安全** |
| [Android Studio 缓存](https://developer.android.com/studio/intro/studio-config) | `~/Library/Caches/Google/AndroidStudio*` | Android Studio 的索引、编译缓存与日志 | 删掉后首次打开项目要重建索引<br>恢复：无需恢复；IDE 自动重建 | **安全** |
| [Android 虚拟机镜像](https://developer.android.com/studio/run/emulator-commandline) | `~/.android/avd` | Android 虚拟机（AVD）的系统镜像与里面存的数据 | 这些虚拟机连同已装的 App 数据一起没了<br>恢复：无法直接恢复；需在 Device Manager 重新创建 | **不可恢复** |
| [Android SDK](https://developer.android.com/tools) | `~/Library/Android/sdk` | sdkmanager 装的 Android 平台、构建工具与系统镜像 | 删掉后所有安卓项目都构建不了，要重装整套 SDK<br>恢复：无法直接恢复；需用 sdkmanager 重新安装 | **重下** |
| [Go 模块缓存](https://go.dev/ref/mod#module-cache) | `~/go/pkg/mod` | go 下载的依赖模块源码 | 删掉后下次构建会重新下载依赖<br>恢复：无需恢复；go mod download 自动重建 | **安全** |
| [Go 构建缓存](https://pkg.go.dev/cmd/go#hdr-Build_cache) | `~/Library/Caches/go-build` | go 编译产生的中间产物 | 删掉后首次构建慢一次<br>恢复：无需恢复；go build 自动重建 | **安全** |
| [CocoaPods 缓存](https://guides.cocoapods.org/using/repo.html) | `~/Library/Caches/CocoaPods` | CocoaPods 下载的 pod 源码压缩包 | 删掉后下次 pod install 会重新下载<br>恢复：无需恢复；pod install 自动重下 | **安全** |
| [SwiftPM 缓存](https://www.swift.org/documentation/package-manager/) | `~/Library/Caches/org.swift.swiftpm` | Swift Package Manager 克隆下来的依赖仓库副本 | 删掉后首次解析依赖要重新克隆<br>恢复：无需恢复；Xcode 或 swift build 会自动重新获取 | **安全** |
| oMLX 本地模型 | `~/.omlx/models` | oMLX 拉下来的 MLX 格式模型权重，一个模型仓库一整份 | 删掉后这些模型不能再跑，已装好的 oMLX 本身不受影响<br>恢复：无需恢复；要用时 oMLX 会重新下载这十几 GB | **重下** |
| OrbStack 虚拟机磁盘 | `~/Library/Group Containers/*.dev.orbstack` | OrbStack 的 Linux 虚拟机磁盘镜像与交换文件，里面的容器、镜像、代码全装在这一个文件里（镜像看着有 460 GB，稀疏文件实占小得多） | 删掉后这台虚拟机连同里面的容器、镜像、代码全部消失<br>恢复：无法恢复；只能重建虚拟机并把环境重装一遍 | **不可恢复** |
| iOS 模拟器运行时 | `/System/Volumes/Data/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime` | 从 App Store 下载的 iOS 模拟器系统运行镜像（dmg），Xcode 靠它把模拟器跑起来 | 删掉后对应版本的模拟器跑不起来，Xcode 会要求重新下载<br>恢复：无需恢复；需要时在 Xcode 里重新下一次，几十 GB 起 | **重下** |
| ZCode 运行时数据 | `~/.zcode/cli` | ZCode 命令行留下的运行时数据：会话数据库、模型调用记录、生成产物、图片缓存 | 删掉会丢掉 ZCode 的会话历史与已生成的产物；日志和图片缓存能重建，数据库不能<br>恢复：无法恢复；只想腾地方的话，先删它下面的 log 和 image-cache | **不可恢复** |
| Hermes 升级前快照 | `~/.hermes/state-snapshots` | Hermes 升级前自动留下的状态快照，用来在新版出问题时回滚 | 删掉后就没法退回升级前那一版状态<br>恢复：无法恢复；确认新版跑得没问题之后，这一份就没用了 | **不可恢复** |
| [LM Studio 模型](https://lmstudio.ai/docs) | `~/.lmstudio/models` | LM Studio 下载到本地的模型权重，单个模型常常几个 GB | 删掉的模型要重新下载才能再用<br>恢复：无需恢复；在 LM Studio 里重新下载即可 | **重下** |
| [Jan 模型](https://jan.ai/docs) | `~/Library/Application Support/Jan/data/models` | Jan 下载到本地的模型权重，存放在它的数据目录里 | 删掉的模型要重新下载才能再用，对话记录不受影响<br>恢复：无需恢复；在 Jan 的模型页重新下载 | **重下** |
| [GPT4All 模型](https://docs.gpt4all.io/) | `~/Library/Application Support/nomic.ai/GPT4All` | GPT4All 下载到本地的模型权重，主要是 GGUF 格式 | 删掉的模型要重新下载才能再用<br>恢复：无需恢复；在 GPT4All 的下载页重新获取 | **重下** |
| [Draw Things 模型](https://drawthings.ai/) | `~/Library/Containers/com.liuliu.draw-things/Data/Documents/Models` | Draw Things 下载的生图模型，住在它的沙盒容器里 | 删掉的模型要重新下载才能再用，作品不受影响<br>恢复：无需恢复；在 Draw Things 的模型页重新下载 | **重下** |
| [DiffusionBee 模型](https://diffusionbee.com/) | `~/.diffusionbee/downloads` | DiffusionBee 下载的 Stable Diffusion 模型文件 | 删掉的模型要重新下载才能再用<br>恢复：无需恢复；在 DiffusionBee 里重新下载 | **重下** |
| [llama.cpp 模型缓存](https://github.com/ggml-org/llama.cpp) | `~/.cache/llama.cpp` | llama-run 等命令下载的 GGUF 模型，默认放在用户缓存目录 | 删掉的模型下次运行时要重新下载<br>恢复：无需恢复；llama-run 会按需重新下载 | **重下** |
| [PyTorch Hub 缓存](https://pytorch.org/docs/stable/hub.html) | `~/.cache/torch` | torch.hub 下载的预训练模型与代码 | 删掉后下次加载同个模型会重新下载<br>恢复：无需恢复；torch.hub.load 会自动重新下载 | **安全** |
| ZCode 内嵌浏览器网页缓存 | `~/Library/Application Support/ZCode/session/Partitions/*/Cache` | ZCode 内嵌浏览器各分区攒下的网页资源缓存，光一个分区就能到 1 GB | 删掉不影响任何功能，只是网页要重新下载一遍资源<br>恢复：无需恢复；打开过的网页会自动重新缓存 | **安全** |
| ZCode 内嵌浏览器脚本缓存 | `~/Library/Application Support/ZCode/session/Partitions/*/Code Cache` | ZCode 内嵌浏览器编译过的脚本与样式缓存 | 删掉不影响任何功能，只是网页首次打开要重新编译一遍<br>恢复：无需恢复；再次打开网页时自动重建 | **安全** |

## 应用缓存与系统日志

| 名称 | 路径 | 这是什么 | 删了会怎样 | 代价 |
| --- | --- | --- | --- | --- |
| Chrome 崩溃转储 | `~/Library/Application Support/Google/Chrome/Crashpad/pending` | Chrome 崩溃时生成的报告文件堆积 | 删掉不影响任何功能<br>恢复：无需恢复；下次程序崩溃会自动生成新的报告 | **安全** |
| 系统崩溃诊断报告 | `~/Library/Logs/DiagnosticReports` | DiagnosticReports，系统与应用的崩溃诊断日志 | 删掉不影响系统运行<br>恢复：无需恢复；有新崩溃时系统会自动写入新报告 | **安全** |
| [Docker 数据](https://www.docker.com/) | `~/Library/Containers/com.docker.docker` | Docker Desktop 的镜像、容器与卷数据 | 删掉等于清空全部本地镜像和容器<br>恢复：无法逐项恢复；重新打开 Docker Desktop 后可重新拉取镜像、重建容器。更稳妥的做法是在 Docker Desktop 里清理 | **不可恢复** |
| 应用缓存总目录 | `~/Library/Caches` | ~/Library/Caches，各应用的缓存总目录 | 删掉后各应用首次启动会变慢，随后自行重建<br>恢复：无需恢复；应用启动后自动重建 | **重下** |
| 应用日志 | `~/Library/Logs` | ~/Library/Logs，应用写下的日志文件 | 删掉后旧日志找不回来，不影响使用<br>恢复：旧日志无法恢复；应用会继续写入新日志 | **安全** |
| 废纸篓 | `~/.Trash` | 访达废纸篓里等你确认的东西 | 清空后才真正释放空间，清空后不可恢复<br>恢复：清空前随时可在访达里把文件拖回原位置 | **不可恢复** |

## 国产 App

| 名称 | 路径 | 这是什么 | 删了会怎样 | 代价 |
| --- | --- | --- | --- | --- |
| 微信缓存 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/users/*/xworker` | 小程序、搜一搜等内嵌组件的运行包（按账号存放） | 不影响聊天记录和登录状态；下次打开对应小程序时微信会重新下载<br>恢复：无需恢复；微信按需重新下载 | **安全** |
| 微信小程序公共库 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/users/*/applet/publicLib` | 各小程序共用的基础运行库（一份带版本号的包） | 不影响聊天记录；打开小程序时微信会重新下载<br>恢复：无需恢复；微信按需重新下载 | **安全** |
| 微信网页缓存 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/radium/web/profiles/*/Cache` | 微信内置浏览器（朋友圈、文章、网页）的 HTTP 缓存 | 登录状态不在这一层目录里；网页重新打开时重新加载<br>恢复：无需恢复；微信会按需重建 | **安全** |
| 微信日志 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/log` | 微信自己记录的运行日志（按日期的 .xlog，用于排查问题） | 不影响功能与聊天记录；只是之后回看不了这段日志<br>恢复：无需恢复；微信会继续新建日志 | **安全** |
| 微信图片缓存 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/*/cache` | 聊天与朋友圈浏览时留下的图片、表情缓存（同一张图的原件在 msg 目录下，这里是显示用的副本） | 聊天记录与图片原件都不受影响；重新打开时这些副本会再建一次<br>恢复：无需恢复；微信按需重建 | **安全** |
| 微信临时文件 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/*/temp` | 收发过程中留下的临时文件（ImageTemp 等，按账号存放） | 不影响已保存的聊天记录<br>恢复：无需恢复；微信会自动重建 | **安全** |
| 微信插件运行包 | `~/Library/Containers/com.tencent.xinWeChat/Data/Documents/app_data/xplugin/plugins/Magicdy/*` | 微信插件的运行包，内含通话、多媒体、传输等运行库；升级后可能同时留着多个版本，每个版本都是一份完整运行库 | 正在使用的版本删掉后这些功能会异常，需要重启微信；被删的版本下次用到时重新下载<br>恢复：建议先退出微信再删；微信会在需要时重新下载 | **重下** |
| QQ 缓存 | `~/Library/Containers/com.tencent.qq/Data/Library/Caches` | QQ 在电脑上的临时缓存 | 删掉不影响聊天记录和登录状态<br>恢复：无需恢复；QQ 会按需自动重建 | **安全** |
| QQ 聊天图片视频 | `~/Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ/nt_qq_*/nt_data` | 新版 QQ 的聊天图片、视频、文件数据（按账号存放） | 聊天记录文字还在；图片和视频重新点开需要重新下载<br>恢复：无法本地恢复；在手机 QQ 的对应聊天里点开即可重新下载 | **不可恢复** |
| 钉钉缓存 | `~/Library/Caches/com.alibaba.DingTalkMac` | 钉钉在电脑上的临时缓存 | 删掉不影响聊天记录和登录状态<br>恢复：无需恢复；钉钉会按需自动重建 | **安全** |
| 钉钉日志 | `~/Library/Application Support/*[Dd]ing[Tt]alk*/log` | 钉钉写入的运行日志（本机实测常见几百 MB） | 删掉后旧日志找不回来，不影响使用<br>恢复：旧日志无法恢复；钉钉会继续写新日志 | **安全** |
| 钉钉聊天数据 | `~/Library/Application Support/*[Dd]ing[Tt]alk*/*_v[0-9]*` | 钉钉按账号存放的聊天图片、视频与文件数据 | 聊天记录文字还在；图片和视频重新点开需要重新下载，本地文件原件会没<br>恢复：无法本地恢复；在手机钉钉的对应聊天里重新下载（未过期部分） | **不可恢复** |
| 企业微信缓存 | `~/Library/Containers/com.tencent.WeWork/Data/Library/Caches` | 企业微信在电脑上的临时缓存 | 删掉不影响聊天记录和登录状态<br>恢复：无需恢复；企业微信会按需自动重建 | **安全** |
| 企业微信聊天数据 | `~/Library/Containers/com.tencent.WeWork/Data/Library/Application Support/WXWork/*/Cache` | 企业微信按账号存放的聊天图片、视频与文件数据 | 聊天记录文字还在；图片和视频重新点开需要重新下载<br>恢复：无法本地恢复；在手机企业微信的对应聊天里重新下载 | **不可恢复** |

---

这份文档由 `build_app/make_safety_doc.py` 从 `safety_db.json` 生成，别直接改它。要补条目或改说法，改 JSON 然后重新生成：

```sh
python3 build_app/make_safety_doc.py
```

知识库版本 1，更新于 2026-10-17。缺了你常用工具的缓存路径？提个 PR 把它加进 JSON 就行。
