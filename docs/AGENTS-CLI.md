# DiskWise for AI agents — CLI 与 MCP 安全模型

`diskwise` 是 DiskWise 的命令行形态（直装版随 App 附带；App Store 沙盒版不带）。
它把 App 的清理能力开放给终端与 AI agent（Claude Code、Cursor、Codex……），
但安全模型原封不动，且对 agent **更严**：

> **它不能 `rm -rf`。** 唯一的删除路径是把东西移进废纸篓，且每次操作都可整单撤销。

## 安全模型

**四档判词**（与 App 同一知识库，`safety_db.json`，现 80 条）：

| tier | 含义 | agent 能动吗 | `--i-am-human` 能动吗 |
|---|---|---|---|
| `safe` | 删了没影响，会自动重建（DerivedData、pip 缓存…） | ✅ | ✅ |
| `redo` | 认得，删了要重新下载（模型权重、依赖仓库…） | ✅（须用户同意计划） | ✅ |
| `risky` | 删了就真没了（模拟器设备、聊天记录…） | ❌ | ❌（谁都不行） |
| `unknown` | 知识库不认识（没命中 ≠ 安全） | ❌ | ✅ |

**agent 额外的三道闸**（人用 App 时没有的）：

1. **只动认识的位置本体**：agent 点名的路径必须就是知识库条目（或其通配实例）。
   缓存目录里用户自己建的子文件夹会拒（`not_a_known_location`）——人可以动它
   （App 下钻页同款自由），agent 不行。
2. **两步确认**：`plan` 生成计划文件（**10 分钟有效**、最多 **200 项 / 200 GB**），
   `trash` 只认 plan_id、不收裸路径；执行时**逐项重跑判定管线并核对 inode**——
   计划生成之后路径被换成软链（`symlink`）或原地换过内容（`changed_since_plan`）
   都会被当场拦下。
3. **持久留痕**：每次执行追加一行 `operations.jsonl`（只追加、永不改写），
   `undo` 按日志整单恢复；废纸篓里已被清掉的项报 `gone_from_trash`，不影响其余。

判定管线（所有入口共用，顺序固定）：路径展开 → 保护路径（`~/Documents`、`/`…）
→ 范围（家目录、`/Applications`、`/tmp`、`/var/tmp` 之外不动）→ lstat（不存在 /
软链拒绝）→ 知识库判词 → 放行。MCP 模式下**不存在** `--i-am-human`。

## 命令

```
diskwise report [--min 200MB] [--stale-days 90] [--json]   # 一次给完：账 + 建议
diskwise overview [--json]                    # 只给整盘账：空间到底去哪了
diskwise scan [--category all|dev|ai_models|apps] [--min 100MB] [--json]
diskwise project-assets [--roots DIR...] [--min 100MB] [--stale-days 90] [--json]
diskwise unused [--min 200MB] [--stale-days 90] [--roots DIR...] [--json]
diskwise grant-access                        # 打开完全磁盘访问授权页
diskwise explain <path> [--json]
diskwise plan <path>... [--i-am-human] [--json]
diskwise trash --plan <plan_id> [--json]     # 只认 plan_id
diskwise undo [<operation_id>] [--json]
diskwise history [--limit 20] [--json]
diskwise mcp                                 # stdio MCP server
diskwise --version
```

- stdout 只放结果（agent 解析它），日志走 stderr；`--json` 键为 snake_case、时间 ISO8601；
- 退出码：`0` 成功 · `1` 参数错误 · `2` 有项被拒（部分成功也是 2，明细在输出里）· `3` 计划过期或不存在；
- 大小参数十进制（`500MB`、`2GB`、纯字节），与 App 同口径。

`scan` 的结果由两路合并：**知识库词条**（人写的安全知识）加**签名发现**（引擎自管缓存按
布局认：HuggingFace 布局的模型仓、散装模型权重、更新器下载缓存——不管它长在家目录还是某个
项目的 var 里，`HF_HOME` 挪走的也算）。每项带 `source` 字段（`knowledge_base` |
`signature`）。签名项 tier 封顶 redo、`agent_may_trash` 恒 false——agent 契约不变，
`--i-am-human` 可以带走。

状态目录：`~/Library/Application Support/DiskWise/agent/`（`plans/` 计划文件、
`operations.jsonl` 操作日志）。每行操作记录**来源客户端**——MCP 按 initialize 里
自报的 `clientInfo.name`（如 claude-code），终端默认 `diskwise-cli`；不带该字段的
旧日志行视为未知来源。CLI 单写者假设：同一时刻只跑一个写操作。

## 接入你的 AI 工具

`diskwise mcp` 是标准的 stdio MCP server——任何能挂**本地 stdio 服务**的客户端都接得动。
各家不变的只有两件事：这个二进制的**绝对路径**，和参数 **`mcp`**；变的是方言。所以下面按客户端
分列，别把一家的写法粘进另一家。路径按 App 实际安装位置写，装在别处就把那一处路径整段换掉。

下表之外的客户端同样在支持范围内：本地 stdio 这一段走的是 MCP 标准协议，服务端这边按协议逐条
实测过（`initialize` / `tools/list` / `tools/call`，换行分隔的 JSON）。所以**接不上按客户端那边的
实现问题处理**——欢迎开 issue 或提 PR，附上客户端名与版本、你写进去的那段配置原文，以及直接跑
`"<路径>" mcp` 时它收到的输出。

| 客户端 | 放在哪儿 | 本机实测（2026-10-10） |
|---|---|---|
| Claude Code | 终端一条命令 | ✔ Connected |
| Qoder | CLI 一条命令，或 IDE 设置里粘 JSON | ✓ Connected |
| OpenCode | `opencode.json` | ✓ connected |
| Codex CLI | 终端一条命令，或 `~/.codex/config.toml` | 登记成功（它 list 时不握手） |
| Cursor | `~/.cursor/mcp.json` | 本机未装，按官方文档写 |
| Zed | `~/.config/zed/settings.json` 的 `context_servers` | 本机未装，按官方文档写 |
| ZCode | `~/.zcode/cli/config.json` 的 `mcp.servers` | 本机未装，按官方文档写 |
| Claude 桌面版 | `~/Library/Application Support/Claude/claude_desktop_config.json` | 本机未装，按官方文档写 |

### Claude Code

```sh
claude mcp add diskwise -- "/Applications/DiskWise.app/Contents/MacOS/diskwise" mcp
```

加到项目里（`--scope project`）时，还要在那个目录里进一次 `claude` 批准，服务才真启动——
实测新目录 add 完 `claude mcp list` 回的是「⏸ Pending approval」。

### Codex CLI

```sh
codex mcp add diskwise -- "/Applications/DiskWise.app/Contents/MacOS/diskwise" mcp
```

或直接写 `~/.codex/config.toml`：

```toml
[mcp_servers.diskwise]
command = "/Applications/DiskWise.app/Contents/MacOS/diskwise"
args = ["mcp"]
```

`codex mcp list` 只报登记状态、不发起握手，所以那里看不到「连上了没」，跑一次会话才算。

### Qoder

命令行（默认只作用于当前目录；`--scope project` 才写进项目的 `.mcp.json`）：

```sh
qoder mcp add diskwise -- "/Applications/DiskWise.app/Contents/MacOS/diskwise" mcp
```

或在 IDE 里：`⌘⇧,` → Qoder 设置 → MCP → 我的服务 → ＋ 添加，粘这段：

```json
{
  "mcpServers": {
    "diskwise": {
      "command": "/Applications/DiskWise.app/Contents/MacOS/diskwise",
      "args": ["mcp"]
    }
  }
}
```

### Cursor

`~/.cursor/mcp.json`（或项目里的 `.cursor/mcp.json`）：

```json
{
  "mcpServers": {
    "diskwise": {
      "type": "stdio",
      "command": "/Applications/DiskWise.app/Contents/MacOS/diskwise",
      "args": ["mcp"]
    }
  }
}
```

官方字段表要求写 `type`，它自己的示例片段里却省着——照这里写全就不会错。`command` 必须是
完整路径或系统 PATH 上有的程序。

### OpenCode

`~/.config/opencode/opencode.json`（或项目根目录的 `opencode.json`）：

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "diskwise": {
      "type": "local",
      "command": ["/Applications/DiskWise.app/Contents/MacOS/diskwise", "mcp"],
      "enabled": true
    }
  }
}
```

三处和别家不一样，照抄别家的写法起不来：`type` 必须是 `"local"`、`command` 是**数组**
（程序和参数在同一个方括号里）、环境变量那个键叫 `environment` 而不是 `env`。

### Zed

`~/.config/zed/settings.json`：

```json
{
  "context_servers": {
    "diskwise": {
      "command": "/Applications/DiskWise.app/Contents/MacOS/diskwise",
      "args": ["mcp"]
    }
  }
}
```

是 `context_servers`，不是 `agent_servers`——后者用来挂外部编码 agent，挂 MCP 服务进去不会生效。

### ZCode

`~/.zcode/cli/config.json`（项目级是 `<项目根>/.zcode/config.json`，两处的目录深度不一样）：

```json
{
  "mcp": {
    "servers": {
      "diskwise": {
        "command": "/Applications/DiskWise.app/Contents/MacOS/diskwise",
        "args": ["mcp"]
      }
    }
  }
}
```

它的设置里也能直接从 Claude Code / Codex / OpenCode 的现有配置导入；另外它默认不吃系统的
`HTTP_PROXY`，走代理的机器上注意这点。

### Claude 桌面版

`~/Library/Application Support/Claude/claude_desktop_config.json`：

```json
{
  "mcpServers": {
    "diskwise": {
      "command": "/Applications/DiskWise.app/Contents/MacOS/diskwise",
      "args": ["mcp"]
    }
  }
}
```

改完要**完全退出**再打开（不是关窗口）。新版官方更推 `.mcpb` 扩展包那条路，手写配置仍然支持。

Homebrew 用户：cask 提供 `diskwise` 命令（发新版起加入 `binary` 一行后），
上述所有配置里的路径都可以换成 `/opt/homebrew/bin/diskwise`。

## MCP 工具

| 工具 | 说明 |
|---|---|
| `disk_overview()` | 只读：整盘账——每块空间都有归属（闭合账，没有「没量到」的黑洞）、按体积排序的位置清单、以及一个 `access` 字段：哪些目录因权限读不到、当前有没有完全磁盘访问、下一步怎么授权。回答「磁盘空间都去哪了」用它 |
| `open_access_settings()` | 打开系统设置「隐私与安全性 → 完全磁盘访问权限」。当 `disk_overview` 报读不到的目录时调它——macOS 不允许程序自己授权，必须由人勾；勾完要**重启 MCP server** 新权限才生效，然后重扫 |
| `scan_disk(category?, min_bytes?)` | 只读：**只能删的清单**——知识库认识的位置，不是整盘用量。它的合计远小于盘的已用空间，这是设计如此；要查空间去向用 `disk_overview` |
| `scan_project_assets(roots?, min_bytes?, stale_days?)` | 只读：**白名单看不到的那部分**——项目内部的可再生资产（模型权重、node_modules、.venv、构建产物、历史跑分）。按 inode 去重硬链接（HuggingFace 的 snapshots/blobs 只算一次），每个资产带大小、多久没动（stale_days）、类型和恢复方式。回答「过期的、不是缓存的垃圾在哪」用它，通常比 `scan_disk` 挖出的多。把报出的路径交给 `plan_cleanup` 才真正腾空间 |
| `scan_unused(roots?, min_bytes?, stale_days?)` | 只读：**建议层**——很久没打开的应用、旧会话历史、备份/快照、同一工具的多个版本、装完没删的安装包、没人管的旧项目、应用卸载后留下的数据、废纸篓。每条带 `recommend`：`safe`（删了不丢东西）/ `review`（大概率没用但存着数据）/ `keep`（在用或太新）/ `blocked`（真的动不了，附 `blocked_reason` 与 `user_action`）。体积是物理占盘，稀疏项另有标注。**只给建议，不删任何东西** |
| `explain_path(path)` | 只读：一个路径的完整画像与拒绝原因 |
| `plan_cleanup(paths[])` | 只读：生成计划。**description 要求模型把摘要给用户看、取得同意后再执行** |
| `execute_cleanup(plan_id)` | 按计划移入废纸篓（可撤销，`destructiveHint: false`） |
| `undo_cleanup(operation_id?)` | 整单恢复 |
| `cleanup_history(limit?)` | 只读：最近操作 |
| `diag_coverage()` | 只读：诊断转储的定向发现——命中清单 + 动不了的观察位置（原因码与拒绝词同源） |
| `diag_velocity()` | 只读：每个崩溃转储条目「本次 vs 上一轮」的增长差；`tier: fast`（突发）/ `growth`（长间隔累积） |
| `diag_probe(path)` | 只读：一个崩溃转储目录的内容归属（读样本文件头 64 KB，指纹永远脱敏输出）。本地「内容探针」开关关闭时拒绝 |

**四个工具各管一段，别拿错**：
- `disk_overview` 回答「盘满是因为什么」（整盘量体积，每块有归属）。
- `scan_disk` 回答「哪些缓存能安全删」（知识库白名单固定路径）。
- `scan_project_assets` 回答「项目里那些过期的、非缓存的东西能不能删」（模型权重、依赖、构建产物、旧跑分）——这部分白名单永远扫不到，在一台开发机上常常是最大的可腾空间。
- `scan_unused` 回答「还有什么是我不要了的」（应用、会话、备份、旧版本、安装包、旧项目）——它给结论，不动手。

`scan_disk` 在 500 GB 的盘上常常只报几十 GB，那不是漏扫——它本来就只管白名单里那部分。
把它的合计当成盘的已用空间，或当成全部可删空间，都会得出错误结论。
**要列全「能删什么」，三个都要调**：`scan_disk` + `scan_project_assets` + `scan_unused`；
`disk_overview` 只是空间去向账。四个工具的 description 和返回文本里都写明了边界。

`scan_unused` 的关键口径：
- 体积是物理占盘（`physical_bytes`，st_blocks×512），另给 `logical_bytes`。两者差一个量级就是稀疏
  文件（虚拟机磁盘、预留日志）——删它腾不出它号称的那么多，返回里会直接写明。
- `stale_days` 一定配 `stale_basis`：`file_mtime`（按内部最新文件）/ `container_date`（按备份/快照
  容器自身的日期）/ `last_used_date`（按系统记的上次打开）。**备份目录必须看 container_date**——
  快照里的文件保留着原始旧时间，按文件时间判会把昨天刚备份的记忆说成两年前的老东西。
- 应用的上次打开时间在 macOS 上经常是 `(null)`，而且偶尔是假的（索引活动会刷新它）。拿不到就退回
  文件时间并在 `why` 里说明，不编一个日期。
- `blocked_reason` 是枚举：`needs_fda` / `needs_admin` / `sip` / `readonly_volume` / `in_use` /
  `functional_dependency`。`user_action` 写明人该怎么处理；「需要管理员密码」不算删不掉——那只是
  要人自己输一次密码。
- **系统缓存（`kind` 为 `system_index` / `version_history`）的量出 0 字节不等于空的。**
  `/System/Volumes/Data/.Spotlight-V100`、`.DocumentRevisions-V100`、`.fseventsd` 的所有者是
  root 或 `_mds_stores`，普通权限读不到体积，返回 `blocked_reason: needs_admin` 并在 `user_action`
  里给出 `sudo` 测量命令。**不要因为 0 字节就跳过这一条**——实测一台机器上 Spotlight 索引涨到
  47 GB（三百万文件正常 2~5 GB），是整机最大的单块可清项，而它既不在家目录、也不在任何应用的
  缓存路径，只有这类专门的探测能看到。
- 判断索引该不该清，看的是**比它该有的大多少**，不是「多久没动」：索引天天在写，按时间判会判成
  「刚用过」。超过 8 GB（索引）/ 2 GB（版本历史）才提示。
- 清 Spotlight 索引必须用完整序列：`sudo mdutil -i off / && sudo killall mds mds_stores;
  sudo rm -rf <path>; sudo mdutil -i on /`。**`sudo mdutil -E /` 单独用不够**——它只标记重建，
  旧索引原地不动，空间一个字节都不回来（实测还新写了 6 GB）。`user_action` 里已经写死这一点，
  照抄即可。

`scan_project_assets` 的关键口径：
- 硬链接按 APFS 文件 ID 去重——HuggingFace 的 `snapshots/` 和 `blobs/` 共享块，只算一次；
  删除时必须删整个 `hf/hub`，只删 snapshots 不会真正释放空间（返回里写明了）。
- `stale_days` 过滤「至少 N 天没动过」的资产（按目录内最新文件算）。传 90 只看真正陈旧的。
- `roots` 默认扫家目录顶层（不含 Library，那是 `scan_disk` 的地盘）；可传绝对目录数组缩小范围、提速。
- `state/`、`runtime/` 这类运行数据不归为资产，不会出现在这个工具里——它们不是可再生的。

业务错误（被拒、过期、超限）以 `isError: true` 的结果返回并附下一步指引
（例如 `plan_expired` → 重新 `plan_cleanup`）。

**读不全时怎么办**：`disk_overview` 的每个位置带 `need_full_disk_access` / `need_admin`
（读不到的目录**个数**，不是字节——读不到就没法编一个体积）。整体状态在 `access`：
`has_full_disk_access`、`need_full_disk_access_dirs`、`need_admin_dirs`、`next_step`、`settings_url`。
看到非 0 就告诉用户「这些目录读不到，所以报的体积是下限」，然后调 `open_access_settings`
打开授权页。关键顺序：**用户勾完 → 重启 MCP server → 重扫**，macOS 只把授权给到新进程。
`need_admin_dirs` 是 root 或其他用户才能读的（系统数据、别人的家目录），不归这个授权管，
也不该删——如实报，别承诺能修。CLI 里同样的动作是 `diskwise grant-access`。

诊断三工具的边界：**只读，不提供删除或修剪**。一次性清理仍走 `plan_cleanup` / `execute_cleanup`
那条两步确认的链路；「按保留策略修剪」是 App 内的人工动作，不进 agent 通道——
agent 看见增长可以报告，动手的是人。

## 一段真实对话（Claude Code + diskwise MCP）

> **我**：看看我的 Mac 哪里能清
>
> **assistant**（调 `scan_disk`）：
> 扫描结果（category=dev，min_bytes=100000000）：
> - 总共 30 处；agent 能动 23 处，合计约 57.7 GB；
> - 最大三项：OrbStack 虚拟机磁盘 19.7 GB（`may_lose_data`，不能动）、
>   Ollama 模型 17.7 GB（`redo`，能动能撤销）、iOS 模拟器运行时 16.6 GB
>   （系统区，`outside_allowed`）。
> 要清哪些？
>
> **我**：把 Ollama 和 oMLX 的模型清了吧
>
> **assistant**（调 `plan_cleanup`）：
> 计划已生成，两项合计 31.4 GB，进废纸篓（可随时撤销）：
> `~/.ollama/models` 17.7 GB · `~/.omlx/models` 13.7 GB。确认执行吗？
>
> **我**：可以
>
> **assistant**（调 `execute_cleanup`）：
> 已移入废纸篓，腾出 31.4 GB。后悔的话说一声，我用 undo_cleanup 原样放回。

## 维护备注

- 直装版打包：`build_app/build.sh` 会把 CLI 编进 `Contents/MacOS/diskwise`，
  **先单独签嵌套二进制、再签整包**（两个签名分支都如此），并在签名后冒烟
  `diskwise --version`；App Store 分支不拷贝 CLI。
- 发新版时 cask 需加一行：`binary "#{appdir}/DiskWise.app/Contents/MacOS/diskwise"`
  （连同 version / sha256 一起更新；当前未加，因为线上最后一个 DMG 里还没有这个二进制）。
- 词表：CLI/MCP 面向 agent 的解释字段走 `en.lproj/Localizable.strings` 查表，
  查不到回落中文原文；`DISKWISE_RESOURCES` 环境变量可覆盖资源目录（测试用）。
